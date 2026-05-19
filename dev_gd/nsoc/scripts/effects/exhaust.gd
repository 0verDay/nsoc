extends Effect

# 法术专用：使用后从游戏中除外（不进墓地）。
# 替代旧 main.gd 中 `if eff == "exhaust"` 的硬编码分支。

func id() -> String:
	return "exhaust"

func display_name() -> String:
	return "除外"

func description() -> String:
	return "除外：使用后从游戏中除外"

func resolve_destination(card_data, ctx) -> String:
	return "banish"
