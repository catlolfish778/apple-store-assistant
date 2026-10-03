#!/usr/bin/env python3
"""Generate clean saved plans from the project's documented Apple variants."""

from __future__ import annotations

import argparse
import json
import uuid
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
REFERENCE = ROOT / "reference_projects/apple-pickup-watcher/crates/apw-core/data/products_zh_CN.json"
CAPACITY_LABELS = {
    "256gb": "256GB",
    "512gb": "512GB",
    "1tb": "1TB",
    "2tb": "2TB",
}
DUO_COLORS = {
    "nightsky": "夜空色",
    "starwhite": "星光白色",
}
PRO_COLORS = {
    "black": "黑色",
    "silver": "银色",
    "burgundy": "勃艮第酒红色",
    "glacier": "冰川蓝色",
}
DUO_PRICES = {
    "256gb": 15999.0,
    "512gb": 17999.0,
    "1tb": 21499.0,
    "2tb": 26499.0,
}
DUO_SOURCE = "https://www.apple.com.cn/shop/buy-iphone/iphone-duo"
PRO_SOURCE = "https://www.apple.com.cn/shop/buy-iphone/iphone-18-pro"
CAPTURED_AT = "2026-09-20T00:00:00Z"
DUO_RELEASE_AT = "2026-10-16T12:00:00Z"  # 2026-10-16 20:00 Asia/Shanghai, documented Duo preorder time.
UNVERIFIED_RELEASE_AT = "2026-12-31T12:00:00Z"  # Future placeholder; Pro/Max release time is not documented.


def plan_id(part_number: str) -> str:
    return str(uuid.uuid5(uuid.NAMESPACE_URL, f"apple-store-assistant:{part_number}")).upper()


def actions() -> list[dict[str, str]]:
    return [
        {"kind": "configure", "selector": "", "label": "确认已选配置", "host": "", "path": ""},
        {"kind": "add", "selector": "", "label": "加入购物袋", "host": "", "path": ""},
        {"kind": "checkout", "selector": "", "label": "进入结账", "host": "", "path": ""},
    ]


def make_plan(*, family: str, source: str, part_number: str, selections: dict[str, str], label: str, price: float, release_at: str, catalog_hash: str) -> dict:
    slug = part_number.lower()
    return {
        "id": plan_id(part_number),
        "name": f"{label}（配送）",
        "source": source,
        "variant": {
            "partNumber": part_number,
            "family": family,
            "selections": selections,
            "label": label,
            "url": f"{source}/{slug}",
            "price": price,
            "comingSoon": True,
        },
        "catalogHash": catalog_hash,
        "capturedAt": CAPTURED_AT,
        "releaseAt": release_at,
        "prepareSeconds": 300,
        "quietSeconds": 120,
        "executionSeconds": 60,
        "autoSubmit": False,
        "maxTotal": price,
        "actions": actions(),
        "version": 1,
    }


def duo_plans() -> list[dict]:
    rows = [
        ("MK2N4CH/A", "256gb", "nightsky"), ("MK2M4CH/A", "256gb", "starwhite"),
        ("MK2Q4CH/A", "512gb", "nightsky"), ("MK2P4CH/A", "512gb", "starwhite"),
        ("MK2U4CH/A", "1tb", "nightsky"), ("MK2T4CH/A", "1tb", "starwhite"),
        ("MK2W4CH/A", "2tb", "nightsky"), ("MK2V4CH/A", "2tb", "starwhite"),
    ]
    result = []
    for part, capacity, color in rows:
        label = f"{CAPACITY_LABELS[capacity]} · {DUO_COLORS[color]}"
        result.append(make_plan(
            family="iphoneduo", source=DUO_SOURCE, part_number=part,
            selections={"dimensionCapacity": capacity, "dimensionColor": color},
            label=label, price=DUO_PRICES[capacity], release_at=DUO_RELEASE_AT,
            catalog_hash="reference:APPLE_OFFICIAL_DATA_AND_CHECKOUT_BOUNDARIES:iphone-duo:20260919",
        ))
    return result


def pro_plans() -> list[dict]:
    raw = json.loads(REFERENCE.read_text(encoding="utf-8"))
    if isinstance(raw, list):
        products = [product for entry in raw for product in entry.get("data", {}).get("products", [])]
    else:
        products = raw.get("products", [])
    result = []
    for product in products:
        family_type = product.get("familyType")
        if family_type not in {"iphone18pro", "iphone18promax"}:
            continue
        is_max = family_type == "iphone18promax"
        family = "iphone-18-pro-max" if is_max else "iphone-18-pro"
        title = "iPhone 18 Pro Max" if is_max else "iPhone 18 Pro"
        capacity = product["dimensionCapacity"]
        color = product["dimensionColor"]
        label = f"{title} · {CAPACITY_LABELS[capacity]} · {PRO_COLORS[color]}"
        result.append(make_plan(
            family=family, source=PRO_SOURCE, part_number=product["partNumber"],
            selections={
                "dimensionCapacity": capacity,
                "dimensionColor": color,
                "dimensionScreensize": "6_9inch" if is_max else "6_3inch",
            },
            label=label, price=0.0, release_at=UNVERIFIED_RELEASE_AT,
            catalog_hash=f"reference:products_zh_CN:{family_type}:20260919",
        ))
    return result


def main() -> None:
    parser = argparse.ArgumentParser()
    parser.add_argument("--output", type=Path, required=True)
    args = parser.parse_args()
    plans = duo_plans() + pro_plans()
    assert len(plans) == 40, len(plans)
    assert len({p["variant"]["partNumber"] for p in plans}) == 40
    selected = next(p for p in plans if p["variant"]["partNumber"] == "MK2Q4CH/A")
    payload = {"plans": plans, "selectedID": selected["id"]}
    args.output.parent.mkdir(parents=True, exist_ok=True)
    args.output.write_text(json.dumps(payload, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
    print(f"generated {len(plans)} plans; selected={selected['variant']['partNumber']}; output={args.output}")


if __name__ == "__main__":
    main()
