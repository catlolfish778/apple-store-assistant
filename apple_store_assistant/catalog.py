from __future__ import annotations

import hashlib
import html
import json
import re
from dataclasses import dataclass
from datetime import datetime
from html.parser import HTMLParser
from typing import Any, Mapping
from urllib.parse import urlsplit


class CatalogError(ValueError):
    """The official product-page snapshot cannot safely form an order package."""


class _TextExtractor(HTMLParser):
    def __init__(self) -> None:
        super().__init__()
        self.parts: list[str] = []

    def handle_data(self, data: str) -> None:
        self.parts.append(data)


def _display_text(value: object) -> str:
    if isinstance(value, dict):
        value = value.get("value", "")
    raw = html.unescape(str(value or ""))
    raw = re.sub(r"<as-footnote\b.*?</as-footnote>", "", raw, flags=re.S)
    parser = _TextExtractor()
    parser.feed(raw)
    return " ".join("".join(parser.parts).split())


def _bootstrap_payload(page_html: str) -> dict[str, Any]:
    marker = "window.PRODUCT_SELECTION_BOOTSTRAP"
    index = page_html.find(marker)
    if index < 0:
        raise CatalogError("官方页面中没有 PRODUCT_SELECTION_BOOTSTRAP")
    equals = page_html.find("=", index)
    if equals < 0:
        raise CatalogError("PRODUCT_SELECTION_BOOTSTRAP 缺少 JSON 赋值")
    payload_start = equals + 1
    while payload_start < len(page_html) and page_html[payload_start].isspace():
        payload_start += 1
    # Apple uses a JavaScript wrapper with unquoted keys. Decode only its JSON
    # productSelectionData value; never evaluate the script as Python/JavaScript.
    source = page_html[payload_start:]
    field = re.search(r'(?:"productSelectionData"|\bproductSelectionData)\s*:\s*', source)
    try:
        payload, _ = json.JSONDecoder().raw_decode(source[field.end():] if field else source)
    except json.JSONDecodeError as exc:
        raise CatalogError("PRODUCT_SELECTION_BOOTSTRAP 不是合法 JSON") from exc
    if not isinstance(payload, dict):
        raise CatalogError("PRODUCT_SELECTION_BOOTSTRAP 必须是对象")
    selection_data = payload.get("productSelectionData", payload)
    if not isinstance(selection_data, dict):
        raise CatalogError("productSelectionData 必须是对象")
    return selection_data


def _variant_url(catalog_url: str, part_number: str, product: Mapping[str, Any]) -> str:
    explicit = product.get("productUrl") or product.get("url")
    if isinstance(explicit, str):
        parsed = urlsplit(explicit)
        if parsed.scheme != "https" or parsed.hostname != urlsplit(catalog_url).hostname or parsed.username or parsed.password:
            raise CatalogError("变体链接与目录站点不一致")
        return explicit.rstrip("/")
    return f"{catalog_url.rstrip('/')}/{part_number.lower()}"


@dataclass(frozen=True)
class OptionGroup:
    key: str
    label: str
    values: tuple[tuple[str, str], ...]


@dataclass(frozen=True)
class CatalogVariant:
    part_number: str
    product_url: str
    selections: tuple[tuple[str, str], ...]
    price_currency: str | None = None
    price_amount: str | None = None

    def selection_map(self) -> dict[str, str]:
        return dict(self.selections)


@dataclass(frozen=True)
class CatalogSnapshot:
    source_url: str
    fetched_at: str
    family_type: str
    option_groups: tuple[OptionGroup, ...]
    variants: tuple[CatalogVariant, ...]
    catalog_hash: str

    def resolve(self, selections: Mapping[str, str]) -> CatalogVariant:
        expected = {group.key for group in self.option_groups}
        actual = set(selections)
        if actual != expected:
            missing = sorted(expected - actual)
            extra = sorted(actual - expected)
            details = []
            if missing:
                details.append("缺少 " + ", ".join(missing))
            if extra:
                details.append("未知 " + ", ".join(extra))
            raise CatalogError("配置不完整或不属于此商品：" + "；".join(details))
        wanted = dict(selections)
        matches = [variant for variant in self.variants if variant.selection_map() == wanted]
        if len(matches) != 1:
            raise CatalogError("该配置没有唯一的官方可售变体")
        return matches[0]


