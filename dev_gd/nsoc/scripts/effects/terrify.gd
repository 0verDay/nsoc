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
		var v_is_enemy: bool = v.is_enemy if typeof(v) == TYPE_DICTIONARY else v.is_enemy
		var cdata = ctx.game.get_card(v_name)
		if cdata == null:
			continue
		var deck = ctx.game.deck
		if v_is_enemy:
			if deck.enemy_graveyard.has(cdata):
				deck.enemy_graveyard.erase(cdata)
				deck.pile_changed.emit("enemy_graveyard")
			deck.enemy_banish(cdata)
		else:
			if deck.graveyard.has(cdata):
				deck.graveyard.erase(cdata)
				deck.pile_changed.emit("graveyard")
			deck.banish(cdata)
