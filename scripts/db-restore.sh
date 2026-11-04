#!/usr/bin/env bash
# Restaura um backup feito com scripts/db-backup.sh nos containers Postgres deste host
# (os nomes dos containers são iguais em todos os ambientes).
#
# Cada base de dados é restaurada para uma BD temporária (<db>__restore_<ts>), validada contra
# as estatísticas do backup e só depois trocada por rename. A BD anterior fica como
# <db>__old_<ts> para rollback; remove-se à mão quando o ambiente estiver validado.
#
# Uso:  scripts/db-restore.sh <dir-do-backup> [opções]
#   --test             restaura e valida nas BDs temporárias, sem trocar nada (removidas no fim)
#   --only C[/DB]      restaura só esse container (ou essa BD); pode repetir-se
#   --include-airflow  inclui airflow-db-local-metrics (por omissão é excluído; ver abaixo)
#   --jobs N           processos paralelos do pg_restore (4)
#   --yes              não pede confirmação
#
# O Airflow fica fora por omissão: Variables/Connections cifradas dependem da FERNET_KEY e da
# configuração de cada ambiente; restaurar a metadata de outro ambiente raramente é desejável.
#
# Variáveis: STOP_CONTAINERS (containers parados durante a troca; repostos no fim).
set -Eeuo pipefail

AIRFLOW_DB_CONTAINER=airflow-db-local-metrics
STOP_CONTAINERS=${STOP_CONTAINERS:-"hydra-pt-hydra-1 api-tabular-pt-postgrest-1 airflow-local-metrics"}

DIR=""; TEST=0; YES=0; JOBS=4; INCLUDE_AIRFLOW=0; ONLY=()
while (( $# )); do
  case $1 in
    --test) TEST=1 ;;
    --yes) YES=1 ;;
    --jobs) JOBS=$2; shift ;;
    --only) ONLY+=("$2"); shift ;;
    --include-airflow) INCLUDE_AIRFLOW=1 ;;
    -h|--help) sed -n '2,21p' "$0"; exit 0 ;;
    -*) echo "Argumento desconhecido: $1" >&2; exit 2 ;;
    *) DIR=$1 ;;
  esac
  shift
done
[[ -n $DIR ]] || { sed -n '2,21p' "$0"; exit 2; }
DIR=$(realpath "$DIR")

log() { echo "[$(date '+%F %T')] $*"; }
die() { log "ERRO: $*" >&2; exit 1; }

pg_user()  { docker exec "$1" printenv POSTGRES_USER 2>/dev/null || echo postgres; }
pg_image() { docker inspect -f '{{.Config.Image}}' "$1"; }
psql_q()   { local c=$1 db=$2; shift 2; docker exec "$c" psql -U "$(pg_user "$c")" -d "$db" -v ON_ERROR_STOP=1 -AtX -F $'\t' "$@"; }
psql_in()  { local c=$1 db=$2; shift 2; docker exec -i "$c" psql -U "$(pg_user "$c")" -d "$db" -v ON_ERROR_STOP=1 -AtX -F $'\t' "$@"; }
sidecar() {
  local c=$1; shift
  PGPASSWORD=$(docker exec "$c" printenv POSTGRES_PASSWORD 2>/dev/null || true) \
  docker run --rm --network "container:$c" \
    -e PGPASSWORD -e PGHOST=127.0.0.1 -e PGUSER="$(pg_user "$c")" \
    -v "$DIR:/backup:ro" "$(pg_image "$c")" "$@"
}

