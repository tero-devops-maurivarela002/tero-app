# SCA con Trivy fs (DEVOPS-32)

Parte de la observación **D** del auditor ("no hay análisis de dependencias"). Trivy fs lee los archivos de dependencias de cada servicio y los compara contra bases de vulnerabilidades conocidas (CVE/GHSA). Es **SCA** (*Software Composition Analysis*): no mira nuestro código, mira el código de terceros que usamos.

| Servicio | Archivo que analiza |
|---|---|
| catalog, orders | `go.mod` |
| cart | `requirements.txt` |
| checkout | `yarn.lock` |
| ui, admin | `package-lock.json` |

## Qué hace en el pipeline

El job `trivy-fs` corre después de `gitleaks` y en paralelo con `build-test` y `semgrep`. `docker-build` necesita que pasen los tres.

1. Instala Trivy con versión fija (`0.76.1`) y **verifica el checksum**. No usamos `aquasecurity/trivy-action`, porque sus tags fueron movidos a código malicioso en un ataque de cadena de suministro.
2. **Reporte completo:** `trivy fs` con todas las severidades, en SARIF. No falla. Se publica en **Security → Code scanning** y queda como artefacto (`trivy-fs-report`).
3. **Quality gate:**
   ```
   trivy fs . --scanners vuln --severity CRITICAL,HIGH --ignore-unfixed --exit-code 1
   ```
   - `--severity CRITICAL,HIGH`: solo bloquean las graves.
   - `--ignore-unfixed`: si todavía **no existe versión corregida**, no bloquea, porque no hay nada que hacer salvo aceptar el riesgo. Es exactamente lo que pide la letra: "bloquea ante CRITICAL o HIGH **con fix disponible**".
   - `--exit-code 1`: si queda alguno, el job falla y no se construye ninguna imagen.

## Resultado: antes y después (14/11/2026)

La primera corrida sobre `develop` encontró esto (solo dependencias de producción):

| Servicio | CRITICAL | HIGH | MEDIUM | LOW |
|---|---|---|---|---|
| catalog (Go) | 3 | 26 | 18 | 4 |
| orders (Go) | 2 | 20 | 18 | 1 |
| checkout (NestJS) | 1 | 23 | 20 | 4 |
| cart (Python) | 0 (*) | 0 (*) | 0 | 0 |
| ui, admin | 0 | 0 | 0 | 0 |
| **Total** | **6** | **69** | 56 | 9 |

(*) **Punto ciego en cart:** `requirements.txt` solo fijaba las 5 dependencias directas, así que Trivy no veía las transitivas. Al fijarlas todas aparecieron **3 HIGH más en `starlette`** (que viene con FastAPI), entre ellos CVE-2024-47874, un DoS por `multipart/form-data`.

**Después de remediar: 0 CRITICAL, 0 HIGH.** Quedan 3 MEDIUM, que no bloquean (ver abajo).

### Cómo se remediaron

| Servicio | Cambio | Qué corrige |
|---|---|---|
| catalog, orders | **Go 1.24 → 1.26** (`go.mod` y la imagen `golang:1.26.11-bookworm` del Dockerfile) | Las versiones corregidas de `golang.org/x/net`, `x/crypto` y `x/text` requieren Go ≥ 1.26. Además, Go 1.24 ya no recibe parches de seguridad. |
| catalog, orders | `pgx/v5` 5.6.0 → 5.13.0 | 2 CRITICAL del driver de Postgres (CVE-2026-33815/33816) |
| catalog, orders | `x/crypto`, `x/net`, `x/text` a la última versión | La mayoría de los HIGH |
| catalog | `grpc` 1.73 → 1.85, `opentelemetry` 1.37 → 1.47, `klauspost/compress` | 1 CRITICAL de gRPC (CVE-2026-33186) y varios HIGH |
| checkout | `yarn up -R` de NestJS 11 (sin cambiar de versión mayor), `multer`, `body-parser`, `path-to-regexp`, `proxy-addr`, `qs`, etc. | 1 CRITICAL (`proxy-addr`) y 23 HIGH. Se evitó subir NestJS a la 12 porque es un cambio mayor con riesgo de romper la app. |
| cart | `fastapi` 0.115 → 0.163, `starlette` 0.38 → 1.10, `uvicorn`, `pydantic`, `psycopg2-binary`, y **todas** las dependencias fijadas en `requirements.txt` | Los 3 HIGH de `starlette` y el punto ciego |
| cart | `@app.on_event("startup")` → `lifespan` en `app/main.py` | El API viejo quedó deprecado con la versión nueva de FastAPI |

