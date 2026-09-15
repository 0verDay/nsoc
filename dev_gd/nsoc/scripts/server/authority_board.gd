class_name AuthorityBoard
extends RefCounted

## 权威端棋盘适配器（重构文档.md §4「确保无法作弊」：棋盘结算也归服务器）。
##
## 为什么是"适配器"：`BattleAuthority` 刻意保持纯状态机（RefCounted、不碰场景树、
## 不引用 UI、可在无 SceneTree 环境构造），而棋盘规则引擎（BoardModel / BoardSlot /
## CellData / BoardSlotFactory）需要 Godot 的 autoload 与节点。两者用本类解耦：
##
##   BattleAuthority  ---- deploy_unit() / state() ---->  AuthorityBoard  ---->  规则引擎
##
## 于是"服务器裁决棋盘"用的是**同一套规则与同一份数据表示**（`CellData`），
## 不是第二份规则实现 —— 这正是阶段 2/3 做数据/表现分离的目的。
##
## 落子会带上 slot 的 team_id / owner_player_id，跨盘与友敌判定与客户端一致。

var _by_pid: Dictionary = {}        # pid -> Array[BoardSlot]（1v3/3v3 下一个玩家可有多盘）
var _by_slot_id: Dictionary = {}    # slot_id -> BoardSlot


## 建盘。config：
##   players: Array[pid]                 按行动顺序
##   teams:   {pid: team_id}             "defender" / "attacker" / "team_a" …（可选）
##   hero_hp: {pid: int}                 英雄血量（可选，默认 30）
##   slot_ids:{pid: slot_id}             自定义盘 id（可选，默认 "main_<pid>"）
##   level:   {slot_id: {initial_units: [...]}}  初始铺盘（可选）
## 返回 {"ok": bool, "reason": String}。
func start(config: Dictionary) -> Dictionary:
	_by_pid.clear()
	_by_slot_id.clear()

	var players: Array = config.get("players", [])
	if players.is_empty():
		return {"ok": false, "reason": "no_players"}
	var teams: Dictionary = config.get("teams", {})
	var hero_hp: Dictionary = config.get("hero_hp", {})
	var slot_ids: Dictionary = config.get("slot_ids", {})
	var level: Dictionary = config.get("level", {})

	for i in range(players.size()):
		var pid := String(players[i])
		# 默认盘 id：main_<pid>；阵营按行动顺序轮替（0 = 玩家侧 / 1 = 敌方侧），
		# 多队伍 PVP 的友敌判定由 team_id 决定（faction 只作 PVE 兜底）。
		var slot_id := String(slot_ids.get(pid, "main_%s" % pid))
		var faction: int = BoardSlot.FACTION_PLAYER if i % 2 == 0 else BoardSlot.FACTION_ENEMY
		var role: int = BoardSlot.ROLE_MAIN_PLAYER if faction == BoardSlot.FACTION_PLAYER \
			else BoardSlot.ROLE_MAIN_ENEMY
		var section: Dictionary = level.get(slot_id, {})
		var hero_spec := {"hp": int(hero_hp.get(pid, 30)), "name_short": pid, "name_full": pid}
		var team := String(teams.get(pid, ""))

		var slot: BoardSlot = BoardSlotFactory.create_headless(
			slot_id, faction, role, hero_spec, section, team, pid)
		if slot == null:
			return {"ok": false, "reason": "board_setup_failed"}
		var list: Array = _by_pid.get(pid, [])
		list.append(slot)
		_by_pid[pid] = list
		_by_slot_id[slot_id] = slot

	return {"ok": true, "reason": ""}


func is_empty() -> bool:
	return _by_slot_id.is_empty()


func slots_of(pid: String) -> Array:
	return _by_pid.get(pid, [])


func slot_at(slot_id: String) -> BoardSlot:
	return _by_slot_id.get(slot_id)


func cell_at(slot_id: String, row: int, col: int):
	var slot: BoardSlot = _by_slot_id.get(slot_id)
	if slot == null or slot.board == null:
		return null
	return slot.board.get_cell(Vector2(row, col))


## 校验并落子。**只做校验与状态写入**，不碰手牌/费用（那是 BattleAuthority 的职责）：
## 失败时调用方不应消耗任何资源。
## 返回 {"ok": bool, "reason": String(NetProtocol.REJECT_*), "unit": {...}}。
func deploy_unit(pid: String, card_name: String, payload: Dictionary) -> Dictionary:
	var row := int(payload.get("row", -1))
	var col := int(payload.get("col", -1))
	if row < 0 or col < 0:
		return {"ok": false, "reason": NetProtocol.REJECT_BAD_PAYLOAD}
	if not _by_pid.has(pid):
		return {"ok": false, "reason": NetProtocol.REJECT_UNKNOWN_PLAYER}

	var slot: BoardSlot = _resolve_slot(pid, String(payload.get("target_slot_id", "")))
	if slot == null:
		# 指定了他人的盘 / 不存在的盘：一律非法目标（防"把单位放到对手盘上"）
		return {"ok": false, "reason": NetProtocol.REJECT_ILLEGAL_TARGET}

	var cdata = Game.get_card(card_name)
	if cdata == null:
		return {"ok": false, "reason": NetProtocol.REJECT_BAD_PAYLOAD}
	if not (cdata is CardUnit):
		# 法术 / 装备 / 英雄技能的权威结算待后续切片；现在明确拒绝而不是静默放行
		return {"ok": false, "reason": NetProtocol.REJECT_NOT_ALLOWED}

	var cell = slot.board.get_cell(Vector2(row, col))
	if cell == null:
		return {"ok": false, "reason": NetProtocol.REJECT_ILLEGAL_TARGET}
	if cell.has_card or cell.is_phantom:
		return {"ok": false, "reason": NetProtocol.REJECT_ILLEGAL_TARGET}

	cell.set_card(cdata.name, cdata.attack, cdata.health,
		slot.faction == BoardSlot.FACTION_ENEMY, cdata.effects,
		slot.id, "hand", slot.team_id)
	return {"ok": true, "reason": "", "unit": {
		"slot_id": slot.id, "row": row, "col": col, "card": cdata.name,
		"attack": cdata.attack, "health": cell.health.duplicate(),
		"team_id": slot.team_id, "owner": pid, "origin": "hand",
	}}


## 盘面公开状态（战棋里单位位置本就公开；隐藏信息只有手牌，由 view_for 处理）。
func state() -> Dictionary:
	var out: Dictionary = {}
	for slot_id in _by_slot_id.keys():
		var slot: BoardSlot = _by_slot_id[slot_id]
		var cells: Dictionary = {}
		for key in slot.board.grid_cells.keys():
			var cell = slot.board.grid_cells[key]
			cells["%d,%d" % [int(key.x), int(key.y)]] = cell.to_dict()
		out[slot_id] = {
			"owner": slot.owner_player_id,
			"team_id": slot.team_id,
			"faction": slot.faction,
			"hero": {"hp": slot.hero.health if slot.hero != null else 0},
			"cells": cells,
			"graveyard": slot.graveyard.size(),
			"banished": slot.banished.size(),
		}
	return out


## 解析目标盘：显式 slot_id 必须在 pid 名下；未指定则取 pid 的第一块盘。
func _resolve_slot(pid: String, slot_id: String) -> BoardSlot:
	var owned: Array = _by_pid.get(pid, [])
	if slot_id == "":
		return owned[0] if owned.size() > 0 else null
	for slot in owned:
		if slot.id == slot_id:
			return slot
	return null
