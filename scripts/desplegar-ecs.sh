#!/usr/bin/env bash
# CD a ECS (DEVOPS-27): despliega en un ambiente las imágenes de un commit.
#
# Uso:   ./scripts/desplegar-ecs.sh <ambiente> <sha>
# Ej.:   ./scripts/desplegar-ecs.sh dev 745bca30e1089cc4303cfa2abe02b127e99434a7
#
# Lo corre el job deploy-dev del CI en cada merge a develop, pero también se
# puede correr a mano (CloudShell) con credenciales de AWS válidas.
#
# Para cada uno de los 6 servicios:
#   1. Lee la task definition ACTUAL del servicio (la que dejó Terraform o el
#      deploy anterior), así no se pierden variables, secrets ni logs.
#   2. Le cambia SOLO la imagen por <registry>/tero/<repo>:<sha> y registra una
#      revisión nueva de la misma familia (tero-<amb>-<svc>).
#   3. Hace update-service para que ECS haga el rolling update.
# Después espera a que los 6 queden estables, verifica que no hubo rollback
# del circuit breaker y hace un smoke test contra el ALB público.
set -euo pipefail

ENVIRONMENT="${1:?Falta el ambiente (dev, test o prod)}"
SHA="${2:?Falta el SHA del commit a desplegar}"
REGION="${AWS_REGION:-us-east-1}"
CLUSTER="tero-${ENVIRONMENT}"
ALB_NAME="tero-${ENVIRONMENT}-alb"

# servicio ECS -> repositorio de ECR (el servicio "carts" usa el repo "cart").
declare -A REPO=(
  [catalog]=catalog [carts]=cart [orders]=orders
  [checkout]=checkout [ui]=ui [admin]=admin
)
# Orden de despliegue: primero los backends, al final las interfaces.
SERVICES=(catalog carts orders checkout ui admin)

ACCOUNT="$(aws sts get-caller-identity --query Account --output text)"
REGISTRY="${ACCOUNT}.dkr.ecr.${REGION}.amazonaws.com"

echo "==> Desplegando ${SHA} en ${CLUSTER}"

# 0. Antes de tocar nada: las 6 imágenes tienen que existir en ECR.
for svc in "${SERVICES[@]}"; do
  aws ecr describe-images --region "$REGION" \
    --repository-name "tero/${REPO[$svc]}" --image-ids imageTag="$SHA" >/dev/null \
    || { echo "❌ No existe tero/${REPO[$svc]}:${SHA} en ECR"; exit 1; }
done
echo "✅ Las 6 imágenes existen en ECR"

declare -A NEW_TD=()
for svc in "${SERVICES[@]}"; do
  image="${REGISTRY}/tero/${REPO[$svc]}:${SHA}"

  current_td="$(aws ecs describe-services --region "$REGION" --cluster "$CLUSTER" \
    --services "$svc" --query 'services[0].taskDefinition' --output text)"

  # Se sacan los campos de solo lectura que describe devuelve pero register
  # no acepta, se conservan los tags y se cambia SOLO la imagen del contenedor.
  aws ecs describe-task-definition --region "$REGION" \
    --task-definition "$current_td" --include TAGS --output json \
  | jq --arg img "$image" --arg name "$svc" '
      (.tags // []) as $tags
      | .taskDefinition
      | .containerDefinitions |= map(if .name == $name then .image = $img else . end)
      | del(.taskDefinitionArn, .revision, .status, .requiresAttributes,
            .compatibilities, .registeredAt, .registeredBy, .deregisteredAt)
      | if ($tags | length) > 0 then . + {tags: $tags} else . end
    ' > "/tmp/td-${svc}.json"

  NEW_TD[$svc]="$(aws ecs register-task-definition --region "$REGION" \
    --cli-input-json "file:///tmp/td-${svc}.json" \
    --query 'taskDefinition.taskDefinitionArn' --output text)"

  aws ecs update-service --region "$REGION" --cluster "$CLUSTER" --service "$svc" \
    --task-definition "${NEW_TD[$svc]}" --query 'service.serviceName' --output text >/dev/null

  echo "  ${svc}: ${current_td##*/} -> ${NEW_TD[$svc]##*/}"
done

echo "==> Esperando a que los 6 servicios queden estables (puede tardar unos minutos)"
aws ecs wait services-stable --region "$REGION" --cluster "$CLUSTER" --services "${SERVICES[@]}"

