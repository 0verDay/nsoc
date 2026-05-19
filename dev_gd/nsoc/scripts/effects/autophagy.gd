extends RefCounted

func display_name() -> String:
	return "自噬"

func description() -> String:
	return "自噬：使用该牌时对己方英雄造成x点伤害(x为本场游戏中触发自噬效果的次数)"

func on_play(card_data, main_node: Node) -> void:
	var dmg = main_node.autophagy_counter
	if dmg > 0:
		main_node.apply_damage_to_hero(false, dmg)
	main_node.autophagy_counter += 1
