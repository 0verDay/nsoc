#!/usr/bin/env python3
"""一次性迁移工具：把规则层的动画等待统一改为 `Game.wait_delay(...)`。

背景（重构文档.md §3.4-6）：规则推进原本直接 `await ...get_tree().create_timer(x).timeout`，
这既让服务器无法"瞬时批量结算"，也让规则层依赖场景时钟。改为统一入口后，
`Game.instant_battle = true` 即可跳过等待（且**不改变任何状态转移**）。

用法:
    py -3 tools/ci/route_rules_delays.py            # 干跑
    py -3 tools/ci/route_rules_delays.py --apply    # 实际写入

只处理 TARGETS 里列出的文件；UI（hand_view / front_row_selector / sparring_panel /
dialogue_manager）与章节叙事（main.gd 的 8 秒过场）刻意不动。
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPTS = REPO / "dev_gd" / "nsoc" / "scripts"

TARGETS: list[str] = [
    "core/combat_system.gd",
    "core/turn_system.gd",
    "core/spell_caster_system.gd",
    "effects/destroy_unit.gd",
    "effects/weaken.gd",
    "abilities/yi_yong_jun.gd",
    "ai/ai_agent.gd",
]

# await [receiver.]get_tree().create_timer(<arg>).timeout   →   await Game.wait_delay(<arg>)
PATTERN = re.compile(
    r"^([ \t]*)await[ \t]+(?:[A-Za-z_][\w\.]*\.)?get_tree\(\)\.create_timer\(([^)]+)\)\.timeout",
    re.MULTILINE,
)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true")
    args = ap.parse_args()

    total = 0
    for rel in TARGETS:
        path = SCRIPTS / rel
        if not path.exists():
            print(f"[skip] {rel}: 文件不存在")
            continue
        text = path.read_text(encoding="utf-8")
        matches = list(PATTERN.finditer(text))
        if not matches:
            print(f"[skip] {rel}: 无匹配")
            continue
        if not args.apply:
            for m in matches:
                print(f"[dry-run] {rel}: {m.group(0).strip()} → await Game.wait_delay({m.group(2).strip()})")
        else:
            text = PATTERN.sub(lambda m: f"{m.group(1)}await Game.wait_delay({m.group(2).strip()})", text)
            path.write_text(text, encoding="utf-8", newline="\n")
            print(f"[apply] {rel}: 替换 {len(matches)} 处")
        total += len(matches)

    print(f"\n共 {total} 处" + ("（已写入）" if args.apply else "（干跑，未写入）"))
    return 0


if __name__ == "__main__":
    sys.exit(main())
