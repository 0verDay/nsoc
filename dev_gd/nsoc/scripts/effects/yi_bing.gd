extends Effect

# 疑兵（展示用 + 标记）。
# 战斗机制（无法攻击 / 到达敌方底线自爆 / 被攻击时自爆 + 攻击者四维-2）
# 由 turn_system / combat_system 在后续迭代中按本 effect.id 检测实装，
# 当前脚本仅提供 UI 描述文本与注册占位。

func id() -> String:
	return "yi_bing"

func display_name() -> String:
	return "疑兵"

func description() -> String:
	return "疑兵：无法攻击；到达敌方底线时自我消灭；被攻击时自我消灭，并使该攻击者的四维各 -2。"
