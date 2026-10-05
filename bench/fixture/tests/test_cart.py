import pytest

from shopkit.cart import Cart
from shopkit.catalog import sample_catalog


def make_cart():
    return Cart(sample_catalog())


def test_add_and_subtotal():
    cart = make_cart()
    cart.add("A100", 2)
    cart.add("B100")
    assert cart.quantity("A100") == 2
    assert cart.subtotal_cents() == 2 * 1500 + 900


def test_add_rejects_bad_input():
    cart = make_cart()
    with pytest.raises(ValueError):
        cart.add("A100", 0)
    with pytest.raises(KeyError):
        cart.add("Z999")


def test_remove_some():
    cart = make_cart()
    cart.add("A100", 3)
    cart.remove("A100")
    assert cart.quantity("A100") == 2


def test_empty():
    assert make_cart().is_empty()
