extends Effect

# 消灭：消灭一个目标敌方单位（走标准死亡流程，触发 on_death）。
# 视觉：闪红 → 0.45s 后执行死亡。

func id() -> String:
	return "destroy_unit"

func display_name() -> String:
	return "消灭"

func description() -> String:
	return "消灭：消灭一个敌方单位（触发其死亡效果）。"

func target() -> String:
	return "enemy_unit"

func on_play(_card_data, ctx) -> bool:
	var cell = ctx.target_cell
	if cell == null or not cell.has_card:
		return false

	# 闪红
	cell.play_damage_effect()

	# 等待与 CombatSystem.DEATH_DELAY 一致的延迟，再走死亡流程
	await ctx.game.get_tree().create_timer(CombatSystem.DEATH_DELAY).timeout

	# 退出到菜单时 combat.aborted = true，安全退出
	if ctx.game.combat != null and ctx.game.combat.aborted:
		return true
	if not is_instance_valid(cell) or not cell.has_card:
		return true

	# 播死亡特效
	cell.play_death_effect()
	await ctx.game.get_tree().create_timer(CombatSystem.DEATH_DELAY).timeout
	if ctx.game.combat != null and ctx.game.combat.aborted:
		return true
	if not is_instance_valid(cell) or not cell.has_card:
		return true

	# 走标准死亡流程（触发 on_death、入墓/除外）
	if Game.play != null and Game.play.has_method("handle_unit_death"):
		Game.play.handle_unit_death(cell)
	if is_instance_valid(cell) and cell.has_card:
		cell.clear_card()

	return true
