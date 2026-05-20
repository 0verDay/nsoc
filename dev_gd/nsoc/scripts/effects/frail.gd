extends Effect

# 虚弱：受到任意方向的伤害时，同步扣除四维的血量（伤害施加到所有四面）。
# 任一面血量 <=0 即视为阵亡。
#
# 实际伤害分发由 CombatSystem.attack_cells 在攻击结算时检查 effects 字段处理，
# 本脚本仅承载元数据 / 注册。

func id() -> String:
	return "frail"

func display_name() -> String:
	return "虚弱"

func description() -> String:
	return "虚弱：受到任意方向的伤害时，同步扣除四维的血量"
