from __future__ import annotations

import json
import email.utils
import time
from datetime import datetime, timezone
from http.client import HTTPResponse
from typing import Protocol
from urllib.error import HTTPError, URLError
from urllib.parse import urlencode
from urllib.request import Request, urlopen

from .config import AppConfig
from .models import Availability, Observation, QueryBatch, Target, UnknownReason


class ProviderError(RuntimeError):
    def __init__(self, reason: UnknownReason, detail: str, retry_after: float = 0):
        super().__init__(detail)
        self.reason = reason
        self.detail = detail
        self.retry_after = max(0.0, retry_after)


class StockProvider(Protocol):
    def check(self, config: AppConfig) -> QueryBatch:
        ...


def _now() -> str:
    return datetime.now(timezone.utc).astimezone().isoformat(timespec="seconds")


def _retry_after(response: HTTPResponse) -> float:
    value = response.headers.get("Retry-After")
    try:
        return max(0.0, float(value)) if value else 0.0
    except ValueError:
        try:
            parsed = email.utils.parsedate_to_datetime(value)
            return max(0.0, parsed.timestamp() - time.time()) if parsed else 0.0
        except (TypeError, ValueError, OverflowError):
            return 0.0


def _stores_from_payload(payload: object) -> list[dict]:
    if not isinstance(payload, dict):
        raise ProviderError(UnknownReason.SCHEMA_DRIFT, "响应根节点不是对象")
    body = payload.get("body")
    if not isinstance(body, dict):
        raise ProviderError(UnknownReason.SCHEMA_DRIFT, "响应缺少 body")
    stores = body.get("stores")
    if isinstance(stores, list):
        return [item for item in stores if isinstance(item, dict)]
    content = body.get("content")
    if isinstance(content, dict):
        pickup = content.get("pickupMessage")
        if isinstance(pickup, dict) and isinstance(pickup.get("stores"), list):
            return [item for item in pickup["stores"] if isinstance(item, dict)]
    raise ProviderError(UnknownReason.SCHEMA_DRIFT, "响应缺少可识别的门店列表")


def _part_payload(store: dict, target: Target) -> dict:
    parts = store.get("partsAvailability")
    if not isinstance(parts, dict):
        raise ProviderError(UnknownReason.SCHEMA_DRIFT, "门店响应缺少 partsAvailability")
    part = parts.get(target.part_number)
    if not isinstance(part, dict):
        raise ProviderError(UnknownReason.MISSING_PRODUCT, "响应缺少目标产品")
    return part


def _observation_from_store(store: dict, target: Target, checked_at: str) -> Observation:
    store_id = store.get("storeNumber")
    if store_id != target.store_id:
        return Observation(
            target,
            Availability.UNKNOWN,
            checked_at,
            reason=UnknownReason.MISSING_STORE,
            detail="响应未包含目标门店",
        )
    store_city = store.get("city")
    if store_city and store_city not in (target.city, f"{target.city}市"):
        return Observation(
            target,
            Availability.UNKNOWN,
            checked_at,
            reason=UnknownReason.CITY_MISMATCH,
            detail=f"响应城市为 {store_city}",
        )
    try:
        part = _part_payload(store, target)
    except ProviderError as exc:
        return Observation(target, Availability.UNKNOWN, checked_at, reason=exc.reason, detail=exc.detail)

    display = part.get("pickupDisplay")
    eligible = part.get("storePickEligible")
    quote = str(part.get("pickupSearchQuote") or "").strip()
    message_types = part.get("messageTypes")
    if isinstance(message_types, dict):
        regular = message_types.get("regular")
        if isinstance(regular, dict) and not quote:
            quote = str(regular.get("storePickupQuote") or "").strip()

    if display == "available" and eligible is True:
        return Observation(target, Availability.IN_STOCK, checked_at, quote=quote)
    if display in {"unavailable", "ineligible"}:
        return Observation(target, Availability.OUT_OF_STOCK, checked_at, quote=quote)
    return Observation(
        target,
        Availability.UNKNOWN,
        checked_at,
        quote=quote,
        reason=UnknownReason.SCHEMA_DRIFT,
        detail=f"无法识别 pickupDisplay/storePickEligible：{display!r}/{eligible!r}",
    )


