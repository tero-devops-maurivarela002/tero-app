# Validación de logs en CloudWatch con LabRole (DEVOPS-47)

## Objetivo

Antes de escribir el Terraform de observabilidad, confirmar que en el lab de AWS Academy:

1. Podemos crear log groups de CloudWatch y ponerles retención (lo que va a hacer Terraform).
2. Una tarea de ECS Fargate que usa **LabRole** como *execution role* puede mandar sus logs a CloudWatch con el driver `awslogs`.
3. Los logs en formato JSON llegan tal cual (para poder filtrarlos después con Logs Insights).
4. Se puede crear un cluster ECS con Container Insights activado (insumo para DEVOPS-49).

Esto importa porque en Academy **no podemos crear roles de IAM propios**: todo tiene que andar con el LabRole que ya existe.

## Cómo se probó

Con el script [`prueba-labrole-logs.sh`](prueba-labrole-logs.sh), corrido en AWS CloudShell dentro del lab (región `us-east-1`, usuario `voclabs`). El script:

| Paso | Qué hace |
|------|----------|
| 0 | Muestra la identidad (`voclabs`) y lee el ARN de `LabRole`. |
| 1 | Crea el log group `/tero/devops47-test` con retención de 1 día. |
| 2 | Crea el cluster ECS `devops47-test` con Container Insights activado. |
| 2b | Verifica que exista el service-linked role `AWSServiceRoleForECS` y, si no, lo crea. |
| 3 | Registra una task definition Fargate con dos contenedores `busybox` que escriben logs JSON con el driver `awslogs`. `executionRoleArn` y `taskRoleArn` son LabRole. Uno de ellos usa `awslogs-create-group=true` para ver si ECS puede crear el log group solo. |
| 4 | Toma la VPC por defecto, una subnet y su security group. |
| 5 | Corre la tarea en Fargate y espera a que termine. |
| 6 | Lee los logs de los dos log groups con `aws logs tail`. |
| 7 | Borra todo lo que creó. |

## Resultado (corrida del 17/11/2026)

| Verificación | Resultado |
|---|---|
| Crear log group y retención con `voclabs` | ✅ OK |
| Crear cluster ECS con Container Insights | ✅ OK (`ACTIVE`) |
| Service-linked role `AWSServiceRoleForECS` | ✅ Existe (ver nota) |
| Registrar task definition con LabRole como execution/task role | ✅ OK |
| Tarea Fargate termina bien | ✅ `STOPPED`, los dos contenedores con exit 0 |
| Logs JSON en el log group creado antes | ✅ Llegaron los 5 mensajes, con stream `ecs/logger/<task-id>` |
| Log group creado por ECS (`awslogs-create-group=true`) | ✅ Lo creó y llegó el mensaje |
| Limpieza | ✅ Todo borrado |

Salida del paso 6 (recortada):

```
--- /tero/devops47-test (log group creado antes) ---
2026-11-17T23:38:31Z ecs/logger/0da95399... {"level":"INFO","service":"devops47","msg":"log de prueba 1"}
...
2026-11-17T23:38:39Z ecs/logger/0da95399... {"level":"INFO","service":"devops47","msg":"log de prueba 5"}
--- /tero/devops47-autocreate (log group creado por ECS con awslogs-create-group) ---
2026-11-17T23:38:31Z ecs/logger-autocreate/0da95399... {"level":"INFO","msg":"log group creado por ECS"}
```

**Nota: primera corrida fallida.** La primera vez `run-task` falló con *"Unable to assume the service linked role"*. La cuenta del lab era nueva y todavía no existía `AWSServiceRoleForECS`, el rol que AWS crea la primera vez que se usa ECS. Se agregó el paso 2b al script y en la segunda corrida el rol ya existía, así que la tarea arrancó sin problema. En un lab nuevo puede volver a pasar, y el paso 2b lo resuelve.

## Decisiones para el Terraform de logs

1. **Los log groups los crea Terraform** (`aws_cloudwatch_log_group`), uno por servicio: `/tero/<entorno>/<servicio>`, por ejemplo `/tero/dev/catalog`. No usamos `awslogs-create-group=true` aunque funcione, porque los log groups creados así no tienen retención (guardan para siempre y cuestan) y quedan fuera del estado de Terraform.
2. **Retención corta**: 7 días en dev/test y 14 en prod, para cuidar el crédito de Academy.
3. **LabRole como `execution_role_arn` y `task_role_arn`** de todas las task definitions, leído con `data "aws_iam_role" "lab" { name = "LabRole" }`. No se crean roles de IAM.
4. **Driver `awslogs`** con `awslogs-stream-prefix = "ecs"`, así cada stream queda como `ecs/<contenedor>/<task-id>`.
5. **Logs en JSON** desde las apps: llegan tal cual a CloudWatch y se pueden consultar con Logs Insights.
6. **Container Insights activado** en el cluster (`setting { name = "containerInsights", value = "enabled" }`). Se validó que Academy lo permite y queda para DEVOPS-49.
7. **Prerrequisito del lab**: que exista `AWSServiceRoleForECS`. Si `terraform apply` falla con el error del service-linked role, correr una vez `aws iam create-service-linked-role --aws-service-name ecs.amazonaws.com` (o el paso 2b del script).

## Evidencia

- Captura de la salida de CloudShell, pasos 5 y 6: `docs/evidencias/sprint2/devops47-cloudshell.png`.
