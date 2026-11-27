# Informe de seguridad: hallazgos, remediaciones y excepciones (DEVOPS-37)

> Fecha de corte: 27/11/2026. Cubre los dos repositorios: `tero-app` (código, dependencias e imágenes) y `tero-infra` (Terraform y AWS).
> Cada herramienta tiene su documento con el detalle; este informe junta los resultados y explica qué se hizo con cada hallazgo.

## 1. Resumen

| Herramienta | Qué analiza | Dónde corre | Hallazgos iniciales | Hoy |
|---|---|---|---|---|
| Gitleaks | Secretos en **todo** el historial de git | CI de tero-app, primer job | 10 secretos en el commit inicial | 0 (commit inicial en allowlist, secretos rotados) |
| Semgrep (SAST) | Código fuente: OWASP Top 10, reglas generales, Dockerfiles | CI de tero-app | 16 WARNING en el primer PR; 1 XSS fuera del ruleset | 0 ERROR, 0 WARNING; XSS corregido |
| Trivy fs (SCA) | Dependencias declaradas (`go.mod`, `yarn.lock`, `package-lock.json`, `requirements.txt`) | CI de tero-app | 6 CRITICAL, 69 HIGH, 56 MEDIUM, 9 LOW | **0 de cualquier severidad** |
| Trivy image | La imagen final: sistema operativo base, runtime y dependencias | CI de tero-app, antes del push a ECR | 107 CRITICAL/HIGH en las imágenes base | 0 (1 excepción con fecha de revisión) |
| SonarCloud | Bugs, vulnerabilidades y *security hotspots* del código nuevo | CI de tero-app (PRs y `develop`) | Quality gate *Sonar way* | Gate en verde en todos los PRs |
| Checkov (IaC) | Terraform contra buenas prácticas de seguridad de AWS | CI de tero-infra | 52 controles fallidos (22 reglas) en la primera corrida | 0 fallidos: 2 corregidos, el resto con excepción justificada en el código |
| Escaneo de ECR + Lambda | Cada imagen publicada, con la base de vulnerabilidades de AWS | AWS: EventBridge → Lambda → SNS (mail) | n/a (control de detección, no de bloqueo) | Activo en `global/` |

Todas las herramientas de CI son **gates**: si encuentran algo nuevo por encima del umbral, el pipeline falla y no se publica ninguna imagen ni se aplica ningún cambio de infraestructura. Los umbrales y su justificación están en [quality-gates.md](quality-gates.md).

Las observaciones del auditor que cubre este informe ([assessment.md](assessment.md)):

| Observación | Cómo se cerró |
|---|---|
| **A.** Contraseñas en el repo | DEVOPS-30 las sacó del código y las rotó, DEVOPS-31 (Gitleaks) evita que vuelvan, DEVOPS-35 (Secrets Manager y runbook de rotación) las gestiona en AWS |
| **B.** Imágenes grandes que corren como root | Multi-stage, imágenes mínimas (Alpine, slim, distroless), `USER` no root, Trivy image como gate |
| **D.** Sin análisis de código ni de dependencias | Semgrep, Trivy fs y SonarCloud en el CI, Checkov en tero-infra |

## 2. Hallazgos de secretos

