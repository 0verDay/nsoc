extends Effect

# 直入：所在英雄回合开始时，所有友方单位获得「冲锋」。

func id() -> String:
	return "straight_in"

func display_name() -> String:
	return "直入"

func description() -> String:
	return "直入：回合开始时友方单位获得「冲锋」"
