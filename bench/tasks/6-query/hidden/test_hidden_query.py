import pytest

from shopkit.catalog import Catalog, sample_catalog
from shopkit.cli import main
from shopkit.query import QueryError, matches


def skus(expr):
    return [p.sku for p in sample_catalog().query(expr)]


# A100 Plain T-Shirt     15.00  clothing, sale
# A200 Wool Sweater      45.00  clothing, winter
# B100 Coffee Mug         9.00  kitchen
# B200 Espresso Machine 249.00  kitchen, electronics
# C100 Notebook           4.50  stationery, sale
# C200 Fountain Pen      32.00  stationery


@pytest.mark.parametrize(
    "expr, expected",
    [
        ("price<15", ["B100", "C100"]),
        ("price<=15", ["A100", "B100", "C100"]),
        ("price>45", ["B200"]),
        ("price>=45", ["A200", "B200"]),
        ("price=4.5", ["C100"]),
        ("price=4.50", ["C100"]),
        ("price = 9", ["B100"]),
        ("price!=9", ["A100", "A200", "B200", "C100", "C200"]),
        ("price < 14.99", ["B100", "C100"]),
        ("price>1000", []),
    ],
)
def test_price(expr, expected):
    assert skus(expr) == expected


@pytest.mark.parametrize(
    "expr, expected",
    [
        ("tag:sale", ["A100", "C100"]),
        ("tag:SALE", ["A100", "C100"]),
        ("tag : kitchen", ["B100", "B200"]),
        ("tag:nothing", []),
        ('name~"pen"', ["C200"]),
        ('name~"E"', ["A200", "B100", "B200", "C100", "C200"]),
        ('name ~ "wool sw"', ["A200"]),
        ('name~""', ["A100", "A200", "B100", "B200", "C100", "C200"]),
        ("sku=b100", ["B100"]),
        ("sku = C200", ["C200"]),
        ("sku=Z999", []),
    ],
)
def test_other_terms(expr, expected):
    assert skus(expr) == expected


@pytest.mark.parametrize(
    "expr, expected",
    [
        ("tag:sale and price<10", ["C100"]),
        ("tag:sale or tag:kitchen", ["A100", "B100", "B200", "C100"]),
        ("not tag:sale", ["A200", "B100", "B200", "C200"]),
        ("not not tag:sale", ["A100", "C100"]),
        # and binds tighter than or
        ("tag:kitchen or tag:sale and price<10", ["B100", "B200", "C100"]),
        ("(tag:kitchen or tag:sale) and price<10", ["B100", "C100"]),
        # not binds tighter than and
        ("not tag:sale and tag:kitchen", ["B100", "B200"]),
        ("not (tag:sale or tag:kitchen)", ["A200", "C200"]),
        ("TAG:sale AND NOT Price>10", ["C100"]),
        ('(price<10 or price>100)and(not name~"mug")', ["B200", "C100"]),
        ("((tag:clothing))", ["A100", "A200"]),
        ('tag:stationery and (name~"pen" or price<5) and not sku=c100', ["C200"]),
    ],
)
def test_combinations(expr, expected):
    assert skus(expr) == expected


@pytest.mark.parametrize(
    "expr",
    [
        "",
        "   ",
        "price",
        "price<",
        "price<abc",
        "price<1.234",
        "price<<5",
        "tag:",
        "tag:sale and",
        "and tag:sale",
        "tag:sale tag:kitchen",
        "(tag:sale",
        "tag:sale)",
        "()",
        "not",
        'name~"unterminated',
        "name~pen",
        "colour=red",
        "sku<A100",
        "tag:sale && price<5",
    ],
)
def test_invalid_queries(expr):
    with pytest.raises(QueryError):
        sample_catalog().query(expr)


def test_query_error_is_a_value_error():
    assert issubclass(QueryError, ValueError)


def test_invalid_query_on_empty_catalog():
    with pytest.raises(QueryError):
        Catalog().query("price<")


def test_matches_function():
    product = sample_catalog().get("A100")
    assert matches(product, "tag:sale and price<=15") is True
    assert matches(product, "tag:winter") is False


def test_cli_search(capsys):
    assert main(["search", "tag:sale and price<10"]) == 0
    assert capsys.readouterr().out.splitlines() == ["C100\tNotebook\t$4.50"]


def test_cli_search_invalid(capsys):
    assert main(["search", "price<"]) == 2
    captured = capsys.readouterr()
    assert captured.out == ""
    assert captured.err.startswith("error:")


def test_cli_list_still_works(capsys):
    assert main(["list"]) == 0
    assert len(capsys.readouterr().out.splitlines()) == 6
