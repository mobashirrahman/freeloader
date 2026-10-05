class InvalidTransition(Exception):
    pass


_MOVES = {
    "pay": ({"created"}, "paid"),
    "ship": ({"paid"}, "shipped"),
    "deliver": ({"shipped"}, "delivered"),
    "cancel": ({"created", "paid"}, "cancelled"),
}


class Order:
    def __init__(self, order_id, cart, inventory):
        if cart.is_empty():
            raise ValueError("empty cart")
        self.order_id = order_id
        self.lines = {product.sku: qty for product, qty in cart.lines()}
        self.total_cents = cart.subtotal_cents()
        self._inventory = inventory
        inventory.reserve(order_id, self.lines)
        self.status = "created"
        self.history = ["created"]

    def _move(self, name):
        allowed, target = _MOVES[name]
        if self.status not in allowed:
            raise InvalidTransition(f"cannot {name} an order that is {self.status}")
        self.status = target
        self.history.append(target)

    def pay(self):
        self._move("pay")

    def ship(self):
        self._move("ship")
        self._inventory.commit(self.order_id)

    def deliver(self):
        self._move("deliver")

    def cancel(self):
        self._move("cancel")
        self._inventory.release(self.order_id)
