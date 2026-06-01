extends HeroAbility

# 水攻（英雄版）——威震华夏·关羽 专属技能。
# 消耗 2 费：选择任意敌方单位（不含英雄/spawner），对其施加"浸水"。
# 不限每回合次数。

func id() -> String:
	return "flood_strategy_hero"

func display_name() -> String:
	return "水攻"

func description() -> String:
	return "水攻：消耗 2 费，选择任意敌方单位，使其获得「浸水」（受到伤害后立即消灭，一次性）"

func cost() -> int:
	return 2

func once_per_turn() -> bool:
	return false

func on_activate(ctx) -> void:
	if ctx == null:
		return
	# 弹出目标选择器，筛选所有棋盘上的敌方单位格
	var target_cell = await ctx.pick_target_async("enemy_unit")
	if target_cell == null or not target_cell.has_card:
		# 玩家取消 → 退费
		Game.mana.gain(cost())
		return
	if not target_cell.effects.has("soaked"):
		target_cell.effects.append("soaked")
		if is_instance_valid(target_cell) and target_cell.has_node("InnerPanel"):
			var inner = target_cell.get_node("InnerPanel")
			EffectBadgeFactory.refresh(inner.get_node_or_null("EffectBadges"), target_cell.effects)
		# effects_changed：只刷新已开面板，不弹出
		target_cell.effects_changed.emit({
			"name": target_cell.card_name, "attack": target_cell.attack,
			"health": target_cell.health, "effects": target_cell.effects,
		})
