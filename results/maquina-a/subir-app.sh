#!/bin/bash
# Sobe a app Spring (MVC ou WebFlux) na Maquina A e, ao receber Ctrl+C,
# faz git add/commit/push automatico do projeto. Nao coleta metricas:
# a coleta e disparada remotamente pela Maquina B (run-experimento-completo.sh).
#
# Uso (na Maquina A):
#   ./subir-app.sh <mvc|webflux> [tomcat_threads_max]
#
# Exemplos:
#   ./subir-app.sh mvc 800
#   ./subir-app.sh webflux
#
# Pre-requisitos na Maquina A:
#   - Java 21 (Corretto), Maven instalados
#   - Codigo do projeto clonado em $PROJETO_ROOT (default: ~/projeto-apps/performance-concurrency-models-java-spring)
#   - Git configurado com credencial para push (HTTPS token ou ssh)

set -euo pipefail

readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

FRAMEWORK=${1:-}
TOMCAT_THREADS_MAX=${2:-200}

PROJETO_ROOT=${PROJETO_ROOT:-$HOME/projeto-apps/performance-concurrency-models-java-spring}

if [[ -z "$FRAMEWORK" ]]; then
  echo "Uso: $0 <mvc|webflux> [tomcat_threads_max]"
  exit 1
fi

case "$FRAMEWORK" in
  mvc)
    APP_DIR="${PROJETO_ROOT}/app-mvc-io-http"
    APP_PORT="8080"
    APP_MAIN_CLASS="MvcIoHttpApplication"
    EXTRA_ARGS="--server.tomcat.threads.max=${TOMCAT_THREADS_MAX}"
    ;;
  webflux)
    APP_DIR="${PROJETO_ROOT}/app-webflux-io-http"
    APP_PORT="8081"
    APP_MAIN_CLASS="WebFluxIoHttpApplication"
    EXTRA_ARGS=""
    ;;
  *)
    echo "ERRO: framework deve ser 'mvc' ou 'webflux'"
    exit 1
    ;;
esac

if [[ ! -d "$APP_DIR" ]]; then
  echo "ERRO: diretorio do projeto nao existe: $APP_DIR"
  echo "  Defina PROJETO_ROOT corretamente ou clone o repo."
  exit 1
fi

git_publish() {
  local repo_root
  if ! repo_root=$(git -C "${PROJETO_ROOT}" rev-parse --show-toplevel 2>/dev/null); then
    echo "AVISO: ${PROJETO_ROOT} nao e um repo git. Pulando commit/push."
    return 0
  fi

  if ! git -C "${repo_root}" add -A 2>/dev/null; then
    echo "AVISO: 'git add' falhou. Pulando."
    return 0
  fi

  if git -C "${repo_root}" diff --cached --quiet; then
    echo "Nenhuma mudanca para commitar."
    return 0
  fi

  local branch
  branch=$(git -C "${repo_root}" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  if [[ -z "${branch}" || "${branch}" == "HEAD" ]]; then
    echo "AVISO: HEAD destacada. Pulando push."
    return 0
  fi

  local msg
  msg="run ${FRAMEWORK} threads=${TOMCAT_THREADS_MAX} | $(date +%Y-%m-%d_%H:%M:%S)"
  if ! git -C "${repo_root}" commit -m "${msg}" >/dev/null 2>&1; then
    echo "AVISO: commit falhou."
    return 0
  fi
  echo "Commit: ${msg}"

  if git -C "${repo_root}" push origin "${branch}"; then
    echo "Push concluido para origin/${branch}."
  else
    echo "AVISO: push falhou. Commit local mantido."
  fi
}

cleanup() {
  echo
  echo "==========================================="
  echo "Recebido sinal de parada. Encerrando app..."
  echo "==========================================="
  if [[ -n "${APP_PID:-}" ]] && kill -0 "$APP_PID" 2>/dev/null; then
    kill -TERM "$APP_PID" 2>/dev/null || true
    for _ in {1..15}; do
      kill -0 "$APP_PID" 2>/dev/null || break
      sleep 1
    done
    if kill -0 "$APP_PID" 2>/dev/null; then
      echo "App nao parou em 15s. Forcando kill -9."
      kill -KILL "$APP_PID" 2>/dev/null || true
    fi
  fi

  pkill -f "${APP_MAIN_CLASS}" 2>/dev/null || true

  echo
  echo "Publicando no Git..."
  git_publish || true

  exit 0
}

trap cleanup INT TERM

echo "==========================================="
echo "Subindo app ${FRAMEWORK} na porta ${APP_PORT}"
echo "Diretorio: ${APP_DIR}"
if [[ "$FRAMEWORK" == "mvc" ]]; then
  echo "Tomcat threads max: ${TOMCAT_THREADS_MAX}"
fi
echo "Pressione Ctrl+C para parar (faz git push automatico)"
echo "==========================================="

cd "$APP_DIR"

mvn spring-boot:run \
  -Dspring-boot.run.arguments="--server.port=${APP_PORT} ${EXTRA_ARGS}" \
  &
APP_PID=$!

wait "$APP_PID"