# "services-stable" vuelve cuando corren las tareas pedidas, pero ECS marca el
# deploy como COMPLETED (rolloutState) un rato después. Con 2 tareas por
# servicio (prod) el waiter volvía antes y el deploy fallaba con IN_PROGRESS
# aunque había salido bien. Se espera a que ningún servicio siga IN_PROGRESS
# (hasta ROLLOUT_TIMEOUT segundos, 10 minutos por defecto).
limite=$(( SECONDS + ${ROLLOUT_TIMEOUT:-600} ))
while :; do
  pendientes="$(aws ecs describe-services --region "$REGION" --cluster "$CLUSTER" --services "${SERVICES[@]}" \
    --output text --query 'services[?deployments[?status==`PRIMARY` && rolloutState==`IN_PROGRESS`]].serviceName')"
  [[ -z "$pendientes" || "$pendientes" == "None" ]] && break
  if (( SECONDS >= limite )); then
    echo "⚠️  Siguen en IN_PROGRESS después de ${ROLLOUT_TIMEOUT:-600}s: ${pendientes}"
    break
  fi
  echo "  esperando que termine el rollout de: ${pendientes}"
  sleep 15
done

# "Estable" también puede significar que el circuit breaker hizo ROLLBACK a la
# versión anterior: hay que confirmar que cada servicio corre la IMAGEN nueva.
# Se compara la imagen y no el número de revisión porque otro proceso (por
# ejemplo el apply del pipeline de Terraform) puede registrar una revisión
# equivalente con la misma imagen: eso es correcto y no es un fallo del deploy.
failed=0
for svc in "${SERVICES[@]}"; do
  expected="${REGISTRY}/tero/${REPO[$svc]}:${SHA}"
  read -r running_td rollout <<<"$(aws ecs describe-services --region "$REGION" --cluster "$CLUSTER" \
    --services "$svc" --output text \
    --query 'services[0].deployments[?status==`PRIMARY`] | [0].[taskDefinition, rolloutState]')"
  running_image="$(aws ecs describe-task-definition --region "$REGION" --task-definition "$running_td" \
    --output text --query "taskDefinition.containerDefinitions[?name=='${svc}'] | [0].image")"

  if [[ "$running_image" != "$expected" ]]; then
    echo "❌ ${svc} corre ${running_image##*/} (${running_td##*/}) en vez de ${REPO[$svc]}:${SHA}: rollback del circuit breaker o un deploy posterior"
    failed=1
  elif [[ "$rollout" != "COMPLETED" ]]; then
    echo "❌ ${svc}: el deploy quedó en estado ${rollout}"
    failed=1
  elif [[ "$running_td" != "${NEW_TD[$svc]}" ]]; then
    echo "  ${svc}: corre ${running_td##*/} (misma imagen, registrada por otro proceso, ej. Terraform)"
  fi
done
[[ "$failed" -eq 0 ]] || exit 1
echo "✅ Los 6 servicios corren ${SHA}"

# Smoke test contra el ALB público: la tienda y una API que pasa por el ALB interno.
ALB_DNS="$(aws elbv2 describe-load-balancers --region "$REGION" --names "$ALB_NAME" \
  --query 'LoadBalancers[0].DNSName' --output text)"
# HTTP a propósito: en AWS Academy no hay dominio propio ni certificado de ACM,
# así que el ALB solo escucha en el puerto 80 (riesgo aceptado, ver
# docs/seguridad/checkov.md de tero-infra: CKV_AWS_2). Pasar a https:// cuando haya dominio.
BASE_URL="http://${ALB_DNS}" # NOSONAR
for path in /health / /api/catalog/products; do
  ok=0
  for _ in 1 2 3 4 5 6; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "${BASE_URL}${path}" || true)"
    if [[ "$code" = "200" ]]; then ok=1; break; fi
    sleep 10
  done
  if [[ "$ok" -eq 1 ]]; then echo "✅ GET ${path} -> 200"; else echo "❌ GET ${path} -> ${code}"; exit 1; fi
done

echo "🚀 Deploy de ${SHA} en ${ENVIRONMENT} OK: ${BASE_URL}"
# Para el link del ambiente en la pestaña Deployments de GitHub.
if [[ -n "${GITHUB_OUTPUT:-}" ]]; then echo "url=${BASE_URL}" >> "$GITHUB_OUTPUT"; fi
