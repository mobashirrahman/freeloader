from shopkit.catalog import sample_catalog


class OutOfStock(Exception):
    def __init__(self, sku, requested, available):
        super().__init__(f"{sku}: wanted {requested}, {available} available")
        self.sku, self.requested, self.available = sku, requested, available


class Inventory:
    def __init__(self, catalog, stock=None):
        self._on_hand = {p.sku: 0 for p in catalog}
        self._orders = {}
        for sku, qty in (stock or {}).items():
            if sku not in self._on_hand:
                raise KeyError(sku)
            if qty < 0:
                raise ValueError("negative stock")
            self._on_hand[sku] = qty

    def on_hand(self, sku):
        return self._on_hand[sku]

    def reserved(self, sku):
        self._on_hand[sku]
        return sum(lines.get(sku, 0) for lines in self._orders.values())

    def available(self, sku):
        return self.on_hand(sku) - self.reserved(sku)

    def receive(self, sku, qty):
        if qty < 1:
            raise ValueError("qty must be positive")
        self._on_hand[sku] += qty

    def reserve(self, order_id, lines):
        if order_id in self._orders:
            raise ValueError("already reserved")
        for sku in sorted(lines):
            if lines[sku] > self.available(sku):
                raise OutOfStock(sku, lines[sku], self.available(sku))
        self._orders[order_id] = dict(lines)

    def release(self, order_id):
        del self._orders[order_id]

    def commit(self, order_id):
        for sku, qty in self._orders.pop(order_id).items():
            self._on_hand[sku] -= qty


def sample_inventory():
    catalog = sample_catalog()
    return Inventory(catalog, {p.sku: 10 for p in catalog})
