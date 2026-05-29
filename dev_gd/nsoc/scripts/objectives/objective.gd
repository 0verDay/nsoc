class_name Objective
extends RefCounted

# 战役胜利目标基类。子类放 res://scripts/objectives/，文件名 stem 即 type id。
# 由 ObjectiveRegistry 启动期扫描自动注册（仿 Effect / HeroAbility）。
#
# 章节 JSON 格式：
#   "objective": {"type": "<id>", "<param>": <value>, ...}
#
# 生命周期：
#   1. setup(params)         —— 战斗启动时调用一次
#   2. is_completed(params)  —— 由 ObjectiveRegistry 在 turn_started 时调用，
#                                 返回 true 即触发 objective_completed 信号

# 唯一 type id（默认取脚本文件名 stem）
func id() -> String:
	return ""

# UI 描述（详情面板/失败提示等使用）
func description(_params: Dictionary) -> String:
	return ""

# 战斗启动初始化（可选；用于子类内部计数器置零等）
func setup(_params: Dictionary) -> void:
	pass

# 是否已达成胜利条件
func is_completed(_params: Dictionary) -> bool:
	return false
