class_name AiStrategy
extends RefCounted

# 决策接口。输入只读快照，输出按执行顺序排列的行动序列（含末尾 END_TURN）。
func decide(_view: AiGameView) -> Array:
	return [AiAction.end_turn()]

# 跨盘即时回调：返回目标盘 slot_id；"" = 走自动默认。
func choose_cross_target(_view: AiGameView, _cell) -> String:
	var slots := _view.opponent_slots()
	return String(slots[0].id) if not slots.is_empty() else ""
