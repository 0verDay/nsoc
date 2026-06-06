extends HeroAbility

# 直入——徐晃专属被动。
# 自身所在盘（enemy_xuhuang）回合开始时：全场所有敌方单位（含跨入玩家半场者）获得「冲锋」。
# steadfast 单位不受影响。

func id() -> String:
	return "straight_in_ability"

func display_name() -> String:
	return "直入"

func description() -> String:
	return "直入：回合开始时友方单位获得「冲锋」"

func can_activate(_ctx) -> bool:
	return false

# 回合开始：全场所有敌方单位获得 charge（含已跨入玩家半场的单位）
static func trigger_start(game_node: Node) -> void:
	if game_node == null or game_node.registry == null:
		return
	var xuhuang_slot: BoardSlot = game_node.registry.get_by_id("enemy_xuhuang")
	if xuhuang_slot == null or xuhuang_slot.hero == null or xuhuang_slot.hero.is_dead:
		return
	for slot in game_node.registry.slots:
		if slot.board == null:
			continue
		var local_team: String = game_node.team_of_player(game_node.local_player_id)
		for cell in slot.board.grid_cells.values():
			if not is_instance_valid(cell) or not cell.has_card or not cell.is_hostile_to(local_team):
				continue
			if cell.effects.has("steadfast"):
				continue
			if not cell.effects.has("charge"):
				cell.effects.append("charge")
			_refresh_cell_display(cell)

# 刷新格子徽章 + 若详情面板正在展示该单位则同步更新描述（不弹出面板）
static func _refresh_cell_display(cell) -> void:
	if not is_instance_valid(cell):
		return
	if cell.has_node("InnerPanel"):
		var inner = cell.get_node("InnerPanel")
		EffectBadgeFactory.refresh(inner.get_node_or_null("EffectBadges"), cell.effects)
	# effects_changed：只刷新已开面板，不触发弹出
	cell.effects_changed.emit({
		"name": cell.card_name, "attack": cell.attack,
		"health": cell.health, "effects": cell.effects,
	})
