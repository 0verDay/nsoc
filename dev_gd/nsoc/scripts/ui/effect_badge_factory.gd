class_name EffectBadgeFactory
extends RefCounted

# 生成效果徽章 PanelContainer，cell/hand_card 共用。

static func create(eff_id: String) -> PanelContainer:
	var badge_name: String = _resolve_name(eff_id)

	var vertical_text := ""
	for i in range(badge_name.length()):
		vertical_text += badge_name[i]
		if i < badge_name.length() - 1:
			vertical_text += "\n"

	var panel := PanelContainer.new()
	panel.add_theme_stylebox_override("panel", ThemeFactory.badge())
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var lbl := Label.new()
	lbl.text = vertical_text
	lbl.add_theme_color_override("font_color", Color.WHITE)
	lbl.add_theme_font_size_override("font_size", 12)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	panel.add_child(lbl)
	return panel

static func refresh(container: Node, effects: Array) -> void:
	if container == null:
		return
	for c in container.get_children():
		c.queue_free()
	for eff in effects:
		container.add_child(create(eff))

static func _resolve_name(eff_id: String) -> String:
	# autoload "Effects" 在 GDScript 中作为全局标识符可直接访问。
	# 为防止单元测试场景未配置 autoload，做一次空守卫。
	var loop := Engine.get_main_loop()
	if loop is SceneTree:
		var root := (loop as SceneTree).root
		var node := root.get_node_or_null("Effects")
		if node and node.has_method("get_display_name"):
			return node.get_display_name(eff_id)
	return eff_id
