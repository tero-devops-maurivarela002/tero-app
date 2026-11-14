# SAST con Semgrep (DEVOPS-34)

Parte de la observación **D** del auditor ("no hay análisis de código"). Semgrep analiza el **código fuente** sin ejecutarlo (SAST) y busca patrones inseguros: inyección SQL, comandos armados con input del usuario, cookies sin flags de seguridad, Dockerfiles que corren como root, etc.

## Qué hace en el pipeline

El job `semgrep` de `.github/workflows/ci.yml` corre después de `gitleaks` y en paralelo con `build-test`. `docker-build` necesita que pasen los dos, así que **si el SAST falla no se construye ninguna imagen**.

1. Instala Semgrep con versión fija (`1.185.0`).
2. **Reporte completo:** analiza todo con las reglas de abajo y genera `semgrep.sarif` con todos los hallazgos, de cualquier severidad. Este paso no falla.
3. **Quality gate:** vuelve a correr con `--severity ERROR --severity WARNING --error`. Si queda **algún hallazgo ERROR o WARNING**, el job sale con código 1 y el pipeline falla.
4. Publica el SARIF en **Security → Code scanning** del repo y lo guarda como artefacto (`semgrep-report`, 14 días).

## Reglas usadas

| Ruleset | Para qué |
|---|---|
| `p/owasp-top-ten` | Lo que pide la letra: las categorías del OWASP Top 10 (inyección, control de acceso, criptografía, etc.) |
| `p/default` | Reglas generales de seguridad mantenidas por Semgrep, para Go, Python y JS/TS |
| `p/dockerfile` | Buenas prácticas de seguridad en los 6 Dockerfiles |

Cubren los lenguajes de Tero: Go (catalog, orders), Python (cart), TypeScript (checkout, ui, admin) y Dockerfiles.

Qué no se analiza (`.semgrepignore`): dependencias y artefactos (`node_modules`, `dist`), el binario de Yarn (código de terceros), los lockfiles, los tests y la documentación.

## Umbral (quality gate) y por qué

| Severidad de Semgrep | Qué significa | ¿Bloquea? |
|---|---|---|
| **ERROR** | Vulnerabilidad probable (por ejemplo, inyección SQL) | **Sí** |
| **WARNING** | Patrón riesgoso que hay que revisar | **Sí** |
| INFO | Buena práctica o estilo | No. Se reporta y se revisa en el informe |

Bloqueamos ERROR y WARNING porque hoy el código tiene **0 hallazgos** de esas severidades: el gate arranca en verde y cualquier problema nuevo de seguridad lo pone en rojo. No bloqueamos INFO porque son recomendaciones de estilo y bloquearlas obligaría a llenar el repo de excepciones sin ganar seguridad.

## Resultado del análisis (14/11/2026)

**0 ERROR, 0 WARNING, 21 INFO.** Los INFO quedan así:

| Regla | Dónde | Cant. | Qué dice | Decisión |
|---|---|---|---|---|
| `dockerfile-source-not-pinned` | Los 6 Dockerfiles, en cada `FROM` | 15 | La imagen base se referencia por tag (`node:22.11.0-alpine3.20`) y no por digest (`@sha256:...`). Un tag puede moverse y un digest no. | **Aceptado por ahora.** Ya usamos tags con versión exacta, nunca `latest`. Fijar por digest se evalúa en el Sprint 3 junto con Trivy image y Dependabot, que actualiza los digests solo. Si no, cada parche de seguridad de la imagen base habría que actualizarlo a mano. |
| `prefer-json-notation` | `HEALTHCHECK` de admin, ui, checkout y cart | 4 | Recomienda la forma JSON (`["cmd", "arg"]`) en lugar de la forma shell. | **Excepción justificada.** El healthcheck usa `\|\| exit 1` para que cualquier error cuente como *unhealthy*, y eso necesita un shell. En la forma JSON no funciona. |
| `missing-template-string-indicator` | `src/admin/src/app.ts:90` | 2 | Ve `'{}'` dentro de un string y sospecha que falta un `${}`. | **Falso positivo.** Es SQL de Postgres (`COALESCE(..., '{}')` es un array vacío), no una interpolación de JavaScript. |

Lo bueno, que también sirve para la defensa: **no apareció ninguna inyección SQL**. Todas las queries de `admin` usan parámetros (`$1`, `$2`) y nunca concatenan input del usuario.

## Cómo correrlo local

```bash
pip install semgrep==1.185.0
semgrep scan --config p/owasp-top-ten --config p/default --config p/dockerfile
```

## Qué hacer si el job falla (runbook)

1. Abrir el job `semgrep` y, en el paso *Quality gate*, ver el archivo, la línea, la regla y la explicación. También está en **Security → Code scanning**.
2. **Si es un problema real:** corregir el código. Cada regla trae un link con la explicación y el arreglo recomendado.
3. **Si es un falso positivo:** agregar en esa línea un comentario `// nosemgrep: <id-de-la-regla>` (`# nosemgrep: ...` en Python o en el Dockerfile) **con el motivo**, y anotarlo en la tabla de arriba. No se ignora una regla entera para todo el repo.
