# Promoción dev → test → prod (DEVOPS-28, DEVOPS-29)

**Build once, deploy many:** la imagen se construye **una sola vez**, en el
merge a `develop`, con tag = SHA del commit. Test y prod reciben **esa misma
imagen**. Nunca se reconstruye para otro ambiente. Los repositorios de ECR son
inmutables (un tag no se puede pisar), así que lo que se probó en un ambiente
es, byte por byte, lo que llega al siguiente.

## Flujo (Git Flow, ADR-001)

```
feature/* ──PR──► develop ──► CI completo ──► push a ECR (:SHA) ──► deploy-dev ──► integration-dev
                                                                                     │ gate 1
develop ──(se corta)──► release/x.y ──► CI completo (no reconstruye: la imagen ya está)
                                        └─► deploy-test ──► integration-test
                                            (verifica gate 1)          │ gate 2
release/x.y ──PR (merge commit)──► main ──► CI completo (no publica nada)
                                            └─► gate-prod ──► ⏸ aprobación ──► deploy-prod ──► smoke-prod
                                                (verifica gate 2)   (production)
```

| Ambiente | Rama que lo dispara | Qué imagen se despliega | Gate de entrada | Aprobación | Tests después |
|---|---|---|---|---|---|
| dev | push a `develop` | la recién construida (`:SHA`) | los 6 gates del CI ([quality-gates.md](../quality-gates.md)) | no | `integration-dev`: colección completa |
| test | push a `release/*` | la del mismo SHA, ya publicada desde `develop` | **`integration-dev` en verde para ese SHA** | no | `integration-test`: colección completa |
| prod | push a `main` (merge de `release/*`) | la del commit de la rama release (2do padre del merge) | **`integration-test` en verde para ese SHA** | **sí** (environment `production`) | `smoke-prod`: solo la carpeta de lectura |

## Los gates entre ambientes

Los dos gates usan [`scripts/verificar-gate.sh`](../../scripts/verificar-gate.sh).
Para un SHA, busca en la API de GitHub Actions un run del pipeline CI donde el
job pedido haya terminado en verde. Si no lo encuentra, el job falla y no se
despliega nada.

- **dev → test:** una versión entra a test solo si **sus** tests de integración
  pasaron contra dev. Una rama `release/*` recién cortada apunta al mismo commit
  que `develop`, así que encuentra ese run.
- **test → prod:** el commit de `main` es un merge nuevo (otro SHA, sin imagen).
  `gate-prod` toma el 2do padre del merge, que es la punta de la rama release,
  y exige que tenga `integration-test` en verde. Corre **antes** de la
  aprobación, así quien aprueba ve en el resumen del run qué SHA va a prod.
- **Aprobación manual:** `deploy-prod` usa el environment `production`, que
  tiene *required reviewers*. El run queda en pausa (*Waiting*) hasta que
  alguien entra a Actions y toca **Review deployments → Approve**.
- En prod Newman corre solo la carpeta `01 Solo lectura`: no se crean órdenes
  de prueba en el ambiente productivo.

## Cómo sacar una versión a prod (paso a paso)

1. Con `develop` en verde (deploy-dev e integration-dev OK), crear la rama
   release desde `develop`: en GitHub, *Branches → New branch* →
   `release/1.0` con origen `develop`.
2. El CI corre en la rama: vuelve a pasar todos los gates, reutiliza la imagen
   y despliega en **test**. Esperar `integration-test` en verde.
3. Abrir un PR `release/1.0` → `main` y mergearlo con **Create a merge commit**
   (no squash ni rebase: hacen falta los dos padres para saber qué SHA se promueve).
4. En el run de `main`: `gate-prod` muestra el SHA, `deploy-prod` queda
   esperando. *Review deployments → production → Approve and deploy*.
5. `deploy-prod` despliega y `smoke-prod` verifica.
6. Volver a mergear `main` en `develop` (Git Flow) si la release tuvo cambios.

## Decisiones y límites

- **Un arreglo para una release se hace en `develop`** y se corta (o se mergea)
  de nuevo a la rama release. Un commit hecho directamente en `release/*` se
  publica en ECR, pero no tiene `integration-dev`, así que el gate 1 lo frena.
  Es a propósito: toda versión pasa por dev antes de llegar a test.
- **Test y prod se prenden solo para probar** (cuestan crédito de AWS
  Academy). Antes de cortar una release, levantarlos con el pipeline de
  tero-infra (*Run workflow* → `test`/`prod` → `apply`). Si el ambiente no
  existe, el deploy falla al buscar los servicios. Ver el runbook
  [prender-el-lab.md](https://github.com/tero-devops-maurivarela002/tero-infra/blob/develop/docs/runbooks/prender-el-lab.md).
- **Rollback en test o prod:** igual que en dev
  (`./scripts/desplegar-ecs.sh prod <sha-anterior>`), con un SHA que ya haya
  estado en ese ambiente.

## Requisitos

En tero-app, *Settings → Environments*: `dev`, `test` y `production`. En
`production`: **Required reviewers** (`maurivarela002`, `mauriciovarela-2inn`).
