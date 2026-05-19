extends Effect

func id() -> String:
	return "autophagy"

func display_name() -> String:
	return "自噬"

func description() -> String:
	return "自噬：使用该牌时对己方英雄造成x点伤害(x为本场游戏中触发自噬效果的次数)"

func on_play(card_data, ctx) -> void:
	var dmg: int = ctx.get_counter("autophagy", 0)
	if dmg > 0:
		ctx.damage_player_hero(dmg)
	ctx.inc_counter("autophagy", 1)
