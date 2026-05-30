extends HeroAbility

# 曹操专属技能描述（展示用）。
# 实际法术施放由 SpellCasterSystem 自动驱动，本脚本仅提供 UI 文本。
# 无费用、无激活逻辑，不会出现在玩家技能栏。

func id() -> String:
	return "caocao_archery"

func display_name() -> String:
	return "箭阵"

func description() -> String:
	return "箭阵：每回合对最前方的玩家方单位释放「放箭」，使其四维各-1。"

func can_activate(_ctx) -> bool:
	return false  # 敌方被动技能，玩家不可激活
