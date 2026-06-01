extends HeroAbility

# 死守（展示用）——樊城·曹仁 专属被动。
# 实际免伤由 BoardSlot.damage_hero 中检查 HeroState.flags["die_hard"] 实现。
# 本脚本仅提供 UI 描述文本，不可主动激活。

func id() -> String:
	return "die_hard_display"

func display_name() -> String:
	return "死守"

func description() -> String:
	return "死守：免疫单位直接伤害与法术直接伤害。援樊、蓄水等触发型效果可穿透。"

func cost() -> int:
	return 0

func can_activate(_ctx) -> bool:
	return false  # 纯被动，玩家不可激活
