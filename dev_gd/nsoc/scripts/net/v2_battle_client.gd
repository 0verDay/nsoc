class_name V2BattleClient
extends Node

## v2 权威战斗客户端（客户端接入权威路径的核心，场景无关、可无头测试）。
##
## 职责两件事：
##   ① 上行：把玩家操作变成 `intent/*`（自动维护单调 `seq`；**不猜结果、不做本地裁决**）
##   ② 下行：把 `auth/state` / `auth/event` / `auth/reject` / `auth/verdict` 收敛成一份
##      "服务器说现在是什么样"的镜像（board/hand/mana/equipments/turn/active），
##      供战斗场景渲染。
##
## 与 `Net` 解耦：默认通过 `Net` 发送/订阅；测试可设置 `send_override` 并直接调
## `apply_state/apply_event/apply_reject/apply_verdict`，无需网络。
##
## 分层：`scripts/net/` —— 不引用 UI，可在无场景树的测试里构造。

signal state_changed
signal board_changed
signal event_received(payload: Dictionary)
signal rejected(payload: Dictionary)
signal verdict_received(payload: Dictionary)

## 测试缝隙：非空时所有上行都走它（收集器），不碰真实网络。
var send_override: Callable = Callable()

## 序号：服务器要求单调递增（重复/回退会被判 stale_seq）。
var seq: int = 0

# ── 服务器视图镜像（只由 auth/* 更新）──────────────────────────────────────
var board: Dictionary = {}          # slot_id -> {owner, team_id, faction, hero, cells{"r,c": cell}}
var hand: Array = []
var mana: Dictionary = {}
var equipments: Array = []
var hero: Dictionary = {}
var graveyard: Array = []
var turn: int = 0
var active: String = ""
var finished: bool = false
var winner: String = ""
var last_reject: Dictionary = {}
var events: Array = []

## 已发送的意图记录（测试/调试用）：[{type, payload}]
var sent: Array = []


# ══ 上行：意图 ════════════════════════════════════════════════════════════

func play_unit(card_name: String, slot_id: String, row: int, col: int) -> bool:
	return _send_intent(NetProtocol.INTENT_PLAY_CARD, _cell_payload(card_name, slot_id, row, col))


func play_spell(card_name: String, slot_id: String, row: int, col: int) -> bool:
	return _send_intent(NetProtocol.INTENT_PLAY_CARD, _cell_payload(card_name, slot_id, row, col))


func play_equip(card_name: String) -> bool:
	return _send_intent(NetProtocol.INTENT_PLAY_EQUIP, {"card_name": card_name})


func activate_equip(equip_name: String, slot_id: String = "", row: int = -1, col: int = -1) -> bool:
	var payload: Dictionary = {"equip_name": equip_name}
	if slot_id != "" and row >= 0 and col >= 0:
		payload["target_slot_id"] = slot_id
		payload["row"] = row
		payload["col"] = col
	return _send_intent(NetProtocol.INTENT_ACTIVATE_EQUIP, payload)


func activate_hero(ability_id: String, slot_id: String = "", row: int = -1, col: int = -1) -> bool:
	var payload: Dictionary = {"ability_id": ability_id}
	if slot_id != "" and row >= 0 and col >= 0:
		payload["target_slot_id"] = slot_id
		payload["row"] = row
		payload["col"] = col
	return _send_intent(NetProtocol.INTENT_ACTIVATE_HERO, payload)


func end_turn() -> bool:
	return _send_intent(NetProtocol.INTENT_END_TURN, {})


func surrender() -> bool:
	return _send_intent(NetProtocol.INTENT_SURRENDER, {})


func cross_board(source_slot_id: String, target_slot_id: String) -> bool:
	return _send_intent(NetProtocol.INTENT_CROSS_BOARD,
		{"source_slot_id": source_slot_id, "target_slot_id": target_slot_id})


func choose(request_id: String, option_index: int) -> bool:
	return _send_intent(NetProtocol.INTENT_CHOICE,
		{"request_id": request_id, "option_index": option_index})


