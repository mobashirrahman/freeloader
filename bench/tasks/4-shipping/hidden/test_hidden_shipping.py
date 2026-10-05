import pytest

from shopkit.cart import Cart
from shopkit.catalog import Catalog, Product, sample_catalog
from shopkit.shipping import cart_weight_grams, parse_weight, shipping_cents


def cart_with(**lines):
    cart = Cart(sample_catalog())
    for sku, qty in lines.items():
        cart.add(sku, qty)
    return cart


@pytest.mark.parametrize(
    "text, grams",
    [
        ("200g", 200),
        ("200 g", 200),
        ("1.5kg", 1500),
        ("  2 KG ", 2000),
        ("0.5Kg", 500),
        ("2 lb", 907),
        ("1lb", 454),
        ("8oz", 227),
        ("1 oz", 28),
        ("0g", 0),
        ("0.0005kg", 1),
    ],
)
def test_parse_weight(text, grams):
    assert parse_weight(text) == grams


@pytest.mark.parametrize("bad", ["", "12", "kg", "-1kg", "1.2.3kg", "5 stone", "1,5kg", "g200"])
def test_parse_weight_rejects(bad):
    with pytest.raises(ValueError):
        parse_weight(bad)


def test_cart_weight():
    assert cart_weight_grams(cart_with(A100=2, B200=1)) == 2 * 200 + 4200
    assert cart_weight_grams(Cart(sample_catalog())) == 0


@pytest.mark.parametrize("zone", ["domestic", "eu", "world"])
def test_empty_cart_ships_free(zone):
    assert shipping_cents(Cart(sample_catalog()), zone) == 0


@pytest.mark.parametrize(
    "lines, cents",
    [
        ({"C200": 1}, 500),  # 40 g
        ({"B100": 1, "C200": 1, "A100": 0}, 500),  # 390 g
        ({"A100": 2, "C200": 2, "C100": 0}, 500),  # 480 g
        ({"A200": 1}, 650),  # 600 g
        ({"A100": 5}, 650),  # exactly 1000 g
        ({"A100": 5, "C200": 1}, 800),  # 1040 g
        ({"B200": 1}, 500 + 8 * 150),  # 4200 g
    ],
)
def test_domestic(lines, cents):
    cart = cart_with(**{sku: qty for sku, qty in lines.items() if qty})
    assert shipping_cents(cart, "domestic") == cents


def test_domestic_exactly_500_is_base():
    catalog = Catalog([Product("W", "Weight", 100, (), 500)])
    cart = Cart(catalog)
    cart.add("W")
    assert shipping_cents(cart, "domestic") == 500
    cart.add("W")
    assert shipping_cents(cart, "domestic") == 650


@pytest.mark.parametrize(
    "lines, eu, world",
    [
        ({"C200": 1}, 1200, 2500),
        ({"A100": 5}, 1200, 2500),  # exactly 1000 g
        ({"A100": 5, "C200": 1}, 1600, 3400),
        ({"B200": 1}, 1200 + 4 * 400, 2500 + 4 * 900),  # 4200 g
    ],
)
def test_eu_and_world(lines, eu, world):
    cart = cart_with(**lines)
    assert shipping_cents(cart, "eu") == eu
    assert shipping_cents(cart, "world") == world


def test_weightless_cart_pays_base():
    catalog = Catalog([Product("D1", "Download", 999)])
    cart = Cart(catalog)
    cart.add("D1", 3)
    assert shipping_cents(cart, "domestic") == 500
    assert shipping_cents(cart, "eu") == 1200
    assert shipping_cents(cart, "world") == 2500


def test_free_shipping_threshold_domestic_only():
    cart = cart_with(A200=1)  # 4500 cents, 600 g
    assert shipping_cents(cart, "domestic", free_over_cents=4500) == 0
    assert shipping_cents(cart, "domestic", free_over_cents=4501) == 650
    assert shipping_cents(cart, "eu", free_over_cents=1) == 1200
    assert shipping_cents(cart, "world", free_over_cents=1) == 2500


@pytest.mark.parametrize("zone", ["mars", "", "Domestic"])
def test_unknown_zone(zone):
    with pytest.raises(ValueError):
        shipping_cents(cart_with(A100=1), zone)