selected() {
  local c=$1 db=$2 o
  [[ $c == "$AIRFLOW_DB_CONTAINER" ]] && (( ! INCLUDE_AIRFLOW )) && return 1
  (( ${#ONLY[@]} == 0 )) && return 0
  for o in "${ONLY[@]}"; do [[ $o == "$c" || $o == "$c/$db" ]] && return 0; done
  return 1
}

# Mesmas consultas do db-backup.sh (têm de se manter iguais).
STATS_SQL=$(sed -n "/^STATS_SQL=\$(cat <<'SQL'/,/^SQL/p" "$(dirname "$0")/db-backup.sh" | sed '1d;$d')
ROWS_SQL=$(sed -n "/^ROWS_SQL=\$(cat <<'SQL'/,/^SQL/p" "$(dirname "$0")/db-backup.sh" | sed '1d;$d')
[[ -n $STATS_SQL && -n $ROWS_SQL ]] || die "não consegui ler as consultas de validação de db-backup.sh"

# --- verificações prévias -------------------------------------------------------------
[[ -f $DIR/MANIFEST && -f $DIR/SHA256SUMS ]] || die "$DIR não parece um backup (falta MANIFEST/SHA256SUMS)"
log "a verificar checksums de $DIR"
( cd "$DIR" && sha256sum --quiet -c SHA256SUMS ) || die "checksums não batem certo"
head -1 "$DIR/MANIFEST"
QUIESCED=$(head -1 "$DIR/MANIFEST" | grep -o 'quiesced=[01]' | cut -d= -f2)
EXCL=$(head -1 "$DIR/MANIFEST" | grep -o 'exclude_table_data=[^ ]*' | cut -d= -f2)

TS=$(date '+%Y%m%dT%H%M%S')
PLAN=()
NEED=0
docker_root=$(docker info -f '{{.DockerRootDir}}')
while IFS=$'\t' read -r c db f major collate ctype size; do
  [[ $c == \#* ]] && continue
  selected "$c" "$db" || continue
  [[ $(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null) == true ]] || die "container $c não está a correr neste host"
  tmajor=$(psql_q "$c" postgres -c "select current_setting('server_version_num')::int / 10000")
  (( tmajor >= major )) || die "$c é PG$tmajor mas o backup é de PG$major (não se restaura para uma versão mais antiga)"
  NEED=$(( NEED + size * 12 / 10 ))
  PLAN+=("$c"$'\t'"$db"$'\t'"$f"$'\t'"$collate"$'\t'"$ctype")
done < "$DIR/MANIFEST"
(( ${#PLAN[@]} )) || die "nada para restaurar com os filtros dados"
# As BDs antigas são mantidas, por isso é preciso espaço para uma cópia completa de tudo.
avail=$(( $(df --output=avail -B1 "$docker_root" | tail -1) ))
(( avail > NEED )) || die "espaço insuficiente em $docker_root: $((avail>>20)) MB livres, ~$((NEED>>20)) MB necessários"
STATS_TMP=$(mktemp -d)

log "host: $(hostname)  modo: $( (( TEST )) && echo TESTE || echo RESTORE )"
for p in "${PLAN[@]}"; do IFS=$'\t' read -r c db _ <<<"$p"; log "  $c/$db"; done
if (( ! TEST && ! YES )); then
  echo "As BDs acima vão ser SUBSTITUÍDAS em $(hostname). Containers parados durante a troca: $STOP_CONTAINERS"
  read -r -p "Escreve o hostname para confirmar: " answer
  [[ $answer == "$(hostname)" ]] || die "cancelado"
fi

STOPPED=()
TMP_DBS=()
cleanup() {
  local rc=$? c entry
  for entry in "${TMP_DBS[@]}"; do
    IFS=$'\t' read -r c db <<<"$entry"
    log "a remover BD temporária $c/$db"
    # Sem "with (force)": não existe no PG12 (Airflow).
    psql_in "$c" template1 >/dev/null <<SQL || log "AVISO: não removi $c/$db"
select pg_terminate_backend(pid) from pg_stat_activity where datname = '$db';
drop database if exists "$db";
SQL
  done
  for c in "${STOPPED[@]}"; do
    log "a arrancar $c"; docker start "$c" >/dev/null || log "AVISO: falhou docker start $c"
  done
  rm -rf "$STATS_TMP"
  (( rc == 0 )) || log "restore terminou com erro (rc=$rc); BDs de produção não trocadas ficaram intactas"
}
trap cleanup EXIT

# --- restore para BDs temporárias + validação -----------------------------------------
READY=()
for p in "${PLAN[@]}"; do
  IFS=$'\t' read -r c db f collate ctype <<<"$p"
  tmp="${db}__restore_$TS"
  log "$c/$db: a criar $tmp"
  psql_q "$c" template1 -c "create database \"$tmp\" template template0 encoding 'UTF8' lc_collate '$collate' lc_ctype '$ctype'" >/dev/null
  TMP_DBS+=("$c"$'\t'"$tmp")
  log "$c/$db: pg_restore -j $JOBS"
  start=$SECONDS
  sidecar "$c" pg_restore -d "$tmp" -j "$JOBS" --exit-on-error --no-owner "/backup/$f"
  log "$c/$db: restaurado em $(( SECONDS - start ))s; ANALYZE"
  psql_q "$c" "$tmp" -c "analyze" >/dev/null

  { psql_q "$c" "$tmp" -c "$STATS_SQL"; psql_in "$c" "$tmp" -v excl="$EXCL" <<<"$ROWS_SQL"; } > "$STATS_TMP/$c.$db.stats"
  if ! diff <(grep '^obj' "$DIR/$c.$db.stats") <(grep '^obj' "$STATS_TMP/$c.$db.stats"); then
    die "$c/$db: objetos restaurados diferentes do backup (diff acima)"
  fi
  if ! diff <(grep '^rows' "$DIR/$c.$db.stats") <(grep '^rows' "$STATS_TMP/$c.$db.stats"); then
    # As contagens são tiradas antes do dump: sem --quiesce o hydra/Airflow podem ter escrito entretanto.
    (( QUIESCED )) && [[ $c != "$AIRFLOW_DB_CONTAINER" ]] && die "$c/$db: contagens de linhas diferentes num backup quiesced"
    log "$c/$db: AVISO contagens de linhas diferentes (backup sem --quiesce, escritas durante o dump)"
  fi
  log "$c/$db: validação ok"
  READY+=("$c"$'\t'"$db"$'\t'"$tmp")
done

if (( TEST )); then
  log "TESTE concluído: todas as BDs restauram e validam. Nada foi trocado."
  exit 0
fi

# --- troca ------------------------------------------------------------------------------
for c in $STOP_CONTAINERS; do
  if [[ $(docker inspect -f '{{.State.Running}}' "$c" 2>/dev/null) == true ]]; then
    log "a parar $c"; docker stop -t 60 "$c" >/dev/null; STOPPED+=("$c")
  fi
done

OLD=()
for r in "${READY[@]}"; do
  IFS=$'\t' read -r c db tmp <<<"$r"
  old="${db}__old_$TS"
  log "$c: $db -> $old, $tmp -> $db"
  # As duas renomeações na mesma transação: ou trocam as duas ou nenhuma.
  psql_in "$c" template1 >/dev/null <<SQL
select pg_terminate_backend(pid) from pg_stat_activity where datname = '$db' and pid <> pg_backend_pid();
begin;
alter database "$db" rename to "$old";
alter database "$tmp" rename to "$db";
commit;
SQL
  OLD+=("$c/$old")
done
TMP_DBS=()

log "restore concluído. BDs antigas mantidas para rollback:"
for o in "${OLD[@]}"; do log "  $o   (remover: docker exec ${o%%/*} psql -U postgres -d template1 -c 'drop database \"${o#*/}\"')"; done
