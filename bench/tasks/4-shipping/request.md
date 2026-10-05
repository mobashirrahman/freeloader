Add shipping costs to shopkit, with tests.

Create `shopkit/shipping.py` with three functions.

`parse_weight(text: str) -> int` turns a weight such as `"1.5kg"`, `"200 g"`, `"2 lb"` or `"8oz"` into grams.
- Units are `g`, `kg`, `lb` and `oz`, in any letter case, with optional spaces around the number and before the unit.
- 1 lb is 453.592 g and 1 oz is 28.3495 g.
- The result is rounded half up to a whole gram.
- The number is a non-negative decimal such as `2`, `0.5` or `1.25`.
- Anything else, including a missing unit, a negative number, or an empty string, raises `ValueError`.

`cart_weight_grams(cart: Cart) -> int` returns the sum of `weight_grams * quantity` over the cart.

`shipping_cents(cart: Cart, zone: str, free_over_cents: int | None = None) -> int`:
- An empty cart ships for 0.
- `"domestic"`: 500 for the first 500 g, plus 150 for each further 500 g or part of it.
- `"eu"`: 1200 for the first 1000 g, plus 400 for each further 1000 g or part of it.
- `"world"`: 2500 for the first 1000 g, plus 900 for each further 1000 g or part of it.
- A cart that is not empty but weighs 0 g pays the zone's base price.
- If `free_over_cents` is given, the zone is `"domestic"`, and `cart.subtotal_cents()` is at least `free_over_cents`, shipping is 0. It has no effect in other zones.
- Any other zone raises `ValueError`.
