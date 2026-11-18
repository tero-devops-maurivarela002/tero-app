# syntax=docker/dockerfile:1

# ---- Etapa 1: compilar TypeScript ----
FROM node:22.23.5-alpine3.24 AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY tsconfig.json ./
COPY src ./src
RUN npm run build

# ---- Etapa 2: solo dependencias de producción ----
FROM node:22.23.5-alpine3.24 AS deps
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev && npm cache clean --force

# ---- Etapa 3: ejecutar ----
FROM node:22.23.5-alpine3.24
ENV NODE_ENV=production PORT=8080
# En ejecución solo hace falta "node": se sacan npm, npx, yarn y corepack que trae
# la imagen oficial. Tenían CVEs HIGH propios (Trivy image, DEVOPS-33) y además
# son herramientas que un atacante podría usar dentro del contenedor.
RUN rm -rf /usr/local/lib/node_modules /usr/local/bin/npm /usr/local/bin/npx \
           /usr/local/bin/corepack /usr/local/bin/yarn /usr/local/bin/yarnpkg /opt/yarn-*
WORKDIR /app
COPY --from=deps --chown=node:node /app/node_modules ./node_modules
COPY --from=build --chown=node:node /app/dist ./dist
COPY --chown=node:node public ./public
COPY --chown=node:node package.json ./
EXPOSE 8080
# La imagen oficial de Node ya trae el usuario "node" (uid 1000)
USER node
HEALTHCHECK --interval=30s --timeout=3s --start-period=10s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/health || exit 1
CMD ["node", "dist/app.js"]
