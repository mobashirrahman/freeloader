from dataclasses import dataclass


@dataclass(frozen=True)
class PercentOff:
    percent: int
    tag: str | None = None

    def __post_init__(self):
        if not 1 <= self.percent <= 100:
            raise ValueError("percent must be 1..100")


@dataclass(frozen=True)
class FixedOff:
    cents: int
    min_subtotal_cents: int = 0

    def __post_init__(self):
        if self.cents < 1 or self.min_subtotal_cents < 0:
            raise ValueError("bad fixed discount")


@dataclass(frozen=True)
class BuyXGetY:
    sku: str
    buy: int
    free: int

    def __post_init__(self):
        if self.buy < 1 or self.free < 1:
            raise ValueError("bad offer")


def total_cents(cart, discounts):
    discounts = list(discounts)
    total = 0
    for product, qty in cart.lines():
        free = max(
            ((qty // (d.buy + d.free)) * d.free for d in discounts if isinstance(d, BuyXGetY) and d.sku == product.sku),
            default=0,
        )
        line = product.price_cents * (qty - free)
        percent = max(
            (d.percent for d in discounts if isinstance(d, PercentOff) and (d.tag is None or d.tag in product.tags)),
            default=0,
        )
        line -= (line * percent + 50) // 100
        total += line
    subtotal = cart.subtotal_cents()
    for d in discounts:
        if isinstance(d, FixedOff) and subtotal >= d.min_subtotal_cents:
            total -= d.cents
    return max(total, 0)
