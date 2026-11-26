package main

import (
	"bytes"
	"encoding/json"
	"log/slog"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/gin-gonic/gin"
)

func TestJSONLevelFor(t *testing.T) {
	casos := map[int]slog.Level{200: slog.LevelInfo, 302: slog.LevelInfo, 404: slog.LevelWarn, 500: slog.LevelError, 503: slog.LevelError}
	for status, want := range casos {
		if got := LevelFor(status); got != want {
			t.Errorf("LevelFor(%d) = %v, esperaba %v", status, got, want)
		}
	}
}

func TestJSONLoggerEscribeUnaLineaJSONPorRequest(t *testing.T) {
	gin.SetMode(gin.TestMode)
	var buf bytes.Buffer
	logger := slog.New(slog.NewJSONHandler(&buf, nil)).With("service", "orders")

	r := gin.New()
	r.Use(JSONLogger(logger))
	r.GET("/health", func(c *gin.Context) { c.Status(http.StatusOK) })
	r.GET("/products", func(c *gin.Context) { c.Status(http.StatusNotFound) })

	for _, path := range []string{"/health", "/products?page=2"} {
		r.ServeHTTP(httptest.NewRecorder(), httptest.NewRequest(http.MethodGet, path, nil))
	}

	lines := strings.Split(strings.TrimSpace(buf.String()), "\n")
	if len(lines) != 1 {
		t.Fatalf("esperaba 1 línea (sin /health), hubo %d: %q", len(lines), buf.String())
	}
	var entry map[string]any
	if err := json.Unmarshal([]byte(lines[0]), &entry); err != nil {
		t.Fatalf("la línea no es JSON: %v", err)
	}
	want := map[string]any{"level": "WARN", "msg": "request", "service": "orders", "method": "GET", "path": "/products", "status": float64(404)}
	for k, v := range want {
		if entry[k] != v {
			t.Errorf("%s = %v, esperaba %v", k, entry[k], v)
		}
	}
	if _, ok := entry["duration_ms"]; !ok {
		t.Error("falta duration_ms")
	}
}
