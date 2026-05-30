extends Node

# ActionRegistry —— 启动期扫描 res://scripts/actions/*.gd 自动注册。
# 作为 autoload 单例，名字 "Actions"。
# 用法：await Actions.run("spawn_unit", params, ctx)
#
# Action 脚本规范（与 Effect 同款 duck-typing）：
#   func id() -> String        唯一 ID，与文件名 stem 一致
#   func run(params, ctx)      执行逻辑（可含 await）

const ACTIONS_DIR := "res://scripts/actions/"

var _instances: Dictionary = {}  # id -> action 实例

func _ready() -> void:
	_scan_and_register()

func _scan_and_register() -> void:
	var dir := DirAccess.open(ACTIONS_DIR)
	if dir == null:
		push_warning("ActionRegistry: cannot open %s" % ACTIONS_DIR)
		return
	var seen: Dictionary = {}
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir():
			var ext: String = ""
			if   fname.ends_with(".gd"):     ext = ".gd"
			elif fname.ends_with(".gdc"):    ext = ".gdc"
			elif fname.ends_with(".remap"):  ext = ".remap"
			if ext != "":
				var stem: String = fname.substr(0, fname.length() - ext.length())
				if ext == ".remap" and stem.ends_with(".gd"):
					stem = stem.substr(0, stem.length() - 3)
				if not seen.has(stem):
					seen[stem] = true
					var path := ACTIONS_DIR + stem + ".gd"
					var script := load(path) as Script
					if script == null:
						push_warning("ActionRegistry: failed to load %s" % path)
					else:
						var inst = script.new()
						if inst.has_method("id"):
							var aid: String = inst.id()
							_instances[aid] = inst
		fname = dir.get_next()
	dir.list_dir_end()

func has(action_id: String) -> bool:
	return _instances.has(action_id)

# 执行一个 action。params = action 字典（含 "type" 等字段），ctx = 运行时上下文。
# 若 action 脚本含 await，调用方必须 await 此函数。
func run(action_id: String, params: Dictionary, ctx: Dictionary) -> void:
	var inst = _instances.get(action_id)
	if inst == null:
		push_warning("ActionRegistry: unknown action id: " + action_id)
		return
	if inst.has_method("run"):
		await inst.run(params, ctx)
