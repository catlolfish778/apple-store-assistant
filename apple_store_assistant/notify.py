from __future__ import annotations

import json
import subprocess
import urllib.request
from dataclasses import dataclass
from typing import Protocol
from urllib.parse import urlsplit


class Notifier(Protocol):
    def send(self, title: str, body: str, url: str | None = None) -> None:
        ...


class Opener(Protocol):
    def open(self, url: str) -> None:
        ...


class ConsoleNotifier:
    def send(self, title: str, body: str, url: str | None = None) -> None:
        print(f"\n{title}\n{body}")
        if url:
            print(f"链接：{url}")


class NullNotifier:
    def send(self, title: str, body: str, url: str | None = None) -> None:
        return


class DesktopNotifier:
    def send(self, title: str, body: str, url: str | None = None) -> None:
        if subprocess.call(["which", "osascript"], stdout=subprocess.DEVNULL) != 0:
            return
        script = (
            "on run argv\n"
            "display notification (item 2 of argv) with title (item 1 of argv)\n"
            "end run"
        )
        subprocess.run(
            ["osascript", "-e", script, title, body],
            check=False,
            timeout=5,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
        )


class BarkNotifier:
    def __init__(self, base_url: str):
        parsed = urlsplit(base_url)
        if parsed.scheme != "https" or not parsed.hostname or parsed.username or parsed.password:
            raise ValueError("Bark 地址必须是 HTTPS，且不能包含账号密码")
        self.base_url = base_url.rstrip("/")

    def send(self, title: str, body: str, url: str | None = None) -> None:
        payload = json.dumps({"title": title, "body": body, "url": url or ""}, ensure_ascii=False).encode()
        request = urllib.request.Request(
            self.base_url,
            data=payload,
            headers={"Content-Type": "application/json; charset=utf-8"},
            method="POST",
        )
        with urllib.request.urlopen(request, timeout=6) as response:
            if response.status >= 300:
                raise RuntimeError(f"Bark 返回 HTTP {response.status}")


@dataclass
class CompositeNotifier:
    notifiers: list[Notifier]

    def send(self, title: str, body: str, url: str | None = None) -> None:
        for notifier in self.notifiers:
            try:
                notifier.send(title, body, url)
            except Exception as exc:
                # A notification channel failure must not alter inventory state.
                print(f"通知渠道失败：{type(exc).__name__}")


class BrowserOpener:
    def open(self, url: str) -> None:
        import webbrowser

        webbrowser.open(url, new=2)


class NullOpener:
    def open(self, url: str) -> None:
        return
