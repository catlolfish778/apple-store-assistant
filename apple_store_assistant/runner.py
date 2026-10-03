from __future__ import annotations

import threading
import time
from datetime import datetime
from typing import Callable

from .config import AppConfig
from .models import Availability, Observation, QueryBatch
from .notify import Notifier, Opener
from .providers import ProviderError, StockProvider
from .state import StateStore


def backoff_seconds(failures: int, retry_after: float = 0) -> float:
    schedule = (30, 60, 120, 300, 900)
    return max(retry_after, schedule[min(max(failures, 1) - 1, len(schedule) - 1)])


class MonitorRunner:
    def __init__(
        self,
        config: AppConfig,
        provider: StockProvider,
        notifier: Notifier,
        opener: Opener,
        state_store: StateStore,
        logger: Callable[[str], None] = print,
    ):
        self.config = config
        self.provider = provider
        self.notifier = notifier
        self.opener = opener
        self.state_store = state_store
        self.logger = logger
        self.stop_event = threading.Event()
        self._opened = False

    def stop(self) -> None:
        self.stop_event.set()

    def _state(self) -> dict:
        return self.state_store.load()

    def _save_observations(self, batch: QueryBatch, *, health: str, failures: int = 0) -> None:
        state = self._state()
        last_known = state.get("last_known", {})
        if not isinstance(last_known, dict):
            last_known = {}
        for item in batch.observations:
            if item.availability is not Availability.UNKNOWN:
                last_known[item.target.key] = item.availability.value
        state.update(
            {
                "health": health,
                "checked_at": batch.checked_at,
                "failure_count": failures,
                "request_count": batch.request_count,
                "elapsed_ms": batch.elapsed_ms,
                "source": batch.source,
                "last_known": last_known,
                "observations": {
                    item.target.key: {
                        "availability": item.availability.value,
                        "quote": item.quote,
                        "reason": item.reason.value if item.reason else None,
                        "detail": item.detail,
                        "checked_at": item.checked_at,
                    }
                    for item in batch.observations
                },
            }
        )
        if health != "error":
            state.pop("cooldown_until", None)
        self.state_store.save(state)

    def _notify_hit(self, item: Observation) -> None:
        title = f"{item.target.city} Apple Store 有货"
        body = f"{item.target.store_name}\n{item.target.product_name}"
        if item.quote:
            body += f"\n{item.quote}"
        self.notifier.send(title, body, item.target.product_url)

    def _process(self, batch: QueryBatch) -> tuple[Observation, ...]:
        state = self._state()
        previous_state = state.get("last_known", {})
        if not isinstance(previous_state, dict):
            previous_state = {}
        # Compatibility with state files created before last_known was added.
        if not previous_state:
            observations = state.get("observations", {})
            if isinstance(observations, dict):
                previous_state = {
                    key: value.get("availability")
                    for key, value in observations.items()
                    if isinstance(value, dict)
                    and value.get("availability") in {
                        Availability.IN_STOCK.value,
                        Availability.OUT_OF_STOCK.value,
                    }
                }
        hits: list[Observation] = []
        for item in batch.observations:
            previous_availability = previous_state.get(item.target.key)
            # Unknown never overwrites a known state and therefore cannot create a
            # false restock alert after an outage or a blocked response.
            if item.availability is Availability.IN_STOCK and previous_availability != Availability.IN_STOCK.value:
                hits.append(item)
        self._save_observations(batch, health="partial" if batch.has_unknown else "ok")
        for item in hits:
            self._notify_hit(item)
            if not self._opened:
                destination = self.config.bag_url() if self.config.open_bag_on_hit else item.target.product_url
                self.opener.open(destination)
                self._opened = True
        return tuple(hits)

    def run_once(self) -> QueryBatch:
        try:
            batch = self.provider.check(self.config)
        except ProviderError as exc:
            checked_at = datetime.now().astimezone().isoformat(timespec="seconds")
            observations = tuple(
                Observation(
                    target,
                    Availability.UNKNOWN,
                    checked_at,
                    reason=exc.reason,
                    detail=exc.detail,
                )
                for target in self.config.targets
            )
            batch = QueryBatch(tuple(observations), checked_at, 0, 0, "error")
            state = self._state()
            failures = int(state.get("failure_count", 0)) + 1
            cooldown = backoff_seconds(failures, exc.retry_after)
            state["cooldown_until"] = time.time() + cooldown
            self.state_store.save(state)
            self._save_observations(batch, health="error", failures=failures)
            self.logger(f"查询失败，库存未知：{exc.detail}；退避 {cooldown:.0f} 秒")
            return batch
        self._process(batch)
        self.logger(
            f"查询完成：{len(batch.hits)} 有货，{len(batch.observations)} 个组合，"
            f"{batch.elapsed_ms}ms，requests={batch.request_count}"
        )
        return batch

    def _wait_until_start(self) -> None:
        if not self.config.start_at:
            return
        start = datetime.fromisoformat(self.config.start_at.replace("Z", "+00:00"))
        if start.tzinfo is None:
            start = start.astimezone()
        remaining = (start - datetime.now(start.tzinfo)).total_seconds()
        if remaining > 0:
            self.logger(f"等待计划开始：{start.isoformat()}")
            self.stop_event.wait(remaining)

    def run(self, *, max_cycles: int | None = None) -> int:
        self._wait_until_start()
        cycles = 0
        while not self.stop_event.is_set():
            state = self._state()
            cooldown_until = state.get("cooldown_until", 0)
            if isinstance(cooldown_until, (int, float)) and cooldown_until > time.time():
                self.stop_event.wait(min(cooldown_until - time.time(), 60))
                continue
            batch = self.run_once()
            cycles += 1
            if batch.hits and self.config.stop_on_hit:
                self.logger("检测到有货，已停止继续查询；请在官方页面人工确认并完成购买。")
                return 0
            if max_cycles is not None and cycles >= max_cycles:
                return 0
            self.stop_event.wait(self.config.interval_seconds)
        return 0
