extends Effect

# 强化：对目标友方单位的四维 + 攻击 各 +1。
# 由 spell 系统调用 on_play 时通过 ctx.target_cell 拿目标。

const BUFF: int = 1

func id() -> String:
	return "empower"

func display_name() -> String:
	return "强化"

func description() -> String:
	return "强化：对任意友方单位使用，使其获得+1/+1/+1/+1（四维各+1）"

func on_play(_card_data, ctx) -> bool:
	var cell = ctx.target_cell
	if cell == null or not cell.has_card:
		return true
	# 友敌判定：PVP 按 team_id；PVE 回退 is_enemy
	var local_team: String = ctx.game.team_of_player(ctx.game.local_player_id) \
		if ctx.game != null else ""
	if cell.is_hostile_to(local_team):
		return true
	for s in Orientation.SIDES:
		cell.health[s] += BUFF
	if cell.has_method("_update_hp_labels"):
		cell._update_hp_labels()
	return true
