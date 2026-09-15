extends Node

# ObjectiveRegistry —— 显式注册 res://scripts/objectives/*.gd（不含基类 objective.gd）。
# 作为 autoload 单例，名字 "Objectives"。
#
# 显式表理由同 EffectRegistry（重构文档.md §3.4-3）：无目录扫描、顺序确定、
# 漏登记由 CI 的 tools/ci/check_content.py 拦下。
#
# 战斗装载时由 GameContext.bootstrap 调用 setup_for_battle(level.objective) 激活；
# 完成时（turn_started 检查通过）发射 objective_completed 信号，由 main / test_main
# 连接到胜利展示路径。

const OBJECTIVES_DIR := "res://scripts/objectives/"

## 显式注册表：新增关卡目标必须在此登记（基类 objective.gd 不入表）。
const OBJECTIVE_PATHS: Array = [
	"res://scripts/objectives/survive_turns.gd",
]

signal objective_completed

var _instances: Dictionary = {}     # type id -> Objective 实例

# 当前战斗激活的目标（每局至多一个）
var _active_type: String = ""
var _active_params: Dictionary = {}
var _completed: bool = false

func _ready() -> void:
	_register_explicit()

func _register_explicit() -> void:
	for path in OBJECTIVE_PATHS:
		var script := load(String(path)) as Script
		if script == null:
			push_error("ObjectiveRegistry: failed to load %s" % path)
			continue
		var stem: String = String(path).get_file().get_basename()
		_instances[stem] = script.new()

func has(type_id: String) -> bool:
	return _instances.has(type_id)

## 已注册的全部 id（字典序，确定性输出）。
func ids() -> Array:
	var out: Array = []
	for k in _instances.keys():
		out.append(String(k))
	out.sort()
	return out

func get_objective(type_id: String):
	return _instances.get(type_id)

# ── 战斗装载 ────────────────────────────────────────────────────────
# objective_data: 章节 JSON 的 "objective" 字段（{"type":..., 其它参数}）。
# 空 / 无效 type 时清空当前目标，不报错（旧关卡兼容）。
func setup_for_battle(objective_data: Dictionary) -> void:
	clear()
	var t: String = String(objective_data.get("type", ""))
	if t == "" or not _instances.has(t):
		return
	_active_type = t
	_active_params = objective_data.duplicate()
	var inst: Objective = _instances[t]
	inst.setup(_active_params)
	# 接 turn_ended 信号，每回合结算完毕后检查胜利条件
	if Game != null and Game.turn != null:
		if not Game.turn.turn_ended.is_connected(_check_completion):
			Game.turn.turn_ended.connect(_check_completion)

# 清空当前目标（退出到菜单时调用，避免下局脏读）
func clear() -> void:
	_active_type = ""
	_active_params = {}
	_completed = false
	if Game != null and Game.turn != null \
			and Game.turn.turn_ended.is_connected(_check_completion):
		Game.turn.turn_ended.disconnect(_check_completion)

# turn_ended 回调：检查目标是否达成
func _check_completion() -> void:
	if _completed or _active_type == "":
		return
	var inst: Objective = _instances.get(_active_type)
	if inst == null:
		return
	if inst.is_completed(_active_params):
		_completed = true
		objective_completed.emit()

# 当前激活目标的描述（UI 用）
func current_description() -> String:
	if _active_type == "" or not _instances.has(_active_type):
		return ""
	return _instances[_active_type].description(_active_params)

func has_active() -> bool:
	return _active_type != ""

# 当前激活目标的进度文本（如 "5 / 15"），无则返回 ""。
func current_progress_text() -> String:
	if _active_type == "" or not _instances.has(_active_type):
		return ""
	return _instances[_active_type].progress_text(_active_params)
