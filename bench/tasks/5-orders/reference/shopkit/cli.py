"""Command line entry point: python -m shopkit.cli <command>."""

import argparse
import sys

from shopkit.catalog import Product, sample_catalog
from shopkit.money import format_cents


def format_product(product: Product) -> str:
    """Return the one-line listing for a product."""
    return f"{product.sku}\t{product.name}\t{format_cents(product.price_cents)}"


def build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(prog="shopkit")
    commands = parser.add_subparsers(dest="command", required=True)
    listing = commands.add_parser("list", help="list products")
    listing.add_argument("--tag", help="only products with this tag")
    commands.add_parser("stock", help="show stock levels")
    return parser


def main(argv=None) -> int:
    """Run the command line tool and return its exit code."""
    args = build_parser().parse_args(argv)
    catalog = sample_catalog()
    if args.command == "list":
        products = catalog.with_tag(args.tag) if args.tag else list(catalog)
        for product in products:
            print(format_product(product))
    elif args.command == "stock":
        from shopkit.inventory import sample_inventory

        inventory = sample_inventory()
        for product in catalog:
            print(f"{product.sku}\t{inventory.on_hand(product.sku)}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
