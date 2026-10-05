import pytest

from shopkit.cart import Cart
from shopkit.catalog import sample_catalog


@pytest.fixture
def cart():
    c = Cart(sample_catalog())
    c.add("A100", 3)
    c.add("B100", 1)
    return c


def test_remove_decrements(cart):
    cart.remove("A100", 2)
    assert cart.quantity("A100") == 1
    assert cart.subtotal_cents() == 1500 + 900


def test_remove_default_is_one(cart):
    cart.remove("A100")
    assert cart.quantity("A100") == 2


def test_remove_exact_quantity_drops_line(cart):
    cart.remove("B100", 1)
    assert cart.quantity("B100") == 0
    assert [p.sku for p, _ in cart.lines()] == ["A100"]


def test_remove_more_than_present_drops_line(cart):
    cart.remove("A100", 10)
    assert cart.quantity("A100") == 0
    assert [p.sku for p, _ in cart.lines()] == ["B100"]
    assert cart.subtotal_cents() == 900


def test_remove_everything_leaves_empty_cart(cart):
    cart.remove("A100", 3)
    cart.remove("B100", 1)
    assert cart.is_empty()
    assert cart.subtotal_cents() == 0


def test_remove_sku_not_in_cart(cart):
    with pytest.raises(KeyError):
        cart.remove("C100")
    assert cart.quantity("C100") == 0
    assert len(cart.lines()) == 2


@pytest.mark.parametrize("bad", [0, -1])
def test_remove_rejects_non_positive(cart, bad):
    with pytest.raises(ValueError):
        cart.remove("A100", bad)
    assert cart.quantity("A100") == 3


def test_add_still_works_after_remove(cart):
    cart.remove("B100")
    cart.add("B100", 2)
    assert cart.quantity("B100") == 2
