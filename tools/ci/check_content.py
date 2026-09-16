#!/usr/bin/env python3
"""内容与数据一致性检查（重构文档.md §1 目标 4 / §3.3 数据驱动）。

检查 dev_gd/nsoc/data 下的全部 JSON：
  1. 结构性: 必需字段、类型、取值范围、重名
  2. 交叉引用: 卡名 / 英雄 key / 效果 id / 技能 id / 关卡动作 id / 棋盘 slot / 场景路径
  3. 明显错误: 数量 <= 0、坐标越界、引用了不存在的资源

用法:
    py -3 tools/ci/check_content.py
    py -3 tools/ci/check_content.py --verbose
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
PROJECT = REPO / "dev_gd" / "nsoc"
DATA = PROJECT / "data"
SCRIPTS = PROJECT / "scripts"

ROWS, COLS = 6, 3
VALID_CARD_TYPES = {"单位", "法术", "装备"}
SLOT_INDEX_RANGE = range(0, 6)

errors: list[str] = []
warnings: list[str] = []


def err(msg: str) -> None:
    errors.append(msg)


def warn(msg: str) -> None:
    warnings.append(msg)


def load(path: Path):
    try:
        return json.loads(path.read_text(encoding="utf-8"))
    except Exception as exc:  # noqa: BLE001
        err(f"{rel(path)}: JSON 解析失败: {exc}")
        return None


def rel(path: Path) -> str:
    return str(path.relative_to(REPO)).replace("\\", "/")


def res_exists(res_path: str) -> bool:
    """res://xxx -> dev_gd/nsoc/xxx 是否存在。"""
    if not res_path.startswith("res://"):
        return False
    return (PROJECT / res_path[len("res://"):]).exists()


def collect_effect_ids() -> set[str]:
    return {p.stem for p in (SCRIPTS / "effects").glob("*.gd")}


def collect_ability_ids() -> set[str]:
    return {p.stem for p in (SCRIPTS / "abilities").glob("*.gd")}


def collect_action_ids() -> set[str]:
    return {p.stem for p in (SCRIPTS / "actions").glob("*.gd")}


def check_cards(cards_path: Path, all_names: set[str] | None = None) -> set[str]:
    """校验卡牌库，返回卡名集合。"""
    data = load(cards_path)
    if not isinstance(data, list):
        if data is not None:
            err(f"{rel(cards_path)}: 顶层应为数组")
        return all_names or set()

    names: set[str] = set()
    effect_ids = collect_effect_ids()
    for i, card in enumerate(data):
        where = f"{rel(cards_path)}[{i}]"
        if not isinstance(card, dict):
            err(f"{where}: 应为对象")
            continue
        name = card.get("name")
        if not isinstance(name, str) or not name.strip():
            err(f"{where}: 缺少 name")
            continue
        where = f"{rel(cards_path)}[{i}] \"{name}\""
        if name in names:
            err(f"{where}: 卡名重复")
        names.add(name)

        ctype = card.get("type")
        if ctype not in VALID_CARD_TYPES:
            err(f"{where}: type={ctype!r} 非法（应为 {sorted(VALID_CARD_TYPES)}）")

        cost = card.get("cost")
        if not isinstance(cost, int) or cost < 0:
            err(f"{where}: cost={cost!r} 应为非负整数")

        for eff in card.get("effects", []) or []:
            if eff not in effect_ids:
                err(f"{where}: 引用了不存在的效果脚本 scripts/effects/{eff}.gd")

        if ctype == "单位":
            atk = card.get("attack")
            if not isinstance(atk, int) or atk < 0:
                err(f"{where}: 单位 attack={atk!r} 应为非负整数")
            health = card.get("health")
            if not isinstance(health, dict):
                err(f"{where}: 单位缺少 health 对象")
            else:
                for side in ("top", "bottom", "left", "right"):
                    v = health.get(side)
                    if not isinstance(v, int) or v < 0:
                        err(f"{where}: health.{side}={v!r} 应为非负整数")
        elif ctype == "法术":
            target = card.get("target", "")
            if target not in ("", "friendly_unit", "enemy_unit", "any_unit", "any_cell"):
                warn(f"{where}: 未知的 target={target!r}")
        elif ctype == "装备":
            dur = card.get("durability")
            if not isinstance(dur, int) or dur <= 0:
                err(f"{where}: 装备 durability={dur!r} 应为正整数")
    return names


