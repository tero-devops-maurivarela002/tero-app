"""Tests de los logs en JSON (DEVOPS-48)."""
import io
import json
import logging

import pytest

from app import jsonlog


class _Salida:
    """Captura lo que se loguea y lo devuelve como lista de dicts."""

    def __init__(self):
        self.stream = io.StringIO()

    def __call__(self):
        return [json.loads(line) for line in self.stream.getvalue().splitlines() if line.strip()]


@pytest.fixture
def salida():
    capturada = _Salida()
    jsonlog.configure(stream=capturada.stream)
    yield capturada
    logging.getLogger().handlers = []


@pytest.mark.parametrize("status,nivel", [(200, logging.INFO), (404, logging.WARNING), (503, logging.ERROR)])
def test_level_for(status, nivel):
    assert jsonlog.level_for(status) == nivel


def test_log_request_escribe_una_linea_json(salida):
    jsonlog.log_request("GET", "/carts/c1", 404, 1.23456)
    [entry] = salida()
    assert entry["level"] == "WARN"
    assert entry["msg"] == "request"
    assert entry["service"] == "cart"
    assert entry["method"] == "GET"
    assert entry["path"] == "/carts/c1"
    assert entry["status"] == 404
    assert entry["duration_ms"] == pytest.approx(1.235)
    assert entry["time"].endswith("+00:00")


def test_health_no_se_loguea(salida):
    jsonlog.log_request("GET", "/health", 200, 0.5)
    assert salida() == []


def test_excepciones_van_en_el_campo_error(salida):
    try:
        raise ValueError("falló")
    except ValueError:
        logging.getLogger("tero.test").exception("algo salió mal")
    [entry] = salida()
    assert entry["level"] == "ERROR"
    assert "ValueError: falló" in entry["error"]


def test_uvicorn_access_queda_deshabilitado(salida):
    assert logging.getLogger("uvicorn.access").disabled


def test_middleware_http_loguea_cada_request(salida):
    """El middleware de main.py loguea método, ruta y status de la respuesta."""
    import asyncio
    from types import SimpleNamespace

    from app.main import json_access_log

    # Importar main configura los logs a stdout: se vuelve a apuntar a la captura.
    jsonlog.configure(stream=salida.stream)
    request = SimpleNamespace(method="POST", url=SimpleNamespace(path="/carts/c1/items"))

    async def call_next(_request):
        return SimpleNamespace(status_code=201)

    response = asyncio.run(json_access_log(request, call_next))
    assert response.status_code == 201
    [entry] = salida()
    assert entry["path"] == "/carts/c1/items"
    assert entry["status"] == 201
    assert entry["level"] == "INFO"
