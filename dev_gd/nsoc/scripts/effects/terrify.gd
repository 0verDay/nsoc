extends Effect

# 破胆：被本单位击杀的目标从游戏中除外。
# 注意：默认死亡流程已在击杀触发前把 victim 送入对应阵营墓地（见 PlayController.handle_unit_death），
# 本效果在 on_kill 中将其从墓地取出再放入除外区，保证最终去向正确。

func id() -> String:
	return "terrify"

func display_name() -> String:
	return "破胆"

func description() -> String:
	return "破胆：被本单位击杀的单位从游戏中除外"

func on_kill(_attacker_cell, victim_cells: Array, ctx) -> void:
	if victim_cells.is_empty():
		return
	for v in victim_cells:
		if v == null:
			continue
		var v_name: String = v.card_name if typeof(v) == TYPE_DICTIONARY else v.card_name
		# 取原属盘 id 与 origin（victim 快照含 owner_slot_id / origin）
		var v_owner_id: String = ""
		var v_origin: String = ""
		if typeof(v) == TYPE_DICTIONARY:
			v_owner_id = v.get("owner_slot_id", "")
			if v_owner_id == "":
				v_owner_id = v.get("slot_id", "")
			v_origin = v.get("origin", "")
		else:
			v_owner_id = v.owner_slot_id if v.owner_slot_id != "" else v.slot_id
			v_origin = v.origin
		var cdata = ctx.game.get_card(v_name)
		if cdata == null:
			continue
		# origin == "hand" → game.deck（玩家手牌部署的单位）
		# 其他 → 原属盘 slot.graveyard
		if v_origin == "hand":
			var deck = ctx.game.deck
			if deck.graveyard.has(cdata):
				deck.graveyard.erase(cdata)
				deck.pile_changed.emit("graveyard")
			deck.banish(cdata)
		else:
			# 从原属盘 graveyard 取出 → banished。原属盘已销毁则跳过。
			var slot: BoardSlot = ctx.game.registry.get_by_id(v_owner_id) if ctx.game.registry != null else null
			if slot != null:
				if slot.graveyard.has(cdata):
					slot.graveyard.erase(cdata)
					slot.pile_changed.emit("graveyard")
				slot.banish(cdata)
