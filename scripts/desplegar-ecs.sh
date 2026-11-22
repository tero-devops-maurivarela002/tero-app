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

# "Estable" también puede significar que el circuit breaker hizo ROLLBACK a la
# versión anterior: hay que confirmar que corre la revisión nueva.
failed=0
for svc in "${SERVICES[@]}"; do
  running="$(aws ecs describe-services --region "$REGION" --cluster "$CLUSTER" \
    --services "$svc" --query 'services[0].deployments[?status==`PRIMARY`].taskDefinition | [0]' --output text)"
  if [ "$running" != "${NEW_TD[$svc]}" ]; then
    echo "❌ ${svc} no quedó con la revisión nueva (corre ${running##*/}): rollback del circuit breaker"
    failed=1
  fi
done
[ "$failed" -eq 0 ] || exit 1
echo "✅ Los 6 servicios corren ${SHA}"

# Smoke test contra el ALB público: la tienda y una API que pasa por el ALB interno.
ALB_DNS="$(aws elbv2 describe-load-balancers --region "$REGION" --names "$ALB_NAME" \
  --query 'LoadBalancers[0].DNSName' --output text)"
for path in /health / /api/catalog/products; do
  ok=0
  for _ in 1 2 3 4 5 6; do
    code="$(curl -s -o /dev/null -w '%{http_code}' --max-time 10 "http://${ALB_DNS}${path}" || true)"
    if [ "$code" = "200" ]; then ok=1; break; fi
    sleep 10
  done
  if [ "$ok" -eq 1 ]; then echo "✅ GET ${path} -> 200"; else echo "❌ GET ${path} -> ${code}"; exit 1; fi
done

echo "🚀 Deploy de ${SHA} en ${ENVIRONMENT} OK: http://${ALB_DNS}"
