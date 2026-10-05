import pytest

from shopkit.money import format_cents, parse_price


def test_format_cents():
    assert format_cents(1234) == "$12.34"
    assert format_cents(-5) == "-$0.05"
    assert format_cents(900, "EUR") == "€9.00"


def test_format_unknown_currency():
    with pytest.raises(ValueError):
        format_cents(1, "XYZ")


def test_parse_price():
    assert parse_price("12.34") == 1234
    assert parse_price("$12") == 1200
    assert parse_price("0.5") == 50


@pytest.mark.parametrize("bad", ["", "abc", "1.234", "-1"])
def test_parse_price_rejects(bad):
    with pytest.raises(ValueError):
        parse_price(bad)
