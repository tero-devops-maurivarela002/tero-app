# Detección de secretos con Gitleaks (DEVOPS-31)

Resuelve la observación **A** del auditor ("las contraseñas de la base y del admin están en archivos del repo") junto con DEVOPS-30. DEVOPS-30 sacó los secretos del código; este control evita que vuelvan a entrar.

## Qué hace

El job `gitleaks` es la **primera etapa** del pipeline de CI (`.github/workflows/ci.yml`). Corre en cada PR a `develop`/`main` y en cada merge:

1. Hace checkout con `fetch-depth: 0`, o sea **todo el historial**. Con el default (`1`) solo vería el último commit, y un secreto que se agregó y se borró en commits anteriores pasaría sin verse. Es el "punto ciego" del lab T09-02.
2. Instala Gitleaks con versión fija (`8.21.2`) y **verifica el checksum** SHA-256 del binario antes de usarlo.
3. Ejecuta `gitleaks detect --log-opts="--all"` con la configuración `.gitleaks.toml`.
4. Si encuentra algo, **sale con código 1 y el pipeline falla**. `build-test` tiene `needs: gitleaks`, así que no se compila ni se construye ninguna imagen.
5. Usa `--redact` para que el valor del secreto **no** aparezca en el log de Actions, y guarda el reporte JSON como artefacto (`gitleaks-report`, 14 días).

## Reglas

| Regla | Qué detecta | Ejemplo que detectaría |
|---|---|---|
| Reglas por defecto de Gitleaks (~160) | Claves de AWS, tokens de GitHub, llaves privadas, API keys, etc. | `AKIA...`, `ghp_...` |
| `tero-password-en-config` | Contraseña literal en `.yml`, `.env`, `.tf`, `.tfvars`, etc. | `POSTGRES_PASSWORD: retailpassword` |
| `tero-password-default-js` | Secreto con valor por defecto en Node/TS | `process.env.DB_PASSWORD \|\| '...'` |
| `tero-password-default-py` | Secreto con valor por defecto en Python | `os.getenv("DB_PASSWORD", "...")` |

> En la tabla, `...` representa una contraseña literal. No escribimos un ejemplo real a propósito: este mismo archivo lo escanea Gitleaks, y un ejemplo completo hace fallar el pipeline (pasó en el primer intento de este PR).

**Por qué hacen falta reglas propias:** con solo las reglas por defecto, Gitleaks encontraba **1 hallazgo** en el historial (un falso positivo dentro del binario de Yarn) y **ninguna** de las contraseñas reales de Tero. Las reglas por defecto buscan formatos conocidos, como tokens con prefijo o claves de alta entropía, y `retailpassword` no tiene ninguno de los dos. Con las 3 reglas propias aparecen los 10 secretos del commit inicial.

Las reglas no marcan referencias a variables (`${POSTGRES_PASSWORD:?...}`) ni valores vacíos (`ADMIN_PASSWORD=` en `.env.example`), que es como quedó el repo después de DEVOPS-30.

## Excepciones (allowlist) y su justificación

| Excepción | Por qué |
|---|---|
| Commit `56fd8cb` (commit inicial) | Tiene las credenciales de ejemplo con las que vino Tero (`retailpassword`, `admin`, `change-me-in-production`) en `docker-compose.yml` y `src/admin/src/app.ts`. En DEVOPS-30 (PR #7) se sacaron del código y se **rotaron**: los valores reales están solo en el `.env` local, que está en `.gitignore`. Se decidió **no reescribir el historial** con `git filter-repo`, porque rompería los PRs ya mergeados y las ramas de todos, y porque el valor expuesto ya no sirve. La excepción es **solo para ese commit**: si alguien vuelve a escribir esas contraseñas en un commit nuevo, el pipeline falla. |
| `src/checkout/.yarn/releases/` | Es el binario de Yarn 4 que versiona el propio Yarn. Tiene un string `apiKey:"..."` que es parte del código de Yarn y no una credencial nuestra (falso positivo de `generic-api-key`). |

## Resultados

| Escenario | Hallazgos |
|---|---|
| Historial completo, solo reglas por defecto | 1 (falso positivo de Yarn) |
| Historial completo, reglas propias, **sin** excepciones | 11: los 10 secretos del commit inicial y el falso positivo |
| Historial completo, con `.gitleaks.toml` completo | 0, el pipeline pasa |
| Commit nuevo con `POSTGRES_PASSWORD: supersecreta123` en un `.yml` | 1, el pipeline **falla** |

## Cómo correrlo local

```bash
# Windows: winget install gitleaks  |  macOS: brew install gitleaks
gitleaks detect --source . --config .gitleaks.toml --log-opts="--all" --redact -v
```

## Qué hacer si el job falla (runbook)

1. Abrir el job `gitleaks` y ver en el log el archivo, la línea, el commit y la regla. El valor aparece como `REDACTED`.
2. **Si es un secreto real:**
   1. Considerarlo comprometido: **rotarlo ya**. Borrarlo del código no alcanza, porque queda en el historial.
   2. Sacarlo del código y leerlo de una variable de entorno o de Secrets Manager.
   3. Si el commit todavía no se mergeó, rehacer la rama sin ese commit. Si ya se mergeó, documentar la excepción de ese commit acá y en `.gitleaks.toml`, con la evidencia de la rotación.
3. **Si es un falso positivo:** agregar una excepción en `.gitleaks.toml`, lo más acotada posible (un commit, un archivo o un regex), **con un comentario que la justifique**, y sumarla a la tabla de excepciones de este documento.
