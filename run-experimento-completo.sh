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
#   /api/io-http  - workload com chamada HTTP downstream  [default]
#   /api/io       - workload com pg_sleep (DB)            [requer Postgres no host remoto]
#
# Variaveis de ambiente (override opcional dos defaults):
#   REMOTE_HOST         (default: 178.238.235.114)  host onde rodam as apps WebFlux/MVC
#   COLLECT_METRICS     (default: 0)     se 1, executa coleta-metricas.sh (precisa adaptar p/ SSH)
#   WARMUP_VUS          (default: 70)    VUs durante a fase de warmup
#   WARMUP_DURATION     (default: 60s)   duracao do warmup
#   STEADY_DURATION     (default: 40s)   duracao da fase de medicao
#   PAUSE_BETWEEN_REPS  (default: 90)    pausa em segundos entre repeticoes
#
# Exemplo com overrides:
#   WARMUP_VUS=1000 WARMUP_DURATION=10s STEADY_DURATION=50s \
#     ./run-experimento-completo.sh webflux 5000 2 webflux_5kvus_10s_50s
#
# Pre-requisitos:
#   - App Java ja em execucao no host remoto: ${REMOTE_HOST}
#       MVC      -> porta 8080
#       WebFlux  -> porta 8081
#   - k6 instalado nesta maquina (gerador de carga)
#   - Endpoint do experimento respondendo 2xx em http://${REMOTE_HOST}:<porta><endpoint>
#
set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FRAMEWORK=${1:-}
VUS=${2:-1500}
REPS=${3:-2}
NOME_BASE=${4:-experimento}
ENDPOINT=${5:-/api/io-http}

REMOTE_HOST=${REMOTE_HOST:-178.238.235.114}
COLLECT_METRICS=${COLLECT_METRICS:-0}
WARMUP_VUS=${WARMUP_VUS:-70}
WARMUP_DURATION=${WARMUP_DURATION:-60s}
STEADY_DURATION=${STEADY_DURATION:-40s}
PAUSE_BETWEEN_REPS=${PAUSE_BETWEEN_REPS:-90}

if [[ -z "$FRAMEWORK" ]]; then
  echo "Uso: $0 <mvc|webflux> <vus> <reps> <nome_base> [endpoint]"
  echo "  endpoint default: /api/io-http"
  echo "  endpoint db:      /api/io (requer Postgres no host remoto)"
  exit 1
fi

case "$FRAMEWORK" in
  mvc)
    BASE_URL="http://${REMOTE_HOST}:8080"
    APP_PORT="8080"
    APP_CLASS="MvcIoApplication"
    ;;
  webflux)
    BASE_URL="http://${REMOTE_HOST}:8081"
    APP_PORT="8081"
    APP_CLASS="WebFluxIoApplication"
    ;;
  *)
    echo "ERRO: framework deve ser 'mvc' ou 'webflux'"
    exit 1
    ;;
esac

if ! curl -s --max-time 5 -o /dev/null -w '%{http_code}' "$BASE_URL$ENDPOINT" | grep -q '^2'; then
  HTTP_CODE=$(curl -s --max-time 5 -o /dev/null -w '%{http_code}' "$BASE_URL$ENDPOINT" || echo "000")
  echo "ERRO: endpoint $BASE_URL$ENDPOINT nao respondeu 2xx (HTTP $HTTP_CODE)"
  echo "Verifique se a app $FRAMEWORK esta no ar em $BASE_URL"
  exit 1
fi

echo "Endpoint $BASE_URL$ENDPOINT respondendo OK"

TIMESTAMP=$(date +%Y%m%d_%H%M%S)
OUTPUT_DIR="${SCRIPT_DIR}/results/${FRAMEWORK}_io_${NOME_BASE}_${TIMESTAMP}"
mkdir -p "$OUTPUT_DIR"

echo "==========================================="
echo "Coleta: $FRAMEWORK | VUs steady: $VUS | Reps: $REPS"
echo "Warmup: ${WARMUP_VUS} VUs por ${WARMUP_DURATION} | Steady: ${STEADY_DURATION}"
echo "Pausa entre reps: ${PAUSE_BETWEEN_REPS}s"
echo "Alvo: $BASE_URL$ENDPOINT (host remoto: ${REMOTE_HOST})"
echo "Coleta de metricas de sistema: $([[ "$COLLECT_METRICS" == "1" ]] && echo "ATIVA" || echo "DESATIVADA (use COLLECT_METRICS=1 para ativar; precisa adaptar coleta-metricas.sh para SSH)")"
echo "Pasta: $OUTPUT_DIR"
echo "==========================================="