Verificación: los tests unitarios de los 3 servicios pasan, los 6 servicios compilan, y `cart` se probó con `TestClient` (health, alta y consulta de carrito, 404 en update inexistente, `/metrics`).

## Los 3 MEDIUM que quedaban (remediados en DEVOPS-37, 27/11/2026)

Después de la remediación de arriba quedaban 3 MEDIUM en checkout, que no bloqueaban el gate:

| Paquete | CVE | Fix de Trivy | Cómo se resolvió |
|---|---|---|---|
| `uuid` 9.0.1 | CVE-2026-41907 | 11.1.1 (cambio mayor) | Se **sacó la dependencia**. Solo se usaba para generar un id en `MockOrdersService`, y Node 22 ya trae `crypto.randomUUID()`. Una dependencia menos es una superficie de ataque menos. |
| `glob` 11.1.0 | CVE-2026-118773 | 14.0.2 (cambio mayor) | Llegaba por `rimraf`, que estaba como dependencia de **producción** aunque solo se usa en el script `prebuild` (`rimraf dist`). Se movió a `devDependencies`: ya no entra en la imagen. |
| `minimatch` 10.2.6 | CVE-2026-118764 | 11.0.1 (cambio mayor) | Ídem: venía con `glob`. |

Resultado: `trivy fs .` con **todas** las severidades da **0 vulnerabilidades** en los 6 servicios. Build y tests de checkout siguen pasando.

**Dependencias de desarrollo:** por defecto Trivy no cuenta las `devDependencies` (CLI de Nest, webpack, etc.), porque **no entran en la imagen**: el Dockerfile de checkout instala solo producción (`workspaces focus --production`). Con `--include-dev-deps` hoy aparecen 15 HIGH en herramientas de build (`glob`, `picomatch`, `tmp`, `serialize-javascript`, etc.). Se revisan junto con la migración a NestJS 12.

**`.trivyignore`:** está creado y vacío. Si en algún momento hay que aceptar un CVE, va ahí con su justificación, quién lo aceptó y hasta cuándo.

## Cómo correrlo local

```bash
# Windows: winget install AquaSecurity.Trivy  |  macOS: brew install trivy
trivy fs . --scanners vuln --severity CRITICAL,HIGH --ignore-unfixed
```

## Qué hacer si el job falla (runbook)

1. Abrir el job `trivy-fs`, paso *Quality gate*. La tabla dice qué servicio, qué paquete, qué versión tenemos y cuál lo corrige (*Fixed Version*).
2. **Actualizar la dependencia** a la versión corregida:
   - Go: `go get <modulo>@<version> && go mod tidy`
   - npm: `npm install <paquete>@<version>` (o `npm audit fix`)
   - Yarn (checkout): `node .yarn/releases/yarn-4.11.0.cjs up -R <paquete>`
   - Python: subir la versión en `requirements.txt`. Si es transitiva, regenerar el archivo con `pip freeze` en un venv limpio.
3. Correr los tests y levantar el servicio. Si la versión corregida es un **cambio mayor** que rompe la app y el riesgo es bajo, agregar el CVE a `.trivyignore` **con justificación, responsable y fecha de revisión**, y anotarlo en el informe de hallazgos.
