extends Effect

# 获得 1 点当前费用（不超过当前回合上限）。装备"圣杯"用。

func id() -> String:
	return "gain_mana_1"

func display_name() -> String:
	return "增益"

func description() -> String:
	return "获得 1 点费用。"

func on_play(_card_data, _ctx) -> bool:
	if Game != null and Game.mana != null:
		Game.mana.gain(1)
	return true
