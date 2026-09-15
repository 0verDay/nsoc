class_name AuthBoardRenderer
extends RefCounted

## 把**权威盘面**（`auth/state.board`）落到本地棋盘上（重构文档.md §4.2 客户端接入）。
##
## v2 模式下客户端**不再本地结算**：出牌/行动的结果完全由服务器给出，本类只做"重绘" ——
## 按镜像里的 `has_card` / 牌面 / 四维 / 效果，逐格 set_card 或 clear_card。
##
## 之所以单独成类：它既能作用在客户端的 `Cell`（带视图，`set_card` 会刷标签与徽章），
## 也能作用在无头的 `CellData`（纯数据，`set_card` 只写状态）—— 因此可以**无 UI 测试**。
##
## 与"本地锁步"的区别：锁步是"两端各算一遍、用同一份规则得出同样结果"；本类是
## "只有服务器算，客户端照着画"。两者在 v2 里不能同时启用。

## 应用镜像。registry 默认取 Game.registry。
## 返回 {"applied": int, "cleared": int, "unknown_slots": Array, "unchanged": int}。
static func apply(board_state: Dictionary, registry: BoardRegistry = null) -> Dictionary:
	var reg: BoardRegistry = registry
	if reg == null:
		reg = Game.registry
	var applied: int = 0
	var cleared: int = 0
	var unchanged: int = 0
	var unknown: Array = []
	if reg == null:
		return {"applied": 0, "cleared": 0, "unknown_slots": board_state.keys(), "unchanged": 0}

	for slot_id_raw in board_state.keys():
		var slot_id := String(slot_id_raw)
		var slot: BoardSlot = reg.get_by_id(slot_id)
		if slot == null or slot.board == null:
			unknown.append(slot_id)
			continue
		var slot_state: Dictionary = board_state[slot_id_raw]
		var cells: Dictionary = slot_state.get("cells", {})
		for key in cells.keys():
			var parts: PackedStringArray = String(key).split(",")
			if parts.size() != 2:
				continue
			var row := int(parts[0])
			var col := int(parts[1])
			var cell = slot.board.get_cell(Vector2(row, col))
			if cell == null:
				continue
			var want: Dictionary = cells[key]
			# 有牌面**或幻影**都要画（幻影 has_card=false 但保留牌面预告）
			if bool(want.get("has_card", false)) or bool(want.get("is_phantom", false)):
				if _needs_card_update(cell, want):
					_apply_card(cell, want)
					applied += 1
				else:
					unchanged += 1
			else:
				if bool(cell.has_card) or bool(cell.is_phantom):
					cell.clear_card()
					cleared += 1
				else:
					unchanged += 1
	return {"applied": applied, "cleared": cleared, "unknown_slots": unknown,
		"unchanged": unchanged}


## 是否需要重写（牌面/四维/效果/归属/幻影任一不同）。避免每帧无谓重绘导致动画重播。
static func _needs_card_update(cell, want: Dictionary) -> bool:
	# 本地空 → 一定需要画
	if not bool(cell.has_card) and not bool(cell.is_phantom):
		return true
	if bool(cell.is_phantom) != bool(want.get("is_phantom", false)):
		return true
	if String(cell.card_name) != String(want.get("card_name", "")):
		return true
	if int(cell.attack) != int(want.get("attack", 0)):
		return true
	if (cell.effects as Array) != (want.get("effects", []) as Array):
		return true
	var want_hp: Dictionary = want.get("health", {})
	for side in Orientation.SIDES:
		if int(cell.health.get(side, 0)) != int(want_hp.get(side, 0)):
			return true
	if String(cell.owner_slot_id) != String(want.get("owner_slot_id", cell.owner_slot_id)):
		return true
	if bool(cell.is_phantom) != bool(want.get("is_phantom", false)):
		return true
	return false


## 按镜像写一格。字段语义与 `CellData.to_dict()` 一一对应。
static func _apply_card(cell, want: Dictionary) -> void:
	var card_name := String(want.get("card_name", ""))
	var attack := int(want.get("attack", 0))
	var health: Dictionary = want.get("health", {})
	var effects: Array = (want.get("effects", []) as Array).duplicate()
	var owner := String(want.get("owner_slot_id", ""))
	var origin := String(want.get("origin", ""))
	var enemy := int(want.get("faction", 0)) == 1
	var phantom := bool(want.get("is_phantom", false))
	if phantom:
		cell.set_phantom(card_name, attack, health, enemy, effects)
	else:
		cell.set_card(card_name, attack, health, enemy, effects, owner, origin)
	# 队伍与攻击标记：镜像值优先（set_card 会按 owner_slot_id 反查 registry，
	# 但权威端的 team_id 是最终真相）
	var team := String(want.get("team_id", ""))
	if team != "":
		cell.team_id = team
	cell.has_charged = bool(want.get("has_charged", false))
	cell.has_attacked = bool(want.get("has_attacked", false))
