import pytest

from shopkit.text import slugify


@pytest.mark.parametrize(
    "text, expected",
    [
        ("Hello, World!", "hello-world"),
        ("  Plain   T-Shirt  ", "plain-t-shirt"),
        ("Already-Slugged_text", "already-slugged-text"),
        ("Café Crème", "caf-cr-me"),
        ("100% Wool", "100-wool"),
        ("!!!", ""),
        ("", ""),
    ],
)
def test_slugify(text, expected):
    assert slugify(text) == expected


def test_max_length_cuts():
    assert slugify("Espresso Machine Deluxe", max_length=8) == "espresso"


def test_max_length_drops_trailing_dash():
    assert slugify("Espresso Machine Deluxe", max_length=9) == "espresso"


def test_max_length_longer_than_text():
    assert slugify("Mug", max_length=50) == "mug"


@pytest.mark.parametrize("bad", [0, -3])
def test_max_length_must_be_positive(bad):
    with pytest.raises(ValueError):
        slugify("anything", max_length=bad)
