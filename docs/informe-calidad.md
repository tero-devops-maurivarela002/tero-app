# Informe de calidad: interpretación de resultados (DEVOPS-40)

> Fecha de corte: 27/11/2026, sobre `develop` (después del merge de #32).
> Cubre las pruebas automáticas (unitarias e integración) y el análisis de código (SonarCloud y Semgrep). Lo de seguridad de dependencias, imágenes e infraestructura está en [informe-seguridad.md](informe-seguridad.md). Los umbrales de cada gate están en [quality-gates.md](quality-gates.md).

## 1. Resumen en un párrafo

Tero pasó de no tener ningún test ni análisis (assessment, observación D) a un pipeline donde cada cambio pasa por 6 gates antes de construir una imagen, y por los mismos tests de integración contra cada ambiente antes de promoverse. Hoy todos los gates están en verde: los 6 servicios compilan y pasan sus tests unitarios, el flujo de compra completo pasa con Newman (28 de 28 aserciones) en compose, dev y test, Semgrep da 0 hallazgos bloqueantes y el quality gate de SonarCloud pasa en todos los PRs (en el release a prod, 95,1 % de cobertura sobre el código nuevo). La debilidad principal es la **cobertura del código heredado**: entre 26 % y 52 % en los servicios de Go y Python. El gate de Sonar no la castiga porque mide solo el código nuevo, y por eso no lo frena. La recomendación es subirla empezando por los handlers HTTP, que hoy tienen 0 %.

## 2. Tests unitarios

Corren en el job `build-test`, uno por servicio (matriz de 6). Medición local con los mismos comandos del CI:

| Servicio | Lenguaje | Tests | Cobertura de líneas | Qué está cubierto | Qué no |
|---|---|---|---|---|---|
| catalog | Go | 8 | **25,9 %** | `repository` 67 %, `middleware` 16 % | `controller` y `httputil` 0 %: los handlers HTTP |
| orders | Go | 6 | **40,3 %** | Lógica de órdenes y logs | Handlers y conexión a la base |
| cart | Python | 16 | **52 %** | `service.py`, `models.py`, `config.py`, `jsonlog.py` al 100 % | `postgres_service.py` y `dynamodb_service.py` 0 %, `router.py` 56 % |
| checkout | TypeScript | 5 | 100 % (*) | Logs JSON y middleware de logging | El controlador y el servicio de checkout |
| ui | TypeScript | 4 | 100 % (*) | Logs JSON | El proxy `/api/*` |
| admin | TypeScript | 4 | 100 % (*) | Logs JSON | Login, CRUD de productos y órdenes |

(*) **Cómo leer el 100 % de Node:** `c8` mide solo los archivos que los tests **cargan**, y hoy los tests de Node prueban los módulos de logging que agregó DEVOPS-48. El 100 % es real sobre esos archivos, pero no dice nada del resto del servicio. En SonarCloud, que mide contra todos los archivos fuente, esos servicios aparecen con cobertura baja. Es un ejemplo de por qué un número de cobertura no se lee sin saber **contra qué** se mide.

**Interpretación:** la cobertura alta está donde hay lógica pura (cálculos del carrito, armado de logs, repositorio en memoria) y la baja está en el borde: handlers HTTP y acceso a base. Eso se explica porque esa parte es más difícil de probar unitariamente, y en parte ya la cubren los tests de integración (sección 3), que la recorren de punta a punta. Igual, un bug de validación en un handler hoy solo lo detecta Newman, que corre más tarde y es más lento de diagnosticar.

## 3. Tests de integración (Newman, DEVOPS-39)

La colección `tests/integration/tero.postman_collection.json` tiene 13 requests y 28 aserciones: health, catálogo, un 404 esperado, el flujo de compra completo (carrito → checkout → orden → vaciar carrito) y dos casos inválidos (422 y 400). Detalle en [testing/tests-de-integracion.md](testing/tests-de-integracion.md).

| Dónde | Contra qué | Resultado | Evidencia |
|---|---|---|---|
| `integration` (cada PR y push) | Los 6 servicios con `docker compose` en el runner | 28/28 | Runs de CI |
| `integration-dev` | Dev en AWS, por el ALB | 28/28 | [DEVOPS-39-newman-contra-dev.png](evidencias/sprint4/DEVOPS-39-newman-contra-dev.png) |
| `integration-test` | Test en AWS, mismo SHA `b92e060` | 28/28 | Run del release/1.0 |
| `smoke-prod` | Prod, solo la carpeta de lectura (no crea órdenes) | OK | Run del merge a main |

**Interpretación:** es el control que más valor dio. Los tests unitarios de cada servicio pasaban, pero no garantizaban que el UI llegara a catalog o que checkout pudiera crear la orden en orders. Newman sí lo prueba, y lo prueba **dos veces con la misma colección**: antes de publicar la imagen (compose) y después de desplegar (AWS), donde aparecen problemas que el compose no reproduce, como security groups, service discovery, RDS o ElastiCache con TLS. Que el gate funciona se probó apagando `orders`: Newman falló en "Confirmar la compra" y cortó el job.

## 4. SonarCloud (DEVOPS-38)

Gate **Sonar way**, aplicado al código nuevo: reliability, security y maintainability en A, 100 % de hotspots revisados, cobertura ≥ 80 % y duplicación ≤ 3 %.

| Resultado | Interpretación |
|---|---|
| El gate pasó en todos los PRs que se mergearon | Ningún cambio introdujo bugs, vulnerabilidades ni code smells por encima del umbral |
| Release a prod (PR #31): **95,1 % de cobertura sobre el código nuevo**, gate *Passed* | El código que se escribió en el proyecto (logs, middleware, `lifespan` de cart, etc.) sí viene con tests. Es lo que busca *Clean as You Code* |
| La cobertura **total** del proyecto es baja (sección 2) | Es la deuda del código heredado de Tero. Sonar way no la bloquea a propósito: si lo hiciera, ningún PR pasaría hasta escribir tests para todo lo viejo |

**Limitación encontrada:** el plan Free de SonarCloud solo analiza la rama principal (`develop`) y los PRs. Al crear `release/1.0` el job falló con *"not allowed to access data from non main branches"*. Se resolvió analizando solo en PRs y `develop`, que no pierde control porque el SHA que llega a test y prod es el mismo que ya pasó el gate en `develop` (build once, deploy many). Detalle en [quality-gates.md](quality-gates.md).

## 5. Semgrep (DEVOPS-34)

| Severidad | Cantidad | Lectura |
|---|---|---|
| ERROR | 0 | Ninguna vulnerabilidad probable. En particular, **ninguna inyección SQL**: todas las queries usan parámetros |
| WARNING | 0 (eran 16 en el primer PR) | Se corrigieron: 14 actions fijadas por SHA, 2 falsos positivos del favicon resueltos igual |
| INFO | 21 | 15 imágenes base por tag (aceptado), 4 `HEALTHCHECK` en forma shell (excepción justificada), 2 falsos positivos de SQL de Postgres |

**Interpretación:** el gate en 0 ERROR y 0 WARNING es una buena base, pero no prueba que no haya problemas. Corriendo a mano las reglas de JavaScript de navegador, que no están en los rulesets del pipeline, apareció un **XSS almacenado** en la tienda y en el admin, ya corregido en el PR #33. La conclusión es que el resultado de un analizador estático vale tanto como las reglas que corre. Detalle en [seguridad/semgrep.md](seguridad/semgrep.md).

## 6. Qué dicen los gates cuando fallan

Que un gate frene un cambio es el resultado esperado. Casos reales del proyecto:

| Gate | Qué frenó | Qué se hizo |
|---|---|---|
| Gitleaks | El propio documento de Gitleaks, en su primer intento, por un ejemplo de contraseña escrito completo | Se reescribió el ejemplo |
| Semgrep | 16 WARNING en su primer PR | Corregidos antes de mergear |
| Trivy fs | 6 CRITICAL y 69 HIGH en dependencias | Remediados (informe de seguridad) |
| Trivy image | 107 CRITICAL/HIGH en las imágenes base | Imágenes nuevas, sin npm en ejecución |
| Newman | Prueba con `orders` apagado | Falló como se esperaba |
| deploy-test (gate de promoción) | Un SHA sin `integration-dev` en verde no puede ir a test | Funcionó en el release/1.0 |

## 7. Recomendaciones

1. **Tests de los handlers HTTP** de catalog y orders con `httptest` (Go), que hoy están en 0 %. Es lo que más sube la cobertura con menos esfuerzo y cubre la validación de entrada.
2. **Tests del router de cart** con `TestClient` de FastAPI (ya se usó a mano en DEVOPS-32) y de `postgres_service.py` contra un Postgres efímero.
3. **Tests de los controladores de Node** (checkout, admin), para que la cobertura de `c8` deje de medir solo los módulos de logging.
4. **Reglas de JavaScript de navegador en Semgrep**, para que el próximo XSS lo frene el gate.
5. **Subir gradualmente un umbral de cobertura total** (por ejemplo, no bajar del valor actual) además del gate de código nuevo, para que la deuda no crezca.
6. Sumar a Newman un caso del admin (login y alta de producto), que hoy no tiene ningún test de integración.