DURACAO_TOTAL=$(( $(echo "$WARMUP_DURATION" | tr -d 's') + $(echo "$STEADY_DURATION" | tr -d 's') + 5 ))

for r in $(seq 1 "$REPS"); do
  echo
  echo "--- Rep $r/$REPS ---"

  K6_OUT="$OUTPUT_DIR/io_${VUS}_${FRAMEWORK}_${r}.csv"
  METRICAS_OUT="$OUTPUT_DIR/metricas_${VUS}_${FRAMEWORK}_${r}.csv"

  METRICAS_BG_PID=""
  if [[ "$COLLECT_METRICS" == "1" ]]; then
    # TODO: adaptar coleta-metricas.sh para rodar via SSH na Maquina A (REMOTE_HOST)
    # Hoje ele coleta do PID local; rodar localmente nao faz sentido com app remota.
    "${SCRIPT_DIR}/coleta-metricas.sh" "$METRICAS_OUT" "$PID" "$DURACAO_TOTAL" &
    METRICAS_BG_PID=$!
  fi

  echo "Iniciando k6..."
  k6 run --quiet \
    -e BASE_URL="$BASE_URL" \
    -e ENDPOINT="$ENDPOINT" \
    -e VUS="$VUS" \
    -e WARMUP_VUS="$WARMUP_VUS" \
    -e WARMUP_DURATION="$WARMUP_DURATION" \
    -e STEADY_DURATION="$STEADY_DURATION" \
    --out csv="$K6_OUT" \
    "${SCRIPT_DIR}/scriptk6.js"

  if [[ -n "$METRICAS_BG_PID" ]]; then
    wait "$METRICAS_BG_PID" 2>/dev/null || true
  fi

  echo "Rep $r concluida"
  echo "  k6:       $K6_OUT ($(du -h "$K6_OUT" | cut -f1))"
  if [[ -f "$METRICAS_OUT" ]]; then
    echo "  metricas: $METRICAS_OUT ($(du -h "$METRICAS_OUT" | cut -f1))"
  fi

  if [[ "$r" -lt "$REPS" ]]; then
    echo "Pausa de ${PAUSE_BETWEEN_REPS}s antes da proxima rep..."
    sleep "$PAUSE_BETWEEN_REPS"
  fi
done

echo
echo "==========================================="
echo "Filtrando CSVs do k6 (steady + duration_ms)..."
echo "==========================================="

if [[ -x "${SCRIPT_DIR}/filter-csv.sh" ]]; then
  for csv_in in "$OUTPUT_DIR"/io_*.csv; do
    [[ -f "$csv_in" ]] || continue
    "${SCRIPT_DIR}/filter-csv.sh" --inplace "$csv_in"
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

echo
echo "==========================================="
echo "Enviando resultados para o GitHub..."
echo "==========================================="

git_publish_results() {
  local repo_root
  if ! repo_root=$(git -C "${SCRIPT_DIR}" rev-parse --show-toplevel 2>/dev/null); then
    echo "AVISO: ${SCRIPT_DIR} nao esta dentro de um repositorio git. Pulando commit/push."
    return 0
  fi

  local results_dir="${SCRIPT_DIR}/results"
  if ! git -C "${repo_root}" add "${results_dir}" 2>/dev/null; then
    echo "AVISO: falha em 'git add ${results_dir}'. Pulando commit/push."
    return 0
  fi

  if git -C "${repo_root}" diff --cached --quiet; then
    echo "Nenhuma mudanca em scripts/results/ para commitar."
    return 0
  fi

  local branch
  branch=$(git -C "${repo_root}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  if [[ -z "${branch}" || "${branch}" == "HEAD" ]]; then
    echo "AVISO: nao foi possivel determinar a branch atual (HEAD destacada?). Pulando push."
    return 0
  fi

  local msg="experimento ${FRAMEWORK} | vus=${VUS} reps=${REPS} | ${NOME_BASE} | ${TIMESTAMP}"
  if ! git -C "${repo_root}" commit -m "${msg}" >/dev/null 2>&1; then
    echo "AVISO: 'git commit' falhou. Pulando push."
    return 0
  fi
  echo "Commit criado: ${msg}"

  if git -C "${repo_root}" push origin "${branch}"; then
    echo "Push concluido para origin/${branch}."
  else
    echo "AVISO: 'git push origin ${branch}' falhou. Commit ficou local; envie manualmente quando puder."
  fi
}

git_publish_results || true
