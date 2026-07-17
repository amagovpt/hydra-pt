# Deployment do hydra-pt em Docker (tudo num container)

Documento de referência da containerização do hydra-pt: como está montado, o que
foi alterado, como manter e como consultar os logs.

> Contexto: os serviços **app**, **crawler**, **worker** e o **agendador do catálogo**
> correm **todos dentro de um único container** (`hydra`), gerido por `supervisord`.
> As bases de dados PostgreSQL continuam em containers próprios (são *stateful*).
> Última atualização: 2026-07-17.

---

## 1. Resultado

`docker compose ps` mostra **três** containers:

| Container | Papel |
|---|---|
| `hydra-pt-database-1` | PostgreSQL principal (catálogo, checks, metadados) — porta `5432` |
| `hydra-pt-database-csv-1` | PostgreSQL das tabelas CSV convertidas — porta `5434` |
| `hydra-pt-hydra-1` | **Tudo-num-container**: migração + app + crawler + worker + catálogo |

Dentro do `hydra`, ao arrancar:

1. `docker/run-all.sh` corre `udata-hydra migrate` **uma vez** (idempotente, com retry
   até a BD estar disponível);
2. entrega o controlo ao **supervisord**, que gere 4 processos de longa duração com
   *auto-restart* individual:

```
app        udata-hydra-app                 (API aiohttp, porta 8080 -> 8000 no host)
crawler    udata-hydra-crawl               (crawl contínuo do catálogo)
worker     rq worker -c udata_hydra.worker (filas high/default/low)
catalog    docker/catalog-cron.sh          (load-catalog diário às 03:00)
```

Estado saudável esperado:

```
$ docker exec -it hydra-pt-hydra-1 supervisorctl status
app        RUNNING   pid 66, uptime 0:03:20
catalog    RUNNING   pid 67, uptime 0:03:20
crawler    RUNNING   pid 68, uptime 0:03:20
worker     RUNNING   pid 69, uptime 0:03:20
```

A API responde em `http://localhost:8000` (ex.: `GET /api/status/crawler` → `200`), e o
container tem `healthcheck` HTTP próprio.

---

## 2. Ficheiros

| Ficheiro | Papel |
|---|---|
| `Dockerfile` | Imagem única (`python:3.11-slim` + `uv sync` + `supervisor`, com `libmagic1`). Versão fixada via `SETUPTOOLS_SCM_PRETEND_VERSION` (não há `.git` no build). |
| `.dockerignore` | Reduz o contexto de build e garante que `config.toml` (segredos) e `logs/` **não** entram na imagem. |
| `docker-compose.yml` | Serviços `database`, `database-csv`, `hydra` (+ `test-database`/`broker` por *profile*). Rede `hydra_net`, healthchecks e ordenação de arranque. |
| `config.docker.toml` | Overrides **só do container**: `DATABASE_URL`/`DATABASE_URL_CSV` a apontar para os serviços do compose. Sem segredos (versionável). |
| `docker/entrypoint.sh` | Funde `config.toml` (host) + `config.docker.toml` e define `HYDRA_SETTINGS`. |
| `docker/run-all.sh` | Migração inicial (idempotente) → `exec supervisord`. É o `CMD` por defeito. |
| `docker/supervisord.conf` | Definição dos 4 programas, logs por serviço em `/app/logs` com rotação. |
| `docker/catalog-cron.sh` | Agendador do `load-catalog` (diário; hora via `CATALOG_CRON_HOUR`). |
| `logs/` | Pasta (bind-mount) onde ficam os logs por serviço. Só `.gitkeep` é versionado. |

### Estratégia de configuração (importante)

O `udata-hydra` lê a configuração **apenas de ficheiros TOML** (ver
`udata_hydra/__init__.py`), **não** de variáveis de ambiente. Por isso:

- O `config.toml` do host (segredos + settings PT: `REDIS_URL`, `API_KEY`,
  `CATALOG_URL`, `UDATA_URI`, …) é montado *read-only* em `/app/config.toml`.
- O `config.docker.toml` fornece **apenas** os hostnames das BDs do compose
  (`database`, `database-csv`).
- O `docker/entrypoint.sh` funde os dois num ficheiro efetivo e aponta
  `HYDRA_SETTINGS` para ele. Uma chave definida no `config.toml` **nunca** é
  sobreposta (evita duplicados, que o `tomllib` rejeita).

> **Redis:** mantém-se o Redis **externo** indicado no `config.toml`. O serviço
> `broker` local (profile `broker`) fica desligado.

---

## 3. Como consultar

### Logs (persistidos em `hydra-pt/logs/`)

Cada serviço tem o seu ficheiro, com **rotação automática** (10 MB × 5 cópias:
`worker.log`, `worker.log.1`, … `worker.log.5`), pelo que a pasta não cresce sem limite.

