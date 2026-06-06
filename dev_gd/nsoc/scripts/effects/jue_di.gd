extends Effect

# 决堤：
# 1. 永久剥夺 enemy_main 英雄（曹仁）的"死守"：清 flag + 移除 abilities 里的展示条目
# 2. 全场所有棋盘敌方单位施加浸水，立即刷新 badge
# 3. 水坝英雄 hp 归零 → died 信号 → ScriptedEvents trigger 负责蓄水结算 + remove_board

func id() -> String:
	return "jue_di"

func display_name() -> String:
	return "决堤"

func description() -> String:
	return "决堤：剥夺「曹仁」死守，使「水坝」退场并结算蓄水，所有敌方单位获得「浸水」"

func on_play(card_data, ctx) -> bool:
	if ctx == null or ctx.game == null:
		return true

	var game = ctx.game

	# 1. 永久剥夺曹仁死守：清 flag + 从 abilities 移除展示条目
	if game.registry != null:
		for slot in game.registry.by_role(BoardSlot.ROLE_MAIN_ENEMY):
			if slot.hero != null:
				slot.hero.set_flag("die_hard", false)
				slot.hero.abilities.erase("die_hard_display")
			break

	# 2. 全场所有棋盘敌方单位施加浸水，并立即刷新 badge
	var local_team: String = game.team_of_player(game.local_player_id)
	if game.registry != null:
		for slot in game.registry.slots:
			if slot.board == null:
				continue
			for cell in slot.board.grid_cells.values():
				if not is_instance_valid(cell) or not cell.has_card or not cell.is_hostile_to(local_team):
					continue
				if not cell.effects.has("soaked"):
					cell.effects.append("soaked")
			# 立即刷新效果徽章 + 更新已开详情面板（不弹出）
				if cell.has_node("InnerPanel"):
					var inner = cell.get_node("InnerPanel")
					EffectBadgeFactory.refresh(inner.get_node_or_null("EffectBadges"), cell.effects)
				cell.effects_changed.emit({
					"name": cell.card_name, "attack": cell.attack,
					"health": cell.health, "effects": cell.effects,
			})

	# 3. 水坝英雄 hp 归零 → 触发 died 信号 → ScriptedEvents trigger 接管后续
	if game.registry != null:
		for slot in game.registry.by_role(BoardSlot.ROLE_ALLY):
			if slot.hero != null and not slot.hero.is_dead:
				slot.hero.apply_damage(slot.hero.health)
			break

	return true

func resolve_destination(_card_data, _ctx) -> String:
	return "graveyard"