class ApplePickupProvider:
    """Conservative, read-only Apple pickup availability adapter.

    The endpoint is not a public developer API. This adapter deliberately does not
    rotate proxies, spoof browser fingerprints, solve challenges, or submit orders.
    """

    source = "apple-pickup-message"

    def __init__(self, timeout_seconds: int = 15):
        self.timeout_seconds = timeout_seconds

    def build_url(self, config: AppConfig) -> str:
        params: list[tuple[str, str]] = [
            ("pl", "true"),
            ("mts.0", "regular"),
            ("location", config.location),
        ]
        params.extend((f"parts.{index}", part) for index, part in enumerate(config.part_numbers))
        return f"{config.storefront_url}/shop/retail/pickup-message?{urlencode(params)}"

    def _request(self, url: str) -> tuple[int, bytes, float, float | None]:
        request = Request(
            url,
            headers={
                "Accept": "application/json, text/javascript, */*; q=0.01",
                "User-Agent": "AppleStorePersonalAssistant/0.1 (local availability check)",
            },
            method="GET",
        )
        started = time.monotonic()
        try:
            with urlopen(request, timeout=self.timeout_seconds) as response:
                body = response.read(4 * 1024 * 1024 + 1)
                if len(body) > 4 * 1024 * 1024:
                    raise ProviderError(UnknownReason.SCHEMA_DRIFT, "响应超过安全上限")
                age = response.headers.get("Age")
                try:
                    cache_age = float(age) if age is not None else None
                except ValueError:
                    cache_age = None
                return response.status, body, (time.monotonic() - started) * 1000, cache_age
        except HTTPError as exc:
            retry_after = _retry_after(exc)
            if exc.code in (403, 541):
                raise ProviderError(UnknownReason.BLOCKED, f"Apple 返回 HTTP {exc.code}", retry_after) from exc
            if exc.code == 429:
                raise ProviderError(UnknownReason.RATE_LIMITED, "Apple 返回 HTTP 429", retry_after) from exc
            raise ProviderError(UnknownReason.NETWORK, f"Apple 返回 HTTP {exc.code}", retry_after) from exc
        except (TimeoutError, URLError, OSError) as exc:
            raise ProviderError(UnknownReason.NETWORK, f"网络请求失败：{type(exc).__name__}") from exc

    def check(self, config: AppConfig) -> QueryBatch:
        checked_at = _now()
        started = time.monotonic()
        try:
            status, body, request_ms, cache_age = self._request(self.build_url(config))
            if status != 200:
                raise ProviderError(UnknownReason.NETWORK, f"Apple 返回 HTTP {status}")
            if cache_age is not None and cache_age > 120:
                raise ProviderError(UnknownReason.CACHE_STALE, f"响应缓存已过期 {cache_age:.0f} 秒")
            try:
                payload = json.loads(body)
            except (UnicodeDecodeError, json.JSONDecodeError) as exc:
                raise ProviderError(UnknownReason.SCHEMA_DRIFT, "响应不是合法 JSON") from exc
            stores = _stores_from_payload(payload)
            by_store = {store.get("storeNumber"): store for store in stores}
            observations: list[Observation] = []
            for target in config.targets:
                store = by_store.get(target.store_id)
                if store is None:
                    observations.append(
                        Observation(
                            target,
                            Availability.UNKNOWN,
                            checked_at,
                            reason=UnknownReason.MISSING_STORE,
                            detail="响应未包含目标门店，不能据此判断无货",
                        )
                    )
                else:
                    observations.append(_observation_from_store(store, target, checked_at))
            return QueryBatch(
                tuple(observations),
                checked_at,
                max(0, round(request_ms)),
                1,
                self.source,
                cache_age,
            )
        except ProviderError:
            raise
        except Exception as exc:  # Defensive boundary: parser failures become unknown upstream.
            raise ProviderError(UnknownReason.SCHEMA_DRIFT, f"解析库存失败：{type(exc).__name__}") from exc


class StaticProvider:
    """Deterministic provider for offline tests and dry-run demos."""

    def __init__(self, availability: dict[str, Availability]):
        self.availability = availability
        self.calls = 0

    def check(self, config: AppConfig) -> QueryBatch:
        self.calls += 1
        checked_at = _now()
        observations = tuple(
            Observation(
                target,
                self.availability.get(target.key, Availability.UNKNOWN),
                checked_at,
                reason=(UnknownReason.NOT_CHECKED if target.key not in self.availability else None),
            )
            for target in config.targets
        )
        return QueryBatch(observations, checked_at, 0, 0, "static")
