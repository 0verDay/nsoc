extends Node

## v2 权威战斗客户端测试（重构文档.md §4.2「客户端接入权威路径」核心件）。
##
## 运行：
##   godot --headless --path dev_gd/nsoc res://tests/V2BattleClientTest.tscn
##
## 输出：
##   V2BC_CASE [PASS|FAIL] <用例名> <说明>
##   V2BC_RESULT PASS|FAIL passed=N failed=M
##
## 不需要网络：上行用 `send_override` 收集，下行直接喂 auth/* 载荷。

const EXPECTED_CASES: int = 30

var _passed: int = 0
var _failed: int = 0


func _ready() -> void:
	_test_intents()
	_test_state_mirror()
	_test_events_and_verdict()

	var total: int = _passed + _failed
	if total != EXPECTED_CASES:
		_failed += 1
		print("V2BC_CASE FAIL 用例数量异常：期望 %d，实际 %d（有测试函数被运行时错误静默中断）"
			% [EXPECTED_CASES, total])

	print("V2BC_RESULT %s passed=%d failed=%d" % [
		"PASS" if _failed == 0 else "FAIL", _passed, _failed,
	])
	get_tree().quit(0 if _failed == 0 else 1)


func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("V2BC_CASE PASS %s" % name)
	else:
		_failed += 1
		print("V2BC_CASE FAIL %s | %s" % [name, detail])


func _make():
	var c = V2BattleClient.new()
	add_child(c)
	return c


func _last_intent(c) -> Dictionary:
	if c.sent.is_empty():
		return {}
	return c.sent[c.sent.size() - 1]


func _test_intents() -> void:
	var c = _make()
	var calls: Array = []
	c.send_override = func(t, p): calls.append({"type": t, "payload": p})

	# ① 单位落子：带落点
	c.play_unit("guanyu", "main_p1", 2, 1)
	var it := _last_intent(c)
	_check("意图: 单位落子用 INTENT_PLAY_CARD", String(it.get("type", "")) == NetProtocol.INTENT_PLAY_CARD)
	_check("意图: 单位落子带 card_name + 落点 + seq",
		String((it.payload as Dictionary).get("card_name", "")) == "guanyu"
		and String((it.payload as Dictionary).get("target_slot_id", "")) == "main_p1"
		and int((it.payload as Dictionary).get("row", -99)) == 2
		and int((it.payload as Dictionary).get("col", -99)) == 1
		and int((it.payload as Dictionary).get("seq", -1)) == 1, str(it))

	# ② seq 单调递增
	c.play_spell("huogong", "main_p2", 0, 0)
	c.end_turn()
	c.surrender()
	var seqs: Array = []
	for entry in c.sent:
		seqs.append(int((entry["payload"] as Dictionary).get("seq", -1)))
	_check("意图: seq 单调递增（1..4）", seqs == [1, 2, 3, 4], str(seqs))
	_check("意图: 结束回合用 INTENT_END_TURN 且只带 seq",
		String(c.sent[2].type) == NetProtocol.INTENT_END_TURN
		and (c.sent[2].payload as Dictionary).size() == 1, str(c.sent[2]))
	_check("意图: 投降用 INTENT_SURRENDER", String(c.sent[3].type) == NetProtocol.INTENT_SURRENDER)

	# ③ 装备 / 英雄技能 / 跨盘 / 选择
	c.play_equip("shengbei")
	_check("意图: 打出装备用 INTENT_PLAY_EQUIP（只带 card_name）",
		String(_last_intent(c).type) == NetProtocol.INTENT_PLAY_EQUIP
		and String((_last_intent(c).payload as Dictionary).get("card_name", "")) == "shengbei",
		str(_last_intent(c)))
	c.activate_equip("shengbei")
	_check("意图: 无目标装备激活不带落点字段",
		String(_last_intent(c).type) == NetProtocol.INTENT_ACTIVATE_EQUIP
		and not (_last_intent(c).payload as Dictionary).has("row"), str(_last_intent(c)))
	c.activate_equip("shengbei", "main_p1", 1, 1)
	_check("意图: 有目标装备激活带落点",
		int((_last_intent(c).payload as Dictionary).get("row", -1)) == 1
		and String((_last_intent(c).payload as Dictionary).get("target_slot_id", "")) == "main_p1")
	c.activate_hero("weishan_ability")
	_check("意图: 英雄技能用 INTENT_ACTIVATE_HERO（只带 ability_id + seq）",
		String(_last_intent(c).type) == NetProtocol.INTENT_ACTIVATE_HERO
		and String((_last_intent(c).payload as Dictionary).get("ability_id", "")) == "weishan_ability"
		and (_last_intent(c).payload as Dictionary).size() == 2, str(_last_intent(c)))
	c.cross_board("main_p1", "main_p2")
	_check("意图: 跨盘用 INTENT_CROSS_BOARD 带两端盘 id",
		String(_last_intent(c).type) == NetProtocol.INTENT_CROSS_BOARD
		and String((_last_intent(c).payload as Dictionary).get("target_slot_id", "")) == "main_p2")
	c.choose("req-1", 1)
	_check("意图: 选择用 INTENT_CHOICE 带 request_id + option_index",
		String(_last_intent(c).type) == NetProtocol.INTENT_CHOICE
		and String((_last_intent(c).payload as Dictionary).get("request_id", "")) == "req-1"
		and int((_last_intent(c).payload as Dictionary).get("option_index", -1)) == 1)
	_check("意图: 每一次发送都进了 send_override（共 10 次）", calls.size() == 10, str(calls.size()))

	# ④ 无通道时不崩（没有 Net 也没有 override）
	var c2 = _make()
	_check("意图: 没有通道时返回 false 且不崩", not c2.end_turn())


