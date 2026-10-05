import pytest

from shopkit.cart import Cart
from shopkit.catalog import sample_catalog
from shopkit.cli import main
from shopkit.inventory import Inventory, OutOfStock, sample_inventory
from shopkit.orders import InvalidTransition, Order


@pytest.fixture
def inv():
    return Inventory(sample_catalog(), {"A100": 5, "B100": 2})


def cart_with(**lines):
    cart = Cart(sample_catalog())
    for sku, qty in lines.items():
        cart.add(sku, qty)
    return cart


# --- inventory ---------------------------------------------------------------


def test_levels_default_to_zero(inv):
    assert inv.on_hand("A100") == 5
    assert inv.on_hand("C200") == 0
    assert inv.reserved("A100") == 0
    assert inv.available("A100") == 5


def test_unknown_sku_in_stock():
    with pytest.raises(KeyError):
        Inventory(sample_catalog(), {"Z999": 1})


def test_negative_stock():
    with pytest.raises(ValueError):
        Inventory(sample_catalog(), {"A100": -1})


def test_queries_reject_unknown_sku(inv):
    for query in (inv.on_hand, inv.reserved, inv.available):
        with pytest.raises(KeyError):
            query("Z999")


def test_receive(inv):
    inv.receive("C200", 4)
    assert inv.on_hand("C200") == 4
    with pytest.raises(ValueError):
        inv.receive("C200", 0)


def test_reserve_holds_stock(inv):
    inv.reserve("o1", {"A100": 3, "B100": 2})
    assert inv.reserved("A100") == 3
    assert inv.available("A100") == 2
    assert inv.on_hand("A100") == 5
    assert inv.available("B100") == 0


def test_reserve_is_all_or_nothing(inv):
    with pytest.raises(OutOfStock) as caught:
        inv.reserve("o1", {"A100": 1, "B100": 3})
    assert (caught.value.sku, caught.value.requested, caught.value.available) == ("B100", 3, 2)
    assert inv.reserved("A100") == 0
    assert inv.available("B100") == 2


def test_out_of_stock_reports_first_sku_in_sorted_order(inv):
    with pytest.raises(OutOfStock) as caught:
        inv.reserve("o1", {"C100": 1, "B100": 9, "A100": 9})
    assert caught.value.sku == "A100"


def test_reservations_count_against_availability(inv):
    inv.reserve("o1", {"A100": 4})
    with pytest.raises(OutOfStock) as caught:
        inv.reserve("o2", {"A100": 2})
    assert caught.value.available == 1


def test_reserve_twice_for_same_order(inv):
    inv.reserve("o1", {"A100": 1})
    with pytest.raises(ValueError):
        inv.reserve("o1", {"A100": 1})
    assert inv.reserved("A100") == 1


def test_release(inv):
    inv.reserve("o1", {"A100": 3})
    inv.release("o1")
    assert inv.available("A100") == 5
    with pytest.raises(KeyError):
        inv.release("o1")


def test_commit(inv):
    inv.reserve("o1", {"A100": 3})
    inv.commit("o1")
    assert inv.on_hand("A100") == 2
    assert inv.reserved("A100") == 0
    assert inv.available("A100") == 2
    with pytest.raises(KeyError):
        inv.commit("o1")


def test_sample_inventory():
    inv = sample_inventory()
    assert all(inv.on_hand(p.sku) == 10 for p in sample_catalog())


# --- orders ------------------------------------------------------------------


def test_order_snapshot_and_reservation(inv):
    cart = cart_with(A100=2, B100=1)
    order = Order("o1", cart, inv)
    assert order.order_id == "o1"
    assert order.status == "created"
    assert order.lines == {"A100": 2, "B100": 1}
    assert order.total_cents == 3900
    assert inv.reserved("A100") == 2
    cart.add("A100", 3)
    assert order.lines == {"A100": 2, "B100": 1}
    assert order.total_cents == 3900


def test_order_from_empty_cart(inv):
    with pytest.raises(ValueError):
        Order("o1", Cart(sample_catalog()), inv)


def test_order_out_of_stock_reserves_nothing(inv):
    with pytest.raises(OutOfStock):
        Order("o1", cart_with(A100=1, B100=5), inv)
    assert inv.reserved("A100") == 0
    Order("o1", cart_with(A100=1), inv)


def test_happy_path_commits_on_ship(inv):
    order = Order("o1", cart_with(A100=2), inv)
    order.pay()
    assert inv.on_hand("A100") == 5
    order.ship()
    assert inv.on_hand("A100") == 3
    assert inv.reserved("A100") == 0
    order.deliver()
    assert order.status == "delivered"
    assert order.history == ["created", "paid", "shipped", "delivered"]


@pytest.mark.parametrize("paid_first", [False, True])
def test_cancel_releases(inv, paid_first):
    order = Order("o1", cart_with(A100=2), inv)
    if paid_first:
        order.pay()
    order.cancel()
    assert order.status == "cancelled"
    assert inv.available("A100") == 5
    assert order.history[-1] == "cancelled"


@pytest.mark.parametrize(
    "setup, move",
    [
        ([], "ship"),
        ([], "deliver"),
        (["pay"], "pay"),
        (["pay"], "deliver"),
        (["pay", "ship"], "cancel"),
        (["pay", "ship"], "pay"),
        (["pay", "ship", "deliver"], "cancel"),
        (["cancel"], "pay"),
        (["cancel"], "cancel"),
    ],
)
def test_invalid_transitions(inv, setup, move):
    order = Order("o1", cart_with(A100=1), inv)
    for step in setup:
        getattr(order, step)()
    before, history = order.status, list(order.history)
    with pytest.raises(InvalidTransition) as caught:
        getattr(order, move)()
    assert before in str(caught.value)
    assert order.status == before
    assert order.history == history


# --- cli ---------------------------------------------------------------------


def test_cli_stock(capsys):
    assert main(["stock"]) == 0
    assert capsys.readouterr().out.splitlines() == [
        "A100\t10", "A200\t10", "B100\t10", "B200\t10", "C100\t10", "C200\t10",
    ]


def test_cli_list_still_works(capsys):
    assert main(["list", "--tag", "sale"]) == 0
    assert len(capsys.readouterr().out.splitlines()) == 2
