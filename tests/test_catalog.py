from __future__ import annotations

import unittest
from pathlib import Path

from apple_store_assistant.catalog import CatalogError, OrderPackage, parse_product_selection_page


SOURCE_URL = "https://www.apple.com.cn/shop/buy-iphone/iphone-duo"
FETCHED_AT = "2026-09-19T12:00:00+08:00"


class CatalogTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        fixture = Path(__file__).parent / "fixtures" / "iphoneduo-product-selection.html"
        cls.html = fixture.read_text(encoding="utf-8")
        cls.snapshot = parse_product_selection_page(cls.html, SOURCE_URL, FETCHED_AT)

    def test_parses_all_official_iphone_duo_variants(self) -> None:
        self.assertEqual(self.snapshot.family_type, "iphoneduo")
        self.assertEqual(len(self.snapshot.variants), 8)
        self.assertEqual(
            [group.key for group in self.snapshot.option_groups],
            ["dimensionColor", "dimensionCapacity"],
        )
        capacity = dict(self.snapshot.option_groups[1].values)
        self.assertEqual(capacity["1tb"], "1TB")
        self.assertTrue(self.snapshot.catalog_hash.startswith("sha256:"))

    def test_resolves_exact_configuration_to_one_part_number(self) -> None:
        result = self.snapshot.resolve(
            {"dimensionColor": "nightsky", "dimensionCapacity": "1tb"}
        )
        self.assertEqual(result.part_number, "MK2U4CH/A")
        self.assertEqual(
            result.product_url,
            "https://www.apple.com.cn/shop/buy-iphone/iphone-duo/mk2u4ch/a",
        )

    def test_rejects_incomplete_or_unknown_configuration(self) -> None:
        with self.assertRaises(CatalogError):
            self.snapshot.resolve({"dimensionCapacity": "1tb"})
        with self.assertRaises(CatalogError):
            self.snapshot.resolve(
                {"dimensionColor": "black", "dimensionCapacity": "1tb"}
            )

    def test_order_package_keeps_catalog_hash_and_resolved_variant(self) -> None:
        package = OrderPackage.create(
            order_package_id="iphoneduo-1tb-nightsky-cn",
            snapshot=self.snapshot,
            selections={"dimensionColor": "nightsky", "dimensionCapacity": "1tb"},
            quantity=1,
            fulfillment="shipping",
            release_at="2026-10-16T20:00:00+08:00",
        )
        self.assertEqual(package.part_number, "MK2U4CH/A")
        self.assertEqual(package.catalog_hash, self.snapshot.catalog_hash)
        self.assertEqual(package.fulfillment, "shipping")

    def test_rejects_non_apple_source_and_bad_bootstrap(self) -> None:
        with self.assertRaises(CatalogError):
            parse_product_selection_page(self.html, "https://example.com/product", FETCHED_AT)
        with self.assertRaises(CatalogError):
            parse_product_selection_page("<html></html>", SOURCE_URL, FETCHED_AT)

    def test_real_apple_javascript_wrapper_and_display_values(self) -> None:
        raw = (Path(__file__).parent / "fixtures/live/iphoneduo-20260919.html").read_text()
        catalog = parse_product_selection_page(raw, SOURCE_URL, FETCHED_AT)
        self.assertEqual(len(catalog.variants), 8)
        self.assertEqual(dict(catalog.option_groups[1].values)["1tb"], "1TB")
        expected = {
            ("256gb", "nightsky"): "MK2N4CH/A", ("256gb", "starwhite"): "MK2M4CH/A",
            ("512gb", "nightsky"): "MK2Q4CH/A", ("512gb", "starwhite"): "MK2P4CH/A",
            ("1tb", "nightsky"): "MK2U4CH/A", ("1tb", "starwhite"): "MK2T4CH/A",
            ("2tb", "nightsky"): "MK2W4CH/A", ("2tb", "starwhite"): "MK2V4CH/A",
        }
        for (capacity, color), part in expected.items():
            self.assertEqual(catalog.resolve({"dimensionCapacity": capacity, "dimensionColor": color}).part_number, part)

    def test_second_real_product_family(self) -> None:
        raw = (Path(__file__).parent / "fixtures/live/iphone17-20260919.html").read_text()
        catalog = parse_product_selection_page(raw, "https://www.apple.com.cn/shop/buy-iphone/iphone-17", FETCHED_AT)
        self.assertEqual(len(catalog.variants), 10)
        self.assertEqual(catalog.resolve({"dimensionCapacity": "512gb", "dimensionColor": "black"}).part_number, "MG724CH/A")

    def test_rejects_credentials_and_bad_quantity(self) -> None:
        with self.assertRaises(CatalogError):
            parse_product_selection_page(self.html, "https://secret@www.apple.com.cn/shop/test", FETCHED_AT)
        for quantity in [0, True, 1.5, 11]:
            with self.assertRaises(CatalogError):
                OrderPackage.create(order_package_id="test", snapshot=self.snapshot, selections={"dimensionColor":"nightsky","dimensionCapacity":"1tb"}, quantity=quantity, fulfillment="shipping", release_at="2026-10-16T20:00:00+08:00")
