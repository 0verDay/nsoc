extends Node

# ObjectiveRegistry —— 启动期扫描 res://scripts/objectives/*.gd 自动注册。
# 作为 autoload 单例，名字 "Objectives"。
# 仿 EffectRegistry / HeroAbilityRegistry，兼容 .gd / .gdc / .remap 三种文件形式。
#
# 战斗装载时由 GameContext.bootstrap 调用 setup_for_battle(level.objective) 激活；
# 完成时（turn_started 检查通过）发射 objective_completed 信号，由 main / test_main
# 连接到胜利展示路径。

const OBJECTIVES_DIR := "res://scripts/objectives/"

signal objective_completed

var _instances: Dictionary = {}     # type id -> Objective 实例

# 当前战斗激活的目标（每局至多一个）
var _active_type: String = ""
var _active_params: Dictionary = {}
var _completed: bool = false

func _ready() -> void:
	_scan_and_register()

func _scan_and_register() -> void:
	var dir := DirAccess.open(OBJECTIVES_DIR)
	if dir == null:
		push_warning("ObjectiveRegistry: cannot open %s" % OBJECTIVES_DIR)
		return
	var seen: Dictionary = {}
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir():
			var ext: String = ""
			if fname.ends_with(".gd"):
				ext = ".gd"
			elif fname.ends_with(".gdc"):
				ext = ".gdc"
			elif fname.ends_with(".remap"):
				ext = ".remap"
			if ext != "":
				var stem: String = fname.substr(0, fname.length() - ext.length())
				if ext == ".remap" and stem.ends_with(".gd"):
					stem = stem.substr(0, stem.length() - 3)
				# 跳过基类
				if stem == "objective":
					fname = dir.get_next()
					continue
				if not seen.has(stem):
					seen[stem] = true
					var path := OBJECTIVES_DIR + stem + ".gd"
					var script := load(path) as Script
					if script == null:
						push_warning("ObjectiveRegistry: failed to load %s" % path)
					else:
						var inst = script.new()
						_instances[stem] = inst
		fname = dir.get_next()
	dir.list_dir_end()

func has(type_id: String) -> bool:
	return _instances.has(type_id)

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
