extends Effect

# 先射：所在英雄回合开始时，若"樊城·关羽"单位在场，对其 front 面造成 4 点伤害。
# 挂在"樊城·庞德"英雄的 abilities 列表中，由 HeroAbility 子类驱动。
# 本脚本仅作注册/显示用。

func id() -> String:
	return "first_arrow"

func display_name() -> String:
	return "先射"

func description() -> String:
	return "先射：回合开始时，若「樊城·关羽」在场，对其 front 面造成 4 点伤害"
