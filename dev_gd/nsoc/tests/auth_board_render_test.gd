extends Node

## 权威盘面渲染测试（重构文档.md §4.2「按 auth/state 渲染」）。
##
## 运行：
##   godot --headless --path dev_gd/nsoc res://tests/AuthBoardRenderTest.tscn
##
## 输出：
##   ABR_CASE [PASS|FAIL] <用例名> <说明>
##   ABR_RESULT PASS|FAIL passed=N failed=M
##
## 用**无头纯数据盘**（`BoardSlotFactory.create_headless` → `CellData`）当目标棋盘：
## 渲染器对 `Cell` 与 `CellData` 是同一套鸭子类型调用，因此无需 UI 即可验证
## "服务器给什么、客户端就画什么"。

const EXPECTED_CASES: int = 16

var _passed: int = 0
var _failed: int = 0


func _ready() -> void:
	Game.registry.clear()
	_test_apply_and_clear()
	_test_idempotent_and_unknown()
	_test_phantom_and_summary()

	var total: int = _passed + _failed
	if total != EXPECTED_CASES:
		_failed += 1
		print("ABR_CASE FAIL 用例数量异常：期望 %d，实际 %d（有测试函数被运行时错误静默中断）"
			% [EXPECTED_CASES, total])

	print("ABR_RESULT %s passed=%d failed=%d" % [
		"PASS" if _failed == 0 else "FAIL", _passed, _failed,
	])
	get_tree().quit(0 if _failed == 0 else 1)


func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("ABR_CASE PASS %s" % name)
	else:
		_failed += 1
		print("ABR_CASE FAIL %s | %s" % [name, detail])


## 单盘测试用：清空注册表后建一块 board_a（避免旧 slot 残留在注册表里被渲染器取到）。
func _mk() -> BoardSlot:
	Game.registry.clear()
	return BoardSlotFactory.create_headless("board_a", BoardSlot.FACTION_PLAYER,
		BoardSlot.ROLE_MAIN_PLAYER, {"hp": 30, "name_short": "P"}, {}, "team_a", "uuid_a")


func _snapshot(slot: BoardSlot) -> Dictionary:
	return {
		"board_a": {"owner": "uuid_a", "team_id": "team_a",
			"cells": {"2,1": {
				"has_card": true, "card_name": "guanyu", "attack": 4,
				"health": {"front": 5, "back": 4, "left": 3, "right": 2},
				"max_health": {"front": 5, "back": 4, "left": 3, "right": 2},
				"effects": ["charge"], "faction": 0, "team_id": "team_a",
				"slot_id": "board_a", "owner_slot_id": "board_a", "origin": "hand",
				"is_phantom": false, "has_charged": true, "has_attacked": false,
			}},
		},
	}


func _test_apply_and_clear() -> void:
	var slot: BoardSlot = _mk()
	var res: Dictionary = AuthBoardRenderer.apply(_snapshot(slot), Game.registry)
	var cell: CellData = slot.board.get_cell(Vector2(2, 1))
	_check("渲染: 空格被写入单位", bool(cell.has_card) and cell.card_name == "guanyu", str(cell.to_dict()))
	_check("渲染: 四维按镜像写入",
		int(cell.health["front"]) == 5 and int(cell.health["back"]) == 4
		and int(cell.health["left"]) == 3 and int(cell.health["right"]) == 2, str(cell.health))
	_check("渲染: 效果/归属/出处/队伍按镜像",
		(cell.effects as Array) == ["charge"] and cell.owner_slot_id == "board_a"
		and cell.origin == "hand" and cell.team_id == "team_a",
		"%s %s %s" % [str(cell.effects), cell.owner_slot_id, cell.team_id])
	_check("渲染: 攻击/冲锋标记按镜像", cell.has_charged and not cell.has_attacked)
	_check("渲染: 返回值计数（applied=1）", int(res["applied"]) == 1 and int(res["cleared"]) == 0,
		str(res))

	# 镜像说这格空了 → 本地必须清掉
	var empty_state: Dictionary = _snapshot(slot)
	(empty_state["board_a"]["cells"]["2,1"] as Dictionary)["has_card"] = false
	var res2: Dictionary = AuthBoardRenderer.apply(empty_state, Game.registry)
	_check("渲染: 镜像为空 → 清空本地格",
		not cell.has_card and int(res2["cleared"]) == 1, str(res2))