func _test_state_mirror() -> void:
	var c = _make()
	var changes: Array = []
	c.state_changed.connect(func(): changes.append("state"))
	c.board_changed.connect(func(): changes.append("board"))

	c.apply_state({
		"turn": 3, "active": "p1", "finished": false, "winner": "",
		"you": {
			"pid": "p1", "hand": ["a", "b"], "mana": {"current": 2, "maximum": 3},
			"equipments": [{"card_name": "shengbei", "durability_left": 2}],
			"hero": {"hp": 25, "max_hp": 30}, "graveyard": ["x"],
		},
		"board": {
			"main_p1": {"owner": "p1", "team_id": "defender", "cells": {
				"2,1": {"has_card": true, "card_name": "guanyu", "attack": 4,
					"health": {"front": 5, "back": 5, "left": 5, "right": 5},
					"team_id": "defender", "owner_slot_id": "main_p1"},
			}},
			"main_p2": {"owner": "p2", "team_id": "attacker", "cells": {}},
		},
	})
	_check("镜像: turn/active 来自 auth/state", c.turn == 3 and c.active == "p1")
	_check("镜像: 手牌/费用/装备/英雄/墓地",
		c.hand == ["a", "b"] and int(c.mana["current"]) == 2
		and c.equipments.size() == 1 and int(c.hero["hp"]) == 25 and c.graveyard == ["x"],
		"%s %s" % [str(c.hand), str(c.mana)])
	_check("镜像: 盘面按 slot 收敛", c.board.size() == 2 and c.board.has("main_p1"))
	_check("镜像: cell_at 能取到单位",
		String(c.cell_at("main_p1", 2, 1).get("card_name", "")) == "guanyu"
		and bool(c.cell_at("main_p1", 2, 1).get("has_card", false)))
	_check("镜像: 空格/未知盘返回空字典",
		c.cell_at("main_p1", 0, 0).is_empty() and c.cell_at("nope", 0, 0).is_empty())
	_check("镜像: slots_of 按 owner 过滤",
		c.slots_of("p1") == ["main_p1"] and c.slots_of("p2") == ["main_p2"],
		str(c.slots_of("p1")))
	_check("镜像: is_my_turn 只认权威状态",
		c.is_my_turn("p1") and not c.is_my_turn("p2"))
	_check("镜像: state_changed + board_changed 都发了",
		changes.has("state") and changes.has("board"), str(changes))

	# ② 不带 board 的 state（例如仅费用变化）不应覆盖盘面
	var before: int = c.board.size()
	c.apply_state({"turn": 4, "active": "p2", "you": {"mana": {"current": 5, "maximum": 5}}})
	_check("镜像: 无 board 字段的 state 不覆盖盘面",
		c.board.size() == before and c.turn == 4 and c.active == "p2", str(c.board.size()))
	_check("镜像: 无 you 字段的 state 不清空手牌", c.hand == ["a", "b"], str(c.hand))


func _test_events_and_verdict() -> void:
	var c = _make()
	c.send_override = func(_t, _p): pass   # 本段不测上行，但 reset 后要能再发一条
	var got: Array = []
	c.event_received.connect(func(p): got.append(String(p.get("event", ""))))
	c.apply_event({"event": "phase_pending", "pid": "p1"})
	_check("事件: 记入 events 并发出信号",
		c.events.size() == 1 and got == ["phase_pending"], str(got))
	c.apply_event({"event": "turn_started", "pid": "p2", "turn": 5})
	_check("事件: turn_started 同步 active/turn", c.active == "p2" and c.turn == 5,
		"%s %d" % [c.active, c.turn])
	c.apply_event({"event": "match_finished", "winner": "p2"})
	_check("事件: match_finished 置 finished/winner", c.finished and c.winner == "p2")

	var rej: Array = []
	c.rejected.connect(func(p): rej.append(String(p.get("reason", ""))))
	c.apply_reject({"reason": NetProtocol.REJECT_ILLEGAL_TARGET, "intent": "intent/play_card"})
	_check("拒绝: 记录并在 rejected 信号里给出原因",
		String(c.last_reject.get("reason", "")) == NetProtocol.REJECT_ILLEGAL_TARGET
		and rej.has(NetProtocol.REJECT_ILLEGAL_TARGET), str(c.last_reject))

	var vd: Array = []
	c.verdict_received.connect(func(p): vd.append(String(p.get("winner", ""))))
	c.apply_verdict({"finished": true, "winner": "p1"})
	_check("终局: auth/verdict 更新并发出信号", c.finished and c.winner == "p1" and vd == ["p1"],
		"%s %s" % [str(c.finished), str(vd)])

	# reset 清空（换局）且 seq 归零
	c.reset()
	_check("重置: reset 清空镜像与 seq",
		c.events.is_empty() and c.sent.is_empty() and c.seq == 0 and not c.finished)
	_check("重置: reset 后 seq 从 1 重新开始", c.end_turn() and c.seq == 1)
