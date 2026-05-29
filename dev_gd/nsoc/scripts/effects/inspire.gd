extends Effect

# 鼓舞：对目标友方单位使用，使其攻击力 +1。
# 由法术"鼓舞"的 on_play 通过 ctx.target_cell 拿目标。

const BUFF: int = 1

func id() -> String:
	return "inspire"

func display_name() -> String:
	return "鼓舞"

func description() -> String:
	return "鼓舞：对任意友方单位使用，使其攻击力 +%d。" % BUFF

func on_play(_card_data, ctx) -> bool:
	var cell = ctx.target_cell
	if cell == null or not cell.has_card:
		return true
	if cell.is_enemy:
		return true
	cell.attack += BUFF
	if cell.has_method("_update_atk_label"):
		cell._update_atk_label()
	return true
