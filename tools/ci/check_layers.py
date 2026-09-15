#!/usr/bin/env python3
"""分层规则检查（对应 重构文档.md §3.2）。

渐进式重构的防回归网：以"基线棘轮"方式工作 —— 已存在的违规记录在基线里，
一旦出现**新增违规**立即失败；违规减少时提示可以收紧基线。

用法:
    py -3 tools/ci/check_layers.py                  # 检查（相对基线）
    py -3 tools/ci/check_layers.py --print-baseline  # 打印当前基线 JSON
    py -3 tools/ci/check_layers.py --no-baseline     # 忽略基线，列出全部违规
    py -3 tools/ci/check_layers.py --quiet           # 只在失败时输出

阶段 2 目录归位后，只需更新下面的 LAYERS / SHARED_LAYERS 配置。
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from pathlib import Path

REPO = Path(__file__).resolve().parents[2]
PROJECT = REPO / "dev_gd" / "nsoc"
SCRIPTS = PROJECT / "scripts"
BASELINE_PATH = Path(__file__).resolve().parent / "layer_baseline.json"

# ── 层定义：目录 → 层名（阶段 2 归位后更新）─────────────────────────────
LAYER_DIRS: list[tuple[str, Path]] = [
    ("core", SCRIPTS / "core"),
    ("rules", SCRIPTS / "effects"),
    ("rules", SCRIPTS / "abilities"),
    ("rules", SCRIPTS / "actions"),
    ("rules", SCRIPTS / "objectives"),
    ("ai", SCRIPTS / "ai"),
    ("net", SCRIPTS / "net"),
    ("client", SCRIPTS / "ui"),
    ("app", SCRIPTS),  # 根目录脚本：main.gd / test_main.gd / cell.gd 等
]

# 必须保持"纯规则"的层：不得出现 UI / 场景树 / 反射 / 资源路径
SHARED_LAYERS = {"core", "rules"}

# 纯规则层中禁止出现的代码符号（只查代码，不查注释与字符串字面量）
BANNED_SYMBOLS: list[tuple[str, str]] = [
    ("ui-type-control", r"\bControl\b"),
    ("ui-type-panel", r"\bPanel\b"),
    ("ui-type-node2d", r"\bNode2D\b"),
    ("ui-type-label", r"\bLabel\b"),
    ("scene-add-child", r"\badd_child\s*\("),
    ("scene-remove-child", r"\bremove_child\s*\("),
    ("scene-queue-free", r"\bqueue_free\s*\("),
    ("anim-tween", r"\bcreate_tween\s*\("),
    ("anim-timer", r"\bcreate_timer\s*\("),
    ("scene-get-tree", r"\bget_tree\s*\("),
    ("scene-get-node", r"\bget_node\s*\("),
    ("scene-node-path", r"\$[A-Za-z_]"),
    ("autoload-root", r'"/root/'),
    ("reflection-has-method", r"\bhas_method\s*\("),
    ("reflection-call", r"\.call\s*\("),
]

# 纯规则层中禁止出现的资源路径（查全文含字符串）
BANNED_PATHS: list[tuple[str, str]] = [
    ("path-ui-script", r"res://scripts/ui/"),
    ("path-scene", r"res://scenes/"),
]

_COMMENT = re.compile(r"#[^\n]*")
_STRING = re.compile(r'"(?:[^"\\]|\\.)*"|\'(?:[^\'\\]|\\.)*\'')


def strip_strings(text: str) -> str:
    """把字符串字面量替换为等长空白，保留行号与列位置。"""
    return _STRING.sub(lambda m: " " * len(m.group(0)), text)


def code_only(text: str) -> str:
    """去掉注释与字符串，用于符号规则。"""
    return strip_strings(_COMMENT.sub("", text))


def iter_scripts() -> list[tuple[str, str, Path]]:
    """返回 [(层名, 相对路径, 路径)]。"""
    out: list[tuple[str, str, Path]] = []
    seen: set[Path] = set()
    for layer, base in LAYER_DIRS:
        if not base.exists():
            continue
        if base == SCRIPTS:  # app 层：只取直接子文件，避免与其他层重复
            files = sorted(base.glob("*.gd"))
        else:
            files = sorted(base.rglob("*.gd"))
        for f in files:
            if f in seen:
                continue
            seen.add(f)
            out.append((layer, str(f.relative_to(PROJECT)).replace("\\", "/"), f))
    return out


def scan() -> dict[str, int]:
    """返回 {违规 key: 次数}，key 形如 `<rule>|<relpath>`。"""
    counts: dict[str, int] = {}
    for layer, rel, path in iter_scripts():
        if layer not in SHARED_LAYERS:
            continue
        raw = path.read_text(encoding="utf-8")
        code = code_only(raw)

        for rule, pattern in BANNED_SYMBOLS:
            n = len(re.findall(pattern, code))
            if n:
                counts[f"{rule}|{rel}"] = counts.get(f"{rule}|{rel}", 0) + n
        for rule, pattern in BANNED_PATHS:
            n = len(re.findall(pattern, raw))
            if n:
                counts[f"{rule}|{rel}"] = counts.get(f"{rule}|{rel}", 0) + n
    return counts


def load_baseline() -> dict[str, int]:
    if not BASELINE_PATH.exists():
        return {}
    data = json.loads(BASELINE_PATH.read_text(encoding="utf-8"))
    return {k: int(v) for k, v in data.get("violations", {}).items()}


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("--print-baseline", action="store_true", help="打印当前基线 JSON")
    ap.add_argument("--no-baseline", action="store_true", help="忽略基线，列出全部违规")
    ap.add_argument("--quiet", action="store_true", help="只在失败时输出")
    args = ap.parse_args()

    current = scan()

    if args.print_baseline:
        payload = {
            "_comment": "分层检查基线（重构文档.md §3.2）。只允许减少，不允许增加。",
            "violations": dict(sorted(current.items())),
        }
        print(json.dumps(payload, ensure_ascii=False, indent=2))
        return 0

    baseline = {} if args.no_baseline else load_baseline()

    regressions: list[tuple[str, int, int]] = []
    improvements: list[tuple[str, int, int]] = []
    for key, n in sorted(current.items()):
        base = baseline.get(key, 0)
        if n > base:
            regressions.append((key, base, n))
        elif n < base:
            improvements.append((key, base, n))

    total = sum(current.values())
    if not args.quiet or regressions:
        print(f"分层检查: 当前违规 {total} 处（基线 {sum(baseline.values())} 处，"
              f"覆盖 {len(current)} 个文件-规则对）")

    if improvements and not args.quiet:
        print(f"  可收紧基线 {len(improvements)} 项（违规已减少）:")
        for key, base, n in improvements[:10]:
            print(f"    - {key}: {base} -> {n}")
        if len(improvements) > 10:
            print(f"    ... 其余 {len(improvements) - 10} 项略")

    if regressions:
        print(f"\n[失败] 出现 {len(regressions)} 项新增违规（重构文档.md §3.2 禁止）:")
        for key, base, n in regressions:
            rule, rel = key.split("|", 1)
            print(f"    {rel}  规则 {rule}: 基线 {base} -> 现在 {n}")
        print("\n修复建议: 纯规则层（core/ 与 effects|abilities|actions|objectives）"
              "不得引用 UI 类型、场景树、Tween、定时器、反射或 res:// 场景/UI 路径。")
        return 1

    if not args.quiet:
        print("  [通过] 无新增违规")
    return 0


if __name__ == "__main__":
    sys.exit(main())
