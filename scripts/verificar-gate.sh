#!/usr/bin/env bash
# Quality gate entre ambientes (DEVOPS-29).
#
# Uso:   ./scripts/verificar-gate.sh <sha> <nombre del job>
# Ej.:   ./scripts/verificar-gate.sh 91cd07e... "integration-dev (newman contra dev)"
#
# Sale con 0 solo si, para ESE commit, hay un run del pipeline CI (push) en el
# que el job pedido terminó en "success". Así una versión pasa a test solo si
# sus tests de integración pasaron en dev, y a prod solo si pasaron en test.
# Como la imagen es la misma (tag = SHA, repos de ECR inmutables), lo que se
# probó es exactamente lo que se promueve.
#
# Necesita: gh (viene en los runners de GitHub), GH_TOKEN con actions:read y
# GITHUB_REPOSITORY (owner/repo).
set -euo pipefail

SHA="${1:?Falta el SHA del commit}"
JOB="${2:?Falta el nombre del job que tiene que haber pasado}"
REPO="${GITHUB_REPOSITORY:?Falta GITHUB_REPOSITORY (owner/repo)}"

echo "Buscando \"${JOB}\" en verde para ${SHA}..."
runs="$(gh api "repos/${REPO}/actions/workflows/ci.yml/runs?head_sha=${SHA}&event=push&per_page=50" \
          --jq '.workflow_runs[].id')"

for run in $runs; do
  ok="$(gh api "repos/${REPO}/actions/runs/${run}/jobs?per_page=100" \
          --jq "[.jobs[] | select(.name == \"${JOB}\" and .conclusion == \"success\")] | length")"
  if [[ "$ok" -gt 0 ]]; then
    url="https://github.com/${REPO}/actions/runs/${run}"
    echo "✅ Gate OK: \"${JOB}\" pasó para ${SHA} en ${url}"
    if [[ -n "${GITHUB_STEP_SUMMARY:-}" ]]; then
      echo "Gate: **${JOB}** pasó para \`${SHA}\` ([run](${url}))" >> "$GITHUB_STEP_SUMMARY"
    fi
    exit 0
  fi
done

echo "❌ Gate NO superado: no hay ningún run de CI para ${SHA} con \"${JOB}\" en verde." >&2
echo "   Esa versión no se promueve. Primero tiene que pasar por el ambiente anterior." >&2
exit 1
