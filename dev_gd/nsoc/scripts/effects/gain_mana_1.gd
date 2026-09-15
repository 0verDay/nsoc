extends Effect

# 获得 1 点当前费用（不超过当前回合上限）。装备"圣杯"用。

func id() -> String:
	return "gain_mana_1"

func display_name() -> String:
	return "增益"

func description() -> String:
	return "获得 1 点费用。"

func on_play(_card_data, ctx) -> bool:
	# 走 ctx：客户端回退到 Game.mana（行为不变），权威端用注入的费用镜像（服务器侧真的加费）
	if ctx != null:
		ctx.gain_mana(1)
	elif Game != null and Game.mana != null:
		Game.mana.gain(1)
	return true
