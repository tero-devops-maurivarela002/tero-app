"""Logs en JSON (DEVOPS-48).

Una línea JSON por evento, con el mismo formato en los 6 servicios, para
consultarlos con CloudWatch Logs Insights. Formato y consultas:
docs/observabilidad/logs-json.md
"""
import json
import logging
import sys
from datetime import datetime, timezone

SERVICE = "cart"

# Mismos nombres de nivel que Go (slog) y Node: INFO, WARN, ERROR.
_LEVELS = {"WARNING": "WARN", "CRITICAL": "ERROR"}

http_logger = logging.getLogger("tero.http")


class JsonFormatter(logging.Formatter):
    def format(self, record: logging.LogRecord) -> str:
        entry = {
            "time": datetime.fromtimestamp(record.created, tz=timezone.utc).isoformat(timespec="milliseconds"),
            "level": _LEVELS.get(record.levelname, record.levelname),
            "msg": record.getMessage(),
            "service": SERVICE,
        }
        entry.update(getattr(record, "fields", {}))
        if record.exc_info:
            entry["error"] = self.formatException(record.exc_info)
        return json.dumps(entry, ensure_ascii=False)


def configure(level: int = logging.INFO, stream=None) -> None:
    """Todo a stdout (o a stream, en los tests) en JSON, incluidos los logs de uvicorn."""
    handler = logging.StreamHandler(stream or sys.stdout)
    handler.setFormatter(JsonFormatter())
    root = logging.getLogger()
    root.handlers = [handler]
    root.setLevel(level)
    for name in ("uvicorn", "uvicorn.error"):
        logging.getLogger(name).handlers = []
        logging.getLogger(name).propagate = True
    # El access log de uvicorn (texto) se reemplaza por log_request.
    logging.getLogger("uvicorn.access").disabled = True


def level_for(status: int) -> int:
    if status >= 500:
        return logging.ERROR
    if status >= 400:
        return logging.WARNING
    return logging.INFO


def log_request(method: str, path: str, status: int, duration_ms: float) -> None:
    """Una línea por request. /health no se loguea: lo llama el ALB cada pocos segundos."""
    if path == "/health":
        return
    http_logger.log(level_for(status), "request", extra={"fields": {
        "method": method,
        "path": path,
        "status": status,
        "duration_ms": round(duration_ms, 3),
    }})
