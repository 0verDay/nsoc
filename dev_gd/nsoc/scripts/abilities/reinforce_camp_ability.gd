extends HeroAbility

# 屯扎——于禁专属被动。
# 自身英雄所在盘（enemy_right）回合开始时，己方（ENEMY 阵营）所有单位四维各 +1。
# 驱动由 ScriptedEvents board_events 在 turn_started 信号触发。

func id() -> String:
	return "reinforce_camp_ability"

func display_name() -> String:
	return "屯扎"

func description() -> String:
	return "屯扎：回合开始时，所有友方单位四维各 +1"

func can_activate(_ctx) -> bool:
	return false

static func trigger(game_node: Node) -> void:
	if game_node == null or game_node.registry == null:
		return
	for slot in game_node.registry.by_faction(BoardSlot.FACTION_ENEMY):
		if slot.board == null:
			continue
		var local_team: String = game_node.team_of_player(game_node.local_player_id)
		for cell in slot.board.grid_cells.values():
			if not is_instance_valid(cell) or not cell.has_card or not cell.is_hostile_to(local_team):
				continue
			for s in Orientation.SIDES:
				cell.health[s] += 1
			if cell.has_method("_update_hp_labels"):
				cell._update_hp_labels()