@dataclass(frozen=True)
class OrderPackage:
    """An immutable, locally stored purchase intent. It never reserves inventory."""

    order_package_id: str
    source_url: str
    catalog_hash: str
    family_type: str
    selections: tuple[tuple[str, str], ...]
    part_number: str
    product_url: str
    quantity: int
    fulfillment: str
    release_at: str

    @classmethod
    def create(
        cls,
        *,
        order_package_id: str,
        snapshot: CatalogSnapshot,
        selections: Mapping[str, str],
        quantity: int,
        fulfillment: str,
        release_at: str,
    ) -> "OrderPackage":
        if not order_package_id.strip():
            raise CatalogError("订单包 ID 不能为空")
        if isinstance(quantity, bool) or not isinstance(quantity, int) or not 1 <= quantity <= 10:
            raise CatalogError("数量必须是 1 到 10 的整数")
        if fulfillment not in {"shipping", "pickup"}:
            raise CatalogError("履约方式必须是 shipping 或 pickup")
        try:
            scheduled = datetime.fromisoformat(release_at.replace("Z", "+00:00"))
        except ValueError as exc:
            raise CatalogError("开售时间必须是 ISO 8601 格式") from exc
        if scheduled.tzinfo is None:
            raise CatalogError("开售时间必须包含时区")
        variant = snapshot.resolve(selections)
        return cls(
            order_package_id=order_package_id.strip(),
            source_url=snapshot.source_url,
            catalog_hash=snapshot.catalog_hash,
            family_type=snapshot.family_type,
            selections=tuple(sorted(selections.items())),
            part_number=variant.part_number,
            product_url=variant.product_url,
            quantity=quantity,
            fulfillment=fulfillment,
            release_at=release_at,
        )


def parse_product_selection_page(page_html: str, source_url: str, fetched_at: str) -> CatalogSnapshot:
    """Parse a public Apple product-page snapshot without using account/session data."""

    parsed = urlsplit(source_url)
    if parsed.scheme != "https" or parsed.hostname not in {"www.apple.com", "www.apple.com.cn"} or parsed.username or parsed.password or parsed.port or parsed.query or parsed.fragment:
        raise CatalogError("目录来源必须是 Apple 官方 HTTPS 商品页")
    try:
        fetched = datetime.fromisoformat(fetched_at.replace("Z", "+00:00"))
    except ValueError as exc:
        raise CatalogError("目录抓取时间必须是 ISO 8601 格式") from exc
    if fetched.tzinfo is None:
        raise CatalogError("目录抓取时间必须包含时区")

    data = _bootstrap_payload(page_html)
    sections = data.get("sections")
    products = data.get("products")
    display_values = data.get("displayValues", {})
    if not isinstance(sections, list) or not sections or not isinstance(products, list) or not products:
        raise CatalogError("productSelectionData 缺少 sections 或 products")
    if not isinstance(display_values, dict):
        raise CatalogError("displayValues 必须是对象")

    section_keys: list[str] = []
    group_labels: dict[str, str] = {}
    for section in sections:
        if not isinstance(section, dict):
            raise CatalogError("sections 中存在非对象")
        key = section.get("formFieldName") or section.get("dimension")
        if not isinstance(key, str) or not key or key in section_keys:
            raise CatalogError("sections 缺少唯一的配置字段")
        section_keys.append(key)
        group_labels[key] = _display_text(section.get("label") or key)

    variants: list[CatalogVariant] = []
    family_types: set[str] = set()
    for product in products:
        if not isinstance(product, dict):
            raise CatalogError("products 中存在非对象")
        part_number = product.get("partNumber")
        family_type = product.get("familyType")
        if not isinstance(part_number, str) or not part_number or not isinstance(family_type, str) or not family_type:
            raise CatalogError("产品缺少 partNumber 或 familyType")
        if not re.fullmatch(r"[A-Z0-9]+/A", part_number.upper()):
            raise CatalogError("产品 partNumber 格式错误")
        selections: list[tuple[str, str]] = []
        for key in section_keys:
            value = product.get(key)
            if not isinstance(value, str) or not value:
                raise CatalogError(f"产品 {part_number} 缺少 {key}")
            selections.append((key, value))
        family_types.add(family_type)
        prices = display_values.get("prices", {})
        price = prices.get(product.get("fullPrice"), {}) if isinstance(prices, dict) else {}
        current = price.get("currentPrice", {}) if isinstance(price, dict) else {}
        variants.append(
            CatalogVariant(
                part_number=part_number.upper(),
                product_url=_variant_url(source_url, part_number, product),
                selections=tuple(selections),
                price_currency=product.get("priceCurrency") or price.get("priceCurrency"),
                price_amount=product.get("priceAmount") or current.get("raw_amount"),
            )
        )
    if len(family_types) != 1:
        raise CatalogError("同一目录快照中存在多个产品系列")
    if len({item.part_number for item in variants}) != len(variants):
        raise CatalogError("目录中存在重复 partNumber")

    groups: list[OptionGroup] = []
    for key in section_keys:
        displayed = display_values.get(key, {})
        if not isinstance(displayed, dict):
            displayed = {}
        raw_values = sorted({variant.selection_map()[key] for variant in variants})
        values = tuple((value, _display_text(displayed.get(value, value))) for value in raw_values)
        groups.append(OptionGroup(key=key, label=group_labels[key], values=values))

    canonical = json.dumps(data, ensure_ascii=False, sort_keys=True, separators=(",", ":"))
    return CatalogSnapshot(
        source_url=source_url.rstrip("/"),
        fetched_at=fetched_at,
        family_type=next(iter(family_types)),
        option_groups=tuple(groups),
        variants=tuple(variants),
        catalog_hash="sha256:" + hashlib.sha256(canonical.encode("utf-8")).hexdigest(),
    )
