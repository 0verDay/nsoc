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

func on_play(_card_data, ctx) -> void:
	var cell = ctx.target_cell
	if cell == null or not cell.has_card:
		return
	if cell.is_enemy:
		return
	cell.health.top += BUFF
	cell.health.bottom += BUFF
	cell.health.left += BUFF
	cell.health.right += BUFF
	if cell.has_method("_update_hp_labels"):
		cell._update_hp_labels()
