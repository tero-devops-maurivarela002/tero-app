# syntax=docker/dockerfile:1

# ---- Etapa 1: compilar ----
FROM golang:1.24.5-bookworm AS build
WORKDIR /src
COPY go.mod go.sum ./
RUN go mod download
COPY . .
# catalog usa SQLite en memoria (mattn/go-sqlite3), que necesita CGO.
# Por eso el binario no es estático y la imagen final necesita glibc.
RUN CGO_ENABLED=1 GOOS=linux go build -trimpath -ldflags="-s -w" -o /out/catalog .

# ---- Etapa 2: ejecutar ----
# base-debian12 incluye glibc (static-debian12 no)
FROM gcr.io/distroless/base-debian12:nonroot
COPY --from=build /out/catalog /catalog
EXPOSE 8080
USER nonroot:nonroot
ENTRYPOINT ["/catalog"]
