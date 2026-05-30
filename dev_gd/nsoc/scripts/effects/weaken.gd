extends Effect

# 放箭：对目标任意单位的四维各 -1（可为负数，无下限）。
# 施加后若任意一面 <=0 则走标准死亡流程。
# 由 spell 系统调用 on_play 时通过 ctx.target_cell 拿目标。

const DEBUFF: int = 1

func id() -> String:
	return "weaken"

func display_name() -> String:
	return "放箭"

func description() -> String:
	return "放箭：对任意单位使用，使其四维各-1"

func on_play(_card_data, ctx) -> bool:
	var cell = ctx.target_cell
	if cell == null or not cell.has_card:
		return true
	for s in Orientation.SIDES:
		cell.health[s] -= DEBUFF
	cell._update_hp_labels()

	# 检查是否有任一面 <=0，若是则走标准死亡流程
	var should_die: bool = false
	for s in Orientation.SIDES:
		if cell.health[s] <= 0:
			should_die = true
			break

	if should_die:
		cell.play_death_effect()
		await ctx.game.get_tree().create_timer(0.45).timeout
		if ctx.game.combat != null and ctx.game.combat.aborted:
			return true
		if not is_instance_valid(cell) or not cell.has_card:
			return true
		if Game.play != null and Game.play.has_method("handle_unit_death"):
			Game.play.handle_unit_death(cell)
		if is_instance_valid(cell) and cell.has_card:
			cell.clear_card()

	return true
