# CD a Dev (DEVOPS-27)

Cada merge a `develop` despliega automáticamente en el ambiente **dev** de ECS
las imágenes de ese commit. No hay pasos manuales.

## Flujo

```
PR a develop ──► CI (gitleaks, tests, semgrep, trivy fs, sonar, docker build + trivy image)
                 (en el PR NO se publica ni se despliega nada)
merge ─────────► mismo CI ──► push de las 6 imágenes a ECR (tag = SHA)
                          └─► deploy-dev ──► ECS tero-dev ──► smoke test
```

El job `deploy-dev` de [`.github/workflows/ci.yml`](../../.github/workflows/ci.yml):

- tiene `needs: docker-build`: si **una** de las 6 imágenes no pasó Trivy o no
  se pudo publicar, no se despliega ninguna (no queda dev con versiones mezcladas);
- corre solo en `push` a `develop` (nunca en PRs ni en `main`);
- usa el ambiente de GitHub `dev` (historial en la pestaña *Deployments*) y
  `concurrency: deploy-dev`, para que dos merges seguidos no se pisen;
- llama a [`scripts/desplegar-ecs.sh`](../../scripts/desplegar-ecs.sh).

## Qué hace el script

Uso: `./scripts/desplegar-ecs.sh <ambiente> <sha>` (lo corre el CI, pero también
se puede usar a mano desde CloudShell para volver a una versión anterior).

1. Verifica que existan las 6 imágenes `tero/<repo>:<sha>` en ECR antes de tocar nada.
2. Por servicio (`catalog, carts, orders, checkout, ui, admin`): lee la task
   definition que está corriendo, le cambia **solo la imagen** y registra una
   revisión nueva de la misma familia (`tero-dev-<svc>`). Variables, secrets
   (Secrets Manager), logs y CPU/memoria se mantienen como los dejó Terraform.
3. `aws ecs update-service` → ECS hace un *rolling update*: levanta las tareas
   nuevas, espera que el target group las vea sanas (`/health`) y recién ahí
   baja las viejas (`minimum_healthy_percent = 100`: sin corte).
4. `aws ecs wait services-stable` para los 6 servicios.
5. Confirma que cada servicio corre la revisión **nueva**: si una tarea no
   levanta, el *circuit breaker* de ECS hace rollback solo a la versión anterior
   y el servicio queda "estable" igual; por eso se chequea y el job falla.
6. Smoke test contra el ALB público: `GET /health`, `GET /` y
   `GET /api/catalog/products` tienen que dar 200 (con reintentos). La última
   pasa por ui → ALB interno → catalog → RDS, o sea que prueba la cadena completa.

## Rollback

- **Automático**: circuit breaker de ECS (si las tareas nuevas no arrancan).
- **Manual**: volver a correr el script con el SHA anterior (las imágenes son
  inmutables y se guardan las últimas 30 por repositorio):
  `./scripts/desplegar-ecs.sh dev <sha-anterior>`, o revertir el PR en `develop`
  (el revert es un commit nuevo y el CD lo despliega solo).

## Relación con Terraform

Terraform (tero-infra) crea la infraestructura y la primera revisión de cada task
definition con la variable `image_tag`; el CD después registra revisiones nuevas
cambiando solo la imagen. El pipeline de Terraform de tero-infra (DEVOPS-45)
toma solo el SHA que está corriendo en dev, así que no pisa el CD. Si se corre
`terraform apply` a mano, hay que pasarle el SHA desplegado (el último commit
de `develop` de tero-app):

```bash
terraform plan -var-file=envs/dev.tfvars -var="image_tag=<último SHA de develop>"
```

Si se pasa un SHA viejo, Terraform vuelve los servicios a esa versión.

## Requisitos

- Secrets del repo `AWS_ACCESS_KEY_ID`, `AWS_SECRET_ACCESS_KEY` y
  `AWS_SESSION_TOKEN`. En AWS Academy son temporales: hay que actualizarlos en
  cada sesión del lab, si no el deploy falla en "Credenciales de AWS".
- El ambiente dev levantado (`terraform apply` en tero-infra). Si dev está
  destruido, `deploy-dev` falla al buscar los servicios: es esperado, el resto del CI (y las imágenes en ECR) quedan bien.
