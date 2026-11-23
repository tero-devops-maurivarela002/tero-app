#!/usr/bin/env bash
# Corre las consultas de CloudWatch Logs Insights de DEVOPS-48 sobre los 6
# servicios de un ambiente y muestra los resultados en tabla.
#
# Uso:  ./scripts/consultar-logs.sh [ambiente] [minutos]   (por defecto: dev 60)
# Las consultas están explicadas en docs/observabilidad/logs-json.md
set -euo pipefail

ENVIRONMENT="${1:-dev}"
MINUTES="${2:-60}"
REGION="${AWS_REGION:-us-east-1}"
LOG_GROUPS=()
for svc in catalog carts orders checkout ui admin; do
  LOG_GROUPS+=("/tero/${ENVIRONMENT}/${svc}")
done

declare -A QUERIES=(
  ["1-errores"]='fields @timestamp, service, level, method, path, status, msg, message | filter level in ["ERROR", "error"] | sort @timestamp desc | limit 20'
  ["2-requests-por-status"]='filter msg = "request" | stats count(*) as requests by service, status | sort service, status'
  ["3-latencia"]='filter msg = "request" | stats count(*) as requests, avg(duration_ms) as prom_ms, pct(duration_ms, 95) as p95_ms, pct(duration_ms, 99) as p99_ms by service | sort p95_ms desc'
  ["4-rutas-lentas"]='filter msg = "request" | stats count(*) as requests, pct(duration_ms, 95) as p95_ms by service, method, path | sort p95_ms desc | limit 10'
)

end="$(date +%s)"
start=$(( end - MINUTES * 60 ))

for name in $(printf '%s\n' "${!QUERIES[@]}" | sort); do
  echo "=== ${name} (últimos ${MINUTES} min, ${ENVIRONMENT}) ==="
  id="$(aws logs start-query --region "$REGION" --log-group-names "${LOG_GROUPS[@]}" \
        --start-time "$start" --end-time "$end" \
        --query-string "${QUERIES[$name]}" --query queryId --output text)"
  status="Running"
  while [[ "$status" == "Running" || "$status" == "Scheduled" ]]; do
    sleep 2
    status="$(aws logs get-query-results --region "$REGION" --query-id "$id" --query status --output text)"
  done
  aws logs get-query-results --region "$REGION" --query-id "$id" --output json \
    | jq -r '.results[] | map(select(.field != "@ptr") | "\(.field)=\(.value)") | join("  ")'
  echo
done
