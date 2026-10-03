from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from apple_store_assistant.config import load_config
from apple_store_assistant.models import Availability, UnknownReason
from apple_store_assistant.providers import (
    ApplePickupProvider,
    _observation_from_store,
    _stores_from_payload,
    ProviderError,
)


class ProviderTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        value = {
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
        directory = Path(tempfile.mkdtemp())
        path = directory / "config.json"
        path.write_text(json.dumps(value), encoding="utf-8")
        cls.config = load_config(path)
        cls.target = cls.config.targets[0]

    def test_extracts_current_store_shape(self):
        payload = {"body": {"stores": [{"storeNumber": "R000"}]}}
        self.assertEqual(len(_stores_from_payload(payload)), 1)

    def test_extracts_legacy_nested_store_shape_for_compatibility(self):
        payload = {"body": {"content": {"pickupMessage": {"stores": []}}}}
        self.assertEqual(_stores_from_payload(payload), [])

    def test_available_requires_eligibility(self):
        store = {
            "storeNumber": "R000",
            "city": "上海",
            "partsAvailability": {
                "ABC123CH/A": {
                    "pickupDisplay": "available",
                    "storePickEligible": True,
                    "pickupSearchQuote": "今天可取",
                }
            },
        }
        result = _observation_from_store(store, self.target, "2026-01-01T00:00:00+08:00")
        self.assertIs(result.availability, Availability.IN_STOCK)

        store["partsAvailability"]["ABC123CH/A"]["storePickEligible"] = False
        result = _observation_from_store(store, self.target, "2026-01-01T00:00:00+08:00")
        self.assertIs(result.availability, Availability.UNKNOWN)
        self.assertIs(result.reason, UnknownReason.SCHEMA_DRIFT)

    def test_missing_store_is_unknown(self):
        result = _observation_from_store({}, self.target, "2026-01-01T00:00:00+08:00")
        self.assertIs(result.availability, Availability.UNKNOWN)
        self.assertIs(result.reason, UnknownReason.MISSING_STORE)

    def test_invalid_payload_is_schema_error(self):
        with self.assertRaises(ProviderError) as context:
            _stores_from_payload({"body": {}})
        self.assertIs(context.exception.reason, UnknownReason.SCHEMA_DRIFT)

    def test_provider_maps_one_current_response_without_network(self):
        payload = {
            "body": {
                "stores": [
                    {
                        "storeNumber": "R000",
                        "city": "上海",
                        "partsAvailability": {
                            "ABC123CH/A": {
                                "pickupDisplay": "available",
                                "storePickEligible": True,
                                "pickupSearchQuote": "今天可取",
                            }
                        },
                    }
                ]
            }
        }
        provider = ApplePickupProvider()
        provider._request = lambda _url: (200, json.dumps(payload).encode(), 4.0, 0.0)
        batch = provider.check(self.config)
        self.assertEqual(batch.request_count, 1)
        self.assertEqual(batch.observations[0].availability, Availability.IN_STOCK)
        self.assertIn("retail/pickup-message", provider.build_url(self.config))
