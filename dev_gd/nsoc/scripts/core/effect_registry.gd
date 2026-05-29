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
	var seen: Dictionary = {}
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir():
			# 兼容三种情形：源码 .gd / 字节码 .gdc / 重映射占位 .remap
			# 安卓导出 script_export_mode=2 时实际只剩 .gdc + .remap。
			var ext: String = ""
			if fname.ends_with(".gd"):
				ext = ".gd"
			elif fname.ends_with(".gdc"):
				ext = ".gdc"
			elif fname.ends_with(".remap"):
				ext = ".remap"
			if ext != "":
				var stem: String = fname.substr(0, fname.length() - ext.length())
				# .remap 形如 foo.gd.remap → 去掉再剥一次 .gd
				if ext == ".remap" and stem.ends_with(".gd"):
					stem = stem.substr(0, stem.length() - 3)
				if stem == "effect_utils":
					fname = dir.get_next()
					continue
				if not seen.has(stem):
					seen[stem] = true
					var path := EFFECTS_DIR + stem + ".gd"
					var script := load(path) as Script
					if script == null:
						push_warning("EffectRegistry: failed to load %s" % path)
					else:
						var inst = script.new()
						_instances[stem] = inst
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
