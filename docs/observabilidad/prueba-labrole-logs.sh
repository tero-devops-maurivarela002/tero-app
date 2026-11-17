#!/usr/bin/env bash
# DEVOPS-47: ¿LabRole deja que una tarea de ECS Fargate mande logs a CloudWatch?
# Correr en AWS CloudShell, dentro del lab de AWS Academy (región us-east-1).
# Crea recursos de prueba con prefijo "devops47-" y al final los BORRA.
set -uo pipefail

REGION=us-east-1
NAME=devops47-test
LOG_GROUP=/tero/devops47-test
LOG_GROUP_AUTO=/tero/devops47-autocreate
export AWS_DEFAULT_REGION=$REGION

ok()   { echo "✅ $*"; }
fail() { echo "❌ $*"; }
step() { echo; echo "=== $* ==="; }

step "0. Identidad y LabRole"
aws sts get-caller-identity --query Arn --output text
ROLE_ARN=$(aws iam get-role --role-name LabRole --query Role.Arn --output text) \
  && ok "LabRole: $ROLE_ARN" || { fail "No se pudo leer LabRole"; exit 1; }
aws iam list-attached-role-policies --role-name LabRole --query 'AttachedPolicies[].PolicyName' --output text 2>/dev/null \
  && true || echo "(no se pueden listar las políticas de LabRole: normal en Academy)"

step "1. ¿Puedo crear un log group? (lo que va a hacer Terraform)"
aws logs create-log-group --log-group-name "$LOG_GROUP" 2>/tmp/e1 \
  && ok "create-log-group OK" || { fail "create-log-group: $(cat /tmp/e1)"; }
aws logs put-retention-policy --log-group-name "$LOG_GROUP" --retention-in-days 1 2>/tmp/e1b \
  && ok "put-retention-policy OK" || fail "put-retention-policy: $(cat /tmp/e1b)"

step "2. Cluster ECS de prueba (con Container Insights, para probar DEVOPS-49)"
aws ecs create-cluster --cluster-name "$NAME" \
  --settings name=containerInsights,value=enabled \
  --query 'cluster.status' --output text 2>/tmp/e2 \
  && ok "cluster creado" || fail "create-cluster: $(cat /tmp/e2)"

step "2b. Service-linked role de ECS (AWSServiceRoleForECS)"
# En una cuenta nueva no existe hasta que se usa ECS por primera vez, y sin él
# run-task falla con "Unable to assume the service linked role" (primera corrida).
if aws iam get-role --role-name AWSServiceRoleForECS >/dev/null 2>&1; then
  ok "AWSServiceRoleForECS ya existe"
else
  aws iam create-service-linked-role --aws-service-name ecs.amazonaws.com >/dev/null 2>/tmp/e2b \
    && ok "AWSServiceRoleForECS creado" || fail "create-service-linked-role: $(cat /tmp/e2b)"
  echo "Esperando 20 s a que IAM lo propague..."; sleep 20
fi

step "3. Task definition con logs JSON (driver awslogs) y LabRole como execution role"
cat > /tmp/taskdef.json <<JSON
{
  "family": "$NAME",
  "requiresCompatibilities": ["FARGATE"],
  "networkMode": "awsvpc",
  "cpu": "256",
  "memory": "512",
  "executionRoleArn": "$ROLE_ARN",
  "taskRoleArn": "$ROLE_ARN",
  "containerDefinitions": [
    {
      "name": "logger",
      "image": "public.ecr.aws/docker/library/busybox:1.36",
      "essential": true,
      "command": ["sh", "-c",
        "for i in 1 2 3 4 5; do printf '{\"level\":\"INFO\",\"service\":\"devops47\",\"msg\":\"log de prueba %s\"}\\\\n' \$i; sleep 2; done"],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "$LOG_GROUP",
          "awslogs-region": "$REGION",
          "awslogs-stream-prefix": "ecs"
        }
      }
    },
    {
      "name": "logger-autocreate",
      "image": "public.ecr.aws/docker/library/busybox:1.36",
      "essential": false,
      "command": ["sh", "-c", "echo '{\"level\":\"INFO\",\"msg\":\"log group creado por ECS\"}'"],
      "logConfiguration": {
        "logDriver": "awslogs",
        "options": {
          "awslogs-group": "$LOG_GROUP_AUTO",
          "awslogs-region": "$REGION",
          "awslogs-stream-prefix": "ecs",
          "awslogs-create-group": "true"
        }
      }
    }
  ]
}
JSON
TD_ARN=$(aws ecs register-task-definition --cli-input-json file:///tmp/taskdef.json \
  --query 'taskDefinition.taskDefinitionArn' --output text 2>/tmp/e3) \
  && ok "task definition: $TD_ARN" || fail "register-task-definition: $(cat /tmp/e3)"

