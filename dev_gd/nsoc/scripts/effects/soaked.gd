extends Effect

# 浸水：受到任意伤害后立即被消灭，伤害后状态消失（一次性）。
# 实际拦截在 CombatSystem.attack_cells 扣血之后、死亡判定之前：
#   若 defender.effects 含 "soaked"，强制将四面血量设为 0，确保当回合死亡判定成立。
# 触发后从 effects 数组移除，保证只触发一次。

func id() -> String:
	return "soaked"

func display_name() -> String:
	return "浸水"

func description() -> String:
	return "浸水：受到伤害后立即被消灭（一次性）"
