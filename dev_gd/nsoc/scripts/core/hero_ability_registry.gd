extends Node

# HeroAbilityRegistry —— 启动期扫描 res://scripts/abilities/*.gd 自动注册。
# 作为 autoload 单例，名字 "HeroAbilities"。
# 兼容 .gd / .gdc / .remap 三种文件形式（适配安卓导出 mode=2），仿 EffectRegistry。

const ABILITIES_DIR := "res://scripts/abilities/"

signal ability_used(ability_id: String)
signal turn_reset

var _instances: Dictionary = {}     # id -> HeroAbility 实例
var _used_this_turn: Dictionary = {} # id -> true

func _ready() -> void:
	_scan_and_register()

func _scan_and_register() -> void:
	var dir := DirAccess.open(ABILITIES_DIR)
	if dir == null:
		push_warning("HeroAbilityRegistry: cannot open %s" % ABILITIES_DIR)
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
				if not seen.has(stem):
					seen[stem] = true
					var path := ABILITIES_DIR + stem + ".gd"
					var script := load(path) as Script
					if script == null:
						push_warning("HeroAbilityRegistry: failed to load %s" % path)
					else:
						var inst = script.new()
						_instances[stem] = inst
		fname = dir.get_next()
	dir.list_dir_end()

func has(ability_id: String) -> bool:
	return _instances.has(ability_id)

func get_ability(ability_id: String):
	return _instances.get(ability_id)

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

func get_cost(ability_id: String) -> int:
	var inst = _instances.get(ability_id)
	if inst and inst.has_method("cost"):
		return int(inst.cost())
	return 0

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