```bash
cd /opt/hydra-pt

tail -f logs/worker.log          # um serviço
tail -f logs/*.log               # todos, com cabeçalho por ficheiro
ls -la logs/                     # ficheiros + rotações

# alternativa: por dentro do container
docker exec -it hydra-pt-hydra-1 supervisorctl tail -f crawler
```

### `docker logs` do container

Mostra o **supervisord** (arranque/reinícios) e o passo de **migração**:

```bash
docker compose logs -f hydra
# ou
docker logs -f hydra-pt-hydra-1
```

### Estado dos processos

```bash
docker exec -it hydra-pt-hydra-1 supervisorctl status
```

> **Nota:** os ficheiros em `logs/` ficam com dono `root` (o container corre como
> root e é um bind-mount). Para limpar no host pode ser preciso `sudo`.

---

## 4. Manutenção

### Arrancar / atualizar / parar

```bash
cd /opt/hydra-pt

docker compose up -d --build     # (re)constrói a imagem e arranca tudo
docker compose ps                # estado dos containers
docker compose restart hydra     # reiniciar o container
docker compose down              # parar (as BDs mantêm os dados nos volumes)
```

### Gerir cada serviço isoladamente (sem reiniciar o container)

```bash
docker exec -it hydra-pt-hydra-1 supervisorctl status
docker exec -it hydra-pt-hydra-1 supervisorctl restart worker
docker exec -it hydra-pt-hydra-1 supervisorctl stop crawler
docker exec -it hydra-pt-hydra-1 supervisorctl start crawler
```

### Base de dados / migração

```bash
# migração avulsa (idempotente)
docker exec -it hydra-pt-hydra-1 udata-hydra migrate
```

### Catálogo

O `load-catalog` corre **1x/dia** às `CATALOG_CRON_HOUR` (por defeito `03:00`,
`Europe/Lisbon`). Para forçar um carregamento imediato:

```bash
docker exec -it hydra-pt-hydra-1 udata-hydra load-catalog
```

Opções (no serviço `hydra`, em `docker-compose.yml`):

| Variável | Default | Efeito |
|---|---|---|
| `CATALOG_CRON_HOUR` | `3` | Hora diária do `load-catalog` (0–23). |
| `CATALOG_LOAD_ON_START` | `false` | `true` → carrega o catálogo também no arranque. |
| `TZ` | `Europe/Lisbon` | Fuso horário do agendador. |

### Correr um serviço isolado (fora do modo tudo-num-container)

A imagem mantém os comandos individuais disponíveis:

```bash
docker compose run --rm hydra udata-hydra-app
docker compose run --rm hydra udata-hydra-crawl
docker compose run --rm hydra rq worker -c udata_hydra.worker
```

---

## 5. Alterações (histórico do que foi feito)

1. **Containerização inicial** — criados `Dockerfile`, `.dockerignore`,
   `config.docker.toml`, `docker/entrypoint.sh`; adicionados ao `docker-compose.yml`
   healthchecks nas BDs e os serviços hydra, com inicialização (migração) após a
   criação das BDs (`depends_on` + `service_healthy`/`service_completed_successfully`).
2. **Agendamento do catálogo** — `docker/catalog-cron.sh`. Começou semanal (Domingo)
   e passou a **diário** (às `CATALOG_CRON_HOUR`).
3. **Consolidação num único container** — os 4 processos passaram a ser geridos por
   `supervisord` dentro do serviço `hydra` (`docker/run-all.sh`, `docker/supervisord.conf`);
   os serviços `hydra-init`/`hydra-app`/`hydra-crawler`/`hydra-worker`/`hydra-catalog`
   foram substituídos por um só serviço `hydra`.
4. **Volume de logs** — cada serviço escreve para `hydra-pt/logs/<serviço>.log` com
   rotação; bind-mount `./logs:/app/logs`; pasta versionada via `.gitkeep`.

### Rede e volumes (preservados)

- Rede `hydra_net` (nome fixo, sem prefixo de projeto) — todos os serviços ligados a ela.
- Volumes `hydra-pt_database-data-15` e `hydra-pt_database-data-csv-15` — **os dados das
  BDs persistem** entre recriações de container.

---

## 6. Trade-offs do modo "tudo num container"

| A favor | Contra |
|---|---|
| 1 imagem e 1 container para arrancar/parar/atualizar | Não escala serviços independentemente |
| Menos peças para manter | O `restart` do Docker vê só o PID 1 (o supervisord trata os reinícios internos) |
| Logs organizados por ficheiro + `supervisorctl` por serviço | Todos os processos partilham os mesmos limites de recursos |

As bases de dados ficam **propositadamente** em containers separados (são *stateful*).

---

## 7. Problema conhecido (alheio à containerização)

O job `send` do worker pode devolver **404** ao comunicar com a instância udata
(`UDATA_URI`, ex.: `https://172.31.204.12/api/2/.../extras/`). É uma questão de
dados/endpoint da instância udata — **não** é causado por esta configuração Docker;
ocorreria igual num deployment com processos separados. O worker recupera e continua.
```
