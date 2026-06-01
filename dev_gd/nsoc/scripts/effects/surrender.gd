extends Effect

# 受降：英雄被击败后，关羽英雄满血 + 玩家侧所有单位四维恢复至初始值。
# 由 HeroAbility 子类驱动，本脚本仅作注册/显示用。

func id() -> String:
	return "surrender"

func display_name() -> String:
	return "受降"

func description() -> String:
	return "受降：英雄被击败后，使「威震华夏·关羽」满血，并使玩家侧所有单位四维恢复初始值"
