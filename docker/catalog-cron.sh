#!/bin/sh
# Executa `udata-hydra load-catalog` num agendamento diário
# (por defeito: todos os dias às 03:00, no fuso horário do container — ver TZ no compose).
# O load-catalog faz UPSERT do catálogo, por isso uma execução extra ocasional é inócua.
set -eu

HOUR="${CATALOG_CRON_HOUR:-3}"  # hora do dia (0-23)

# Carregamento inicial opcional (por defeito desligado; o catálogo é populado na 1.ª execução diária).
if [ "${CATALOG_LOAD_ON_START:-false}" = "true" ]; then
  echo "[catalog-cron] CATALOG_LOAD_ON_START=true -> carregamento inicial do catálogo"
  udata-hydra load-catalog || echo "[catalog-cron] load-catalog inicial falhou"
fi

while true; do
  now_secs=$(( $(date +%-H) * 3600 + $(date +%-M) * 60 + $(date +%-S) ))
  wait_secs=$(( HOUR * 3600 - now_secs ))
  [ "$wait_secs" -le 0 ] && wait_secs=$(( wait_secs + 86400 ))
  echo "[catalog-cron] próximo load-catalog em ${wait_secs}s (alvo: todos os dias às ${HOUR}:00)"
  sleep "$wait_secs"
  echo "[catalog-cron] $(date '+%Y-%m-%d %H:%M:%S') a executar udata-hydra load-catalog"
  udata-hydra load-catalog || echo "[catalog-cron] load-catalog falhou; nova tentativa amanhã"
done
