# syntax=docker/dockerfile:1

# ---- Etapa 1: compilar TypeScript ----
FROM node:22.11.0-alpine3.20 AS build
WORKDIR /app
COPY package*.json ./
RUN npm ci
COPY tsconfig.json ./
COPY src ./src
RUN npm run build

# ---- Etapa 2: solo dependencias de producción ----
FROM node:22.11.0-alpine3.20 AS deps
WORKDIR /app
COPY package*.json ./
RUN npm ci --omit=dev && npm cache clean --force

# ---- Etapa 3: ejecutar ----
FROM node:22.11.0-alpine3.20
ENV NODE_ENV=production PORT=8080
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
