#!/bin/sh
# Arranque do modo "tudo num container": migra o esquema uma vez (idempotente) e
# depois entrega o controlo ao supervisord, que gere app + crawler + worker +
# agendador do catálogo dentro deste mesmo container.
#
# HYDRA_SETTINGS já foi preparado pelo docker/entrypoint.sh (config fundida).
set -eu

echo "[run-all] a migrar o esquema (udata-hydra migrate)..."
tries=0
until udata-hydra migrate; do
  tries=$((tries + 1))
  if [ "$tries" -ge 10 ]; then
    echo "[run-all] migração falhou após ${tries} tentativas; a abortar." >&2
    exit 1
  fi
  echo "[run-all] migrate falhou (tentativa ${tries}); nova tentativa em 3s..." >&2
  sleep 3
done

echo "[run-all] migração concluída; a arrancar o supervisord (app, crawler, worker, catálogo)."
exec supervisord -c /app/docker/supervisord.conf
