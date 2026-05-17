#!/usr/bin/env bash
# Coleta CPU e memoria da maquina a cada 1 segundo.
# Salva CSV em: <output_file>
#
# Uso:
#   ./collect_sys_metrics.sh <output_file.csv> [duracao_segundos]
#
# Exemplos:
#   ./collect_sys_metrics.sh /tmp/sys_metrics_rep1.csv 50
#   ./collect_sys_metrics.sh /tmp/sys_metrics_rep1.csv      # roda ate Ctrl+C

set -euo pipefail
export LC_NUMERIC=C

OUTPUT="${1:?Uso: $0 <output_file.csv> [duracao_segundos]}"
DURATION="${2:-0}"

mkdir -p "$(dirname "$OUTPUT")"

echo "timestamp,cpu_used_pct,cpu_iowait_pct,mem_total_mb,mem_used_mb,mem_avail_mb,mem_used_pct" \
  > "$OUTPUT"

read_cpu_fields() {
  awk '/^cpu /{print $2,$3,$4,$5,$6,$7,$8,$9; exit}' /proc/stat
}

read_mem_mb() {
  awk '
    /^MemTotal:/     { total = $2 }
    /^MemAvailable:/ { avail = $2 }
    END {
      used = total - avail
      printf "%d %d %d %.1f\n",
        int(total/1024), int(used/1024), int(avail/1024),
        (used * 100.0 / total)
    }
  ' /proc/meminfo
}

read -r prev_user prev_nice prev_sys prev_idle prev_iowait prev_irq prev_softirq prev_steal \
  <<< "$(read_cpu_fields)"

count=0
while true; do
  sleep 1

  read -r user nice sys idle iowait irq softirq steal <<< "$(read_cpu_fields)"

  d_user=$(( user     - prev_user ))
  d_nice=$(( nice     - prev_nice ))
  d_sys=$(( sys       - prev_sys  ))
  d_idle=$(( idle     - prev_idle ))
  d_iowait=$(( iowait - prev_iowait ))
  d_irq=$(( irq       - prev_irq  ))
  d_softirq=$(( softirq - prev_softirq ))
  d_steal=$(( steal   - prev_steal ))

  d_active=$(( d_user + d_nice + d_sys + d_irq + d_softirq + d_steal ))
  d_total=$(( d_active + d_idle + d_iowait ))

  if (( d_total > 0 )); then
    cpu_used=$(LC_NUMERIC=C awk "BEGIN{printf \"%.1f\", $d_active * 100.0 / $d_total}")
    cpu_iowait=$(LC_NUMERIC=C awk "BEGIN{printf \"%.1f\", $d_iowait * 100.0 / $d_total}")
  else
    cpu_used="0.0"
    cpu_iowait="0.0"
  fi

  read -r mem_total_mb mem_used_mb mem_avail_mb mem_used_pct <<< "$(read_mem_mb)"

  ts=$(date +%s)
  echo "${ts},${cpu_used},${cpu_iowait},${mem_total_mb},${mem_used_mb},${mem_avail_mb},${mem_used_pct}" \
    >> "$OUTPUT"

  prev_user=$user; prev_nice=$nice; prev_sys=$sys; prev_idle=$idle
  prev_iowait=$iowait; prev_irq=$irq; prev_softirq=$softirq; prev_steal=$steal

  count=$(( count + 1 ))
  if (( DURATION > 0 && count >= DURATION )); then
    break
  fi
done

echo "Coleta finalizada: $OUTPUT ($count amostras)"
