extends HeroAbility

# 受降——于禁专属被动。
# 英雄被击败时：
#   1. 使「威震华夏·关羽」（player_main 英雄）满血
#   2. 玩家侧所有单位四维恢复至初始值（cell.max_health）
# 不可主动激活，由 ScriptedEvents trigger 在 hero_died 时调用。

func id() -> String:
	return "surrender_ability"

func display_name() -> String:
	return "受降"

func description() -> String:
	return "受降：英雄被击败后，使「威震华夏·关羽」满血，玩家侧所有单位四维恢复初始值"

func can_activate(_ctx) -> bool:
	return false

static func trigger(game_node: Node) -> void:
	if game_node == null or game_node.registry == null:
		return
	# 1. 关羽英雄满血
	var player_slot: BoardSlot = game_node.main_player_slot()
	if player_slot != null and player_slot.hero != null:
		player_slot.hero.heal_full()

	# 2. 玩家侧所有单位四维恢复初始值
	for slot in game_node.registry.by_faction(BoardSlot.FACTION_PLAYER):
		if slot.board == null:
			continue
		for cell in slot.board.grid_cells.values():
			if not is_instance_valid(cell) or not cell.has_card or cell.is_enemy:
				continue
			for s in Orientation.SIDES:
				cell.health[s] = cell.max_health[s]
			if cell.has_method("_update_hp_labels"):
				cell._update_hp_labels()
