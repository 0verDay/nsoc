class_name SidePanelManager
extends Node

# 牌堆/墓地/除外 三个右侧弹出面板，原 main.gd:234-400 迁移于此。

signal long_press_requested(payload)
signal long_press_canceled

var _parent: Control
var _ui_panels: Dictionary = {}      # name -> clip_node
var _current_open: String = ""

func setup(parent: Control) -> void:
	_parent = parent
	for p_name in ["deck", "grave", "banished"]:
		_ui_panels[p_name] = _build_panel(p_name)
	# 当任何堆变化且对应面板已打开，则即时刷新内容
	if has_node("/root/Game"):
		Game.deck.pile_changed.connect(_on_deck_pile_changed)

func _on_deck_pile_changed(pile_name: String) -> void:
	var map := {"draw": "deck", "graveyard": "grave", "banish": "banished"}
	if _current_open != "" and _current_open == map.get(pile_name, ""):
		_refresh_content(_current_open)

func _build_panel(p_name: String) -> Control:
	var clip_node := Control.new()
	clip_node.name = p_name + "_clip"
	_parent.add_child(clip_node)
	clip_node.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	clip_node.offset_left = -640
	clip_node.offset_right = -320
	clip_node.offset_top = 10
	clip_node.offset_bottom = -10
	clip_node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_node.clip_contents = true
	clip_node.visible = false

	var pnl := Panel.new()
	pnl.name = p_name + "_panel"
	clip_node.add_child(pnl)
	pnl.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	pnl.offset_left = 320
	pnl.offset_right = 640
	pnl.offset_top = 0
	pnl.offset_bottom = 0
	pnl.mouse_filter = Control.MOUSE_FILTER_STOP
	pnl.add_theme_stylebox_override("panel", ThemeFactory.panel(Color(0.94, 0.95, 0.96, 1.0), Color(1, 1, 1, 1.0), 1, 20))

	var lbl := Label.new()
	match p_name:
		"deck": lbl.text = "牌堆"
		"grave": lbl.text = "墓地"
		"banished": lbl.text = "除外"
	lbl.set_anchors_preset(Control.PRESET_TOP_WIDE)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 28)
	lbl.add_theme_color_override("font_color", Color(0.2, 0.2, 0.2, 1))
	lbl.offset_top = 20
	lbl.offset_bottom = 60
	pnl.add_child(lbl)

	var scroll := ScrollContainer.new()
	scroll.name = "Scroll"
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
	scroll.offset_top = 80
	scroll.offset_bottom = -20
	scroll.offset_left = 20
	scroll.offset_right = -20
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	pnl.add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.name = "ListVBox"
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 10)
	scroll.add_child(vbox)

	return clip_node

func _refresh_content(p_name: String) -> void:
	var clip_node: Control = _ui_panels[p_name]
	var pnl := clip_node.get_node(p_name + "_panel")
	var vbox := pnl.get_node("Scroll/ListVBox")
	for c in vbox.get_children():
		c.queue_free()

	if p_name == "deck":
		var counts := Game.deck.get_deck_counts()
		var names := counts.keys()
		names.sort()
		for n in names:
			vbox.add_child(_create_list_item(n + " x " + str(counts[n])))
	elif p_name == "grave":
		var grave := Game.deck.graveyard
		for i in range(grave.size() - 1, -1, -1):
			vbox.add_child(_create_list_item(grave[i].name))
	elif p_name == "banished":
		var ban := Game.deck.banished
		for i in range(ban.size() - 1, -1, -1):
			vbox.add_child(_create_list_item(ban[i].name))

func _create_list_item(text: String) -> Button:
	var b := Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", 22)
	b.add_theme_color_override("font_color", Color(0.2, 0.2, 0.2, 1))
	b.add_theme_color_override("font_hover_color", Color(0.1, 0.1, 0.1, 1))
	b.add_theme_color_override("font_pressed_color", Color(0.0, 0.0, 0.0, 1))

	var sb := StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.6)
	sb.corner_radius_top_left = 8
	sb.corner_radius_top_right = 8
	sb.corner_radius_bottom_left = 8
	sb.corner_radius_bottom_right = 8
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10

	var sb_hover := sb.duplicate()
	sb_hover.bg_color = Color(1, 1, 1, 0.8)
	var sb_pressed := sb.duplicate()
	sb_pressed.bg_color = Color(0.9, 0.9, 0.9, 0.9)

	b.add_theme_stylebox_override("normal", sb)
	b.add_theme_stylebox_override("hover", sb_hover)
	b.add_theme_stylebox_override("pressed", sb_pressed)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())

	b.button_down.connect(func(): long_press_requested.emit({"name": text}))
	b.button_up.connect(func(): long_press_canceled.emit())
	b.mouse_exited.connect(func(): long_press_canceled.emit())
	return b

func toggle(p_name: String) -> void:
	if _current_open == p_name:
		close_current()
	else:
		if _current_open != "":
			# 立刻收起旧的
			var old_clip: Control = _ui_panels[_current_open]
			old_clip.visible = false
			var old_pnl := old_clip.get_node(_current_open + "_panel")
			old_pnl.offset_left = 320
			old_pnl.offset_right = 640
		_open(p_name)

func _open(p_name: String) -> void:
	_current_open = p_name
	_refresh_content(p_name)
	var clip_node: Control = _ui_panels[p_name]
	clip_node.visible = true
	var pnl := clip_node.get_node(p_name + "_panel")
	var tween := get_tree().create_tween()
	tween.tween_property(pnl, "offset_left", 0.0, 0.3).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(pnl, "offset_right", 320.0, 0.3).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

func close_current() -> void:
	if _current_open == "":
		return
	var clip_node: Control = _ui_panels[_current_open]
	_current_open = ""
	var pnl := clip_node.get_node(clip_node.name.replace("_clip", "_panel"))
	var tween := get_tree().create_tween()
	tween.tween_property(pnl, "offset_left", 320.0, 0.3).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.parallel().tween_property(pnl, "offset_right", 640.0, 0.3).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_callback(func(): clip_node.visible = false)

func is_panel_hit(global_pos: Vector2) -> bool:
	if _current_open == "":
		return false
	var clip_node: Control = _ui_panels[_current_open]
	var pnl := clip_node.get_node(_current_open + "_panel") as Control
	return pnl.get_global_rect().has_point(global_pos)

func has_open_panel() -> bool:
	return _current_open != ""

func get_clip_nodes() -> Array:
	return _ui_panels.values()
