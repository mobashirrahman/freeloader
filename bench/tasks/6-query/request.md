Add a small query language for searching the catalog, with tests. This touches three places.

## `shopkit/query.py`

```python
class QueryError(ValueError)
def matches(product: Product, expr: str) -> bool
```

`matches` says whether a product satisfies a query. A query is built from terms joined with `and`, `or`, `not`, and parentheses.

Terms:

- `price OP NUMBER`, where `OP` is one of `<`, `<=`, `>`, `>=`, `=`, `!=`, and `NUMBER` is an amount in dollars such as `12`, `12.5` or `12.50` (at most two decimals). It compares the product's price. `price<15` is true for a product costing $14.99 and false for one costing $15.00.
- `tag:NAME` is true when the product has that tag. Tag names are letters, digits, `_` and `-`, and match without regard to case.
- `name~"TEXT"` is true when the product name contains TEXT, without regard to case. TEXT is in double quotes and may contain spaces; it cannot contain a double quote. `name~""` matches every product.
- `sku=VALUE` is true when the SKU equals VALUE without regard to case. VALUE is letters, digits, `_` and `-`.

Rules:

- `not` binds tighter than `and`, which binds tighter than `or`. Parentheses override that. `not` can be repeated.
- `and`, `or`, `not`, `price`, `tag`, `name` and `sku` are recognised in any letter case.
- Spaces are allowed, and not required, around operators, `:`, `~`, and parentheses.
- Anything that does not parse raises `QueryError`: an empty or blank query, an unknown term, a missing operand, unbalanced parentheses, an unterminated string, a malformed number, or leftover text.

## `shopkit/catalog.py`

Add `Catalog.query(self, expr: str) -> list[Product]`, returning the matching products sorted by SKU. An invalid query raises `QueryError`, even when the catalog is empty.

## `shopkit/cli.py`

Add a `search EXPR` command that prints the matching products in the same format as `list` and exits 0. For an invalid query it prints a line starting with `error:` to stderr, prints nothing to stdout, and exits 2. The existing `list` command must keep working.