step "4. Red: VPC por defecto, una subnet y su security group default"
VPC=$(aws ec2 describe-vpcs --filters Name=isDefault,Values=true --query 'Vpcs[0].VpcId' --output text)
SUBNET=$(aws ec2 describe-subnets --filters Name=vpc-id,Values=$VPC Name=default-for-az,Values=true --query 'Subnets[0].SubnetId' --output text)
SG=$(aws ec2 describe-security-groups --filters Name=vpc-id,Values=$VPC Name=group-name,Values=default --query 'SecurityGroups[0].GroupId' --output text)
echo "VPC=$VPC SUBNET=$SUBNET SG=$SG"

step "5. Correr la tarea en Fargate"
TASK=""
for intento in 1 2 3; do
  TASK=$(aws ecs run-task --cluster "$NAME" --launch-type FARGATE --task-definition "$TD_ARN" \
    --network-configuration "awsvpcConfiguration={subnets=[$SUBNET],securityGroups=[$SG],assignPublicIp=ENABLED}" \
    --query 'tasks[0].taskArn' --output text 2>/tmp/e5) && break
  fail "run-task (intento $intento): $(cat /tmp/e5)"; TASK=""; sleep 20
done
[ -n "$TASK" ] && ok "tarea lanzada: $TASK"

if [ -n "${TASK:-}" ] && [ "$TASK" != "None" ]; then
  echo "Esperando a que la tarea termine (1-3 minutos)..."
  aws ecs wait tasks-stopped --cluster "$NAME" --tasks "$TASK"
  aws ecs describe-tasks --cluster "$NAME" --tasks "$TASK" \
    --query 'tasks[0].{estado:lastStatus,motivo:stoppedReason,contenedores:containers[].{nombre:name,exit:exitCode,motivo:reason}}' --output json
fi

step "6. RESULTADO: ¿llegaron los logs a CloudWatch?"
sleep 10
echo "--- $LOG_GROUP (log group creado antes) ---"
aws logs tail "$LOG_GROUP" --since 15m 2>/tmp/e6 && true || fail "$(cat /tmp/e6)"
echo "--- $LOG_GROUP_AUTO (log group creado por ECS con awslogs-create-group) ---"
aws logs tail "$LOG_GROUP_AUTO" --since 15m 2>/tmp/e7 && true || fail "$(cat /tmp/e7)"

step "7. Limpieza (borra todo lo de la prueba)"
aws ecs deregister-task-definition --task-definition "$TD_ARN" >/dev/null 2>&1 && ok "task definition dada de baja"
aws ecs delete-cluster --cluster "$NAME" >/dev/null 2>&1 && ok "cluster borrado"
aws logs delete-log-group --log-group-name "$LOG_GROUP" 2>/dev/null && ok "log group borrado"
aws logs delete-log-group --log-group-name "$LOG_GROUP_AUTO" 2>/dev/null && ok "log group autocreado borrado"
echo; echo "Listo. Copiá TODA la salida de este script y pasásela a Claude."
