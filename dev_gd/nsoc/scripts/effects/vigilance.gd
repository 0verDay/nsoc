extends Effect

# 警戒：非己方回合中，若有非己方单位移动进入相邻格（即己方的攻击范围），
# 持有警戒的己方单位立即对其发动一次攻击。
#
# 触发由 TurnSystem 在每次单位完成移动后主动扫描周围发起，
# 本脚本仅承载元数据 (display_name / description) 与注册标识。

func id() -> String:
	return "vigilance"

func display_name() -> String:
	return "警戒"

func description() -> String:
	return "警戒：非己方回合时，若有单位移动进入自己的攻击范围，对其发动一次攻击"
