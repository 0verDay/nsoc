extends Effect

# 坚守：本单位不会在阶段推进时主动移动（仍可攻击邻敌、攻击英雄）。
# 实际拦截在 TurnSystem._run_phase 推进分支按 effects.has("steadfast") 判定。
# 本脚本仅承载元数据/注册。

func id() -> String:
	return "steadfast"

func display_name() -> String:
	return "坚守"

func description() -> String:
	return "坚守：本单位不会主动移动"
