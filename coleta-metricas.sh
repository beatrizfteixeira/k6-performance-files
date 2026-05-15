#!/bin/bash
# Coleta de metricas do processo Java (CPU, memoria, threads, GC, heap) durante execucao do k6
#
# Colunas geradas:
#   timestamp        - epoch unix
#   cpu_pct          - %CPU INSTANTANEA do processo (delta de jiffies em /proc/PID/stat
#                      vs /proc/stat). Estilo top/htop:
#                        100% = 1 core saturado
#                        N*100% = todos os N cores saturados (N = nproc)
#   mem_rss_kb       - memoria fisica residente (ps)
#   mem_vsz_kb       - memoria virtual (ps)
#   threads_total    - numero de threads do processo (/proc/PID/task)
#   ygc              - Young GC count (jstat) acumulado
#   ygc_time_s       - Young GC time em segundos (jstat) acumulado
#   fgc              - Full GC count (jstat) acumulado
#   fgc_time_s       - Full GC time em segundos (jstat) acumulado
#   heap_used_kb     - heap usada total (jstat: EU+OU)
#   heap_capacity_kb - heap capacidade total (jstat: EC+OC)
#   metaspace_used_kb- metaspace usada (jstat: MU)
#
# Uso: ./coleta-metricas.sh <output_csv> <pid_do_java> <duracao_segundos>
#
# Exemplo:
#   PID=$(pgrep -f "MvcIoApplication")
#   ./coleta-metricas.sh metricas_mvc_run1.csv $PID 100

set -euo pipefail

OUTPUT_FILE=${1:-metricas.csv}
TARGET_PID=${2:-}
DURATION=${3:-100}
INTERVAL=1

if [[ -z "$TARGET_PID" ]]; then
  echo "ERRO: PID do processo Java nao informado"
  echo "Uso: $0 <output_csv> <pid> <duracao_segundos>"
  exit 1
fi

if ! kill -0 "$TARGET_PID" 2>/dev/null; then
  echo "ERRO: PID $TARGET_PID nao esta vivo"
  exit 1
fi

JSTAT_AVAILABLE=0
if command -v jstat >/dev/null 2>&1; then
  if jstat -gc "$TARGET_PID" >/dev/null 2>&1; then
    JSTAT_AVAILABLE=1
  fi
fi

readonly CLK_TCK=$(getconf CLK_TCK)
readonly NUM_CORES=$(nproc)

cpu_jiffies_proc() {
  local pid=$1
  local stat
  stat=$(cat "/proc/${pid}/stat" 2>/dev/null) || { echo "0"; return; }
  local utime stime
  utime=$(echo "$stat" | awk '{print $14}')
  stime=$(echo "$stat" | awk '{print $15}')
  echo $(( utime + stime ))
}

cpu_jiffies_total() {
  awk '/^cpu /{sum=0; for (i=2; i<=NF; i++) sum+=$i; print sum; exit}' /proc/stat
}

if [[ $JSTAT_AVAILABLE -eq 1 ]]; then
  echo "Coletando metricas (CPU + RAM + threads + GC + heap) do PID $TARGET_PID por ${DURATION}s"
else
  echo "Coletando metricas (CPU + RAM + threads) do PID $TARGET_PID por ${DURATION}s"
  echo "AVISO: jstat indisponivel - colunas de GC/heap ficarao vazias"
fi
echo "Saida: $OUTPUT_FILE"
echo "Cores: ${NUM_CORES} | CLK_TCK: ${CLK_TCK}"
echo "cpu_pct = uso INSTANTANEO acumulado entre cores"
echo "  100% = 1 core saturado | ${NUM_CORES}00% = todos os ${NUM_CORES} cores saturados"

echo "timestamp,cpu_pct,mem_rss_kb,mem_vsz_kb,threads_total,ygc,ygc_time_s,fgc,fgc_time_s,heap_used_kb,heap_capacity_kb,metaspace_used_kb" > "$OUTPUT_FILE"

PREV_PROC=$(cpu_jiffies_proc "$TARGET_PID")
PREV_TOTAL=$(cpu_jiffies_total)

END_TIME=$(($(date +%s) + DURATION))

while [[ $(date +%s) -lt $END_TIME ]]; do
  if ! kill -0 "$TARGET_PID" 2>/dev/null; then
    echo "Processo morreu durante coleta"
    break
  fi

  TS=$(date +%s)

  CUR_PROC=$(cpu_jiffies_proc "$TARGET_PID")
  CUR_TOTAL=$(cpu_jiffies_total)
  DELTA_PROC=$((CUR_PROC - PREV_PROC))
  DELTA_TOTAL=$((CUR_TOTAL - PREV_TOTAL))
  if [[ $DELTA_TOTAL -gt 0 ]]; then
    CPU=$(awk -v dp="$DELTA_PROC" -v dt="$DELTA_TOTAL" -v nc="$NUM_CORES" 'BEGIN{printf "%.2f", (dp/dt)*nc*100}')
  else
    CPU="0.00"
  fi
  PREV_PROC=$CUR_PROC
  PREV_TOTAL=$CUR_TOTAL

  STATS=$(ps -p "$TARGET_PID" -o rss=,vsz= 2>/dev/null || echo "0 0")
  RSS=$(echo "$STATS" | awk '{print $1}')
  VSZ=$(echo "$STATS" | awk '{print $2}')

  THREADS=$(ls /proc/"$TARGET_PID"/task 2>/dev/null | wc -l)

  YGC=""
  YGCT=""
  FGC=""
  FGCT=""
  HEAP_USED=""
  HEAP_CAP=""
  META_USED=""

  if [[ $JSTAT_AVAILABLE -eq 1 ]]; then
    JSTAT_LINE=$(jstat -gc "$TARGET_PID" 2>/dev/null | tail -1 || echo "")
    if [[ -n "$JSTAT_LINE" ]]; then
      JSTAT_LINE=$(echo "$JSTAT_LINE" | tr ',' '.')
      read -r S0C S1C S0U S1U EC EU OC OU MC MU CCSC CCSU YGC_v YGCT_v FGC_v FGCT_v CGC CGCT GCT <<< "$JSTAT_LINE"
      YGC="$YGC_v"
      YGCT="$YGCT_v"
      FGC="$FGC_v"
      FGCT="$FGCT_v"
      HEAP_USED=$(awk -v eu="$EU" -v ou="$OU" 'BEGIN{printf "%.0f", eu+ou}')
      HEAP_CAP=$(awk -v ec="$EC" -v oc="$OC" 'BEGIN{printf "%.0f", ec+oc}')
      META_USED=$(awk -v mu="$MU" 'BEGIN{printf "%.0f", mu}')
    fi
  fi

  echo "$TS,$CPU,$RSS,$VSZ,$THREADS,$YGC,$YGCT,$FGC,$FGCT,$HEAP_USED,$HEAP_CAP,$META_USED" >> "$OUTPUT_FILE"

  sleep $INTERVAL
done

echo "Coleta concluida: $(wc -l < "$OUTPUT_FILE") linhas em $OUTPUT_FILE"
