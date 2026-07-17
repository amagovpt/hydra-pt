# syntax=docker/dockerfile:1
# Imagem única partilhada pelos serviços hydra-app / hydra-crawler / hydra-worker
# (e pelo one-shot de migração e pelo agendador do catálogo) no docker-compose.yml.
FROM python:3.11-slim-bookworm

# Dependências de sistema em runtime:
#  - libmagic1:       necessário ao python-magic (deteção de tipo de ficheiro)
#  - tzdata:          para o agendador semanal respeitar TZ (ex.: Europe/Lisbon)
#  - ca-certificates: TLS para o crawling e o download do catálogo
RUN apt-get update \
 && apt-get install -y --no-install-recommends libmagic1 tzdata ca-certificates \
 && rm -rf /var/lib/apt/lists/*

# uv (gestor de pacotes Python) — cópia fixada da imagem oficial
COPY --from=ghcr.io/astral-sh/uv:0.5 /uv /usr/local/bin/uv

ENV UV_LINK_MODE=copy \
    UV_COMPILE_BYTECODE=1 \
    UV_PYTHON_DOWNLOADS=never \
    PATH="/app/.venv/bin:$PATH" \
    PYTHONUNBUFFERED=1

# Sem .git no contexto de build, o setuptools_scm não consegue derivar a versão:
# fixamo-la explicitamente (pode ser sobreposta com --build-arg HYDRA_VERSION=...).
ARG HYDRA_VERSION=2.13.2
ENV SETUPTOOLS_SCM_PRETEND_VERSION=${HYDRA_VERSION}

WORKDIR /app

# 1) Camada de dependências (fica em cache até pyproject/uv.lock mudarem).
#    O próprio projeto também é instalado, por isso o código-fonte e o README
#    têm de estar presentes.
COPY pyproject.toml uv.lock README.md ./
COPY udata_hydra ./udata_hydra
RUN uv sync --frozen --no-dev
# supervisor: gere os vários processos no modo "tudo num container" (docker/run-all.sh).
RUN uv pip install --python /app/.venv/bin/python supervisor

# 2) "Cola" do container (overrides + scripts de arranque).
COPY config.docker.toml ./config.docker.toml
COPY docker ./docker
RUN chmod +x docker/entrypoint.sh docker/catalog-cron.sh docker/run-all.sh \
    # local default para o supervisorctl encontrar a config sem -c
    && ln -sf /app/docker/supervisord.conf /etc/supervisord.conf \
    # pasta de logs (normalmente sobreposta pelo bind-mount ./logs do compose)
    && mkdir -p /app/logs

ENTRYPOINT ["/app/docker/entrypoint.sh"]
# Por defeito arranca todos os serviços num só container (migrate + supervisord).
# Os comandos individuais (udata-hydra-app, udata-hydra-crawl, rq worker...) continuam
# disponíveis se for preciso correr um serviço isolado.
CMD ["/app/docker/run-all.sh"]
