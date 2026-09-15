#!/usr/bin/env python3
"""一次性迁移工具：按符号名删除已确认无引用的死函数 / 死常量（重构文档.md 阶段 3 清理）。

用法:
    py -3 tools/ci/strip_dead_code.py            # 干跑：只列出将删除的行范围
    py -3 tools/ci/strip_dead_code.py --apply    # 实际删除

前置条件：TARGETS 里的每个符号都必须先用"词边界 + 全文（含字符串）"统计确认
引用数 == 1（即只有定义本身）。本工具**不检查引用**，只做机械删除 —— 判据由
调用者负责，删除后必须跑 import / 四套 headless 测试 / 冒烟哈希来验证。

删除规则（保守）：
  1. 命中 `[static] func <name>` 或 `const <name>` 的定义行；
  2. 向下删到"第一个非空行且缩进 <= 定义行缩进"为止（支持多行字典/数组字面量）；
  3. 顺带删除紧贴定义行上方、与定义行之间没有空行的连续注释块（GDScript 惯例：
     注释描述其后的成员）；若注释块上方不是空行则不删，避免吃掉别人的注释；
  4. 收尾时裁掉多余的尾部空行，保证成员之间恰好一个空行。
"""

from __future__ import annotations

import argparse
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
SCRIPTS = REPO / "dev_gd" / "nsoc" / "scripts"

# (相对 scripts/ 的路径, 符号名)
TARGETS: list[tuple[str, str]] = [
    ("ui/cell.gd", "receive_damage"),
    ("app/main_menu.gd", "_profile_hover"),
    ("ai/ai_manager.gd", "get_agent"),
    ("ai/ai_agent.gd", "on_cross_requested"),
    ("ai/game_view.gd", "empty_cells_of"),
    ("ai/game_view.gd", "is_own_unit"),
    ("core/board_model.gd", "step_of_slot"),
    ("core/board_model.gd", "is_front_row"),
    ("core/board_model.gd", "is_back_row"),
    ("core/board_model.gd", "iter_cells"),
    ("core/board_registry.gd", "deployable_for_player"),
    ("core/board_registry.gd", "by_team"),
    ("core/board_slot.gd", "is_player_side"),
    ("core/board_slot.gd", "is_enemy_side"),
    ("core/turn_system.gd", "get_extra_board_configs"),
    ("core/turn_system.gd", "register_extra_board"),
    ("core/turn_system.gd", "unregister_extra_board"),
    ("core/turn_system.gd", "clear_cross_choices"),
    ("core/effect_registry.gd", "get_effect"),
    ("core/hero_ability_registry.gd", "get_ability"),
    ("core/hero_ability_registry.gd", "get_cost"),
    ("core/objective_registry.gd", "get_objective"),
    ("core/target_resolver.gd", "resolve_hero"),
    ("core/hero_state.gd", "heal"),
    ("core/game_context.gd", "is_player_alive"),
    ("core/effect_context.gd", "damage_enemy_hero"),
    ("core/data_loader.gd", "_parse_string_array"),
    ("core/empire_save_storage.gd", "delete_slot"),
    ("net/network_manager.gd", "send_to_host"),
    ("net/network_manager.gd", "get_uuid"),
    ("ui/theme_factory.gd", "apply_option_button_style"),
    ("ui/settings_panel_controller.gd", "get_trigger_button"),
    ("ui/sparring_panel.gd", "_build_right_mode_selector"),
    ("ui/sparring_panel.gd", "_on_leave_room"),
    # 死常量
    ("ui/cell.gd", "ORIGIN_HAND"),
    ("ui/cell.gd", "ORIGIN_SPAWNER"),
    ("ui/cell.gd", "ORIGIN_INITIAL"),
    ("core/data_loader.gd", "REVIEW_CARDS_JSON"),
    ("core/empire_save_storage.gd", "MANUAL_SLOTS"),
    ("ui/sparring_panel.gd", "DEFAULT_HOST"),
    ("ui/sparring_panel.gd", "DEFAULT_PORT"),
    ("ui/hero_panel_drag_controller.gd", "SNAP_DURATION"),
    ("ui/enemy_side_panel_manager.gd", "CLIP_BOTTOM_FROM_CENTER"),
    ("ui/empire_test.gd", "PENDING_GHOST_ALPHA"),
    ("abilities/yi_yong_jun.gd", "TARGET_BOARD_ID"),
]


def indent_of(line: str) -> int:
    return len(line) - len(line.lstrip(" \t"))


def remove_symbol(lines: list[str], name: str) -> tuple[int, int] | None:
    """返回被删除的 [start, end) 行范围（0-based），未命中返回 None。"""
    pat = re.compile(rf"^[ \t]*(?:static[ \t]+)?(?:func|const)[ \t]+{re.escape(name)}\b")
    for i, line in enumerate(lines):
        if not pat.match(line):
            continue
        base = indent_of(line)
        end = i + 1
        while end < len(lines):
            cur = lines[end]
            if cur.strip() == "":
                end += 1
                continue
            if indent_of(cur) <= base:
                break
            end += 1
        # 裁掉尾部空行（保留给成员间隔）
        while end - 1 > i and lines[end - 1].strip() == "":
            end -= 1
        # 上方的连续注释块
        start = i
        j = i - 1
        while j >= 0 and lines[j].lstrip().startswith("#") and indent_of(lines[j]) == base:
            start = j
            j -= 1
        if start > 0 and lines[start - 1].strip() != "":
            start = i   # 上方不是空行 → 注释块可能属于别人，不删
        return (start, end)
    return None


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--apply", action="store_true")
    args = ap.parse_args()

    total = 0
    missing: list[str] = []
    by_file: dict[Path, list[str]] = {}
    for rel, name in TARGETS:
        by_file.setdefault(SCRIPTS / rel, []).append(name)

    for path, names in sorted(by_file.items()):
        if not path.exists():
            missing.append(f"{path.relative_to(REPO)}: 文件不存在")
            continue
        lines = path.read_text(encoding="utf-8").splitlines(keepends=True)
        removed_here = 0
        for name in names:
            rng = remove_symbol(lines, name)
            if rng is None:
                missing.append(f"{path.relative_to(REPO)}: 未找到 {name}")
                continue
            start, end = rng
            if not args.apply:
                print(f"[dry-run] {path.relative_to(REPO)}: 删除 {name} → 行 {start + 1}..{end}")
            del lines[start:end]
            removed_here += 1
            total += 1
        if args.apply and removed_here:
            path.write_text("".join(lines), encoding="utf-8", newline="\n")
            print(f"[apply] {path.relative_to(REPO)}: 删除 {removed_here} 个定义")

    print(f"\n共处理 {total} 个定义" + ("（已写入）" if args.apply else "（干跑，未写入）"))
    if missing:
        print("未命中：")
        for m in missing:
            print("  " + m)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main())
