extends RefCounted

# apply_soaked_to_all action：给所有敌方单位施加"浸水"（供 flood_strategy_unit 触发）。
# 仅当场上存在持有 "flood_strategy_unit" 效果的玩家方单位时才执行。
#
# params:
#   "faction" : int  目标阵营（0=玩家方，1=敌方，默认 1）
#   "require_effect" : String  要求场上存在此效果的单位（空串=不检查）

func id() -> String:
	return "apply_soaked_to_all"

func run(params: Dictionary, _ctx: Dictionary) -> void:
	if not _has_game():
		return
	# 可选：要求场上存在特定 effect 的单位
	var require_eff: String = String(params.get("require_effect", ""))
	if require_eff != "" and not _has_unit_with_effect(require_eff):
		return

	var faction: int = int(params.get("faction", 1))
	var is_enemy: bool = faction == 1
	# 遍历全场所有棋盘，含已跨入友方盘的敌方单位
	for slot in Game.registry.slots:
		if slot.board == null:
			continue
		for cell in slot.board.grid_cells.values():
			if not is_instance_valid(cell) or not cell.has_card:
				continue
			if cell.is_enemy != is_enemy:
				continue
			if not cell.effects.has("soaked"):
				cell.effects.append("soaked")
			if cell.has_node("InnerPanel"):
				var inner = cell.get_node("InnerPanel")
				EffectBadgeFactory.refresh(inner.get_node_or_null("EffectBadges"), cell.effects)
			# effects_changed：只刷新已开面板，不弹出
			cell.effects_changed.emit({
				"name": cell.card_name, "attack": cell.attack,
				"health": cell.health, "effects": cell.effects,
			})

static func _has_unit_with_effect(eff_id: String) -> bool:
	if not _has_game():
		return false
	for slot in Game.registry.slots:
		if slot.board == null:
			continue
		for cell in slot.board.grid_cells.values():
			if is_instance_valid(cell) and cell.has_card and cell.effects.has(eff_id):
				return true
	return false

static func _has_game() -> bool:
	var loop = Engine.get_main_loop()
	return loop != null and loop.root != null and loop.root.has_node("/root/Game")
