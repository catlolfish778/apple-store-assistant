from __future__ import annotations

import json
import tempfile
import unittest
from pathlib import Path

from apple_store_assistant.config import load_config
from apple_store_assistant.models import Availability
from apple_store_assistant.notify import NullNotifier, NullOpener
from apple_store_assistant.providers import StaticProvider
from apple_store_assistant.runner import MonitorRunner, backoff_seconds
from apple_store_assistant.state import StateStore


class RunnerTests(unittest.TestCase):
    def setUp(self):
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
            "open_bag_on_hit": False,
        }
        directory = Path(tempfile.mkdtemp())
        config_path = directory / "config.json"
        config_path.write_text(json.dumps(value), encoding="utf-8")
        self.config = load_config(config_path)
        self.state = StateStore(directory / "runtime" / "state.json")

    def test_first_hit_alerts_once_and_persists(self):
        class RecordingNotifier:
            def __init__(self):
                self.events = []

            def send(self, title, body, url=None):
                self.events.append((title, body, url))

        provider = StaticProvider({"R000|ABC123CH/A": Availability.IN_STOCK})
        notifier = RecordingNotifier()
        runner = MonitorRunner(self.config, provider, notifier, NullOpener(), self.state)
        runner.run_once()
        runner.run_once()
        self.assertEqual(len(notifier.events), 1)

    def test_unknown_does_not_erase_known_stock(self):
        provider = StaticProvider({"R000|ABC123CH/A": Availability.IN_STOCK})
        class RecordingNotifier:
            def __init__(self):
                self.events = []

            def send(self, title, body, url=None):
                self.events.append((title, body, url))

        notifier = RecordingNotifier()
        runner = MonitorRunner(self.config, provider, notifier, NullOpener(), self.state)
        runner.run_once()
        provider.availability["R000|ABC123CH/A"] = Availability.UNKNOWN
        runner.run_once()
        provider.availability["R000|ABC123CH/A"] = Availability.IN_STOCK
        runner.run_once()
        saved = self.state.load()
        self.assertEqual(saved["observations"]["R000|ABC123CH/A"]["availability"], Availability.IN_STOCK.value)
        self.assertEqual(saved["last_known"]["R000|ABC123CH/A"], Availability.IN_STOCK.value)
        self.assertEqual(len(notifier.events), 1)

    def test_success_clears_previous_cooldown(self):
        self.state.save({"cooldown_until": 9999999999, "failure_count": 3})
        provider = StaticProvider({"R000|ABC123CH/A": Availability.OUT_OF_STOCK})
        runner = MonitorRunner(self.config, provider, NullNotifier(), NullOpener(), self.state)
        runner.run_once()
        self.assertNotIn("cooldown_until", self.state.load())

    def test_backoff_is_bounded(self):
        self.assertEqual(backoff_seconds(1), 30)
        self.assertEqual(backoff_seconds(3), 120)
        self.assertEqual(backoff_seconds(99), 900)
