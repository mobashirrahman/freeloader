"""Money amounts, always held as integer cents."""

_SYMBOLS = {"USD": "$", "EUR": "€", "GBP": "£"}


def format_cents(cents: int, currency: str = "USD") -> str:
    """Return cents as a display string such as "$12.34" or "-$0.05"."""
    if currency not in _SYMBOLS:
        raise ValueError(f"unknown currency: {currency}")
    sign = "-" if cents < 0 else ""
    cents = abs(cents)
    return f"{sign}{_SYMBOLS[currency]}{cents // 100}.{cents % 100:02d}"


def parse_price(text: str) -> int:
    """Parse a price such as "12.34", "$12.34" or "12" into cents."""
    cleaned = text.strip().lstrip("$")
    if not cleaned:
        raise ValueError("empty price")
    whole, _, fraction = cleaned.partition(".")
    if not whole.isdigit() or (fraction and not fraction.isdigit()) or len(fraction) > 2:
        raise ValueError(f"not a price: {text!r}")
    return int(whole) * 100 + int(fraction.ljust(2, "0") or 0)
