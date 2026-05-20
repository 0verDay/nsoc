extends Effect

# 冲阵：本单位击杀敌人后，向敌人死亡处移动。若一次击杀多个敌人，
# 随机选择其中之一作为落点。移动到位后：
#   1. 触发该格的警戒哨反应（与冲锋落点同步语义）
#   2. 若仍存活且相邻仍有敌方，对其发动攻击（可能再次击杀，递归触发本效果）
#
# 落点必须为空格（攻击发生后 victim 已被 clear_card），但若该位置因连锁
# 反应被其它单位占据则放弃移动。

func id() -> String:
	return "assault_charge"

func display_name() -> String:
	return "冲阵"

func description() -> String:
	return "冲阵：击杀敌人后，向其死亡处移动；若移动后相邻有敌人则对其发动攻击"

func on_kill(attacker_cell, victim_cells: Array, ctx) -> void:
	if attacker_cell == null or not attacker_cell.has_card:
		return
	if victim_cells.is_empty():
		return
	# 过滤出仍可作为落点的格（无牌、非自身、合法）
	var candidates: Array = []
	for v in victim_cells:
		if v == null:
			continue
		var vc = v.cell if typeof(v) == TYPE_DICTIONARY else v
		if vc == null or vc == attacker_cell:
			continue
		if vc.has_card:
			continue
		candidates.append(vc)
	if candidates.is_empty():
		return
	candidates.shuffle()
	var dest = candidates[0]

	var combat = ctx.combat()
	if combat == null:
		return
	# 同列同行皆可（冲阵不限方向，沿用 combat.move_card 的弧线动画）
	await combat.move_card(attacker_cell, dest)

	# 警戒反应；可能打死本单位
	await ctx.trigger_vigilance(dest)
	if not dest.has_card:
		return

	# 仍存活：检查相邻敌方，若有则发动一次攻击
	var enemies: Array = ctx.board().find_adjacent_enemies(dest, dest.is_enemy)
	if enemies.size() > 0:
		await combat.attack_cells(dest, enemies)
