# syntax=docker/dockerfile:1

# ---- Etapa 1: compilar NestJS ----
FROM node:22.11.0-alpine3.20 AS build
WORKDIR /app
# Yarn 4: el binario está versionado en .yarn/releases y lo indica .yarnrc.yml
COPY package.json yarn.lock .yarnrc.yml ./
COPY .yarn/releases ./.yarn/releases
# --immutable: falla si el yarn.lock no coincide con package.json (build reproducible)
RUN node .yarn/releases/yarn-4.11.0.cjs install --immutable
COPY nest-cli.json tsconfig.json tsconfig.build.json ./
COPY src ./src
RUN node .yarn/releases/yarn-4.11.0.cjs build

# ---- Etapa 2: solo dependencias de producción ----
FROM node:22.11.0-alpine3.20 AS deps
WORKDIR /app
COPY package.json yarn.lock .yarnrc.yml ./
COPY .yarn/releases ./.yarn/releases
RUN node .yarn/releases/yarn-4.11.0.cjs workspaces focus --all --production \
 && rm -rf .yarn/cache

# ---- Etapa 3: ejecutar ----
FROM node:22.11.0-alpine3.20
ENV NODE_ENV=production PORT=8080
WORKDIR /app
COPY --from=deps --chown=node:node /app/node_modules ./node_modules
COPY --from=build --chown=node:node /app/dist ./dist
COPY --chown=node:node package.json ./
EXPOSE 8080
USER node
HEALTHCHECK --interval=30s --timeout=3s --start-period=15s --retries=3 \
  CMD wget -qO- http://127.0.0.1:8080/health || exit 1
CMD ["node", "dist/main.js"]
