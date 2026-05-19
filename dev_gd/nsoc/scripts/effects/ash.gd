extends RefCounted

func display_name() -> String:
	return "灰烬"

func description() -> String:
	return "灰烬：死亡后从游戏中除外"

func on_death(card_data, main_node: Node) -> bool:
	main_node.banished.append(card_data)
	return true