def check_heroes(hero_path: Path, strategic: bool = False) -> set[str]:
    data = load(hero_path)
    keys: set[str] = set()
    if not isinstance(data, dict):
        if data is not None:
            err(f"{rel(hero_path)}: 顶层应为对象")
        return keys
    heroes = data.get("heroes")
    if not isinstance(heroes, dict):
        err(f"{rel(hero_path)}: 缺少 heroes 对象")
        return keys
    ability_ids = collect_ability_ids()
    for key, h in heroes.items():
        where = f"{rel(hero_path)} heroes.{key}"
        if not isinstance(h, dict):
            err(f"{where}: 应为对象")
            continue
        keys.add(key)
        hp = h.get("max_health")
        if strategic:
            # 演义模式将领属于战略层人才，只有四维属性，没有 max_health
            if not h.get("display_name"):
                err(f"{where}: 缺少 display_name")
            for attr in ("command", "force", "intelligence", "charisma"):
                v = h.get(attr)
                if v is not None and not isinstance(v, int):
                    err(f"{where}: {attr}={v!r} 应为整数")
        elif not isinstance(hp, int) or hp <= 0:
            err(f"{where}: max_health={hp!r} 应为正整数")
        for ab in h.get("abilities", []) or []:
            if ab not in ability_ids:
                err(f"{where}: 引用了不存在的技能脚本 scripts/abilities/{ab}.gd")
    return keys


# 引擎在 bootstrap 时总会创建的主棋盘，关卡数据可以省略不写
IMPLICIT_SLOTS = {"player_main", "enemy_main"}


def check_slot_refs(where: str, boards: dict, slot_id, field: str) -> None:
    if slot_id in IMPLICIT_SLOTS:
        return
    if slot_id not in boards:
        err(f"{where}: {field}={slot_id!r} 不在 boards 中（候选: {sorted(boards)}）")


def check_positions(where: str, positions) -> None:
    if not isinstance(positions, list):
        err(f"{where}: positions 应为数组")
        return
    for p in positions:
        if not isinstance(p, dict):
            err(f"{where}: positions 元素应为对象")
            continue
        r, c = p.get("row"), p.get("col")
        if not isinstance(r, int) or not 0 <= r < ROWS:
            err(f"{where}: row={r!r} 越界（应为 0..{ROWS - 1}）")
        if not isinstance(c, int) or not 0 <= c < COLS:
            err(f"{where}: col={c!r} 越界（应为 0..{COLS - 1}）")


def check_chapter(path: Path, card_names: set[str], hero_keys: set[str]) -> None:
    data = load(path)
    if not isinstance(data, dict):
        if data is not None:
            err(f"{rel(path)}: 顶层应为对象")
        return
    where = rel(path)

    hero_key = data.get("hero_key")
    if hero_key is not None and hero_key not in hero_keys:
        err(f"{where}: hero_key={hero_key!r} 不在 hero.json 中")

    for i, entry in enumerate(data.get("cards", []) or []):
        w = f"{where} cards[{i}]"
        name = entry.get("name") if isinstance(entry, dict) else None
        if name not in card_names:
            err(f"{w}: 卡牌 {name!r} 不在 all_cards.json 中")
        cnt = entry.get("count") if isinstance(entry, dict) else None
        if not isinstance(cnt, int) or cnt <= 0:
            err(f"{w}: count={cnt!r} 应为正整数")

    boards = data.get("boards", {})
    if not isinstance(boards, dict):
        err(f"{where}: boards 应为对象")
        boards = {}
    for slot_id, board in boards.items():
        w = f"{where} boards.{slot_id}"
        if not isinstance(board, dict):
            err(f"{w}: 应为对象")
            continue
        idx = board.get("slot_index")
        if idx is not None and idx not in SLOT_INDEX_RANGE:
            err(f"{w}: slot_index={idx!r} 越界（应为 0..5）")
        hero = board.get("hero")
        if isinstance(hero, dict):
            hp = hero.get("hp")
            if not isinstance(hp, int) or hp <= 0:
                err(f"{w}.hero: hp={hp!r} 应为正整数")
        for key in ("initial_units", "spawners"):
            for j, unit in enumerate(board.get(key, []) or []):
                wu = f"{w}.{key}[{j}]"
                if not isinstance(unit, dict):
                    err(f"{wu}: 应为对象")
                    continue
                name = unit.get("name")
                if name not in card_names:
                    err(f"{wu}: 卡牌 {name!r} 不在 all_cards.json 中")
                check_positions(wu, unit.get("positions", []))
                if key == "spawners":
                    iv = unit.get("interval")
                    if not isinstance(iv, int) or iv <= 0:
                        err(f"{wu}: interval={iv!r} 应为正整数")

    # 顶层 initial_units / spawners（旧 6x3 布局）
    for key in ("initial_units", "spawners"):
        for j, unit in enumerate(data.get(key, []) or []):
            wu = f"{where} {key}[{j}]"
            name = unit.get("name") if isinstance(unit, dict) else None
            if name not in card_names:
                err(f"{wu}: 卡牌 {name!r} 不在 all_cards.json 中")
            if isinstance(unit, dict):
                check_positions(wu, unit.get("positions", []))

    action_ids = collect_action_ids()
    for i, ev in enumerate(data.get("board_events", []) or []):
        w = f"{where} board_events[{i}]"
        turn = ev.get("turn") if isinstance(ev, dict) else None
        if not isinstance(turn, int) or turn <= 0:
            err(f"{w}: turn={turn!r} 应为正整数")
        for j, action in enumerate((ev or {}).get("actions", []) or []):
            wa = f"{w}.actions[{j}]"
            check_action(wa, action, card_names, boards, action_ids)

    for i, trg in enumerate(data.get("triggers", []) or []):
        w = f"{where} triggers[{i}]"
        if not isinstance(trg, dict):
            err(f"{w}: 应为对象")
            continue
        if not trg.get("id"):
            err(f"{w}: 缺少 id")
        for j, action in enumerate(trg.get("actions", []) or []):
            check_action(f"{w}.actions[{j}]", action, card_names, boards, action_ids)


