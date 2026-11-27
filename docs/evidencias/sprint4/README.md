# Evidencias del Sprint 4 (22 al 29/11)

| Tarea | Evidencia | Qué muestra |
|---|---|---|
| DEVOPS-39 | [DEVOPS-39-newman-contra-dev.png](DEVOPS-39-newman-contra-dev.png) | Run de CI del merge de #26 y #27 con todos los jobs en verde. `integration-dev` corrió la colección de Newman contra el ALB de dev: 13 requests, 28 de 28 aserciones OK. |
| DEVOPS-20 | [DEVOPS-20-revision-pr28.png](DEVOPS-20-revision-pr28.png) | Revisión del PR #28 (promoción a test y prod) por el segundo integrante. Dos preguntas con su respuesta: qué pasa si la release se mergea a main con squash (`gate-prod` falla antes de pedir aprobación y prod queda como estaba) y cómo llega a test un commit hecho directo en la release (no llega: no pasó por dev). La segunda pregunta hizo corregir la documentación de promoción (commit `c0a5ec3`). |
| DEVOPS-29 | [DEVOPS-29-sonar-falla-en-release.png](DEVOPS-29-sonar-falla-en-release.png) | Primer push a `release/1.0`: SonarCloud falla con *"Organization is not allowed to access data from non main branches"* (el plan Free solo analiza `develop` y los PRs). Como el gate falló, no se construyó ni promovió nada. Corregido en #29 y #30. |
| DEVOPS-29 | [DEVOPS-29-release-deploy-test-salteado.png](DEVOPS-29-release-deploy-test-salteado.png) | Primer intento de arreglo (#29): se salteaba el job `sonarcloud` entero en `release/*`, y GitHub saltea también todos los jobs que dependen de uno salteado, así que `deploy-test` no corrió. En #30 se saltean los pasos y no el job. |
| DEVOPS-28 y 29 | [DEVOPS-29-aprobacion-deploy-prod.png](DEVOPS-29-aprobacion-deploy-prod.png) | Merge de `release/1.0` a `main` (#31): todos los gates en verde, `gate-prod` eligió el SHA de la release y `deploy-prod` espera la aprobación manual del environment `production` (revisores: los dos integrantes). Sonar no analiza `main`, porque ese SHA ya pasó el gate en `develop`. |

Resultado de la promoción: el mismo SHA (`b92e060`) pasó por dev, test y prod sin reconstruirse. En cada ambiente corrió su gate (`integration-dev`, `integration-test`, aprobación y `smoke-prod`). La aprobación de Terraform para prod y los dashboards de test y prod están en las evidencias de tero-infra.
