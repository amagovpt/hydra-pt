#!/usr/bin/env bash
# Backup completo dos Postgres do dados.gov.pt que correm em Docker neste host.
#
#   hydra-pt-database-1      (PG15, :5432)  hydra: catalog, checks, ...
#   hydra-pt-database-csv-1  (PG15, :5434)  tabular (tabelas <hash>, tables_index) + schema metric
#   airflow-db-local-metrics (PG12)         metadata do Airflow (sem dados de xcom)
#
# Por cada container: globals (roles, sem passwords) + um dump -Fc por base de dados,
# feitos com o pg_dump da própria imagem do container (versão sempre igual à do servidor).
# Gera MANIFEST, stats (contagens de objetos/linhas, para validar o restore) e SHA256SUMS.
# O backup é escrito em <dir>.tmp e só é renomeado no fim se tudo correr bem.
#
# Uso:  scripts/db-backup.sh [--quiesce]
#   --quiesce  para o container do hydra durante o dump (as duas BDs ficam coerentes entre si);
#              volta a arrancá-lo no fim, mesmo em caso de erro.
#
# Variáveis: BACKUP_ROOT (/opt/backups/postgres), RETENTION_DAYS (7), CONTAINERS,
#            HYDRA_APP_CONTAINER (hydra-pt-hydra-1), EXCLUDE_TABLE_DATA (xcom).
set -Eeuo pipefail

BACKUP_ROOT=${BACKUP_ROOT:-/opt/backups/postgres}
RETENTION_DAYS=${RETENTION_DAYS:-7}
# A ordem conta: a BD do hydra antes da csv, para os checks não apontarem para tabelas
# criadas depois do dump (tabelas órfãs na csv são inofensivas, o contrário não).
CONTAINERS=${CONTAINERS:-"hydra-pt-database-1 hydra-pt-database-csv-1 airflow-db-local-metrics"}
HYDRA_APP_CONTAINER=${HYDRA_APP_CONTAINER:-hydra-pt-hydra-1}
# xcom só tem payloads transitórios das DAGs (1,8 GB); fica a estrutura, sem dados.
EXCLUDE_TABLE_DATA=${EXCLUDE_TABLE_DATA:-xcom}

QUIESCE=0
for arg in "$@"; do
  case $arg in
    --quiesce) QUIESCE=1 ;;
    -h|--help) sed -n '2,22p' "$0"; exit 0 ;;
    *) echo "Argumento desconhecido: $arg" >&2; exit 2 ;;
  esac
done

log() { echo "[$(date '+%F %T')] $*"; }
die() { log "ERRO: $*" >&2; exit 1; }

pg_user()  { docker exec "$1" printenv POSTGRES_USER 2>/dev/null || echo postgres; }
pg_image() { docker inspect -f '{{.Config.Image}}' "$1"; }
# psql_q: comandos com -c (não lê stdin, seguro dentro de loops "while read");
# psql_in: SQL lido do stdin (necessário para variáveis :'x' do psql).
psql_q()  { local c=$1 db=$2; shift 2; docker exec "$c" psql -U "$(pg_user "$c")" -d "$db" -v ON_ERROR_STOP=1 -AtX -F $'\t' "$@"; }
psql_in() { local c=$1 db=$2; shift 2; docker exec -i "$c" psql -U "$(pg_user "$c")" -d "$db" -v ON_ERROR_STOP=1 -AtX -F $'\t' "$@"; }

# pg_dump num container temporário com a imagem e a rede do container alvo, a escrever
# diretamente num ficheiro montado (dump seekable => pg_restore -j funciona).
sidecar() {
  local c=$1; shift
  PGPASSWORD=$(docker exec "$c" printenv POSTGRES_PASSWORD 2>/dev/null || true) \
  docker run --rm --network "container:$c" -u "$(id -u):$(id -g)" \
    -e PGPASSWORD -e PGHOST=127.0.0.1 -e PGUSER="$(pg_user "$c")" \
    -v "$WORK:/backup" "$(pg_image "$c")" "$@"
}

STATS_SQL=$(cat <<'SQL'
select 'obj', 'relkind_' || c.relkind::text, count(*)
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
 where n.nspname not in ('pg_catalog', 'information_schema') and n.nspname !~ '^pg_(toast|temp)'
 group by c.relkind
union all
select 'obj', 'functions', count(*)
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
 where n.nspname not in ('pg_catalog', 'information_schema')
union all select 'obj', 'event_triggers', count(*) from pg_event_trigger
union all select 'obj', 'extensions', count(*) from pg_extension
order by 2;
SQL
)

# Contagem exata por tabela/matview; as tabelas do tabular (nome = hash md5) vão somadas numa linha.
ROWS_SQL=$(cat <<'SQL'
with rels as (
  select n.nspname, c.relname, c.relname ~ '^[0-9a-f]{32}$' as tabular
    from pg_class c join pg_namespace n on n.oid = c.relnamespace
   where c.relkind in ('r', 'p', 'm')
     and n.nspname not in ('pg_catalog', 'information_schema') and n.nspname !~ '^pg_(toast|temp)'
     and c.relname <> all (string_to_array(:'excl', ','))
), counts as (
  select nspname, relname, tabular,
         (xpath('/row/c/text()', query_to_xml(format('select count(*) as c from %I.%I', nspname, relname), false, true, '')))[1]::text::bigint as n
    from rels
)
select 'rows', format('%I.%I', nspname, relname), n from counts where not tabular
union all
select 'rows', '(tabular: ' || count(*) || ' tabelas)', coalesce(sum(n), 0) from counts where tabular having count(*) > 0
order by 2;
SQL
)

