extends Effect

# 屯扎：所在英雄回合开始时，所有友方单位四维各 +1。
# 由 HeroAbility 子类驱动，本脚本仅作注册/显示用。

func id() -> String:
	return "reinforce_camp"

func display_name() -> String:
	return "屯扎"

func description() -> String:
	return "屯扎：回合开始时，所有友方单位四维各 +1"
