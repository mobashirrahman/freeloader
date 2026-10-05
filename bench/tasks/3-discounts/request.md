Add discounts to shopkit, with tests.

Create `shopkit/discounts.py` with three frozen dataclasses and one function.

```python
PercentOff(percent: int, tag: str | None = None)
FixedOff(cents: int, min_subtotal_cents: int = 0)
BuyXGetY(sku: str, buy: int, free: int)

total_cents(cart: Cart, discounts) -> int
```

Each dataclass validates itself on construction and raises `ValueError` for: `percent` outside 1..100, `cents` below 1, `min_subtotal_cents` below 0, `buy` below 1, `free` below 1.

`total_cents` returns what the cart costs after the given discounts, applied in this order whatever order they are passed in:

1. **BuyXGetY**, per cart line. With quantity `q` of that SKU, `(q // (buy + free)) * free` units are free. If several `BuyXGetY` name the same SKU, only the one that gives the most free units applies.
2. **PercentOff**, per cart line, on the line's total after step 1. A `PercentOff` with a `tag` applies only to products carrying that tag; with no tag it applies to every line. If several apply to a line, only the largest percent is used; they do not stack. The amount taken off a line is `line_total * percent / 100` rounded half up to a whole cent.
3. **FixedOff**, on the whole cart. Each one applies if the cart's original subtotal, `cart.subtotal_cents()` before any discount, is at least its `min_subtotal_cents`. Those that apply stack.

The result is never below 0. An empty cart costs 0. A `BuyXGetY` for a SKU that is not in the cart does nothing.
