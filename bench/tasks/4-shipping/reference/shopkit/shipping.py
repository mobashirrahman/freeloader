import re
from decimal import ROUND_HALF_UP, Decimal

_UNITS = {"g": Decimal(1), "kg": Decimal(1000), "lb": Decimal("453.592"), "oz": Decimal("28.3495")}
_ZONES = {"domestic": (500, 500, 150), "eu": (1200, 1000, 400), "world": (2500, 1000, 900)}


def parse_weight(text):
    match = re.fullmatch(r"\s*(\d+(?:\.\d+)?)\s*(g|kg|lb|oz)\s*", text, re.IGNORECASE)
    if not match:
        raise ValueError(f"not a weight: {text!r}")
    grams = Decimal(match.group(1)) * _UNITS[match.group(2).lower()]
    return int(grams.quantize(Decimal(1), rounding=ROUND_HALF_UP))


def cart_weight_grams(cart):
    return sum(product.weight_grams * qty for product, qty in cart.lines())


def shipping_cents(cart, zone, free_over_cents=None):
    if zone not in _ZONES:
        raise ValueError(f"unknown zone: {zone}")
    if cart.is_empty():
        return 0
    if zone == "domestic" and free_over_cents is not None and cart.subtotal_cents() >= free_over_cents:
        return 0
    base, step, extra = _ZONES[zone]
    over = max(cart_weight_grams(cart) - step, 0)
    return base + -(-over // step) * extra