def check_action(where: str, action, card_names: set[str], boards: dict, action_ids: set[str]) -> None:
    if not isinstance(action, dict):
        err(f"{where}: 应为对象")
        return
    atype = action.get("type")
    if atype not in action_ids:
        err(f"{where}: type={atype!r} 没有对应脚本 scripts/actions/{atype}.gd")
        return
    if "board" in action:
        check_slot_refs(where, boards, action.get("board"), "board")
    if "slot" in action:
        check_slot_refs(where, boards, action.get("slot"), "slot")
    name = action.get("name")
    if name is not None and name not in card_names:
        err(f"{where}: 卡牌 {name!r} 不在 all_cards.json 中")
    ability = action.get("ability")
    if ability is not None and ability not in collect_ability_ids():
        err(f"{where}: 技能 {ability!r} 不存在")


def check_campaigns(path: Path) -> None:
    data = load(path)
    if not isinstance(data, dict):
        if data is not None:
            err(f"{rel(path)}: 顶层应为对象")
        return
    campaigns = data.get("campaigns")
    if not isinstance(campaigns, dict):
        err(f"{rel(path)}: 缺少 campaigns 对象")
        return
    for cid, camp in campaigns.items():
        for i, ch in enumerate((camp or {}).get("chapters", []) or []):
            w = f"{rel(path)} campaigns.{cid}.chapters[{i}]"
            if not ch.get("name"):
                err(f"{w}: 缺少 name")
            for field in ("scene", "config"):
                val = ch.get(field)
                if val and not res_exists(val):
                    err(f"{w}: {field}={val!r} 指向的文件不存在")
            if not ch.get("scene") and ch.get("config"):
                warn(f"{w}: 配了 config 但没有 scene，章节无法进入")


def check_empire_maps() -> None:
    maps_dir = DATA / "empire_maps"
    if not maps_dir.exists():
        return
    for path in sorted(maps_dir.glob("*.json")):
        data = load(path)
        if not isinstance(data, dict):
            if data is not None:
                err(f"{rel(path)}: 顶层应为对象")
            continue
        where = rel(path)
        shapes = data.get("shapes")
        if not isinstance(shapes, list):
            err(f"{where}: 缺少 shapes 数组")
            continue
        ids = set()
        for i, s in enumerate(shapes):
            w = f"{where} shapes[{i}]"
            if not isinstance(s, dict):
                err(f"{w}: 应为对象")
                continue
            sid = s.get("id")
            if not isinstance(sid, int):
                err(f"{w}: id={sid!r} 应为整数")
            elif sid in ids:
                err(f"{w}: id={sid} 重复")
            else:
                ids.add(sid)
            if not s.get("name"):
                warn(f"{w}: 地点名为空（测试/草稿地图可接受，正式剧本应有名）")
            for axis in ("x", "y"):
                v = s.get(axis)
                if not isinstance(v, (int, float)):
                    err(f"{w}: {axis}={v!r} 应为数值")
        for i, c in enumerate(data.get("connections", []) or []):
            w = f"{where} connections[{i}]"
            if not isinstance(c, dict):
                err(f"{w}: 应为对象")
                continue
            for field in ("from", "to"):
                v = c.get(field)
                if v not in ids:
                    err(f"{w}: {field}={v!r} 不在 shapes 中")


