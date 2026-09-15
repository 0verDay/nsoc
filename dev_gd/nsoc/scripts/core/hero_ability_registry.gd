extends Node

# HeroAbilityRegistry —— 显式注册 res://scripts/abilities/*.gd。
# 作为 autoload 单例，名字 "HeroAbilities"。
#
# 显式表理由同 EffectRegistry（重构文档.md §3.4-3）：无目录扫描、顺序确定、
# 漏登记由 CI 的 tools/ci/check_content.py 拦下。

const ABILITIES_DIR := "res://scripts/abilities/"

## 显式注册表：新增技能脚本必须在此登记，路径按字典序排列。
const ABILITY_PATHS: Array = [
	"res://scripts/abilities/aid_fancheng_ability.gd",
	"res://scripts/abilities/caocao_archery.gd",
	"res://scripts/abilities/die_hard_display.gd",
	"res://scripts/abilities/first_arrow_ability.gd",
	"res://scripts/abilities/flood_dam_ability.gd",
	"res://scripts/abilities/flood_strategy_hero.gd",
	"res://scripts/abilities/qiaobian_ability.gd",
	"res://scripts/abilities/reinforce_camp_ability.gd",
	"res://scripts/abilities/restart.gd",
	"res://scripts/abilities/straight_in_ability.gd",
	"res://scripts/abilities/surrender_ability.gd",
	"res://scripts/abilities/test_discard.gd",
	"res://scripts/abilities/weishan_ability.gd",
	"res://scripts/abilities/xiefang_ability.gd",
	"res://scripts/abilities/yi_yong_jun.gd",
]

signal ability_used(ability_id: String)
signal turn_reset

var _instances: Dictionary = {}     # id -> HeroAbility 实例
var _used_this_turn: Dictionary = {} # id -> true

func _ready() -> void:
	_register_explicit()

func _register_explicit() -> void:
	for path in ABILITY_PATHS:
		var script := load(String(path)) as Script
		if script == null:
			push_error("HeroAbilityRegistry: failed to load %s" % path)
			continue
		var stem: String = String(path).get_file().get_basename()
		_instances[stem] = script.new()

func has(ability_id: String) -> bool:
	return _instances.has(ability_id)


## 取技能实例。权威端需要单独读 cost()/once_per_turn() 并自行管理费用与回合限制，
## 因此除了 activate()（客户端路径）之外再暴露一个只读取值口。
func get_instance(ability_id: String):
	return _instances.get(ability_id)

## 已注册的全部 id（字典序，确定性输出）。
func ids() -> Array:
	var out: Array = []
	for k in _instances.keys():
		out.append(String(k))
	out.sort()
	return out


func get_display_name(ability_id: String) -> String:
	var inst = _instances.get(ability_id)
	if inst and inst.has_method("display_name"):
		return inst.display_name()
	return ability_id

func get_description(ability_id: String) -> String:
	var inst = _instances.get(ability_id)
	if inst and inst.has_method("description"):
		return inst.description()
	return ""


func can_activate(ability_id: String, ctx) -> bool:
	var inst = _instances.get(ability_id)
	if inst == null:
		return false
	if inst.has_method("can_activate"):
		return bool(inst.can_activate(ctx))
	return true

# 激活技能。返回 true 表示已成功激活并扣费由 ability 自行负责。
func activate(ability_id: String, ctx) -> bool:
	var inst = _instances.get(ability_id)
	if inst == null:
		return false
	if not can_activate(ability_id, ctx):
		return false
	if not Game.mana.spend(int(inst.cost())):
		return false
	if inst.has_method("once_per_turn") and bool(inst.once_per_turn()):
		_used_this_turn[ability_id] = true
	ability_used.emit(ability_id)
	if inst.has_method("on_activate"):
		await inst.on_activate(ctx)
	return true

# 是否本回合已用过。
func is_used_this_turn(ability_id: String) -> bool:
	return _used_this_turn.get(ability_id, false)

# 清除单个技能的本回合使用记录（用于技能取消后允许重试）。
func clear_turn_usage(ability_id: String) -> void:
	_used_this_turn.erase(ability_id)

# 新回合开始时清空"本回合已用"计数。由 main.gd 在 mana.start_new_turn 后调用。
func reset_turn_usage() -> void:
	_used_this_turn.clear()
	turn_reset.emit()
