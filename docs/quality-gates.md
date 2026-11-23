# Quality gates del pipeline (DEVOPS-38)

Un **quality gate** es una condición objetiva que, si no se cumple, **frena el pipeline**: no se construye ni se publica ninguna imagen. Esto resume todos los gates de CI de `tero-app`, qué miden, el umbral y por qué.

## Resumen

| Gate (job) | Qué mide | Umbral que bloquea | Por qué ese umbral | Detalle |
|---|---|---|---|---|
| `gitleaks` | Secretos en todo el historial de git | **1 o más** secretos | Un secreto en el repo se considera filtrado. No hay "pocos secretos aceptables". | [seguridad/gitleaks.md](seguridad/gitleaks.md) |
| `build-test (×6)` | Que cada servicio compile y pasen sus tests unitarios | **Cualquier** error de compilación o test fallido | Si no compila o rompe un test, no tiene sentido seguir. | `.github/workflows/ci.yml` |
| `semgrep` | SAST: patrones inseguros en el código (OWASP Top 10) | **1 o más** hallazgos ERROR o WARNING | Hoy hay 0. Cualquier problema nuevo de seguridad se frena. Los INFO son de estilo y no bloquean. | [seguridad/semgrep.md](seguridad/semgrep.md) |
| `trivy-fs` | SCA: CVEs conocidos en dependencias | **1 o más** CRITICAL o HIGH **con parche disponible** | Lo pide la letra. Si no hay parche, bloquear no ayuda: se documenta y se acepta en `.trivyignore`. | [seguridad/trivy-fs.md](seguridad/trivy-fs.md) |
| `sonarcloud` | Calidad: bugs, vulnerabilidades, code smells, hotspots, cobertura y duplicación del **código nuevo** | Quality gate **"Sonar way"** en estado *Failed* (ver abajo) | Estándar de la industria, centrado en el código nuevo ("Clean as You Code"). | Esta página |

Orden en el pipeline: `gitleaks` → `build-test`, `semgrep` y `trivy-fs` en paralelo → `sonarcloud` (necesita la cobertura de `build-test`) → `docker-build`. Los 5 gates son *required status checks* en los rulesets de `develop` y `main`: un PR no se puede mergear si alguno falla.

## SonarCloud: condiciones del quality gate

Usamos el gate **Sonar way**, que viene con SonarCloud. Todas las condiciones se aplican al **código nuevo**, es decir, lo que cambia en el PR o desde la última versión:

| Métrica (código nuevo) | Umbral | Qué significa |
|---|---|---|
| Reliability rating | **A** | Ningún bug nuevo |
| Security rating | **A** | Ninguna vulnerabilidad nueva |
| Maintainability rating | **A** | Deuda técnica nueva acotada (code smells) |
| Security Hotspots revisados | **100 %** | Todo código sensible nuevo, como criptografía o input del usuario, revisado por una persona |
| Cobertura | **≥ 80 %** | Las líneas nuevas tienen que estar cubiertas por tests |
| Líneas duplicadas | **≤ 3 %** | No copiar y pegar código |

En PRs con **menos de 20 líneas nuevas**, SonarCloud no aplica las condiciones de cobertura y duplicación, para no frenar cambios mínimos.

**¿Por qué Sonar way y no un gate propio?** Crear quality gates personalizados en SonarCloud solo se puede en los planes pagos (Team y Enterprise), y el proyecto usa el plan Free. Igual, Sonar way es exigente y razonable: no castiga el código heredado de Tero, que todavía tiene poca cobertura, pero sí exige que **todo lo nuevo** salga bien. Es el enfoque *Clean as You Code*.

**Consecuencia práctica:** todo código nuevo tiene que venir con tests. Desde DEVOPS-48 los 6 servicios reportan cobertura: Go (`go test -coverprofile`), Python (`pytest-cov`) y Node (`node --test` + `c8`, en `ui`, `admin` y `checkout`).

## Cómo se conecta

- `sonar-project.properties`: organización, proyecto, qué es código y qué es test, y dónde están los reportes de cobertura.
- Cobertura: `build-test` genera `coverage.out` (Go), `coverage.xml` (pytest-cov) y `coverage/lcov.info` (c8, Node) y los sube como artefactos. El job `sonarcloud` los baja antes del análisis.
- `SONAR_TOKEN`: secreto del repo (Actions y Dependabot). No está en el código.
- `sonar.qualitygate.wait=true`: el job espera el veredicto del gate y falla si es *Failed*.

## Qué hacer si el gate falla (runbook)

1. Abrir el job `sonarcloud` o el comentario que SonarCloud deja en el PR, que tiene el link al análisis. Ahí dice **qué condición** falló.
2. Según la condición:
   - **Bug, vulnerabilidad o code smell:** abrir el issue en SonarCloud, que explica el problema y cómo corregirlo, y arreglarlo.
   - **Security Hotspot sin revisar:** revisarlo en SonarCloud y marcarlo *Safe* (con comentario) o *Fixed*.
   - **Cobertura < 80 %:** agregar tests para las líneas nuevas.
   - **Duplicación > 3 %:** extraer el código repetido a una función.
3. Pushear el arreglo. El pipeline vuelve a correr.
