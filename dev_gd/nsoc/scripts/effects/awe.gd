extends Effect

# 威震：击杀敌方单位后，对该单位"原属盘"的英雄造成 1 点"triggered"伤害。
# 挂在"樊城·关羽"单位卡上，触发 on_kill。

func id() -> String:
	return "awe"

func display_name() -> String:
	return "威震"

func description() -> String:
	return "威震：击杀敌方单位后，对其所属阵营英雄造成 1 点伤害（可穿透死守）"

func on_kill(attacker_cell, victim_cells: Array, ctx) -> void:
	if victim_cells.is_empty():
		return
	# 对每个被击杀单位的"原属盘"英雄造成 1 点 triggered 伤害
	for snap in victim_cells:
		var slot_id: String = String(snap.get("owner_slot_id", snap.get("slot_id", "")))
		if slot_id == "":
			continue
		if ctx == null or ctx.game == null or ctx.game.registry == null:
			continue
		var slot: BoardSlot = ctx.game.registry.get_by_id(slot_id)
		if slot != null:
			slot.damage_hero(1, "triggered")
