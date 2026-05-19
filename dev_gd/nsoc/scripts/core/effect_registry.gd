extends Node

# EffectRegistry —— 启动期扫描 res://scripts/effects/*.gd 自动注册。
# 作为 autoload 单例，名字建议为 "Effects"。
# 通过 Effects.get(id) 查表，无需每次 load + new。

const EFFECTS_DIR := "res://scripts/effects/"

var _instances: Dictionary = {}     # id -> Effect 实例
var _ready_done: bool = false

func _ready() -> void:
	_scan_and_register()
	_ready_done = true

func _scan_and_register() -> void:
	var dir := DirAccess.open(EFFECTS_DIR)
	if dir == null:
		push_warning("EffectRegistry: cannot open %s" % EFFECTS_DIR)
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.ends_with(".gd"):
			# 跳过工具类自身（即将下线的 effect_utils.gd 仍存在则忽略）
			if fname == "effect_utils.gd":
				fname = dir.get_next()
				continue
			var eff_id := fname.get_basename()
			var path := EFFECTS_DIR + fname
			var script := load(path) as Script
			if script == null:
				push_warning("EffectRegistry: failed to load %s" % path)
			else:
				var inst = script.new()
				if inst is Effect:
					_instances[eff_id] = inst
				else:
					# 兼容旧未继承 Effect 的脚本（仍走鸭子调用）
					_instances[eff_id] = inst
		fname = dir.get_next()
	dir.list_dir_end()

func has(eff_id: String) -> bool:
	return _instances.has(eff_id)

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

func trigger_play(eff_id: String, card_data, ctx) -> void:
	var inst = _instances.get(eff_id)
	if inst and inst.has_method("on_play"):
		inst.on_play(card_data, ctx)

func trigger_death(eff_id: String, card_data, ctx) -> bool:
	var inst = _instances.get(eff_id)
	if inst and inst.has_method("on_death"):
		return inst.on_death(card_data, ctx)
	return false

# 法术结算去向，返回 "" 时由调用者使用默认（入墓）。
func resolve_destination(eff_id: String, card_data, ctx) -> String:
	var inst = _instances.get(eff_id)
	if inst and inst.has_method("resolve_destination"):
		return inst.resolve_destination(card_data, ctx)
	return ""
