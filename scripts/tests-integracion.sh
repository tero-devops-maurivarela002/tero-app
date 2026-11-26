#!/usr/bin/env bash
# Tests de integración con Newman (DEVOPS-39).
#
# Uso:   ./scripts/tests-integracion.sh <url-base> [carpeta]
# Ej.:   ./scripts/tests-integracion.sh http://localhost:8080
#        ./scripts/tests-integracion.sh http://tero-dev-alb-123.us-east-1.elb.amazonaws.com
#        ./scripts/tests-integracion.sh http://<alb-de-prod> "01 Solo lectura (health y catálogo)"
#
# Corre la colección tests/integration/tero.postman_collection.json contra la
# tienda (el UI y su proxy /api/* hacia catalog, carts, checkout y orders).
# Sin [carpeta] corre todo, incluido el flujo de compra que crea una orden de
# prueba. Con una carpeta corre solo esa (en prod, solo la de lectura).
#
# Antes de correr espera hasta ~2 minutos a que /health responda 200, porque
# en CI la tienda recién se levantó (compose) o recién se desplegó (ECS).
# Sale con código distinto de 0 si falla alguna aserción: eso corta el pipeline.
set -euo pipefail

BASE_URL="${1:?Falta la URL base (ej. http://localhost:8080)}"
FOLDER="${2:-}"
BASE_URL="${BASE_URL%/}"
NEWMAN_VERSION="6.2.3" # versión fija, nunca "latest"
COLLECTION="tests/integration/tero.postman_collection.json"
REPORT_DIR="${REPORT_DIR:-reports}"

cd "$(dirname "$0")/.."
mkdir -p "$REPORT_DIR"

echo "Esperando a que ${BASE_URL}/health responda..."
for i in $(seq 1 24); do
  code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 5 "${BASE_URL}/health" || true)"
  if [[ "$code" == "200" ]]; then
    echo "La tienda responde (intento ${i})."
    break
  fi
  if [[ "$i" == "24" ]]; then
    echo "ERROR: ${BASE_URL}/health no respondió 200 en 2 minutos (último código: ${code})." >&2
    exit 1
  fi
  sleep 5
done

args=(run "$COLLECTION"
  --env-var "base_url=${BASE_URL}"
  --reporters cli,junit
  --reporter-junit-export "${REPORT_DIR}/newman.xml"
  # Corta en la primera aserción fallida de un request y no sigue con el resto
  # del flujo (si no se creó la orden, no tiene sentido buscarla).
  --bail
  --timeout-request 10000)
if [[ -n "$FOLDER" ]]; then
  args+=(--folder "$FOLDER")
fi

npx --yes "newman@${NEWMAN_VERSION}" "${args[@]}"