func _test_idempotent_and_unknown() -> void:
	var slot: BoardSlot = _mk()
	AuthBoardRenderer.apply(_snapshot(slot), Game.registry)
	var res: Dictionary = AuthBoardRenderer.apply(_snapshot(slot), Game.registry)
	_check("幂等: 同一镜像重复应用不重绘（防动画重播）",
		int(res["applied"]) == 0 and int(res["unchanged"]) == 1, str(res))

	# 牌面变了 → 只更这一格
	var changed: Dictionary = _snapshot(slot)
	(changed["board_a"]["cells"]["2,1"] as Dictionary)["attack"] = 9
	var res2: Dictionary = AuthBoardRenderer.apply(changed, Game.registry)
	var cell: CellData = slot.board.get_cell(Vector2(2, 1))
	_check("更新: 攻击变化触发重绘且值正确",
		int(res2["applied"]) == 1 and int(cell.attack) == 9, str(res2))

	# 未知盘 id 不炸，只记入 unknown_slots（用上一步的 changed，保证已应用格未被重绘）
	var with_unknown: Dictionary = changed.duplicate(true)
	with_unknown["no_such_board"] = {"owner": "x", "cells": {}}
	var res3: Dictionary = AuthBoardRenderer.apply(with_unknown, Game.registry)
	_check("健壮: 未知盘 id 记入 unknown_slots 且不影响已应用格",
		(res3["unknown_slots"] as Array).has("no_such_board") and int(res3["unchanged"]) == 1,
		str(res3))

	# 注册表里没有这块盘（相当于"服务器给的盘本地还没有"）：只记 unknown，不崩
	Game.registry.clear()
	var res4: Dictionary = AuthBoardRenderer.apply(changed, null)
	_check("健壮: 本地没有该盘时记入 unknown_slots（null = 用 Game.registry）",
		int(res4["applied"]) == 0 and (res4["unknown_slots"] as Array).has("board_a"), str(res4))


func _test_phantom_and_summary() -> void:
	# 幻影：has_card=false 但 is_phantom=true → 走 set_phantom，不占位
	var slot: BoardSlot = _mk()
	var phantom_state: Dictionary = _snapshot(slot)
	var entry: Dictionary = phantom_state["board_a"]["cells"]["2,1"]
	entry["is_phantom"] = true
	entry["has_card"] = false
	var res: Dictionary = AuthBoardRenderer.apply(phantom_state, Game.registry)
	var cell: CellData = slot.board.get_cell(Vector2(2, 1))
	_check("幻影: is_phantom 走 set_phantom（has_card=false 但保留牌面）",
		bool(cell.is_phantom) and not bool(cell.has_card) and cell.card_name == "guanyu",
		str(cell.to_dict()))
	_check("幻影: 计入 applied（不是 cleared）", int(res["applied"]) == 1 and int(res["cleared"]) == 0,
		str(res))

	# 多盘 + 多格：计数正确
	Game.registry.clear()
	var a: BoardSlot = BoardSlotFactory.create_headless("board_a", BoardSlot.FACTION_PLAYER,
		BoardSlot.ROLE_MAIN_PLAYER, {"hp": 30, "name_short": "P"}, {}, "team_a", "uuid_a")
	var b: BoardSlot = BoardSlotFactory.create_headless("board_b", BoardSlot.FACTION_ENEMY,
		BoardSlot.ROLE_MAIN_ENEMY, {"hp": 30, "name_short": "E"}, {}, "team_b", "uuid_b")
	var two: Dictionary = {
		"board_a": {"owner": "uuid_a", "team_id": "team_a", "cells": {
			"0,0": {"has_card": true, "card_name": "u1", "attack": 1,
				"health": {"front": 1, "back": 1, "left": 1, "right": 1},
				"effects": [], "faction": 0, "team_id": "team_a",
				"owner_slot_id": "board_a", "origin": "initial", "is_phantom": false},
			"0,1": {"has_card": false},
		}},
		"board_b": {"owner": "uuid_b", "team_id": "team_b", "cells": {
			"2,2": {"has_card": true, "card_name": "u2", "attack": 2,
				"health": {"front": 2, "back": 2, "left": 2, "right": 2},
				"effects": [], "faction": 1, "team_id": "team_b",
				"owner_slot_id": "board_b", "origin": "initial", "is_phantom": false},
		}},
	}
	var res2: Dictionary = AuthBoardRenderer.apply(two, Game.registry)
	_check("多盘: 两块盘各写入一格（applied=2）", int(res2["applied"]) == 2 and int(res2["cleared"]) == 0,
		str(res2))
	_check("多盘: 敌方盘单位 is_enemy=true 按 faction 还原",
		bool((b.board.get_cell(Vector2(2, 2)) as CellData).is_enemy))
	_check("多盘: 空镜像格不会误清空（本地本来就空）",
		not bool(a.board.get_cell(Vector2(0, 1)).has_card))

	# 本地有、镜像空的另一盘：应清空
	var clear_b: Dictionary = two.duplicate(true)
	(clear_b["board_b"]["cells"]["2,2"] as Dictionary)["has_card"] = false
	var res3: Dictionary = AuthBoardRenderer.apply(clear_b, Game.registry)
	_check("多盘: 只清镜像为空的格（board_a 两格不变 + board_b 清空）",
		int(res3["cleared"]) == 1 and int(res3["applied"]) == 0 and int(res3["unchanged"]) == 2,
		str(res3))
