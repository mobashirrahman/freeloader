"""Products and the catalog that holds them."""

from dataclasses import dataclass


@dataclass(frozen=True)
class Product:
    """One thing the shop sells."""

    sku: str
    name: str
    price_cents: int
    tags: tuple[str, ...] = ()
    weight_grams: int = 0


class Catalog:
    """A set of products, looked up by SKU."""

    def __init__(self, products=()):
        self._products: dict[str, Product] = {}
        for product in products:
            self.add(product)

    def add(self, product: Product) -> None:
        """Add a product. A SKU can only be added once."""
        if product.sku in self._products:
            raise ValueError(f"duplicate sku: {product.sku}")
        self._products[product.sku] = product

    def get(self, sku: str) -> Product:
        """Return the product with this SKU, or raise KeyError."""
        return self._products[sku]

    def with_tag(self, tag: str) -> list[Product]:
        """Return the products carrying a tag, sorted by SKU."""
        return [p for p in self if tag in p.tags]

    def query(self, expr: str) -> list[Product]:
        """Return the products matching a query, sorted by SKU."""
        from shopkit.query import compile_query

        test = compile_query(expr)
        return [p for p in self if test(p)]

    def __len__(self) -> int:
        return len(self._products)

    def __iter__(self):
        return iter(sorted(self._products.values(), key=lambda p: p.sku))


def sample_catalog() -> Catalog:
    """Return the catalog used by the command line tool and the examples."""
    return Catalog(
        [
            Product("A100", "Plain T-Shirt", 1500, ("clothing", "sale"), 200),
            Product("A200", "Wool Sweater", 4500, ("clothing", "winter"), 600),
            Product("B100", "Coffee Mug", 900, ("kitchen",), 350),
            Product("B200", "Espresso Machine", 24900, ("kitchen", "electronics"), 4200),
            Product("C100", "Notebook", 450, ("stationery", "sale"), 180),
            Product("C200", "Fountain Pen", 3200, ("stationery",), 40),
        ]
    )
