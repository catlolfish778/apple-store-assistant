from __future__ import annotations

import json
import math
import re
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path
from urllib.parse import urlsplit

from .models import Target


class ConfigError(ValueError):
    pass


APPLE_HOSTS = {"www.apple.com", "www.apple.com.cn"}
PART_NUMBER_RE = re.compile(r"[A-Z0-9]+/A")
MIN_INTERVAL_SECONDS = 30
MAX_TARGETS = 256


@dataclass(frozen=True)
class ProductConfig:
    name: str
    part_number: str
    url: str
    store_ids: tuple[str, ...]


@dataclass(frozen=True)
class AppConfig:
    locale: str
    storefront_url: str
    location: str
    city: str
    stores: dict[str, str]
    products: tuple[ProductConfig, ...]
    interval_seconds: int = MIN_INTERVAL_SECONDS
    start_at: str | None = None
    open_bag_on_hit: bool = True
    stop_on_hit: bool = True
    desktop_notifications: bool = True
    bark_urls: tuple[str, ...] = ()
    runtime_dir: Path = Path("runtime")

    @property
    def targets(self) -> tuple[Target, ...]:
        result: list[Target] = []
        for product in self.products:
            for store_id in product.store_ids:
                result.append(
                    Target(
                        product_name=product.name,
                        part_number=product.part_number,
                        product_url=product.url,
                        store_id=store_id,
                        store_name=self.stores[store_id],
                        city=self.city,
                    )
                )
        return tuple(result)

    @property
    def part_numbers(self) -> tuple[str, ...]:
        return tuple(product.part_number for product in self.products)

    def bag_url(self) -> str:
        return f"{self.storefront_url}/shop/bag"


def _require_string(value: object, name: str) -> str:
    if not isinstance(value, str) or not value.strip():
        raise ConfigError(f"{name} 必须是非空字符串")
    return value.strip()


def _validate_url(value: object, name: str, *, allow_query: bool = True) -> str:
    raw = _require_string(value, name)
    parsed = urlsplit(raw)
    if (
        parsed.scheme != "https"
        or parsed.hostname not in APPLE_HOSTS
        or parsed.username
        or parsed.password
        or parsed.port
        or (not allow_query and (parsed.query or parsed.fragment))
    ):
        raise ConfigError(f"{name} 必须是 Apple 官方 HTTPS 地址")
    return raw.rstrip("/")


def _validate_bark_urls(value: object) -> tuple[str, ...]:
    if value in (None, "", []):
        return ()
    if not isinstance(value, list):
        raise ConfigError("bark_urls 必须是 HTTPS 地址数组")
    result: list[str] = []
    for item in value:
        raw = _require_string(item, "bark_urls 中的地址")
        parsed = urlsplit(raw)
        if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
            raise ConfigError("bark_urls 只能使用 HTTPS，且不能带账号密码")
        if raw.rstrip("/") not in result:
            result.append(raw.rstrip("/"))
    if len(result) > 8:
        raise ConfigError("bark_urls 最多 8 个")
    return tuple(result)


def _validate_start_at(value: object) -> str | None:
    if value in (None, ""):
        return None
    raw = _require_string(value, "start_at")
    try:
        datetime.fromisoformat(raw.replace("Z", "+00:00"))
    except ValueError as exc:
        raise ConfigError("start_at 必须是 ISO 8601 日期时间") from exc
    return raw


