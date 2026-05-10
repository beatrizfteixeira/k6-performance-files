#!/usr/bin/env bash
set -euo pipefail

# Filtra CSVs do k6 mantendo apenas timestamp e duration_ms
# de http_req_duration na fase 'steady' (remove warmup).
#
# Uso:
#   ./filter-csv.sh <arquivo.csv> [arquivo2.csv ...]
#   ./filter-csv.sh <diretorio>
#   ./filter-csv.sh <diretorio> -r        # recursivo
#
# Saida:
#   Por padrao gera <nome>_min.csv ao lado do arquivo original.
#   Use -o <dir> para salvar em outro diretorio.
#   Use --inplace para sobrescrever o arquivo original.

usage() {
  cat <<'EOF'
Uso:
  ./filter-csv.sh [opcoes] <arquivo.csv|diretorio> [...]

Opcoes:
  -o, --output-dir <dir>   Salva os arquivos filtrados em <dir>
  -r, --recursive          Processa diretorios recursivamente
      --inplace            Sobrescreve o arquivo original
      --suffix <sufixo>    Sufixo do arquivo de saida (padrao: _min)
  -h, --help               Mostra esta ajuda

Exemplos:
  ./filter-csv.sh resultado.csv
  ./filter-csv.sh resultado.csv -o ./filtrados
  ./filter-csv.sh ./results -r
  ./filter-csv.sh ./results -r --inplace
EOF
}

OUTPUT_DIR=""
RECURSIVE=0
INPLACE=0
SUFFIX="_min"
INPUTS=()

while [[ $# -gt 0 ]]; do
  case "$1" in
    -o|--output-dir)
      OUTPUT_DIR="$2"
      shift 2
      ;;
    -r|--recursive)
      RECURSIVE=1
      shift
      ;;
    --inplace)
      INPLACE=1
      shift
      ;;
    --suffix)
      SUFFIX="$2"
      shift 2
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    -*)
      echo "Opcao desconhecida: $1" >&2
      usage
      exit 1
      ;;
    *)
      INPUTS+=("$1")
      shift
      ;;
  esac
done

if [[ ${#INPUTS[@]} -eq 0 ]]; then
  usage
  exit 1
fi

if [[ -n "${OUTPUT_DIR}" ]]; then
  mkdir -p "${OUTPUT_DIR}"
fi

filter_csv() {
  local input="$1"
  local output="$2"

  awk -F',' '
    NR == 1 {
      for (i = 1; i <= NF; i++) {
        if ($i == "metric_name") col_metric = i
        else if ($i == "timestamp") col_ts = i
        else if ($i == "metric_value") col_val = i
        else if ($i == "scenario") col_scenario = i
      }
      if (!col_metric || !col_ts || !col_val || !col_scenario) {
        print "ERRO: cabecalho inesperado em " FILENAME > "/dev/stderr"
        exit 1
      }
      print "timestamp,duration_ms"
      next
    }
    $col_metric == "http_req_duration" && $col_scenario == "steady" {
      print $col_ts "," $col_val
    }
  ' "${input}" > "${output}.tmp"

  mv "${output}.tmp" "${output}"
}

resolve_output() {
  local input="$1"
  local base
  base=$(basename "${input}")
  local name="${base%.csv}"

  if [[ ${INPLACE} -eq 1 ]]; then
    echo "${input}"
  elif [[ -n "${OUTPUT_DIR}" ]]; then
    echo "${OUTPUT_DIR}/${name}${SUFFIX}.csv"
  else
    local dir
    dir=$(dirname "${input}")
    echo "${dir}/${name}${SUFFIX}.csv"
  fi
}

process_file() {
  local input="$1"

  if [[ ! -f "${input}" ]]; then
    echo "AVISO: arquivo nao encontrado: ${input}" >&2
    return
  fi

  local output
  output=$(resolve_output "${input}")

  filter_csv "${input}" "${output}"

  local rows_in rows_out
  rows_in=$(($(wc -l < "${input}") - 1))
  rows_out=$(($(wc -l < "${output}") - 1))
  printf '  %s -> %s (%d -> %d linhas)\n' "${input}" "${output}" "${rows_in}" "${rows_out}"
}

process_dir() {
  local dir="$1"
  local find_args=("${dir}" -type f -name '*.csv' '!' -name "*${SUFFIX}.csv")

  if [[ ${RECURSIVE} -eq 0 ]]; then
    find_args=("${dir}" -maxdepth 1 -type f -name '*.csv' '!' -name "*${SUFFIX}.csv")
  fi

  while IFS= read -r -d '' csv; do
    process_file "${csv}"
  done < <(find "${find_args[@]}" -print0)
}

echo "Filtrando CSVs (mantendo apenas http_req_duration em fase steady)..."
echo ""

for target in "${INPUTS[@]}"; do
  if [[ -d "${target}" ]]; then
    echo "Diretorio: ${target}"
    process_dir "${target}"
  elif [[ -f "${target}" ]]; then
    process_file "${target}"
  else
    echo "AVISO: nao encontrado: ${target}" >&2
  fi
done

echo ""
echo "Concluido."
