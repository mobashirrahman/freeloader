import pytest

from shopkit.catalog import Catalog, Product, sample_catalog


def test_sample_catalog_is_sorted_by_sku():
    assert [p.sku for p in sample_catalog()] == ["A100", "A200", "B100", "B200", "C100", "C200"]


def test_get_and_missing():
    catalog = sample_catalog()
    assert catalog.get("B100").name == "Coffee Mug"
    with pytest.raises(KeyError):
        catalog.get("Z999")


def test_duplicate_sku_rejected():
    catalog = Catalog([Product("X1", "Thing", 100)])
    with pytest.raises(ValueError):
        catalog.add(Product("X1", "Other", 200))


def test_with_tag():
    assert [p.sku for p in sample_catalog().with_tag("sale")] == ["A100", "C100"]