def load_config(path: str | Path) -> AppConfig:
    config_path = Path(path)
    try:
        raw = json.loads(config_path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise ConfigError(f"找不到配置文件：{config_path}") from exc
    except json.JSONDecodeError as exc:
        raise ConfigError(f"配置不是合法 JSON：第 {exc.lineno} 行") from exc
    if not isinstance(raw, dict):
        raise ConfigError("配置根节点必须是对象")

    locale = _require_string(raw.get("locale", "zh_CN"), "locale")
    location = _require_string(raw.get("location"), "location")
    city = _require_string(raw.get("city"), "city")
    storefront_url = _validate_url(
        raw.get("storefront_url", "https://www.apple.com.cn"), "storefront_url", allow_query=False
    )
    storefront_host = urlsplit(storefront_url).hostname

    raw_stores = raw.get("stores")
    if not isinstance(raw_stores, dict) or not raw_stores:
        raise ConfigError("stores 必须是非空的门店编号到门店名称映射")
    stores: dict[str, str] = {}
    for store_id, store_name in raw_stores.items():
        stores[_require_string(store_id, "门店编号")] = _require_string(store_name, "门店名称")

    raw_products = raw.get("products")
    if not isinstance(raw_products, list) or not raw_products:
        raise ConfigError("products 必须是非空数组")
    products: list[ProductConfig] = []
    seen_products: set[str] = set()
    for item in raw_products:
        if not isinstance(item, dict):
            raise ConfigError("products 中的每一项必须是对象")
        name = _require_string(item.get("name"), "产品 name")
        part_number = _require_string(item.get("part_number"), "产品 part_number").upper()
        if not PART_NUMBER_RE.fullmatch(part_number):
            raise ConfigError(f"产品 part_number 格式不正确：{part_number}")
        if part_number in seen_products:
            raise ConfigError(f"重复的产品 part_number：{part_number}")
        seen_products.add(part_number)
        url = _validate_url(item.get("url"), "产品 url")
        if urlsplit(url).hostname != storefront_host:
            raise ConfigError("产品 url 必须和 storefront_url 使用同一个 Apple 区域站点")
        store_ids_value = item.get("stores")
        if store_ids_value is None:
            store_ids_value = list(stores)
        if not isinstance(store_ids_value, list) or not store_ids_value:
            raise ConfigError(f"产品 {part_number} 的 stores 必须是非空数组")
        store_ids: list[str] = []
        for store_id in store_ids_value:
            normalized = _require_string(store_id, "产品门店编号")
            if normalized not in stores:
                raise ConfigError(f"产品 {part_number} 引用了未定义门店：{normalized}")
            if normalized not in store_ids:
                store_ids.append(normalized)
        products.append(ProductConfig(name, part_number, url, tuple(store_ids)))

    interval_value = raw.get("interval_seconds", MIN_INTERVAL_SECONDS)
    if isinstance(interval_value, bool):
        raise ConfigError("interval_seconds 必须是数字")
    try:
        interval = float(interval_value)
    except (TypeError, ValueError) as exc:
        raise ConfigError("interval_seconds 必须是数字") from exc
    if not math.isfinite(interval) or interval < MIN_INTERVAL_SECONDS or interval > 3600:
        raise ConfigError(f"interval_seconds 必须在 {MIN_INTERVAL_SECONDS}～3600 秒之间")

    for key in ("open_bag_on_hit", "stop_on_hit", "desktop_notifications"):
        if key in raw and not isinstance(raw[key], bool):
            raise ConfigError(f"{key} 必须是 true 或 false")

    runtime_dir = Path(raw.get("runtime_dir", "runtime"))
    if runtime_dir.is_absolute():
        runtime_path = runtime_dir
    else:
        runtime_path = config_path.parent / runtime_dir

    app_config = AppConfig(
        locale=locale,
        storefront_url=storefront_url,
        location=location,
        city=city,
        stores=stores,
        products=tuple(products),
        interval_seconds=int(interval),
        start_at=_validate_start_at(raw.get("start_at")),
        open_bag_on_hit=raw.get("open_bag_on_hit", True),
        stop_on_hit=raw.get("stop_on_hit", True),
        desktop_notifications=raw.get("desktop_notifications", True),
        bark_urls=_validate_bark_urls(raw.get("bark_urls")),
        runtime_dir=runtime_path,
    )
    if len(app_config.targets) > MAX_TARGETS:
        raise ConfigError(f"目标组合不能超过 {MAX_TARGETS} 个")
    return app_config
