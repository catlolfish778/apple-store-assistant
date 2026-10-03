import unittest

from mac_app import MacAssistantApp


class PresetTests(unittest.TestCase):
    def test_normalise_preset_requires_a_complete_target_snapshot(self):
        self.assertIsNone(MacAssistantApp._normalise_preset({"product_name": "iPhone"}))

    def test_normalise_preset_normalises_part_number_and_browser_mode(self):
        payload = {
            "storefront_url": "https://www.apple.com.cn/",
            "city": "上海",
            "location": "上海 上海市 黄浦区",
            "product_name": "iPhone",
            "part_number": "abc123ch/a",
            "product_url": "https://www.apple.com.cn/shop/buy-iphone/example",
            "store_id": "R000",
            "store_name": "Apple Store",
            "browser_mode": "未知浏览器",
        }
        result = MacAssistantApp._normalise_preset(payload)
        self.assertIsNotNone(result)
        assert result is not None
        self.assertEqual(result["part_number"], "ABC123CH/A")
        self.assertEqual(result["browser_mode"], "专用 Chrome 配置（推荐）")


if __name__ == "__main__":
    unittest.main()
