Fix `Cart.remove` in `shopkit/cart.py` and add regression tests.

It currently subtracts without checking anything, so a cart can end up with zero or negative quantities and a wrong subtotal. It should behave like this:

- `qty` must be a positive integer; otherwise raise `ValueError`.
- Removing a SKU that is not in the cart raises `KeyError`.
- Removing as many as are in the cart, or more, removes the line entirely: `quantity(sku)` is then 0 and the SKU no longer appears in `lines()`.
- Otherwise the quantity goes down by `qty`.

Nothing else about `Cart` should change.