mkdir -p "$BACKUP_ROOT"
exec 9>"$BACKUP_ROOT/.lock"
flock -n 9 || die "já existe um backup a correr (lock $BACKUP_ROOT/.lock)"

TS=$(date '+%Y%m%dT%H%M%S')
FINAL="$BACKUP_ROOT/$TS"
WORK="$FINAL.tmp"
mkdir "$WORK"

HYDRA_STOPPED=0
cleanup() {
  local rc=$?
  if (( HYDRA_STOPPED )); then
    log "a arrancar $HYDRA_APP_CONTAINER"
    docker start "$HYDRA_APP_CONTAINER" >/dev/null || log "AVISO: falhou docker start $HYDRA_APP_CONTAINER"
  fi
  if (( rc != 0 )) && [[ -d $WORK ]]; then
    log "backup falhou (rc=$rc); a remover $WORK"
    rm -rf "$WORK"
  fi
}
trap cleanup EXIT

# --- verificações prévias -------------------------------------------------------------
needed=0
for c in $CONTAINERS; do
  [[ $(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null) == true ]] || die "container $c não está a correr"
  needed=$(( needed + $(psql_q "$c" postgres -c "select sum(pg_database_size(datname)) from pg_database where not datistemplate") ))
done
avail=$(( $(df --output=avail -B1 "$BACKUP_ROOT" | tail -1) ))
# Os dumps comprimidos ficam bem abaixo do tamanho das BDs; exigir esse tamanho dá folga.
(( avail > needed )) || die "espaço insuficiente em $BACKUP_ROOT: $((avail>>20)) MB livres, ~$((needed>>20)) MB necessários"
log "backup -> $FINAL (BDs somam $((needed>>20)) MB, livres $((avail>>20)) MB)"

if (( QUIESCE )) && [[ $(docker inspect -f '{{.State.Running}}' "$HYDRA_APP_CONTAINER" 2>/dev/null) == true ]]; then
  log "a parar $HYDRA_APP_CONTAINER durante o dump (--quiesce)"
  docker stop -t 60 "$HYDRA_APP_CONTAINER" >/dev/null
  HYDRA_STOPPED=1
fi

{
  echo "# created=$TS host=$(hostname) quiesced=$QUIESCE exclude_table_data=$EXCLUDE_TABLE_DATA"
  printf '#%s\t%s\t%s\t%s\t%s\t%s\t%s\n' container database file pg_major collate ctype size_bytes
} > "$WORK/MANIFEST"

# --- dumps ------------------------------------------------------------------------------
for c in $CONTAINERS; do
  major=$(psql_q "$c" postgres -c "select current_setting('server_version_num')::int / 10000")
  log "$c (PG$major): globals"
  docker exec "$c" pg_dumpall -U "$(pg_user "$c")" --globals-only --no-role-passwords > "$WORK/$c.globals.sql"

  excl_args=()
  for t in ${EXCLUDE_TABLE_DATA//,/ }; do excl_args+=("--exclude-table-data=$t"); done

  while IFS=$'\t' read -r db collate ctype size; do
    f="$c.$db.dump"
    log "$c/$db: estatísticas ($((size>>20)) MB)"
    psql_q "$c" "$db" -c "$STATS_SQL" > "$WORK/$c.$db.stats"
    psql_in "$c" "$db" -v excl="$EXCLUDE_TABLE_DATA" >> "$WORK/$c.$db.stats" <<<"$ROWS_SQL"
    log "$c/$db: pg_dump"
    start=$SECONDS
    sidecar "$c" pg_dump -d "$db" -Fc -Z 6 "${excl_args[@]}" -f "/backup/$f"
    # Confirma que o arquivo tem um TOC legível e completo.
    sidecar "$c" pg_restore -l "/backup/$f" > "$WORK/$c.$db.toc"
    log "$c/$db: ok, $(du -h "$WORK/$f" | cut -f1) em $(( SECONDS - start ))s, $(grep -vc '^;' "$WORK/$c.$db.toc") entradas no TOC"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$c" "$db" "$f" "$major" "$collate" "$ctype" "$size" >> "$WORK/MANIFEST"
  done < <(psql_q "$c" postgres -c "select datname, datcollate, datctype, pg_database_size(datname) from pg_database where not datistemplate and datallowconn order by datname")
done

if (( HYDRA_STOPPED )); then
  docker start "$HYDRA_APP_CONTAINER" >/dev/null
  HYDRA_STOPPED=0
  log "$HYDRA_APP_CONTAINER arrancado de novo"
fi

( cd "$WORK" && sha256sum -- * > SHA256SUMS )
mv "$WORK" "$FINAL"
ln -sfn "$TS" "$BACKUP_ROOT/latest"
log "backup concluído: $FINAL ($(du -sh "$FINAL" | cut -f1))"

# --- retenção (só depois de um backup bem-sucedido) -------------------------------------
find "$BACKUP_ROOT" -mindepth 1 -maxdepth 1 -type d -name '20??????T??????' -mtime +"$RETENTION_DAYS" -print0 |
  while IFS= read -r -d '' old; do log "retenção: a remover $old"; rm -rf "$old"; done
