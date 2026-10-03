from __future__ import annotations

from dataclasses import dataclass
from enum import Enum
from typing import Any


class Availability(str, Enum):
    """An observation must always be one of these three states."""

    IN_STOCK = "in_stock"
    OUT_OF_STOCK = "out_of_stock"
    UNKNOWN = "unknown"


class UnknownReason(str, Enum):
    NETWORK = "network"
    BLOCKED = "blocked"
    RATE_LIMITED = "rate_limited"
    SCHEMA_DRIFT = "schema_drift"
    CACHE_STALE = "cache_stale"
    MISSING_STORE = "missing_store"
    MISSING_PRODUCT = "missing_product"
    CITY_MISMATCH = "city_mismatch"
    NOT_CHECKED = "not_checked"
    CONFIGURATION = "configuration"


@dataclass(frozen=True)
class Target:
    product_name: str
    part_number: str
    product_url: str
    store_id: str
    store_name: str
    city: str

    @property
    def key(self) -> str:
        return f"{self.store_id}|{self.part_number}"


@dataclass(frozen=True)
class Observation:
    target: Target
    availability: Availability
    checked_at: str
    quote: str = ""
    reason: UnknownReason | None = None
    detail: str = ""


@dataclass(frozen=True)
class QueryBatch:
    observations: tuple[Observation, ...]
    checked_at: str
    elapsed_ms: int
    request_count: int
    source: str
    cache_age_seconds: float | None = None

    @property
    def has_unknown(self) -> bool:
        return any(item.availability is Availability.UNKNOWN for item in self.observations)

    @property
    def hits(self) -> tuple[Observation, ...]:
        return tuple(
            item for item in self.observations if item.availability is Availability.IN_STOCK
        )

    def as_json(self) -> dict[str, Any]:
        return {
            "checked_at": self.checked_at,
            "elapsed_ms": self.elapsed_ms,
            "request_count": self.request_count,
            "source": self.source,
            "cache_age_seconds": self.cache_age_seconds,
            "observations": [
                {
                    "key": item.target.key,
                    "product_name": item.target.product_name,
                    "part_number": item.target.part_number,
                    "store_id": item.target.store_id,
                    "store_name": item.target.store_name,
                    "availability": item.availability.value,
                    "quote": item.quote,
                    "reason": item.reason.value if item.reason else None,
                    "detail": item.detail,
                }
                for item in self.observations
            ],
        }
