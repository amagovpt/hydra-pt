# Diagrama de Implantação (C4) — dados.gov.pt

Vista de **implantação** (deployment) do C4 Model das ligações entre os serviços
**hydra-pt**, **api-tabular-pt**, **dadosgov-metrics** e **dadosgov (udata)**.

> Nota C4: a *Deployment view* é a vista suplementar que mapeia os containers em nós de
> infraestrutura. Para melhor legibilidade das ligações, o diagrama é desenhado como um
> *flowchart* em camadas (subgráficos = sistemas/nós, cilindros = bases de dados). (No C4
> clássico o "Nível 4" é o de *Código*; o que se pretende aqui é o diagrama de implantação.)

![Diagrama de implantação — dados.gov.pt](deployment-c4.png)

<details>
<summary>Fonte do diagrama (Mermaid)</summary>

```mermaid
flowchart LR
  EXT["Recursos externos<br/>URLs dos recursos (HTTP/HTTPS)"]

  subgraph DGOV["dadosgov (udata) — dados.gov.pt"]
    direction TB
    UAPI["udata API<br/>/api/1 · /api/2<br/>172.31.204.12 / 10.55.37.38"]
    MONGO[("MongoDB :27017<br/>10.55.37.40/.143")]
    MATOMO["Matomo<br/>dados.gov.pt/stats"]
  end

  subgraph METRICS["dadosgov-metrics (Airflow)"]
    direction TB
    AIR["airflow :8008<br/>DAG dgv_metrics"]
    ADB[("airflow-db<br/>PostgreSQL 12 :15432")]
  end

  subgraph HYDRA["hydra-pt (docker · rede hydra_net)"]
    direction TB
    HAPP["hydra<br/>app :8000 · crawler<br/>worker · catálogo"]
    HDB[("database<br/>PostgreSQL 15 :5432")]
    HCSV[("database-csv<br/>PostgreSQL 15 :5434<br/>public + metric")]
  end

  REDIS[("Redis :6379<br/>10.55.37.142")]

  subgraph TAB["api-tabular-pt (docker)"]
    direction TB
    PG["postgrest :8080<br/>public + metric"]
    TAPI["tabular-api :8005"]
    MAPI["metrics-api :8006"]
  end

  HAPP -->|"lê catálogo / envia checks"| UAPI
  UAPI -->|"POST /api/resources"| HAPP
  HAPP -->|"HEAD/GET recursos"| EXT
  HAPP <-->|"jobs RQ"| REDIS
  HAPP -->|"SQL catálogo/checks"| HDB
  HAPP -->|"grava CSV (public)"| HCSV

  AIR -->|"lê visitas"| MATOMO
  AIR -->|"slugs / catálogo"| MONGO
  AIR -->|"lê / atualiza"| UAPI
  AIR -->|"grava métricas (metric)"| HCSV
  AIR -->|"metadados"| ADB

  PG -->|"lê public + metric"| HCSV
  TAPI --> PG
  MAPI --> PG
  UAPI -->|"preview tabular :8005"| TAPI
  UAPI -->|"métricas :8006"| MAPI

  classDef db fill:#e8eef7,stroke:#2f5496,stroke-width:1px,color:#111;
  classDef app fill:#eaf3ea,stroke:#548235,stroke-width:1px,color:#111;
  classDef ext fill:#faf3e0,stroke:#bf8f00,stroke-width:1px,color:#111;
  class HDB,HCSV,ADB,MONGO,REDIS db;
  class HAPP,AIR,PG,TAPI,MAPI,UAPI app;
  class EXT,MATOMO ext;
```

</details>

> A imagem `deployment-c4.png` é gerada a partir da fonte Mermaid acima (mermaid-cli, escala 3×).

## Legenda das ligações

