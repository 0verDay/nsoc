extends Effect

# 突围：入场时，相邻格每有一个敌方单位，自身攻击力 +1，四维各 +1。
# 由 PlayController 在 set_card 之后调用 on_play，ctx.target_cell = 自身落点 cell。

const BUFF_PER_ENEMY: int = 1

func id() -> String:
	return "breakout"

func display_name() -> String:
	return "突围"

func description() -> String:
	return "突围：入场时，相邻格每有一个敌方单位，获得+1攻击力和+1四维"

func on_play(_card_data, ctx) -> void:
	var cell = ctx.target_cell
	if cell == null or not cell.has_card:
		return
	var enemies: Array = ctx.get_adjacent_enemies(cell)
	var n: int = enemies.size()
	if n <= 0:
		return
	var buff: int = BUFF_PER_ENEMY * n
	cell.attack += buff
	for s in Orientation.SIDES:
		cell.health[s] += buff
	if cell.has_method("_update_hp_labels"):
		cell._update_hp_labels()
	if cell.has_method("_update_atk_label"):
		cell._update_atk_label()
