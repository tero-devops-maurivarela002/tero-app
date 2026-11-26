"""Tests unitarios del carrito en memoria (no necesitan Postgres)."""
import pytest

from app.models import Item
from app.service import InMemoryCartService


@pytest.fixture
def svc():
    return InMemoryCartService()


def item(item_id="p1", quantity=1, price=100):
    return Item(itemId=item_id, quantity=quantity, unitPrice=price)


def test_carrito_nuevo_esta_vacio(svc):
    cart = svc.get("cliente-1")
    assert cart.customerId == "cliente-1"
    assert cart.items == []


def test_agregar_y_obtener_item(svc):
    svc.add_item("c1", item("p1", 2))
    assert svc.get_item("c1", "p1").quantity == 2
    assert len(svc.get_items("c1")) == 1


def test_actualizar_item_existente(svc):
    svc.add_item("c1", item("p1", 1))
    assert svc.update_item("c1", item("p1", 5)) is not None
    assert svc.get_item("c1", "p1").quantity == 5


def test_actualizar_item_inexistente_devuelve_none(svc):
    assert svc.update_item("c1", item("no-existe")) is None


def test_borrar_item(svc):
    svc.add_item("c1", item("p1"))
    svc.delete_item("c1", "p1")
    assert svc.get_item("c1", "p1") is None


def test_borrar_carrito(svc):
    svc.add_item("c1", item("p1"))
    svc.delete("c1")
    assert svc.get_items("c1") == []


def test_merge_pasa_items_de_la_sesion_sin_pisar_los_del_cliente(svc):
    svc.add_item("cliente", item("p1", quantity=1))
    svc.add_item("sesion", item("p1", quantity=9))
    svc.add_item("sesion", item("p2", quantity=3))

    svc.merge("cliente", "sesion")

    assert svc.get_item("cliente", "p1").quantity == 1  # no se pisa
    assert svc.get_item("cliente", "p2").quantity == 3  # se agrega
    assert svc.get_items("sesion") == []  # la sesión queda vacía


def test_carritos_de_distintos_clientes_estan_aislados(svc):
    svc.add_item("a", item("p1"))
    assert svc.get_items("b") == []
