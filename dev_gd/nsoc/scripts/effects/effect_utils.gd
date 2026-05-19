class_name EffectUtils
extends RefCounted

# 根据 effect id 获取脚本实例（找不到返回 null）
static func get_effect(eff_id: String):
	var script_path = "res://scripts/effects/%s.gd" % eff_id
	if ResourceLoader.exists(script_path):
		return load(script_path).new()
	return null

# 获取展示名（缺省回退到 id）
static func get_display_name(eff_id: String) -> String:
	var inst = get_effect(eff_id)
	if inst and inst.has_method("display_name"):
		return inst.display_name()
	return eff_id

# 获取描述文本（缺省回退到 id）
static func get_description(eff_id: String) -> String:
	var inst = get_effect(eff_id)
	if inst and inst.has_method("description"):
		return inst.description()
	return eff_id

# 触发 on_play 钩子
static func trigger_play(eff_id: String, card_data, main_node: Node) -> void:
	var inst = get_effect(eff_id)
	if inst and inst.has_method("on_play"):
		inst.on_play(card_data, main_node)

# 触发 on_death 钩子，返回是否被处理
static func trigger_death(eff_id: String, card_data, main_node: Node) -> bool:
	var inst = get_effect(eff_id)
	if inst and inst.has_method("on_death"):
		return inst.on_death(card_data, main_node)
	return false
