class_name AiActionSink
extends RefCounted

# 落地接口：返回 bool 是否成功。LocalActionSink 内有 await 时为协程，调用方统一 await。
func apply(_action: AiAction) -> bool:
	return false

func submit_cross_choice(_slot_id: String, _row: int, _col: int, _target_slot_id: String) -> void:
	pass
