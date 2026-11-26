# Tests de integración con Postman/Newman (DEVOPS-39)

## Qué se prueba

Los tests unitarios (DEVOPS-25) prueban cada servicio por separado. Los de
integración prueban que **los servicios funcionan juntos**: entran por el UI,
como lo haría un navegador, y el UI reenvía cada pedido por su proxy `/api/*`
a catalog, carts, checkout y orders. Si una URL entre servicios está mal, si un
servicio no llega a la base o a Redis, o si un contrato JSON cambió de un lado
y no del otro, estos tests fallan aunque todos los unitarios pasen.

La colección está en [`tests/integration/tero.postman_collection.json`](../../tests/integration/tero.postman_collection.json)
y tiene dos carpetas:

| Carpeta | Requests | Qué verifica | ¿Escribe datos? |
|---|---|---|---|
| `01 Solo lectura (health y catálogo)` | 4 | `/health` del UI responde `OK` en menos de 2 s; el catálogo devuelve productos con id, nombre y precio entero; el detalle de un producto; un producto inexistente da **404** (no 500) | No |
| `02 Flujo de compra` | 9 | Agregar 2 unidades al carrito → ver el carrito → preparar el checkout (subtotal, envío 10, impuesto 5, total) → confirmar la compra → la orden aparece en orders con producto, cantidad y costo correctos → vaciar el carrito. También dos casos inválidos: el carrito rechaza una cantidad no numérica (**422**) y el checkout rechaza una cantidad negativa (**400**) | Sí: una orden de prueba |

En total son 13 requests y 28 aserciones. Cada corrida usa un cliente nuevo
(`newman-<timestamp>`), así dos corridas no se pisan y la orden de prueba se
reconoce fácil (email `newman@example.com`).

## Dónde corre en el pipeline

| Job | Cuándo | Contra qué | Si falla |
|---|---|---|---|
| `integration` | En cada PR y en cada push | La tienda levantada con `docker compose` en el runner de GitHub | `docker-build` no corre: **no se construye ni se publica ninguna imagen** |
| `integration-dev` | Después de `deploy-dev` (merge a `develop`) | Dev en AWS, a través del ALB público | El pipeline queda en rojo y esa versión **no se promueve a test** (DEVOPS-29) |

Así el mismo set de tests actúa dos veces: antes de publicar (*shift-left*,
sin necesitar AWS) y después de desplegar, contra la infraestructura real
(ALB, ECS, RDS y ElastiCache), que el compose no puede reproducir.

En **prod** solo se corre la carpeta `01 Solo lectura`, para no crear órdenes
de prueba en el ambiente productivo.

El reporte JUnit (`reports/newman.xml`) queda como artefacto del run
(`newman-compose` y `newman-dev`), y si `integration` falla también se guardan
los logs de los contenedores (`reports/compose.log`).

## Cómo correrlo a mano

Necesitás Node 22. El script espera hasta 2 minutos a que `/health` responda y
después corre Newman 6.2.3 (versión fija, con `npx`).

```bash
# Contra la tienda local (docker compose up -d --build)
./scripts/tests-integracion.sh http://localhost:8080

# Contra dev en AWS (la URL del ALB sale del job deploy-dev o de la consola)
./scripts/tests-integracion.sh http://tero-dev-alb-XXXX.us-east-1.elb.amazonaws.com

# Solo la parte de lectura (la que se usa en prod)
./scripts/tests-integracion.sh http://<alb> "01 Solo lectura (health y catálogo)"
```

También se puede importar la colección en Postman y cambiar la variable
`base_url`.

## Prueba de que el gate funciona

Corrida local con los 6 servicios levantados: 13 requests, **28 de 28
aserciones OK**. Con el servicio `orders` apagado, la misma corrida falló en
"Confirmar la compra" (3 aserciones en rojo), `--bail` cortó ahí el resto del
flujo y Newman salió con código 1, que es lo que corta el job.
