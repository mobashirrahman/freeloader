Add stock tracking and orders to shopkit, with tests. This touches three places.

## `shopkit/inventory.py`

```python
class OutOfStock(Exception)          # has attributes sku, requested, available
class Inventory:
    def __init__(self, catalog: Catalog, stock: dict[str, int] | None = None)
    def on_hand(self, sku: str) -> int
    def reserved(self, sku: str) -> int
    def available(self, sku: str) -> int
    def receive(self, sku: str, qty: int) -> None
    def reserve(self, order_id: str, lines: dict[str, int]) -> None
    def release(self, order_id: str) -> None
    def commit(self, order_id: str) -> None
def sample_inventory() -> Inventory
```

- Every SKU in the catalog has a stock level, 0 unless `stock` says otherwise. A SKU in `stock` that is not in the catalog raises `KeyError`; a negative level raises `ValueError`.
- `on_hand`, `reserved` and `available` raise `KeyError` for a SKU that is not in the catalog. `available` is `on_hand - reserved`.
- `receive` adds to `on_hand`. `qty` below 1 raises `ValueError`.
- `reserve` holds stock for an order. `lines` maps SKU to quantity. It is all or nothing: if any line asks for more than is available, nothing is reserved and `OutOfStock` is raised for the first failing SKU in sorted SKU order, carrying that SKU, the quantity requested, and the quantity available. Reserving again for an `order_id` that already holds a reservation raises `ValueError`.
- `release` drops an order's reservation and makes the stock available again.
- `commit` turns an order's reservation into a sale: `on_hand` goes down by the reserved quantities and the reservation is cleared.
- `release` and `commit` raise `KeyError` for an `order_id` with no reservation.
- `sample_inventory()` returns an inventory over `sample_catalog()` with 10 of every product.

## `shopkit/orders.py`

```python
class InvalidTransition(Exception)
class Order:
    def __init__(self, order_id: str, cart: Cart, inventory: Inventory)
    order_id: str
    lines: dict[str, int]        # SKU -> quantity, copied from the cart
    total_cents: int             # cart.subtotal_cents() at creation
    status: str
    history: list[str]
    def pay(self) -> None
    def ship(self) -> None
    def deliver(self) -> None
    def cancel(self) -> None
```

- Creating an order from an empty cart raises `ValueError`.
- Creating an order reserves its lines in the inventory under its `order_id`. If that raises `OutOfStock`, the error propagates and nothing stays reserved.
- `lines` and `total_cents` are a snapshot: changing the cart afterwards does not change the order.
- `status` starts as `"created"`. The allowed moves are `pay`: created to paid; `ship`: paid to shipped; `deliver`: shipped to delivered; `cancel`: created or paid to cancelled.
- `ship` commits the reservation. `cancel` releases it.
- Any other move raises `InvalidTransition`, with the current status in its message, and changes nothing.
- `history` lists every status the order has had, in order, starting with `"created"`.

## `shopkit/cli.py`

Add a `stock` command. It prints one line per product in SKU order, as the SKU, a tab, and the quantity on hand in `sample_inventory()`, and exits 0. The existing `list` command must keep working.
