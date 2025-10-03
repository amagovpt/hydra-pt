#!/bin/bash

POETRY_BIN="/home/dev/.local/bin/poetry"
WORKDIR="/opt/hydra"
LOGDIR="$WORKDIR/logs"

# Limite de linhas para os logs
MAX_LOG_LINES=50000

mkdir -p "$LOGDIR"

cd "$WORKDIR" || exit 1

# Função para iniciar um serviço com log limitado e monitorização
start_service_with_log_and_monitor() {
    local service_name="$1"
    local logfile="$2"
    local command_to_run="$3"

    echo "Iniciando $service_name. Log em $logfile"
    
    # Redireciona a saída do comando para o ficheiro de log em anexo.
    stdbuf -oL $POETRY_BIN run $command_to_run >> "$logfile" 2>&1 &

    local service_pid=$!

    # Cria um processo de monitorização em segundo plano para este log.
    (
        while true; do
            # Verifica se o número de linhas no ficheiro de log é maior ou igual a 100.
            if [ -f "$logfile" ] && [ "$(wc -l < "$logfile")" -ge "$MAX_LOG_LINES" ]; then
                # Limpa o ficheiro de log.
                echo "" > "$logfile"
            fi
            
            sleep 5 # A verificação é feita a cada 5 segundos.
            
            # Se o processo principal já não estiver a correr, pára o monitor.
            if ! kill -0 "$service_pid" 2>/dev/null; then
                echo "Serviço $service_name parou. Encerrando monitor de log."
                break
            fi
        done
    ) &
}

# ---
# Chamadas dos serviços com a nova função
# ---

# Inicia crawler
start_service_with_log_and_monitor "udata-hydra-crawl" "$LOGDIR/crawl.log" "udata-hydra-crawl"

# Inicia worker
start_service_with_log_and_monitor "rq worker" "$LOGDIR/worker.log" "rq worker -c udata_hydra.worker"

# Inicia app Hydra
start_service_with_log_and_monitor "rq app" "$LOGDIR/app.log" "adev runserver udata_hydra/app.py"

# Agendador semanal do load-catalog
(
    while true; do
        echo "Aguardar até próximo load-catalog semanal..."
        sleep 7d
        echo "Executando load-catalog..."
        timestamp=$(date '+%Y-%m-%d %H:%M:%S')
        echo "[$timestamp] Iniciando load-catalog" >> "$LOGDIR/load_catalog.log"
        
        $POETRY_BIN run udata-hydra load-catalog >> "$LOGDIR/load_catalog.log" 2>&1
        
        # Após a execução, verifica e limpa o log.
        if [ "$(wc -l < "$LOGDIR/load_catalog.log")" -ge "$MAX_LOG_LINES" ]; then
            echo "" > "$LOGDIR/load_catalog.log"
        fi
    done
) &

# Impede que o script termine (mantém systemd ativo)
tail -f /dev/null