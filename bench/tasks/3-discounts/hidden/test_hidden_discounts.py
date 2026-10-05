import pytest

from shopkit.cart import Cart
from shopkit.catalog import sample_catalog
from shopkit.discounts import BuyXGetY, FixedOff, PercentOff, total_cents


def cart_with(**lines):
    cart = Cart(sample_catalog())
    for sku, qty in lines.items():
        cart.add(sku, qty)
    return cart


def test_no_discounts():
    assert total_cents(cart_with(A100=2, B100=1), []) == 3900


def test_empty_cart():
    assert total_cents(Cart(sample_catalog()), [PercentOff(10), FixedOff(500)]) == 0


def test_percent_all_lines():
    assert total_cents(cart_with(A100=2, B100=1), [PercentOff(10)]) == 3510


def test_percent_by_tag():
    # only A100 and C100 carry "sale"
    assert total_cents(cart_with(A100=1, B100=1, C100=2), [PercentOff(20, tag="sale")]) == 1200 + 900 + 720


def test_percent_largest_wins_no_stacking():
    cart = cart_with(A100=1, B100=1)
    assert total_cents(cart, [PercentOff(10), PercentOff(50, tag="sale")]) == 750 + 810


def test_percent_rounds_half_up():
    # C100 is 450; 15% of 450 is 67.5, which rounds to 68 off
    assert total_cents(cart_with(C100=1), [PercentOff(15)]) == 450 - 68


def test_percent_100():
    assert total_cents(cart_with(B100=3), [PercentOff(100)]) == 0


def test_buy_x_get_y():
    # buy 2 get 1 free with 7 mugs: 7 // 3 = 2 free
    assert total_cents(cart_with(B100=7), [BuyXGetY("B100", 2, 1)]) == 5 * 900


def test_buy_x_get_y_not_enough():
    assert total_cents(cart_with(B100=2), [BuyXGetY("B100", 2, 1)]) == 1800


def test_buy_x_get_y_best_offer_for_sku():
    # 6 mugs: "buy 2 get 1" gives 2 free, "buy 1 get 1" gives 3 free; only the better applies
    cart = cart_with(B100=6)
    assert total_cents(cart, [BuyXGetY("B100", 2, 1), BuyXGetY("B100", 1, 1)]) == 3 * 900


def test_buy_x_get_y_other_sku_ignored():
    assert total_cents(cart_with(A100=3), [BuyXGetY("B100", 1, 1)]) == 4500


def test_percent_applies_after_free_units():
    # 3 mugs, 1 free -> 1800, then 10% -> 1620
    assert total_cents(cart_with(B100=3), [PercentOff(10), BuyXGetY("B100", 2, 1)]) == 1620


def test_fixed_off():
    assert total_cents(cart_with(A200=1), [FixedOff(500)]) == 4000


def test_fixed_off_threshold_uses_original_subtotal():
    cart = cart_with(A200=1)  # 4500
    discounts = [PercentOff(50), FixedOff(1000, min_subtotal_cents=4500)]
    assert total_cents(cart, discounts) == 2250 - 1000


def test_fixed_off_below_threshold():
    assert total_cents(cart_with(B100=1), [FixedOff(500, min_subtotal_cents=1000)]) == 900


def test_fixed_off_stacks_and_floors_at_zero():
    assert total_cents(cart_with(C100=1), [FixedOff(300), FixedOff(300)]) == 0


def test_order_of_arguments_does_not_matter():
    cart = cart_with(A100=2, B100=3)
    discounts = [FixedOff(200), PercentOff(10), BuyXGetY("B100", 2, 1)]
    assert total_cents(cart, discounts) == total_cents(cart, list(reversed(discounts))) == 2700 + 1620 - 200


@pytest.mark.parametrize(
    "make",
    [
        lambda: PercentOff(0),
        lambda: PercentOff(101),
        lambda: FixedOff(0),
        lambda: FixedOff(100, min_subtotal_cents=-1),
        lambda: BuyXGetY("B100", 0, 1),
        lambda: BuyXGetY("B100", 1, 0),
    ],
)
def test_validation(make):
    with pytest.raises(ValueError):
        make()


def test_dataclasses_are_frozen():
    discount = PercentOff(10)
    with pytest.raises(Exception):
        discount.percent = 20
