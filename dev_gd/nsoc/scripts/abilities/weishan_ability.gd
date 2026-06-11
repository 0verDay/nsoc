extends HeroAbility

# 围山（展示用）—— 街亭遗恨·马谡 专属被动。
# 实际免伤由 BoardSlot.damage_hero 中检查 HeroState.flags["die_hard"] 实现，
# 友方单位死亡 -1HP 由 chapters/jieting_*.json 的 unit_died trigger 调用
# damage_hero source=triggered（穿透 die_hard）实现。本脚本仅提供 UI 描述文本。

func id() -> String:
	return "weishan_ability"

func display_name() -> String:
	return "围山"

func description() -> String:
	return "围山：无法受到单位与法术的直接伤害；场上每有一个己方单位被消灭，失去 1 点血量。"

func cost() -> int:
	return 0

func can_activate(_ctx) -> bool:
	return false  # 纯被动，玩家不可激活