func _cell_payload(card_name: String, slot_id: String, row: int, col: int) -> Dictionary:
	var payload: Dictionary = {"card_name": card_name}
	if slot_id != "" and row >= 0 and col >= 0:
		payload["target_slot_id"] = slot_id
		payload["row"] = row
		payload["col"] = col
	return payload


## 发一条意图：注入单调 `seq`，记录并发出（返回 false = 当前没有可用通道）。
func _send_intent(type: String, payload: Dictionary) -> bool:
	seq += 1
	var full: Dictionary = payload.duplicate()
	full["seq"] = seq
	sent.append({"type": type, "payload": full.duplicate()})
	if send_override.is_valid():
		send_override.call(type, full)
		return true
	if not has_node("/root/Net") or not Net.is_connected_to_server():
		return false
	Net.send_intent(type, full)
	return true


# ══ 下行：auth/* → 镜像 ═══════════════════════════════════════════════════

func apply_state(payload: Dictionary) -> void:
	turn = int(payload.get("turn", turn))
	active = String(payload.get("active", active))
	finished = bool(payload.get("finished", finished))
	winner = String(payload.get("winner", winner))
	var you: Dictionary = payload.get("you", {}) if typeof(payload.get("you", {})) == TYPE_DICTIONARY else {}
	if not you.is_empty():
		hand = (you.get("hand", hand) as Array).duplicate()
		mana = (you.get("mana", mana) as Dictionary).duplicate()
		equipments = (you.get("equipments", equipments) as Array).duplicate()
		hero = (you.get("hero", hero) as Dictionary).duplicate()
		graveyard = (you.get("graveyard", graveyard) as Array).duplicate()
	# 只有载荷里**真的带了 board** 才覆盖盘面（否则"仅费用变化"的 state 会清空盘面）
	var board_changed_flag: bool = payload.has("board") \
		and typeof(payload.get("board")) == TYPE_DICTIONARY
	if board_changed_flag:
		board = (payload.get("board") as Dictionary).duplicate(true)
	state_changed.emit()
	if board_changed_flag:
		board_changed.emit()


func apply_event(payload: Dictionary) -> void:
	events.append(payload.duplicate())
	# 事件里带 turn/active 时同步（权威事件的语义以 auth/state 为准，这里只做便捷更新）
	if payload.has("turn"):
		turn = int(payload["turn"])
	if payload.has("pid") and String(payload.get("event", "")) == "turn_started":
		active = String(payload["pid"])
	if String(payload.get("event", "")) == "match_finished":
		finished = true
		winner = String(payload.get("winner", ""))
	event_received.emit(payload)


func apply_reject(payload: Dictionary) -> void:
	last_reject = payload.duplicate()
	rejected.emit(payload)


func apply_verdict(payload: Dictionary) -> void:
	finished = bool(payload.get("finished", true))
	winner = String(payload.get("winner", winner))
	verdict_received.emit(payload)


## 便捷查询：某盘某格的单位（无单位/未知格返回空字典）。
func cell_at(slot_id: String, row: int, col: int) -> Dictionary:
	var slot: Dictionary = board.get(slot_id, {})
	var cells: Dictionary = slot.get("cells", {})
	return cells.get("%d,%d" % [row, col], {})


## 便捷查询：某玩家（按 owner）名下的全部盘 id。
func slots_of(owner_pid: String) -> Array:
	var out: Array = []
	for sid in board.keys():
		if String((board[sid] as Dictionary).get("owner", "")) == owner_pid:
			out.append(String(sid))
	return out


## 当前行动者是不是我（客户端只据权威状态判断"能不能操作"）。
func is_my_turn(local_pid: String) -> bool:
	return active != "" and active == local_pid and not finished


func reset() -> void:
	seq = 0
	board = {}
	hand = []
	mana = {}
	equipments = []
	hero = {}
	graveyard = []
	turn = 0
	active = ""
	finished = false
	winner = ""
	last_reject = {}
	events = []
	sent = []
