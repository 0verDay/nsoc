extends Node

# EffectRegistry —— 显式注册 res://scripts/effects/*.gd。
# 作为 autoload 单例，名字建议为 "Effects"。
# 通过 Effects.get(id) 查表，无需每次 load + new。
#
# 为什么不用目录扫描（重构文档.md §3.4-3）：
#   1. 服务器无头装配不应依赖文件系统目录枚举；
#   2. 扫描顺序不确定 → 注册顺序不确定（潜在的不确定性来源）；
#   3. 显式表让"新增效果"成为一次可见的改动，漏登记由 CI 拦下
#      （tools/ci/check_content.py 校验"表与目录严格一致"）。

const EFFECTS_DIR := "res://scripts/effects/"

## 显式注册表：新增效果脚本必须在此登记，路径按字典序排列。
const EFFECT_PATHS: Array = [
	"res://scripts/effects/aid_fancheng.gd",
	"res://scripts/effects/ash.gd",
	"res://scripts/effects/assault_charge.gd",
	"res://scripts/effects/autophagy.gd",
	"res://scripts/effects/awe.gd",
	"res://scripts/effects/battle_hardened.gd",
	"res://scripts/effects/breakout.gd",
	"res://scripts/effects/charge.gd",
	"res://scripts/effects/destroy_unit.gd",
	"res://scripts/effects/die_hard.gd",
	"res://scripts/effects/discard_hand_card.gd",
	"res://scripts/effects/empower.gd",
	"res://scripts/effects/exhaust.gd",
	"res://scripts/effects/fierce_combat.gd",
	"res://scripts/effects/first_arrow.gd",
	"res://scripts/effects/flood_strategy_unit.gd",
	"res://scripts/effects/frail.gd",
	"res://scripts/effects/gain_mana_1.gd",
	"res://scripts/effects/gua_gu_liao_du.gd",
	"res://scripts/effects/inspire.gd",
	"res://scripts/effects/jue_di.gd",
	"res://scripts/effects/love_people.gd",
	"res://scripts/effects/ming_jin.gd",
	"res://scripts/effects/reinforce_camp.gd",
	"res://scripts/effects/soaked.gd",
	"res://scripts/effects/steadfast.gd",
	"res://scripts/effects/straight_in.gd",
	"res://scripts/effects/surrender.gd",
	"res://scripts/effects/terrify.gd",
	"res://scripts/effects/vigilance.gd",
	"res://scripts/effects/weaken.gd",
	"res://scripts/effects/yi_bing.gd",
]

var _instances: Dictionary = {}     # id -> Effect 实例
var _ready_done: bool = false

func _ready() -> void:
	_register_explicit()
	_ready_done = true

func _register_explicit() -> void:
	for path in EFFECT_PATHS:
		var script := load(String(path)) as Script
		if script == null:
			push_error("EffectRegistry: failed to load %s" % path)
			continue
		var stem: String = String(path).get_file().get_basename()
		_instances[stem] = script.new()

func has(eff_id: String) -> bool:
	return _instances.has(eff_id)

## 已注册的全部 id（字典序，确定性输出；供服务器与测试内省）。
func ids() -> Array:
	var out: Array = []
	for k in _instances.keys():
		out.append(String(k))
	out.sort()
	return out

func get_effect(eff_id: String):
	return _instances.get(eff_id)

func get_display_name(eff_id: String) -> String:
	var inst = _instances.get(eff_id)
	if inst and inst.has_method("display_name"):
		return inst.display_name()
	return eff_id

func get_description(eff_id: String) -> String:
	var inst = _instances.get(eff_id)
	if inst and inst.has_method("description"):
		return inst.description()
	return eff_id

# 取 effect 声明的目标类型（"" / "enemy_unit" / "friendly_unit" / "any_unit"）。
func get_target(eff_id: String) -> String:
	var inst = _instances.get(eff_id)
	if inst and inst.has_method("target"):
		return String(inst.target())
	return ""

# 返回 true = 执行成功；false = 玩家主动取消（装备不扣耐久）。
# on_play 可能是协程（含 await），必须 await 调用，否则 Godot 4 报警告且无法拿到返回值。
func trigger_play(eff_id: String, card_data, ctx) -> bool:
	var inst = _instances.get(eff_id)
	if inst and inst.has_method("on_play"):
		var result = await inst.on_play(card_data, ctx)
		# 兼容旧 on_play 返回 void（Callable 返回 null）
		if result == null or result == true:
			return true
		return false
	return true

func trigger_death(eff_id: String, card_data, ctx) -> bool:
	var inst = _instances.get(eff_id)
	if inst and inst.has_method("on_death"):
		return inst.on_death(card_data, ctx)
	return false

func trigger_kill(eff_id: String, attacker_cell, victim_cells: Array, ctx) -> void:
	var inst = _instances.get(eff_id)
	if inst and inst.has_method("on_kill"):
		await inst.on_kill(attacker_cell, victim_cells, ctx)

# 法术结算去向，返回 "" 时由调用者使用默认（入墓）。
func resolve_destination(eff_id: String, card_data, ctx) -> String:
	var inst = _instances.get(eff_id)
	if inst and inst.has_method("resolve_destination"):
		return inst.resolve_destination(card_data, ctx)
	return ""
