from __future__ import annotations

import argparse
import json
import sys
from pathlib import Path

from .config import ConfigError, load_config
from .models import Availability
from .notify import (
    BarkNotifier,
    BrowserOpener,
    CompositeNotifier,
    ConsoleNotifier,
    DesktopNotifier,
    NullOpener,
    NullNotifier,
)
from .providers import ApplePickupProvider, StaticProvider
from .runner import MonitorRunner
from .state import StateStore


def _parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(description="Apple Store 本地库存监控与人工购买辅助")
    subparsers = parser.add_subparsers(dest="command", required=True)

    for name, help_text in (("validate", "校验配置"), ("check", "查询一轮库存"), ("run", "持续监控库存")):
        sub = subparsers.add_parser(name, help=help_text)
        sub.add_argument("-c", "--config", default="config.example.json", help="配置文件路径")
        sub.add_argument("--json", action="store_true", help="以 JSON 输出结果")
        sub.add_argument("--no-open", action="store_true", help="不打开浏览器")
        sub.add_argument("--fixture", help=argparse.SUPPRESS)
        if name == "run":
            sub.add_argument("--once", action="store_true", help="只运行一轮")
            sub.add_argument("--max-cycles", type=int, help="最多运行轮数")
    return parser


def _static_provider(path: str, config):
    raw = json.loads(Path(path).read_text(encoding="utf-8"))
    values = {}
    for row in raw.get("observations", []):
        values[row["key"]] = Availability(row["availability"])
    return StaticProvider(values)


def main(argv: list[str] | None = None) -> int:
    args = _parser().parse_args(argv)
    try:
        config = load_config(args.config)
    except ConfigError as exc:
        print(f"配置错误：{exc}", file=sys.stderr)
        return 2

    if args.command == "validate":
        print(
            json.dumps(
                {
                    "valid": True,
                    "locale": config.locale,
                    "city": config.city,
                    "stores": len(config.stores),
                    "products": len(config.products),
                    "targets": len(config.targets),
                    "interval_seconds": config.interval_seconds,
                },
                ensure_ascii=False,
                indent=2,
            )
        )
        return 0

    provider = _static_provider(args.fixture, config) if args.fixture else ApplePickupProvider()
    notifiers = [] if args.json else [ConsoleNotifier()]
    opener = NullOpener() if args.no_open else BrowserOpener()
    if config.desktop_notifications and not args.fixture and not args.json:
        notifiers.append(DesktopNotifier())
    if not args.fixture and not args.json:
        notifiers.extend(BarkNotifier(url) for url in config.bark_urls)
    notifier = CompositeNotifier(notifiers) if notifiers else NullNotifier()

    runner = MonitorRunner(
        config,
        provider,
        notifier,
        opener,
        StateStore(config.runtime_dir / "state.json"),
        logger=(lambda _message: None) if args.json else print,
    )
    if args.command == "check":
        batch = runner.run_once()
        print(json.dumps(batch.as_json(), ensure_ascii=False, indent=2))
        return 0
    if args.once:
        runner.run(max_cycles=1)
    else:
        runner.run(max_cycles=args.max_cycles)
    return 0
