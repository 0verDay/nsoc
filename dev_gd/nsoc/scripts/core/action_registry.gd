extends Node

# ActionRegistry —— 显式注册 res://scripts/actions/*.gd。
# 作为 autoload 单例，名字 "Actions"。
# 用法：await Actions.run("spawn_unit", params, ctx)
#
# Action 脚本规范（与 Effect 同款 duck-typing）：
#   func id() -> String        唯一 ID，与文件名 stem 一致
#   func run(params, ctx)      执行逻辑（可含 await）
#
# 显式表理由同 EffectRegistry（重构文档.md §3.4-3）：无目录扫描、顺序确定、
# 漏登记由 CI 的 tools/ci/check_content.py 拦下。

const ACTIONS_DIR := "res://scripts/actions/"

## 显式注册表：新增 action 脚本必须在此登记，路径按字典序排列。
const ACTION_PATHS: Array = [
	"res://scripts/actions/add_board.gd",
	"res://scripts/actions/apply_soaked_to_all.gd",
	"res://scripts/actions/cast_spell.gd",
	"res://scripts/actions/damage_hero.gd",
	"res://scripts/actions/remove_board.gd",
	"res://scripts/actions/set_counter.gd",
	"res://scripts/actions/set_hero_flag.gd",
	"res://scripts/actions/show_dialogue.gd",
	"res://scripts/actions/spawn_unit.gd",
	"res://scripts/actions/trigger_ability.gd",
]

var _instances: Dictionary = {}  # id -> action 实例

func _ready() -> void:
	_register_explicit()

func _register_explicit() -> void:
	for path in ACTION_PATHS:
		var script := load(String(path)) as Script
		if script == null:
			push_error("ActionRegistry: failed to load %s" % path)
			continue
		var inst = script.new()
		if inst.has_method("id"):
			var aid: String = String(inst.id())
			_instances[aid] = inst
		else:
			push_error("ActionRegistry: %s 未实现 id()" % path)

func has(action_id: String) -> bool:
	return _instances.has(action_id)

## 已注册的全部 id（字典序，确定性输出）。
func ids() -> Array:
	var out: Array = []
	for k in _instances.keys():
		out.append(String(k))
	out.sort()
	return out

# 执行一个 action。params = action 字典（含 "type" 等字段），ctx = 运行时上下文。
# 若 action 脚本含 await，调用方必须 await 此函数。
func run(action_id: String, params: Dictionary, ctx: Dictionary) -> void:
	var inst = _instances.get(action_id)
	if inst == null:
		push_warning("ActionRegistry: unknown action id: " + action_id)
		return
	if inst.has_method("run"):
		await inst.run(params, ctx)