# 显式注册表与目录的一致性（重构文档.md §3.4-3）。
# 注册表从"启动期扫目录"改为显式路径表后，新增脚本必须登记；
# 本检查保证"表 == 目录"（含基类等豁免项），否则 CI 失败。
REGISTRY_TABLES = [
    ("scripts/core/effect_registry.gd", "EFFECT_PATHS", "scripts/effects", {"effect_utils"}),
    ("scripts/core/action_registry.gd", "ACTION_PATHS", "scripts/actions", set()),
    ("scripts/core/hero_ability_registry.gd", "ABILITY_PATHS", "scripts/abilities", set()),
    ("scripts/core/objective_registry.gd", "OBJECTIVE_PATHS", "scripts/objectives", {"objective"}),
]


def check_registries() -> None:
    for reg_rel, const_name, dir_rel, skip in REGISTRY_TABLES:
        reg = PROJECT / reg_rel
        if not reg.exists():
            err(f"{rel(reg)}: 注册表文件不存在")
            continue
        text = reg.read_text(encoding="utf-8")
        m = re.search(rf"const\s+{const_name}\s*:\s*Array\s*=\s*\[(.*?)\]", text, re.S)
        if not m:
            err(f"{rel(reg)}: 找不到显式注册表 {const_name}")
            continue
        registered = set(re.findall(r'"(res://[^"]+\.gd)"', m.group(1)))
        dir_path = PROJECT / dir_rel
        if not dir_path.exists():
            err(f"{rel(dir_path)}: 目录不存在")
            continue
        actual = {
            f"res://{dir_rel}/{p.name}"
            for p in sorted(dir_path.glob("*.gd"))
            if p.stem not in skip
        }
        for p in sorted(actual - registered):
            err(f"{reg_rel} {const_name}: 脚本未登记 → {p}")
        for p in sorted(registered - actual):
            err(f"{reg_rel} {const_name}: 登记了不存在的脚本 → {p}")


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--verbose", action="store_true")
    args = ap.parse_args()

    if not DATA.exists():
        print(f"[失败] 找不到数据目录 {DATA}")
        return 1

    all_cards = DATA / "all_cards.json"
    card_names = check_cards(all_cards) if all_cards.exists() else set()
    review = DATA / "review_cards.json"
    if review.exists():
        check_cards(review, card_names)
    for extra in ("empire_cards.json",):
        p = DATA / extra
        if p.exists():
            check_cards(p, card_names)

    hero_keys: set[str] = set()
    for extra in ("hero.json", "empire_hero.json"):
        p = DATA / extra
        if p.exists():
            hero_keys |= check_heroes(p, strategic=(extra == "empire_hero.json"))

    chapters_dir = DATA / "chapters"
    if chapters_dir.exists():
        for p in sorted(chapters_dir.glob("*.json")):
            check_chapter(p, card_names, hero_keys)

    for p in sorted(DATA.glob("*level*.json")) + sorted(DATA.glob("multi_board_example.json")):
        check_chapter(p, card_names, hero_keys)

    campaigns = DATA / "campaigns.json"
    if campaigns.exists():
        check_campaigns(campaigns)

    check_empire_maps()
    check_registries()

    print(f"内容检查: 检查了 {len(list(DATA.rglob('*.json')))} 个 JSON")
    print(f"  卡牌 {len(card_names)} 张 / 英雄 {len(hero_keys)} 个")
    if warnings:
        print(f"\n[警告] {len(warnings)} 条:")
        for w in warnings:
            print(f"    {w}")
    if errors:
        print(f"\n[失败] {len(errors)} 条错误:")
        for e in errors:
            print(f"    {e}")
        return 1
    print("\n  [通过] 无错误")
    return 0


if __name__ == "__main__":
    sys.exit(main())
