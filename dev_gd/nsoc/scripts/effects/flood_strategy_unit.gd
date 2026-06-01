extends Effect

# 水攻（单位版）：玩家回合开始时，所有敌方单位获得"浸水"。
# 挂在"樊城·关羽"单位卡上，由 TurnSystem 的 turn_started 信号驱动。
# 本脚本仅承载元数据/注册，实际触发逻辑在 WaterAttackUnitDriver 中。

func id() -> String:
	return "flood_strategy_unit"

func display_name() -> String:
	return "水攻"

func description() -> String:
	return "水攻：玩家回合开始时，所有敌方单位获得「浸水」（受伤即灭，一次性）"
