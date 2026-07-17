#!/bin/sh
# Constrói a configuração efetiva do hydra a partir de:
#   1) /app/config.toml        -> montado do host (segredos + settings PT)
#   2) /app/config.docker.toml -> overrides do container (hostnames das BDs do compose)
# e aponta HYDRA_SETTINGS para o resultado. O udata-hydra só lê config de TOML
# (ver udata_hydra/__init__.py), daí a necessidade de fundir os dois ficheiros.
set -eu

USER_CONFIG="/app/config.toml"
DOCKER_CONFIG="/app/config.docker.toml"
EFFECTIVE="/tmp/hydra.config.toml"

: > "$EFFECTIVE"

if [ -f "$USER_CONFIG" ]; then
  cat "$USER_CONFIG" >> "$EFFECTIVE"
  printf '\n' >> "$EFFECTIVE"
else
  echo "[entrypoint] AVISO: $USER_CONFIG não montado; a usar defaults + overrides docker apenas." >&2
fi

# Acrescenta cada override do docker só se a chave ainda não estiver definida no
# config do utilizador, para nunca gerar uma chave duplicada (o tomllib rejeita-as).
if [ -f "$DOCKER_CONFIG" ]; then
  while IFS= read -r line || [ -n "$line" ]; do
    key=$(printf '%s\n' "$line" | sed -n 's/^[[:space:]]*\([A-Za-z0-9_]\{1,\}\)[[:space:]]*=.*/\1/p')
    if [ -n "$key" ] && [ -f "$USER_CONFIG" ] && grep -qE "^[[:space:]]*${key}[[:space:]]*=" "$USER_CONFIG"; then
      echo "[entrypoint] '$key' já definido no config.toml; a manter o valor do utilizador." >&2
      continue
    fi
    printf '%s\n' "$line" >> "$EFFECTIVE"
  done < "$DOCKER_CONFIG"
fi

export HYDRA_SETTINGS="$EFFECTIVE"
exec "$@"
