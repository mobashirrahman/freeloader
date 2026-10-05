"""A shopping cart: SKUs and how many of each."""

from shopkit.catalog import Catalog, Product


class Cart:
    """Quantities of products from one catalog."""

    def __init__(self, catalog: Catalog):
        self._catalog = catalog
        self._lines: dict[str, int] = {}

    def add(self, sku: str, qty: int = 1) -> None:
        """Add qty of a product. Unknown SKUs raise KeyError."""
        if qty <= 0:
            raise ValueError("qty must be positive")
        self._catalog.get(sku)
        self._lines[sku] = self._lines.get(sku, 0) + qty

    def remove(self, sku: str, qty: int = 1) -> None:
        """Remove qty of a product from the cart."""
        self._lines[sku] = self._lines.get(sku, 0) - qty

    def quantity(self, sku: str) -> int:
        """Return how many of a SKU are in the cart, 0 if none."""
        return self._lines.get(sku, 0)

    def lines(self) -> list[tuple[Product, int]]:
        """Return (product, quantity) pairs sorted by SKU."""
        return [(self._catalog.get(sku), qty) for sku, qty in sorted(self._lines.items())]

    def subtotal_cents(self) -> int:
        """Return the cart total before discounts and shipping."""
        return sum(product.price_cents * qty for product, qty in self.lines())

    def is_empty(self) -> bool:
        """Return True when nothing is in the cart."""
        return not self._lines
