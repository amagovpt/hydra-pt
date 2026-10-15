# syntax=docker/dockerfile:1
# Imagem do GitLab CI (componente devops-python-comp). Mesma imagem "tudo num
# container" do Dockerfile da raiz, mas SEM instalações: o venv (/app/.venv, com
# supervisor) e o libmagic1 são preparados pelo job package-python na mesma imagem
# base e chegam aqui como artefactos em image-build/. Contexto de build: raiz.

# No CI o componente passa --build-arg NEXUS_REGISTRY_PULL_URL=<mirror Nexus>.
ARG NEXUS_REGISTRY_PULL_URL=docker.io/library
# Tem de ser a mesma imagem do input python-image (interpretador do venv).
FROM ${NEXUS_REGISTRY_PULL_URL}/python:3.11-slim-bookworm

ENV PATH="/app/.venv/bin:$PATH" \
    PYTHONUNBUFFERED=1

# Cria /app/logs (logs por serviço do supervisord; normalmente bind-mount).
WORKDIR /app/logs
WORKDIR /app

# libmagic1 + base de dados magic (python-magic). tzdata e ca-certificates já vêm na base.
ADD image-build/libmagic.tar /
# venv de produção construído em /app/.venv (ADD extrai o tar).
ADD image-build/venv.tar /app/

# Código (instalação editable no venv aponta para /app/udata_hydra).
COPY pyproject.toml README.md VERSION ./
COPY udata_hydra ./udata_hydra

# "Cola" do container (overrides + scripts de arranque).
COPY config.docker.toml ./config.docker.toml
COPY --chmod=755 docker ./docker
# Local default para o supervisorctl encontrar a config sem -c.
COPY docker/supervisord.conf /etc/supervisord.conf

ENTRYPOINT ["/app/docker/entrypoint.sh"]
# Por defeito arranca todos os serviços num só container (migrate + supervisord).
CMD ["/app/docker/run-all.sh"]
