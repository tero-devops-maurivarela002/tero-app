# Escaneo de imágenes con Trivy antes del push (DEVOPS-33)

## Qué hace

En el job `docker-build` del pipeline, para cada uno de los 6 servicios:

1. Se construye la imagen y queda **solo en el runner** (`load: true`, sin publicar).
2. **Trivy image** la escanea: paquetes del sistema operativo base (Alpine, Debian), runtimes (Node.js, Python) y todo lo que quedó dentro de la imagen.
3. **Quality gate:** si hay vulnerabilidades **CRITICAL o HIGH con parche disponible** (`--severity CRITICAL,HIGH --ignore-unfixed --exit-code 1`), el job falla y los pasos de push no corren. Una imagen vulnerable **nunca llega a ECR**.
4. Solo si pasa, y solo en push a `develop`/`main`, se publica en ECR con tag = SHA (DEVOPS-26).

El reporte completo (todas las severidades) se sube a **GitHub → Security → Code scanning** (categoría `trivy-image-<servicio>`) y como artefacto del run.

## Diferencia con Trivy fs (DEVOPS-32)

| | Trivy fs | Trivy image |
|---|---|---|
| Qué mira | Archivos de dependencias del repo (`go.mod`, `package-lock.json`, `yarn.lock`, `requirements.txt`) | La imagen final construida |
| Encuentra | CVEs en librerías de la app | Lo anterior **más** el sistema operativo base y las herramientas que trae la imagen |
| Cuándo | Antes de compilar | Después del build, antes del push |

Además de este gate, ECR vuelve a escanear cada imagen al recibirla (*scan on push*, configurado en tero-infra).

## Hallazgos de la primera corrida y remediación

Escaneo local de las imágenes base que usábamos (Trivy 0.76.1, 18/11/2026, solo CRITICAL/HIGH con parche):

| Imagen base | Hallazgos | Dónde | Remediación |
|---|---|---|---|
| `node:22.11.0-alpine3.20` (ui, admin, checkout) | 23 en Alpine 3.20 + 31 en Node.js | `libssl3`, `libcrypto3`, `musl`, `zlib`; y npm empaquetado (`cross-spawn`, `tar`, `glob`, `minimatch`, `sigstore`…) | Subir a `node:22.23.5-alpine3.24` **y borrar npm, npx, yarn y corepack** de la etapa final: en ejecución solo hace falta `node`. La imagen nueva todavía traía 10 HIGH dentro de npm, que desaparecen al sacarlo. |
| `python:3.12.7-slim-bookworm` (cart) | 52 en Debian 12.8 | `openssl`, `libssl3`, `libgnutls30`, `libkrb5`, `apt`, `perl-base`, `liblzma5`… | Subir a `python:3.12.16-slim-bookworm` (Debian 12 al día): 0 hallazgos. |
| `gcr.io/distroless/base-debian12:nonroot` (catalog) | 1 | `libssl3` (CVE-2026-84782) | **Excepción** en `.trivyignore`: Debian publicó el parche pero Google todavía no reconstruyó la imagen distroless, y distroless no permite instalar paquetes. Catalog no usa TLS. Revisar el 01/12/2026. |
| `gcr.io/distroless/static-debian12:nonroot` (orders) | 0 | | |

**27/11/2026: el gate frenó a cart por una CVE nueva.** Salió CVE-2025-6020 (HIGH, `libpam`) con parche en Debian (`1.5.2-6+deb12u3`), pero la imagen `python:3.12.16-slim-bookworm` todavía traía la versión anterior. El Dockerfile de cart ahora corre `apt-get upgrade` en la etapa final, así cada build toma los parches de seguridad de Debian sin esperar a que se publique una imagen base nueva.

Sacar npm de la imagen final es además *hardening*: si alguien lograra ejecutar código en el contenedor, no tendría un gestor de paquetes para bajar herramientas.

## Cómo reproducirlo local

```bash
docker build -t tero-ui:local src/ui
trivy image tero-ui:local --scanners vuln --severity CRITICAL,HIGH --ignore-unfixed
```
