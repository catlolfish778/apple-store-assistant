from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from apple_store_assistant.config import ConfigError, load_config


class ConfigTests(unittest.TestCase):
    def write_config(self, value: dict) -> Path:
        directory = Path(tempfile.mkdtemp())
        path = directory / "config.json"
        path.write_text(json.dumps(value), encoding="utf-8")
        return path

    def base(self) -> dict:
        return {
            "location": "上海 上海市 黄浦区",
            "city": "上海",
            "stores": {"R000": "示例门店"},
            "products": [
                {
                    "name": "示例产品",
                    "part_number": "ABC123CH/A",
                    "url": "https://www.apple.com.cn/shop/buy-iphone/example",
                    "stores": ["R000"],
                }
            ],
        }

    def test_loads_and_expands_targets(self):
        config = load_config(self.write_config(self.base()))
        self.assertEqual(len(config.targets), 1)
        self.assertEqual(config.targets[0].key, "R000|ABC123CH/A")
        self.assertEqual(config.interval_seconds, 30)

    def test_rejects_short_polling_interval(self):
        value = self.base()
        value["interval_seconds"] = 5
        with self.assertRaises(ConfigError):
            load_config(self.write_config(value))

    def test_rejects_non_apple_product_url(self):
        value = self.base()
        value["products"][0]["url"] = "https://example.com/product"
        with self.assertRaises(ConfigError):
            load_config(self.write_config(value))

    def test_rejects_mixed_apple_region(self):
        value = self.base()
        value["products"][0]["url"] = "https://www.apple.com/shop/buy-iphone/example"
        with self.assertRaises(ConfigError):
            load_config(self.write_config(value))

    def test_rejects_unknown_store_reference(self):
        value = self.base()
        value["products"][0]["stores"] = ["R999"]
        with self.assertRaises(ConfigError):
            load_config(self.write_config(value))
