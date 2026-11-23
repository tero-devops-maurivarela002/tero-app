"""Tests de los logs en JSON (DEVOPS-48)."""
import io
import json
import logging

import pytest

from app import jsonlog


@pytest.fixture
def salida():
    stream = io.StringIO()
    jsonlog.configure(stream=stream)
    yield lambda: [json.loads(line) for line in stream.getvalue().splitlines() if line.strip()]
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
