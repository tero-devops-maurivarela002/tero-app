# syntax=docker/dockerfile:1

# ---- Etapa 1: compilar ----
FROM golang:1.24.5-bookworm AS build
WORKDIR /src
# Primero solo go.mod y go.sum: si no cambian, Docker reutiliza la capa de dependencias
COPY go.mod go.sum ./
RUN go mod download
COPY . .
# CGO_ENABLED=0 genera un binario estático, que corre sin libc
RUN CGO_ENABLED=0 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/orders .

# ---- Etapa 2: ejecutar ----
FROM gcr.io/distroless/static-debian12:nonroot
COPY --from=build /out/orders /orders
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/orders"]