| Qué | Dónde | Estado |
|---|---|---|
| `retailpassword` (contraseña de la base) repetida en 5 variables | `docker-compose.yml`, commit inicial `56fd8cb` | **Rotada** y fuera del código (DEVOPS-30, PR #7). El valor real vive solo en el `.env` local (en `.gitignore`) y en AWS en Secrets Manager |
| `ADMIN_PASSWORD: admin` y `ADMIN_JWT_SECRET: change-me-in-production` | `docker-compose.yml` y `src/admin/src/app.ts` (como *fallback* en el código), commit `56fd8cb` | **Rotados.** Se sacaron los *fallbacks*: si falta la variable, admin no arranca |
| Mismo usuario `retail_user` con `GRANT ALL` sobre las 3 bases | `init-db.sql` | **Abierto** (no es un secreto filtrado, es mínimo privilegio): ver hallazgo 6 de la sección 4 |

**Cómo se detectó:** las reglas por defecto de Gitleaks **no encontraban ninguna** de estas contraseñas, porque no tienen un formato reconocible (prefijo tipo `AKIA` o alta entropía). Se agregaron 3 reglas propias (contraseña literal en archivos de configuración y valores por defecto en JS y Python) y con eso aparecieron los 10 secretos. Es la lección principal de este control: un scanner con la configuración por defecto da una falsa sensación de seguridad.

**Por qué no se reescribió el historial:** `git filter-repo` rompería los PRs ya mergeados y las ramas de todos. Como las contraseñas ya se rotaron, el valor que quedó en el historial no sirve. La excepción en `.gitleaks.toml` es **solo para el commit `56fd8cb`**: si alguien vuelve a escribir esas contraseñas en un commit nuevo, el pipeline falla (probado con un commit de prueba).

**Secretos actuales y dónde viven** (detalle en el runbook `tero-infra/docs/runbooks/rotacion-de-secretos.md`):

| Secreto | Dónde vive | Rotación |
|---|---|---|
| Contraseña de PostgreSQL, usuario/contraseña/clave JWT del admin | AWS Secrets Manager (`tero-<entorno>/...`), generados por Terraform con valores *write-only*: no quedan en el plan ni en el state | Manual con runbook (cada 90 días en prod) |
| Credenciales de AWS del pipeline | GitHub Secrets de los dos repos | Cada vez que se inicia el lab (vencen a las ~4 h) |
| `SONAR_TOKEN` | GitHub Secrets (Actions y Dependabot) | Cada 90 días o si se filtra |
| `ALERT_EMAIL`, `ADMIN_ALLOWED_CIDRS` | GitHub Secrets de tero-infra | No son contraseñas, pero son datos personales y el repo es público |

## 3. Hallazgos remediados

### 3.1 Dependencias (Trivy fs, DEVOPS-32)

| Servicio | Antes | Remediación |
|---|---|---|
| catalog, orders (Go) | 5 CRITICAL, 46 HIGH | Go 1.24 → 1.26 (la 1.24 ya no recibe parches), `pgx/v5` 5.6 → 5.13, `grpc` 1.73 → 1.85, `x/crypto`, `x/net`, `x/text` al día |
| checkout (NestJS) | 1 CRITICAL, 23 HIGH | Actualización dentro de NestJS 11 (`yarn up -R`), sin cambiar de versión mayor para no romper la app |
| cart (Python) | 0 aparentes, 3 HIGH ocultos | `requirements.txt` solo fijaba las dependencias directas y Trivy no veía las transitivas. Se fijaron **todas** y apareció `starlette` con 3 HIGH (CVE-2024-47874, DoS). Se subió FastAPI 0.115 → 0.163 |
| checkout | 3 MEDIUM que no bloqueaban: `uuid` (CVE-2026-41907), `glob` (CVE-2026-118773), `minimatch` (CVE-2026-118764) | PR #33: se sacó `uuid` (Node ya trae `crypto.randomUUID()`) y `rimraf`, que traía `glob` y `minimatch`, pasó a `devDependencies` porque solo se usa para compilar. Ninguna de las tres entra ya en la imagen |

Resultado: `trivy fs .` con **todas** las severidades da 0 vulnerabilidades en los 6 servicios.

### 3.2 Imágenes (Trivy image, DEVOPS-33)

| Imagen base | Hallazgos | Remediación |
|---|---|---|
| `node:22.11.0-alpine3.20` (ui, admin, checkout) | 54 (Alpine y npm empaquetado) | `node:22.23.5-alpine3.24` y **borrar npm, npx, yarn y corepack** de la imagen final. En ejecución solo hace falta `node`, y sin gestor de paquetes un atacante dentro del contenedor no puede bajar herramientas |
| `python:3.12.7-slim-bookworm` (cart) | 52 (Debian 12.8) | `python:3.12.16-slim-bookworm`: 0 hallazgos |
| `distroless/static-debian12` (orders) | 0 | Sin cambios |

Además todas las imágenes son multi-stage y corren como usuario no root.

### 3.3 Código (Semgrep, DEVOPS-34)

| Hallazgo | Remediación |
|---|---|
| 14 × `github-actions-mutable-action-tag`: las actions se referenciaban por tag, que su dueño puede mover a código malicioso (como en el ataque a `tj-actions/changed-files`, 2025) | Cada action fijada al **SHA** de su versión. Dependabot abre un PR semanal con las nuevas |
| 2 × `missing-integrity` en el favicon | Falso positivo, pero se resolvió igual: el ícono pasó a un archivo servido por la propia app |
| **XSS almacenado** (`insecure-document-method`): la tienda y el admin metían datos de la API en `innerHTML` sin escapar | PR #33. Al corregirlo apareció que era **más grave de lo estimado**: en la tienda, el listado de órdenes mostraba sin escapar el nombre y el email que cualquier cliente escribe en el checkout, sin necesitar el admin. En el admin, `esc()` dentro de `onclick` no alcanzaba, porque el navegador decodifica `&#39;` antes de ejecutar el JS. Ahora todo dato pasa por `esc()` y los argumentos de `onclick` por `jsArg()`. Probado con Playwright: el mismo texto malicioso antes se ejecutaba y ahora se muestra como texto |
| `dependabot-missing-cooldown` | PR #33: Dependabot espera 7 días antes de proponer una versión nueva. Si la versión es maliciosa, en ese plazo suele detectarse y retirarse |

Lo que **no** apareció y es buena noticia: ninguna inyección SQL. Todas las queries usan parámetros (`$1`, `$2`).

**Por qué lo encontramos aunque no estaba en el ruleset del pipeline:** se corrieron a mano las reglas de JavaScript de navegador de Semgrep. Los rulesets `p/default` y `p/owasp-top-ten` no analizan JS dentro de HTML. Es una limitación a tener en cuenta: un gate en verde dice que no hay hallazgos **de las reglas que corren**, no que el código sea seguro.

### 3.4 Infraestructura (Checkov, DEVOPS-36)

| Regla | Remediación |
|---|---|
| CKV_AWS_394: fijar las zonas de disponibilidad | La red filtra por nombre (`us-east-1a/b/c`): si AWS agrega una zona, no cambia sola |
| CKV_AWS_150: *deletion protection* del ALB interno | Usa la misma variable que el público (activa en prod) |

## 4. Hallazgos abiertos (riesgo aceptado, con remediación planificada)

| # | Hallazgo | Fuente | Riesgo | Mitigación actual | Remediación |
|---|---|---|---|---|---|
| 1 | **Sin TLS hacia RDS** (`rds.force_ssl = 0`) | Checkov CKV2_AWS_69 | Medio: el tráfico servicio → base viaja sin cifrar dentro de la VPC | Subnets privadas; el security group de RDS solo acepta a los servicios | catalog y orders tienen `sslmode=disable` fijo en el código. Leerlo de una variable de entorno (`DB_SSLMODE=require`) y pasar `db_force_ssl = true` en tero-infra (ADR-003) |
| 2 | **Redis sin AUTH token** | Checkov CKV_AWS_31 | Bajo-medio: cualquiera dentro del SG de servicios podría leer las sesiones de checkout | TLS en tránsito activo (`rediss://`), cifrado en reposo, acceso solo desde el SG de servicios | Generar el token con Terraform, guardarlo en Secrets Manager y pasarlo a checkout en la URL de Redis |
| 3 | **HTTP sin TLS hasta el ALB** | Checkov CKV_AWS_2, CKV_AWS_103 y otros | Medio en producción real: credenciales del admin en texto plano | Ambiente académico sin datos reales; el admin solo se publica a `ADMIN_ALLOWED_CIDRS` | AWS Academy no da dominio, y sin dominio no hay certificado de ACM. Con uno: listener 443 y redirect 80 → 443 |
| 4 | **Imágenes base por tag y no por digest** | Semgrep `dockerfile-source-not-pinned` (INFO, 15) | Bajo: el tag tiene versión exacta, nunca `latest` | Trivy image escanea la imagen final en cada build | Fijar por digest y sumar el ecosistema `docker` a Dependabot para que los actualice |
| 5 | **Dependencias de desarrollo con HIGH** (`glob`, `picomatch`, `tmp`, `serialize-javascript`, ...) | Trivy fs `--include-dev-deps` | Bajo: no entran en la imagen; solo corren en el runner de CI | El Dockerfile instala solo producción | Migración a NestJS 12 |
| 6 | **Un solo usuario de base para todos los servicios** (`retail_user`, dueño de las 3 bases) | Assessment, observación A | Medio: si se compromete un servicio, puede leer y modificar las bases de los otros | Cada servicio solo se conecta a su base por configuración; RDS en subnet privada | Que `db-init` cree un usuario por servicio con permisos solo sobre su base, cada uno con su secreto en Secrets Manager |

## 5. Excepciones justificadas

Una excepción es un hallazgo que se acepta a conciencia. Todas están **en el código, al lado de lo que exceptúan**, con su motivo, así se revisan en el mismo PR que el cambio:

| Herramienta | Excepción | Por qué | Revisión |
|---|---|---|---|
| Gitleaks | Commit `56fd8cb` | Secretos del commit inicial, ya rotados (sección 2) | Permanente: el valor no sirve |
| Gitleaks | `src/checkout/.yarn/releases/` | Binario de Yarn: el `apiKey:"..."` es código de Yarn, no una credencial | Permanente |
| Gitleaks | `sonar.projectKey` | Es el id **público** del proyecto en SonarCloud; el token real está en GitHub Secrets | Permanente |
| Trivy image | CVE-2026-84782 (`libssl3` en `distroless/base-debian12`, catalog) | Debian publicó el parche pero Google no reconstruyó la imagen, y distroless no permite instalar paquetes. Catalog no usa TLS | **01/12/2026**: sacarla en cuanto la imagen base traiga la versión corregida |
| Semgrep | `prefer-json-notation` en 4 `HEALTHCHECK` | El `\|\| exit 1` necesita un shell; en forma JSON no funciona | Permanente |
| Semgrep | `missing-template-string-indicator` en `admin/src/app.ts` | Falso positivo: `'{}'` es un array vacío de Postgres, no un template de JS | Permanente |
| Checkov | Una por regla y recurso, cada una con `#checkov:skip` y su motivo | Agrupadas por causa en `tero-infra/docs/seguridad/checkov.md`: controles que solo se activan en prod (Multi-AZ, deletion protection), falta de dominio para HTTPS, limitaciones de AWS Academy (solo existe LabRole, que también usa la Lambda de DEVOPS-46), costo, y 1 falso positivo. Los 2 hallazgos abiertos de Checkov están en la sección 4 | Al pasar a una cuenta real de AWS |

**Lo que no se exceptúa:** ningún CRITICAL o HIGH con parche disponible. `.trivyignore` tiene una sola entrada, y Trivy fs no tiene ninguna.

## 6. Detección en tiempo de ejecución (DEVOPS-46)

Los gates del CI miran la imagen **cuando se construye**. Pero una CVE nueva se puede publicar después, con la imagen ya en ECR y camino a prod. Para eso, cada imagen que llega a ECR se escanea con la base de vulnerabilidades de AWS (*scan on push*). El evento dispara una Lambda (`tero-alertas-escaneo-ecr`) que, si hay CRITICAL o HIGH, manda un mail por SNS (`tero-seguridad`) con la imagen, el SHA y las primeras 10 CVE. Detalle en `tero-infra/docs/seguridad/alertas-escaneo-ecr.md`.

Son dos opiniones independientes (Trivy y ECR, con bases distintas) sobre la **misma imagen**, que es la que se promueve sin reconstruir de dev a test y prod.

## 7. Recomendaciones

1. Cerrar los hallazgos abiertos 1, 2 y 6 (TLS a RDS, AUTH de Redis y un usuario de base por servicio): son cambios chicos, de código y Terraform, y son los de mayor riesgo real.
2. Sumar al pipeline de Semgrep las reglas de JavaScript de navegador (`javascript.browser`), para que un XSS como el de la sección 3.3 lo frene el gate y no dependa de una revisión manual.
3. Activar Dependabot también para `npm`, `gomod`, `pip` y `docker` (con el mismo cooldown), así las dependencias se actualizan solas y Trivy no es el único aviso.
4. Revisar la excepción de distroless el 01/12/2026.
5. En una cuenta real de AWS: dominio y HTTPS, roles de IAM separados por servicio en lugar de LabRole, rotación automática de secretos y WAF en el ALB.

## Documentos de detalle

- [seguridad/gitleaks.md](seguridad/gitleaks.md), [seguridad/semgrep.md](seguridad/semgrep.md), [seguridad/trivy-fs.md](seguridad/trivy-fs.md), [seguridad/trivy-image.md](seguridad/trivy-image.md), [quality-gates.md](quality-gates.md)
- tero-infra: `docs/seguridad/checkov.md`, `docs/seguridad/alertas-escaneo-ecr.md`, `docs/runbooks/rotacion-de-secretos.md`, `docs/adr/ADR-003-ecs-base-de-datos-y-secretos.md`
