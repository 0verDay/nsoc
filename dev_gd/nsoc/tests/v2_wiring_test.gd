extends Node

## v2 接线测试（重构文档.md §4.2：客户端接入权威路径的"最后一根线"）。
##
## 运行：
##   godot --headless --path dev_gd/nsoc res://tests/V2WiringTest.tscn
##
## 输出：
##   V2W_CASE [PASS|FAIL] <用例名> <说明>
##   V2W_RESULT PASS|FAIL passed=N failed=M
##
## 验证 `Game.enable_v2_authority()` 这段接线：
##   Net.auth_state  → V2BattleClient 镜像 + AuthBoardRenderer 重绘本地盘面
##   Net.auth_event / auth_reject / auth_verdict → 对应镜像更新
##   disable 之后不再有任何副作用（关掉 v2 就回到老路径）
##
## 用无头纯数据盘当"本地棋盘"，因此无需 UI。

const EXPECTED_CASES: int = 14

var _passed: int = 0
var _failed: int = 0


func _ready() -> void:
	_test_wiring_on()
	_test_wiring_off()

	var total: int = _passed + _failed
	if total != EXPECTED_CASES:
		_failed += 1
		print("V2W_CASE FAIL 用例数量异常：期望 %d，实际 %d（有测试函数被运行时错误静默中断）"
			% [EXPECTED_CASES, total])

	print("V2W_RESULT %s passed=%d failed=%d" % [
		"PASS" if _failed == 0 else "FAIL", _passed, _failed,
	])
	get_tree().quit(0 if _failed == 0 else 1)


func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("V2W_CASE PASS %s" % name)
	else:
		_failed += 1
		print("V2W_CASE FAIL %s | %s" % [name, detail])


func _board_state() -> Dictionary:
	return {
		"board_a": {"owner": "p1", "team_id": "defender", "cells": {
			"2,1": {"has_card": true, "card_name": "guanyu", "attack": 4,
				"health": {"front": 5, "back": 5, "left": 5, "right": 5},
				"effects": [], "faction": 0, "team_id": "defender",
				"owner_slot_id": "board_a", "origin": "hand", "is_phantom": false},
		}},
	}


func _test_wiring_on() -> void:
	Game.registry.clear()
	var slot: BoardSlot = BoardSlotFactory.create_headless("board_a", BoardSlot.FACTION_PLAYER,
		BoardSlot.ROLE_MAIN_PLAYER, {"hp": 30, "name_short": "P"}, {}, "defender", "p1")
	Game.disable_v2_authority()
	Game.enable_v2_authority()
	_check("接线: 打开 v2 后客户端核心件就绪", Game.v2_authority and Game.v2 != null)

	# 服务器推一条 auth/state：镜像 + 本地盘面都应更新
	Net.auth_state.emit({
		"turn": 2, "active": "p1", "finished": false, "winner": "",
		"you": {"pid": "p1", "hand": ["a", "b", "c"], "mana": {"current": 3, "maximum": 3},
			"equipments": [], "hero": {"hp": 30, "max_hp": 30}, "graveyard": []},
		"board": _board_state(),
	})
	var cell: CellData = slot.board.get_cell(Vector2(2, 1))
	_check("接线: auth/state 把单位画到本地棋盘（渲染器已接上）",
		bool(cell.has_card) and cell.card_name == "guanyu", str(cell.to_dict()))
	_check("接线: 四维按权威值写入", int(cell.health["front"]) == 5, str(cell.health))
	_check("接线: 镜像更新 turn/active", Game.v2.turn == 2 and Game.v2.active == "p1")
	_check("接线: 镜像更新手牌与费用",
		Game.v2.hand == ["a", "b", "c"] and int(Game.v2.mana["current"]) == 3,
		"%s %s" % [str(Game.v2.hand), str(Game.v2.mana)])

	# 服务器推成"这格空了" → 本地必须清掉
	var empty_state: Dictionary = _board_state()
	(empty_state["board_a"]["cells"]["2,1"] as Dictionary)["has_card"] = false
	Net.auth_state.emit({"turn": 3, "active": "p2", "you": {"hand": ["a"]},
		"board": empty_state})
	_check("接线: auth/state 说空 → 本地格被清空", not cell.has_card and cell.card_name == "")
	_check("接线: 手牌按权威校正（被服务器拿掉一张）", Game.v2.hand == ["a"], str(Game.v2.hand))

	# auth/event / reject / verdict
	Net.auth_event.emit({"event": "phase_resolved", "pid": "p2"})
	_check("接线: auth/event 进镜像 events", Game.v2.events.size() == 1, str(Game.v2.events))
	Net.auth_reject.emit({"reason": NetProtocol.REJECT_ILLEGAL_TARGET, "intent": "intent/play_card"})
	_check("接线: auth/reject 记入 last_reject",
		String(Game.v2.last_reject.get("reason", "")) == NetProtocol.REJECT_ILLEGAL_TARGET,
		str(Game.v2.last_reject))
	Net.auth_verdict.emit({"finished": true, "winner": "p1"})
	_check("接线: auth/verdict 置终局", Game.v2.finished and Game.v2.winner == "p1",
		"%s %s" % [str(Game.v2.finished), Game.v2.winner])


func _test_wiring_off() -> void:
	# 关掉 v2：再推 auth/* 不应有任何副作用（老路径不受影响）
	Game.disable_v2_authority()
	_check("接线: disable 后开关关闭", not Game.v2_authority)
	var before: Array = Game.v2.events.duplicate()
	var hand_before: Array = Game.v2.hand.duplicate()
	Net.auth_event.emit({"event": "should_not_arrive"})
	Net.auth_state.emit({"turn": 99, "you": {"hand": ["zzz"]}})
	_check("接线: 关闭后 auth/event 不再进镜像", Game.v2.events.size() == before.size(),
		"%d vs %d" % [Game.v2.events.size(), before.size()])
	_check("接线: 关闭后 auth/state 不再覆盖手牌", Game.v2.hand == hand_before, str(Game.v2.hand))

	# 再次打开：应可用且幂等（不重复连接信号）
	Game.enable_v2_authority()
	Net.auth_event.emit({"event": "again"})
	_check("接线: 重新打开后恢复接收且不重复触发",
		Game.v2.events.size() == 1 and String(Game.v2.events[0].get("event", "")) == "again",
		str(Game.v2.events))
	Game.disable_v2_authority()
