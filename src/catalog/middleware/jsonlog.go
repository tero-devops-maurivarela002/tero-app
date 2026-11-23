package middleware

import (
	"log/slog"
	"time"

	"github.com/gin-gonic/gin"
)

// Logs en JSON (DEVOPS-48): una línea JSON por request, con el mismo formato
// en los 6 servicios, para consultarlos con CloudWatch Logs Insights.
// Formato y consultas: docs/observabilidad/logs-json.md

// LevelFor devuelve el nivel según el status HTTP: 5xx error, 4xx warn.
func LevelFor(status int) slog.Level {
	switch {
	case status >= 500:
		return slog.LevelError
	case status >= 400:
		return slog.LevelWarn
	default:
		return slog.LevelInfo
	}
}

// JSONLogger registra cada request (menos /health, que lo llama el ALB).
// El logger ya trae el campo "service" (ver main.go).
func JSONLogger(logger *slog.Logger) gin.HandlerFunc {
	return func(c *gin.Context) {
		start := time.Now()
		c.Next()

		path := c.Request.URL.Path
		if path == "/health" {
			return
		}
		status := c.Writer.Status()
		logger.Log(c.Request.Context(), LevelFor(status), "request",
			"method", c.Request.Method,
			"path", path,
			"status", status,
			"duration_ms", float64(time.Since(start).Microseconds())/1000,
		)
	}
}
