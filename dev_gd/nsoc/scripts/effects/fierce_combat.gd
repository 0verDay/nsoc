extends Effect

# 酣战：击杀一个敌人后，本单位四维各 +1。
# 一次攻击同时击杀 N 个敌人则四维各 +N。
# 由 PlayController.handle_kills 在 attacker 仍存活时触发 on_kill。

const BUFF_PER_KILL: int = 1

func id() -> String:
	return "fierce_combat"

func display_name() -> String:
	return "酣战"

func description() -> String:
	return "酣战：击杀敌方单位后，四维各+1"

func on_kill(attacker_cell, victim_cells: Array, _ctx) -> void:
	if attacker_cell == null or not attacker_cell.has_card:
		return
	if victim_cells.is_empty():
		return
	var delta: int = BUFF_PER_KILL * victim_cells.size()
	for d in attacker_cell.health.keys():
		attacker_cell.health[d] += delta
	if attacker_cell.has_method("_update_hp_labels"):
		attacker_cell._update_hp_labels()
