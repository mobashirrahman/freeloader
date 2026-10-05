import re


class QueryError(ValueError):
    pass


_TOKEN = re.compile(
    r"""\s*(?:
        (?P<op><=|>=|!=|<|>|=)
      | (?P<punct>[():~])
      | "(?P<string>[^"]*)"
      | (?P<number>\d+(?:\.\d+)?)(?![\w.])
      | (?P<word>[A-Za-z0-9_-]+)
    )""",
    re.VERBOSE,
)


def _tokenize(expr):
    tokens, pos = [], 0
    expr = expr.rstrip()
    while pos < len(expr):
        match = _TOKEN.match(expr, pos)
        if not match:
            raise QueryError(f"cannot read query at position {pos}")
        kind = match.lastgroup
        tokens.append((kind, match.group(kind)))
        pos = match.end()
    return tokens


class _Parser:
    def __init__(self, tokens):
        self.tokens, self.i = tokens, 0

    def peek(self):
        return self.tokens[self.i] if self.i < len(self.tokens) else (None, None)

    def take(self):
        token = self.peek()
        self.i += 1
        return token

    def keyword(self, word):
        kind, value = self.peek()
        if kind == "word" and value.lower() == word:
            self.i += 1
            return True
        return False

    def parse(self):
        if not self.tokens:
            raise QueryError("empty query")
        node = self.or_()
        if self.i != len(self.tokens):
            raise QueryError("unexpected text after query")
        return node

    def or_(self):
        left = self.and_()
        while self.keyword("or"):
            right = self.and_()
            left = (lambda a, b: lambda p: a(p) or b(p))(left, right)
        return left

    def and_(self):
        left = self.not_()
        while self.keyword("and"):
            right = self.not_()
            left = (lambda a, b: lambda p: a(p) and b(p))(left, right)
        return left

    def not_(self):
        if self.keyword("not"):
            inner = self.not_()
            return lambda p: not inner(p)
        return self.primary()

    def primary(self):
        kind, value = self.take()
        if (kind, value) == ("punct", "("):
            node = self.or_()
            if self.take() != ("punct", ")"):
                raise QueryError("missing )")
            return node
        if kind != "word":
            raise QueryError("expected a term")
        field = value.lower()
        if field == "price":
            okind, op = self.take()
            nkind, number = self.take()
            if okind != "op" or nkind != "number" or len(number.partition(".")[2]) > 2:
                raise QueryError("bad price term")
            whole, _, fraction = number.partition(".")
            cents = int(whole) * 100 + int(fraction.ljust(2, "0") or 0)
            compare = {
                "<": lambda a: a < cents, "<=": lambda a: a <= cents, ">": lambda a: a > cents,
                ">=": lambda a: a >= cents, "=": lambda a: a == cents, "!=": lambda a: a != cents,
            }[op]
            return lambda p: compare(p.price_cents)
        if field == "tag":
            if self.take() != ("punct", ":"):
                raise QueryError("expected :")
            kind, name = self.take()
            if kind not in ("word", "number"):
                raise QueryError("expected a tag name")
            return lambda p: name.lower() in (t.lower() for t in p.tags)
        if field == "name":
            if self.take() != ("punct", "~"):
                raise QueryError("expected ~")
            kind, text = self.take()
            if kind != "string":
                raise QueryError("expected a quoted string")
            return lambda p: text.lower() in p.name.lower()
        if field == "sku":
            if self.take() != ("op", "="):
                raise QueryError("expected =")
            kind, sku = self.take()
            if kind not in ("word", "number"):
                raise QueryError("expected a sku")
            return lambda p: p.sku.lower() == sku.lower()
        raise QueryError(f"unknown term: {value}")


def compile_query(expr):
    return _Parser(_tokenize(expr)).parse()


def matches(product, expr):
    return bool(compile_query(expr)(product))
