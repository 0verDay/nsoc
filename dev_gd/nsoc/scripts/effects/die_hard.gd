extends Effect

# 死守：持有者英雄免疫"单位直伤"和"法术直伤"。
# 通过 HeroState.flags["die_hard"] 标志控制，拦截在 BoardSlot.damage_hero 内。
# 可被"决堤"法术永久剥夺（设 flags["die_hard"] = false）。

func id() -> String:
	return "die_hard"

func display_name() -> String:
	return "死守"

func description() -> String:
	return "死守：免疫单位直接伤害与法术直接伤害（不免疫触发型效果伤害）"

# 此 effect 施加给英雄时注册到 HeroState.flags，而非 cell.effects。
# 实际不出现在 cell 上，on_play / on_death 均不使用。
