extends Effect

# 历战：本单位击杀敌方单位后，攻击力 +1。一次攻击同时击杀 N 个敌人则 +N。
# 在 attacker 仍存活时由 PlayController.handle_kills 触发 on_kill。

const BUFF_PER_KILL: int = 1

func id() -> String:
	return "battle_hardened"

func display_name() -> String:
	return "历战"

func description() -> String:
	return "历战：击杀敌方单位后，攻击力+1"

func on_kill(attacker_cell, victim_cells: Array, _ctx) -> void:
	if attacker_cell == null or not attacker_cell.has_card:
		return
	if victim_cells.is_empty():
		return
	attacker_cell.attack += BUFF_PER_KILL * victim_cells.size()
	if attacker_cell.has_method("_update_atk_label"):
		attacker_cell._update_atk_label()