| # | Origem | Destino | Protocolo / porta | Propósito |
|---|--------|---------|-------------------|-----------|
| 1 | hydra (crawler/worker) | udata API | HTTPS `/api/1`, `/api/2` | Lê o catálogo e envia resultados de check/análise (`CATALOG_URL`, `UDATA_URI`). |
| 2 | udata API | hydra (app) | HTTP `POST /api/resources` | Eventos de criação/alteração de recurso (prioriza crawl). |
| 3 | hydra (crawler) | Recursos externos | HTTP/HTTPS | HEAD/GET aos URLs dos recursos do catálogo (dados.gov.pt e terceiros). |
| 4 | hydra (crawler/worker) | Redis | Redis `:6379` | Fila de jobs RQ (`10.55.37.142`). |
| 5 | hydra | database (`:5432`) | SQL (rede `hydra_net`) | Catálogo, checks, metadados. |
| 6 | hydra (worker) | database-csv (`:5434`) | SQL (rede `hydra_net`) | Grava tabelas convertidas de CSV (schema `public`). |
| 7 | postgrest | database-csv | SQL `host.docker.internal:5434` | Lê `public` (tabular) e `metric` (métricas). |
| 8 | tabular-api | postgrest | HTTP `:8080` | Serve dados tabulares. |
| 9 | metrics-api | postgrest | HTTP `:8080` | Serve métricas (schema `metric` via `Accept-Profile`). |
| 10 | udata (frontend/API) | tabular-api (`:8005`) | HTTP | Pré-visualização de dados tabulares. |
| 11 | udata (frontend/API) | metrics-api (`:8006`) | HTTP | Consumo de métricas. |
| 12 | airflow (DAG) | Matomo | HTTPS | Lê visitas (`dados.gov.pt/stats`). |
| 13 | airflow (DAG) | MongoDB udata | Mongo `:27017` | Resolve slugs→ObjectId e lê catálogo. |
| 14 | airflow (DAG) | udata API | HTTP | Lê/atualiza catálogo (`UDATA_INSTANCE_URL`). |
| 15 | airflow (DAG) | database-csv | SQL `host.docker.internal:5434` | Grava métricas no schema `metric`. |
| 16 | airflow | airflow-db (`:15432`) | SQL | Metadados do próprio Airflow (PostgreSQL 12). |

## O elo central

A **`database-csv` do hydra-pt (porta 5434)** é o ponto de integração dos quatro sistemas:

```
hydra worker  ──(escreve schema public)──▶  database-csv  ◀──(escreve schema metric)── dadosgov-metrics
                                                 │
                                            (lê ambos)
                                                 ▼
                                            PostgREST ──▶ tabular-api / metrics-api ──▶ dadosgov (udata)
```

## Endpoints observados (variam por ambiente)

| Serviço | Endereços observados nos configs |
|---|---|
| udata API | `172.31.204.12` (hydra `UDATA_URI`, metrics `.env`), `10.55.37.38` (metrics `variables.json`), `dados.gov.pt` (catálogo público) |
| MongoDB udata | `10.55.37.40` (`connections.json`), `10.55.37.143` (`.env` / script Matomo) |
| Redis | `10.55.37.142:6379` |
| Matomo | `https://dados.gov.pt/stats` |

## Notas

- Os 3 stacks Docker (**hydra-pt**, **api-tabular-pt**, **dadosgov-metrics**) correm no **mesmo host**; api-tabular e metrics chegam à BD do hydra por `host.docker.internal:5434` (porta publicada), enquanto o próprio hydra usa a rede interna `hydra_net` (`database-csv:5432`).
- O código dos DAGs do `dadosgov-metrics` provém do repositório `datagouvfr_data_pipelines` (montado no container Airflow) — é dependência de código, não um serviço em runtime, por isso não aparece no diagrama.
- Os IPs internos diferem entre ambientes (local/distribuído); ver a tabela de endpoints e o `setup.py` (topologia).

## Regenerar a imagem

```bash
# a partir da fonte Mermaid (bloco acima, guardado como diagram.mmd):
npx @mermaid-js/mermaid-cli -i diagram.mmd -o deployment-c4.png -s 3 -b white
```
