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
#   REMOTE_HOST         (default: 172.31.45.57)  IP PRIVADO da maquina A (apps)
#   SSH_HOST            (default: REMOTE_HOST)   host alvo do SSH (pode ser alias do ~/.ssh/config como 'apps')
#   SSH_USER            (default: ec2-user)      usuario SSH na maquina A
#   SSH_KEY             (default: ~/.ssh/id_ed25519_apps)  chave privada
#   APP_CLASS_REMOTE    (default: detectado por framework)  classe Java a buscar com pgrep -f
#   COLLECT_METRICS     (default: 0)     se 1, coleta CPU/MEM/threads/GC via SSH na maquina A
#   WARMUP_VUS          (default: 70)    VUs durante a fase de warmup
#   WARMUP_DURATION     (default: 60s)   duracao do warmup
#   STEADY_DURATION     (default: 40s)   duracao da fase de medicao
#   PAUSE_BETWEEN_REPS  (default: 90)    pausa em segundos entre repeticoes
#
# Coleta de metricas de sistema (COLLECT_METRICS=1):
#   - O script SSH-a na maquina A
#   - Detecta o PID da app (pgrep -f <APP_CLASS>)
#   - Copia coleta-metricas.sh para /tmp/ na A (se ainda nao estiver la)
#   - Dispara coleta em background na A (saida em /tmp/metricas_<vus>_<framework>_<rep>.csv)
#   - Faz scp do CSV para a pasta de results local apos o k6 terminar
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

REMOTE_HOST=${REMOTE_HOST:-172.31.45.57}
SSH_HOST=${SSH_HOST:-${REMOTE_HOST}}
SSH_USER=${SSH_USER:-ec2-user}
SSH_KEY=${SSH_KEY:-$HOME/.ssh/id_ed25519_apps}
COLLECT_METRICS=${COLLECT_METRICS:-0}
WARMUP_VUS=${WARMUP_VUS:-70}
WARMUP_DURATION=${WARMUP_DURATION:-60s}
STEADY_DURATION=${STEADY_DURATION:-40s}
PAUSE_BETWEEN_REPS=${PAUSE_BETWEEN_REPS:-90}

readonly SSH_OPTS=(-i "$SSH_KEY" -o StrictHostKeyChecking=accept-new -o ConnectTimeout=10 -o BatchMode=yes)
ssh_a() { ssh "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}" "$@"; }
scp_from_a() { scp "${SSH_OPTS[@]}" "${SSH_USER}@${SSH_HOST}:$1" "$2"; }
scp_to_a() { scp "${SSH_OPTS[@]}" "$1" "${SSH_USER}@${SSH_HOST}:$2"; }

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
    APP_CLASS_DEFAULT="MvcIoApplication"
    ;;
  webflux)
    BASE_URL="http://${REMOTE_HOST}:8081"
    APP_PORT="8081"
    APP_CLASS_DEFAULT="WebFluxIoApplication"
    ;;
  *)
    echo "ERRO: framework deve ser 'mvc' ou 'webflux'"
    exit 1
    ;;
esac
APP_CLASS_REMOTE=${APP_CLASS_REMOTE:-$APP_CLASS_DEFAULT}

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
if [[ "$COLLECT_METRICS" == "1" ]]; then
  echo "Coleta de metricas de sistema: ATIVA (via SSH em ${SSH_USER}@${SSH_HOST}, classe '${APP_CLASS_REMOTE}')"
else
  echo "Coleta de metricas de sistema: DESATIVADA (use COLLECT_METRICS=1 para ativar)"
fi
echo "Pasta: $OUTPUT_DIR"
echo "==========================================="

DURACAO_TOTAL=$(( $(echo "$WARMUP_DURATION" | tr -d 's') + $(echo "$STEADY_DURATION" | tr -d 's') + 5 ))

REMOTE_COLETA_PATH="/tmp/coleta-metricas.sh"

if [[ "$COLLECT_METRICS" == "1" ]]; then
  echo "Verificando SSH com a maquina A (${SSH_USER}@${SSH_HOST})..."
  if ! ssh_a "echo OK" >/dev/null 2>&1; then
    echo "ERRO: SSH para ${SSH_USER}@${SSH_HOST} falhou."
    echo "  Verifique chave (${SSH_KEY}) e conectividade. Abortando."
    exit 1
  fi

  echo "Copiando coleta-metricas.sh para a maquina A (${REMOTE_COLETA_PATH})..."
  if ! scp_to_a "${SCRIPT_DIR}/coleta-metricas.sh" "${REMOTE_COLETA_PATH}"; then
    echo "ERRO: scp do coleta-metricas.sh para a maquina A falhou. Abortando."
    exit 1
  fi
  ssh_a "chmod +x ${REMOTE_COLETA_PATH}"

  REMOTE_PID=$(ssh_a "pgrep -f '${APP_CLASS_REMOTE}' | head -1" || true)
  if [[ -z "$REMOTE_PID" ]]; then
    echo "ERRO: nao encontrei processo Java com classe '${APP_CLASS_REMOTE}' na maquina A."
    echo "  Verifique se a app esta rodando ou ajuste APP_CLASS_REMOTE."
    exit 1
  fi
  echo "PID da app ${FRAMEWORK} na maquina A: ${REMOTE_PID}"
fi

for r in $(seq 1 "$REPS"); do
  echo
  echo "--- Rep $r/$REPS ---"

  K6_OUT="$OUTPUT_DIR/io_${VUS}_${FRAMEWORK}_${r}.csv"
  METRICAS_OUT="$OUTPUT_DIR/metricas_${VUS}_${FRAMEWORK}_${r}.csv"
  REMOTE_METRICAS_TMP="/tmp/metricas_${VUS}_${FRAMEWORK}_${r}_$$.csv"

  if [[ "$COLLECT_METRICS" == "1" ]]; then
    REMOTE_PID=$(ssh_a "pgrep -f '${APP_CLASS_REMOTE}' | head -1" || true)
    if [[ -z "$REMOTE_PID" ]]; then
      echo "ERRO: PID da app ${FRAMEWORK} sumiu na maquina A. Abortando."
      exit 1
    fi
    echo "Disparando coleta de metricas na maquina A (PID=${REMOTE_PID}, ${DURACAO_TOTAL}s)..."
    ssh_a "nohup ${REMOTE_COLETA_PATH} ${REMOTE_METRICAS_TMP} ${REMOTE_PID} ${DURACAO_TOTAL} >/tmp/coleta_${$}_${r}.log 2>&1 &"
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

  if [[ "$COLLECT_METRICS" == "1" ]]; then
    echo "Aguardando coleta de metricas finalizar na maquina A..."
    ssh_a "while pgrep -f 'coleta-metricas.sh ${REMOTE_METRICAS_TMP}' >/dev/null 2>&1; do sleep 1; done" || true

    echo "Trazendo metricas da maquina A..."
    if scp_from_a "${REMOTE_METRICAS_TMP}" "${METRICAS_OUT}"; then
      ssh_a "rm -f ${REMOTE_METRICAS_TMP}" || true
    else
      echo "AVISO: falha ao trazer ${REMOTE_METRICAS_TMP} da maquina A."
    fi
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
