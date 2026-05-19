extends Effect

func id() -> String:
	return "ash"

func display_name() -> String:
	return "灰烬"

func description() -> String:
	return "灰烬：死亡后从游戏中除外"

func on_death(card_data, ctx) -> bool:
	ctx.banish_card(card_data)
	return true
