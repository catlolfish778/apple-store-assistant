#!/usr/bin/env python3
"""Record redacted Chromium CDP network metadata for a manual Apple login.

This intentionally does not enable body, cookie, header, or credential capture.
Only host/path, method, resource type, status, and timing are written.
"""

from __future__ import annotations

import asyncio
import json
import sys
import time
from pathlib import Path
from urllib.parse import urlsplit

import requests
import websockets


def safe_url(value: str) -> str:
    try:
        parsed = urlsplit(value)
        path = parsed.path or "/"
        return f"{parsed.scheme}://{parsed.netloc}{path}"
    except Exception:
        return "<invalid-url>"


def safe_page(value: dict) -> dict:
    return {
        "id": value.get("id"),
        "type": value.get("type"),
        "url": safe_url(value.get("url", "")),
        "title": value.get("title", ""),
    }


async def main(output: Path) -> int:
    pages = requests.get("http://127.0.0.1:9222/json/list", timeout=5).json()
    candidates = [p for p in pages if p.get("type") == "page"]
    if not candidates:
        print("No debuggable browser page found on port 9222", file=sys.stderr)
        return 2
    page = candidates[-1]
    ws_url = page.get("webSocketDebuggerUrl")
    if not ws_url:
        print("Browser page has no debugger URL", file=sys.stderr)
        return 2

    request_started: dict[str, float] = {}
    output.parent.mkdir(parents=True, exist_ok=True)

    async with websockets.connect(ws_url, max_size=None) as socket:
        sequence = 0

        async def command(method: str, params: dict | None = None) -> None:
            nonlocal sequence
            sequence += 1
            message = {"id": sequence, "method": method}
            if params:
                message["params"] = params
            await socket.send(json.dumps(message))

        await command("Network.enable")
        await command("Page.enable")
        await command("Runtime.enable")

        with output.open("a", encoding="utf-8") as stream:
            def write(event: str, data: dict) -> None:
                record = {"ts": time.time(), "event": event, **data}
                stream.write(json.dumps(record, ensure_ascii=False) + "\n")
                stream.flush()
                print(json.dumps(record, ensure_ascii=False), flush=True)

            write("trace_started", {"page": safe_page(page)})
            print("仅记录脱敏网络元数据；按 Ctrl-C 停止。", file=sys.stderr)

            try:
                async for raw in socket:
                    message = json.loads(raw)
                    method = message.get("method", "")
                    params = message.get("params", {})
                    if method == "Network.requestWillBeSent":
                        request = params.get("request", {})
                        request_id = params.get("requestId", "")
                        request_started[request_id] = time.time()
                        write(
                            "request",
                            {
                                "id": request_id,
                                "url": safe_url(request.get("url", "")),
                                "method": request.get("method", ""),
                                "type": params.get("type", ""),
                            },
                        )
                    elif method == "Network.responseReceived":
                        response = params.get("response", {})
                        request_id = params.get("requestId", "")
                        write(
                            "response",
                            {
                                "id": request_id,
                                "url": safe_url(response.get("url", "")),
                                "status": response.get("status"),
                                "type": params.get("type", ""),
                                "elapsed_ms": round((time.time() - request_started.get(request_id, time.time())) * 1000, 1),
                            },
                        )
                    elif method == "Network.loadingFailed":
                        write(
                            "failed",
                            {
                                "id": params.get("requestId", ""),
                                "error": params.get("errorText", ""),
                                "type": params.get("type", ""),
                            },
                        )
                    elif method == "Page.frameNavigated":
                        frame = params.get("frame", {})
                        if not frame.get("parentId"):
                            write("navigation", {"url": safe_url(frame.get("url", ""))})
            except (asyncio.CancelledError, KeyboardInterrupt):
                pass
    return 0


if __name__ == "__main__":
    trace_path = Path(sys.argv[1]) if len(sys.argv) > 1 else Path("/tmp/apple-store-login.trace.jsonl")
    try:
        raise SystemExit(asyncio.run(main(trace_path)))
    except KeyboardInterrupt:
        raise SystemExit(0)
