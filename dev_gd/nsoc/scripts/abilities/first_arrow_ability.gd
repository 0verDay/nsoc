extends HeroAbility

# 先射——庞德专属被动。
# 自身英雄所在盘（enemy_left）回合开始时，若「樊城·关羽」单位在场，
# 对其 front 面造成 4 点伤害（单位伤害，不走 combat_system，直接扣血）。

func id() -> String:
	return "first_arrow_ability"

func display_name() -> String:
	return "先射"

func description() -> String:
	return "先射：回合开始时，若「樊城·关羽」在场，对其正面造成 4 点伤害"

func can_activate(_ctx) -> bool:
	return false

const TARGET_UNIT_NAME: String = "樊城·关羽"
const DAMAGE_AMOUNT: int = 4

static func trigger(game_node: Node) -> void:
	if game_node == null or game_node.registry == null:
		return
	# 扫描所有棋盘，找「樊城·关羽」单位（玩家方）
	for slot in game_node.registry.slots:
		if slot.board == null:
			continue
		for cell in slot.board.grid_cells.values():
			if not is_instance_valid(cell) or not cell.has_card:
				continue
			if cell.card_name != TARGET_UNIT_NAME:
				continue
			# 对其 front 面 -4（front = 玩家单位面向敌方的那面）
			cell.health["front"] -= DAMAGE_AMOUNT
			if cell.has_method("_update_hp_labels"):
				cell._update_hp_labels()
			cell.play_damage_effect()
			# 检查死亡
			var dead: bool = false
			for s in Orientation.SIDES:
				if cell.health[s] <= 0:
					dead = true
					break
			if dead and game_node.has_node("/root/Game") and Game.play != null:
				if cell.has_method("play_death_effect"):
					cell.play_death_effect()
				# 延迟一帧后走标准死亡流程
				Game.play.handle_unit_death(cell)
				if cell.has_card:
					cell.clear_card()
			return  # 只打第一个找到的
