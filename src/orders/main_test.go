package main

import (
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
)

func TestGetEnvUsesFallback(t *testing.T) {
	t.Setenv("TERO_TEST_VAR", "")
	if got := getEnv("TERO_TEST_VAR", "por-defecto"); got != "por-defecto" {
		t.Errorf("esperaba el valor por defecto, obtuve %q", got)
	}
	t.Setenv("TERO_TEST_VAR", "valor")
	if got := getEnv("TERO_TEST_VAR", "por-defecto"); got != "valor" {
		t.Errorf("esperaba %q, obtuve %q", "valor", got)
	}
}

func TestBuildDSNSplitsHostAndPort(t *testing.T) {
	t.Setenv("RETAIL_ORDERS_PERSISTENCE_ENDPOINT", "db.interno:5433")
	t.Setenv("RETAIL_ORDERS_PERSISTENCE_USERNAME", "usuario")
	t.Setenv("RETAIL_ORDERS_PERSISTENCE_PASSWORD", "clave")
	t.Setenv("RETAIL_ORDERS_PERSISTENCE_NAME", "orders")

	dsn := buildDSN()
	for _, want := range []string{"host=db.interno", "port=5433", "user=usuario", "password=clave", "dbname=orders"} {
		if !strings.Contains(dsn, want) {
			t.Errorf("el DSN %q no contiene %q", dsn, want)
		}
	}
}

func TestBuildDSNDefaultPort(t *testing.T) {
	t.Setenv("RETAIL_ORDERS_PERSISTENCE_ENDPOINT", "db")
	dsn := buildDSN()
	if !strings.Contains(dsn, "host=db ") || !strings.Contains(dsn, "port=5432") {
		t.Errorf("sin puerto debería usar 5432: %q", dsn)
	}
}

// Un body inválido se rechaza con 400 antes de tocar la base,
// así que no hace falta Postgres para este test.
func TestCreateOrderRejectsInvalidJSON(t *testing.T) {
	gin.SetMode(gin.TestMode)
	r := gin.New()
	r.POST("/orders", createOrder)

	req := httptest.NewRequest(http.MethodPost, "/orders", strings.NewReader("{no es json"))
	req.Header.Set("Content-Type", "application/json")
	w := httptest.NewRecorder()
	r.ServeHTTP(w, req)

	if w.Code != http.StatusBadRequest {
		t.Errorf("esperaba 400, obtuve %d", w.Code)
	}
}
