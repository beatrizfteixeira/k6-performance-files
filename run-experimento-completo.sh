#!/bin/bash
# Orquestrador de coleta: k6 + metricas de sistema em paralelo
#
# Uso:
#   ./run-experimento-completo.sh <framework> <vus> <reps> <pasta_nome> [endpoint]
#
# Exemplos:
#   ./run-experimento-completo.sh mvc 1500 2 ancora_pool50_sleep100
#   ./run-experimento-completo.sh webflux 1500 2 ancora_pool50_sleep100
#   ./run-experimento-completo.sh mvc 1500 2 http_downstream /api/io-http
#   ./run-experimento-completo.sh webflux 1500 2 http_downstream /api/io-http
#
# Endpoints disponiveis:
#   /api/io       - workload com pg_sleep (DB)            [default]
#   /api/io-http  - workload com chamada HTTP downstream  [requer downstream-service na porta 9090]
#
# Pre-requisitos:
#   - App Java ja em execucao (porta 8080 para mvc, 8081 para webflux)
#   - k6 instalado
#   - PostgreSQL rodando (para /api/io)
#   - downstream-service na porta 9090 (para /api/io-http)
#
set -euo pipefail

FRAMEWORK=${1:-}
VUS=${2:-1500}
REPS=${3:-2}
NOME_BASE=${4:-experimento}
ENDPOINT=${5:-/api/io}

WARMUP_VUS=70
WARMUP_DURATION=60s
STEADY_DURATION=40s
PAUSE_BETWEEN_REPS=90

if [[ -z "$FRAMEWORK" ]]; then
  echo "Uso: $0 <mvc|webflux> <vus> <reps> <nome_base> [endpoint]"
  echo "  endpoint default: /api/io"
  echo "  endpoint http:    /api/io-http (requer downstream na porta 9090)"
  exit 1
fi

case "$FRAMEWORK" in
  mvc)
    BASE_URL="http://localhost:8080"
    APP_PORT="8080"
    APP_CLASS="MvcIoApplication"
    ;;
  webflux)
    BASE_URL="http://localhost:8081"
    APP_PORT="8081"
    APP_CLASS="WebFluxIoApplication"
    ;;
  *)
    echo "ERRO: framework deve ser 'mvc' ou 'webflux'"
    exit 1
    ;;
esac

PID=""
if command -v ss >/dev/null 2>&1; then
  PID=$(ss -tlnp 2>/dev/null | awk -v port=":$APP_PORT" '$4 ~ port' | grep -oP 'pid=\K[0-9]+' | head -1 || true)
fi

if [[ -z "$PID" ]] && command -v lsof >/dev/null 2>&1; then
  PID=$(lsof -ti :"$APP_PORT" 2>/dev/null | head -1 || true)
fi

if [[ -z "$PID" ]]; then
  PID=$(pgrep -f "$APP_CLASS" | head -1 || echo "")
fi

if [[ -z "$PID" ]]; then
  echo "ERRO: processo do $FRAMEWORK nao encontrado"
  echo "Tentei: porta $APP_PORT (ss/lsof), classe $APP_CLASS (pgrep)"
  echo "Suba a aplicacao primeiro (porta $APP_PORT)"
  exit 1
fi

if ! kill -0 "$PID" 2>/dev/null; then
  echo "ERRO: PID $PID nao esta vivo"
  exit 1
fi

if ! curl -s --max-time 5 "$BASE_URL$ENDPOINT" > /dev/null; then
  echo "ERRO: endpoint $BASE_URL$ENDPOINT nao responde"
  exit 1
fi

if [[ "$ENDPOINT" == "/api/io-http" ]]; then
  if ! curl -s --max-time 5 "http://localhost:9090/downstream/health" > /dev/null; then
    echo "ERRO: downstream-service em http://localhost:9090 nao responde"
    echo "Suba o downstream-service primeiro"
    exit 1
  fi
  echo "Downstream-service detectado em http://localhost:9090"
fi

echo "Detectado processo do $FRAMEWORK: PID $PID na porta $APP_PORT (endpoint $ENDPOINT)"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="./results/${FRAMEWORK}_io_${NOME_BASE}_${TIMESTAMP}"
mkdir -p "$OUTPUT_DIR"

echo "==========================================="
echo "Coleta: $FRAMEWORK | VUs: $VUS | Reps: $REPS"
echo "PID: $PID | Pasta: $OUTPUT_DIR"
echo "==========================================="

DURACAO_TOTAL=$(( $(echo "$WARMUP_DURATION" | tr -d 's') + $(echo "$STEADY_DURATION" | tr -d 's') + 5 ))

for r in $(seq 1 "$REPS"); do
  echo
  echo "--- Rep $r/$REPS ---"

  K6_OUT="$OUTPUT_DIR/io_${VUS}_${FRAMEWORK}_${r}.csv"
  METRICAS_OUT="$OUTPUT_DIR/metricas_${VUS}_${FRAMEWORK}_${r}.csv"

  ./coleta-metricas.sh "$METRICAS_OUT" "$PID" "$DURACAO_TOTAL" &
  METRICAS_BG_PID=$!

  echo "Iniciando k6..."
  k6 run --quiet \
    -e BASE_URL="$BASE_URL" \
    -e ENDPOINT="$ENDPOINT" \
    -e VUS="$VUS" \
    -e WARMUP_VUS="$WARMUP_VUS" \
    -e WARMUP_DURATION="$WARMUP_DURATION" \
    -e STEADY_DURATION="$STEADY_DURATION" \
    --out csv="$K6_OUT" \
    scriptk6.js

  wait $METRICAS_BG_PID 2>/dev/null || true

  echo "Rep $r concluida"
  echo "  k6:       $K6_OUT ($(du -h "$K6_OUT" | cut -f1))"
  echo "  metricas: $METRICAS_OUT ($(du -h "$METRICAS_OUT" | cut -f1))"

  if [[ "$r" -lt "$REPS" ]]; then
    echo "Pausa de ${PAUSE_BETWEEN_REPS}s antes da proxima rep..."
    sleep "$PAUSE_BETWEEN_REPS"
  fi
done

echo
echo "==========================================="
echo "Filtrando CSVs do k6 (steady + duration_ms)..."
echo "==========================================="

if [[ -x ./filter-csv.sh ]]; then
  for csv_in in "$OUTPUT_DIR"/io_*.csv; do
    [[ -f "$csv_in" ]] || continue
    ./filter-csv.sh "$csv_in"
  done
else
  echo "AVISO: filter-csv.sh nao encontrado ou sem permissao de execucao"
  echo "  Rode manualmente para cada io_*.csv da pasta $OUTPUT_DIR"
fi

echo
echo "==========================================="
echo "Concluido. Pasta: $OUTPUT_DIR"
echo "==========================================="
ls -lh "$OUTPUT_DIR"
