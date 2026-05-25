class_name EnemySidePanelManager
extends Node

# 敌方"墓地 / 除外"两个顶部下拉面板。
# 与玩家侧 SidePanelManager 镜像：clip 限定可见区域为顶部半场，
# 内部 panel 从画面上方滑入，遮住敌方半场。

signal long_press_requested(payload)       # payload: {"name": "卡名"}
signal long_press_canceled

const PANEL_NAMES: PackedStringArray = ["enemy_grave", "enemy_banished"]
const PANEL_TITLES: Dictionary = {"enemy_grave": "敌方墓地", "enemy_banished": "敌方除外"}
const PILE_TO_PANEL: Dictionary = {"enemy_graveyard": "enemy_grave", "enemy_banish": "enemy_banished"}

# clip 区域 = 敌方半场（基于 Main.tscn 中 TopGridBg 范围扩边）
const CLIP_TOP: float = 60.0
const CLIP_BOTTOM_FROM_CENTER: float = 0.0   # 至画面垂直中线（viewport_height / 2）
const PANEL_WIDTH: float = 480.0
const PANEL_HEIGHT: float = 470.0
const SLIDE_DURATION: float = 0.3

var _parent: Control
var _center_x_offset: float = 0.0   # 面板水平中心相对视口中心的偏移（与 BOARD_SHIFT 同坐标系）
# panel_name -> {"clip": Control, "panel": Panel, "list": VBoxContainer}
var _ui_panels: Dictionary = {}
var _current_open: String = ""

func setup(parent: Control, center_x_offset: float = 0.0) -> void:
	_parent = parent
	_center_x_offset = center_x_offset
	for p_name in PANEL_NAMES:
		_ui_panels[p_name] = _build_panel(p_name)
	if has_node("/root/Game"):
		Game.deck.pile_changed.connect(_on_deck_pile_changed)

# 主棋盘在 test 动画后调用此方法跟随棋盘平移。
func update_clip_center_x(new_center_x: float) -> void:
	_center_x_offset = new_center_x
	for entry in _ui_panels.values():
		var clip: Control = entry.clip
		clip.offset_left  = new_center_x - PANEL_WIDTH / 2.0
		clip.offset_right = new_center_x + PANEL_WIDTH / 2.0

func _on_deck_pile_changed(pile_name: String) -> void:
	var mapped: String = PILE_TO_PANEL.get(pile_name, "")
	if _current_open != "" and _current_open == mapped:
		_refresh_content(_current_open)

func _build_panel(p_name: String) -> Dictionary:
	# clip：固定在敌方半场顶部，水平居中于 _center_x_offset。
	var clip_node := Control.new()
	clip_node.name = p_name + "_clip"
	_parent.add_child(clip_node)
	clip_node.set_anchors_preset(Control.PRESET_TOP_WIDE, false)
	clip_node.anchor_left = 0.5
	clip_node.anchor_right = 0.5
	clip_node.offset_left  = _center_x_offset - PANEL_WIDTH / 2.0
	clip_node.offset_right = _center_x_offset + PANEL_WIDTH / 2.0
	clip_node.offset_top = CLIP_TOP
	clip_node.offset_bottom = CLIP_TOP + PANEL_HEIGHT
	clip_node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_node.clip_contents = true
	clip_node.visible = false
	# 高 z_index 压住战斗动画 visual（visual.z_index = 100）。
	clip_node.z_index = 200

	# panel：在 clip 内从上方滑入。初始位置 offset_top = -PANEL_HEIGHT（隐藏在 clip 上方）。
	var pnl := Panel.new()
	pnl.name = p_name + "_panel"
	clip_node.add_child(pnl)
	pnl.set_anchors_preset(Control.PRESET_TOP_WIDE, false)
	pnl.offset_left = 0
	pnl.offset_right = 0
	pnl.offset_top = -PANEL_HEIGHT
	pnl.offset_bottom = 0
	pnl.mouse_filter = Control.MOUSE_FILTER_STOP
	pnl.add_theme_stylebox_override("panel", ThemeFactory.panel(Color(0.94, 0.95, 0.96, 1.0), Color(1, 1, 1, 1.0), 1, 20))

	var lbl := Label.new()
	lbl.text = PANEL_TITLES.get(p_name, p_name)
	lbl.set_anchors_preset(Control.PRESET_TOP_WIDE, false)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 28)
	lbl.add_theme_color_override("font_color", Color(0.2, 0.2, 0.2, 1))
	lbl.offset_top = 20
	lbl.offset_bottom = 60
	pnl.add_child(lbl)

	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	scroll.offset_top = 80
	scroll.offset_bottom = -20
	scroll.offset_left = 20
	scroll.offset_right = -20
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	pnl.add_child(scroll)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 10)
	scroll.add_child(vbox)

	# 拖动滚动支持（移动端）。
	var helper := DragScrollHelper.new()
	helper.name = "DragScroll"
	scroll.add_child(helper)
	helper.setup(scroll, Callable(self, "_emit_long_press_canceled"))

	return {"clip": clip_node, "panel": pnl, "list": vbox}

func _emit_long_press_canceled() -> void:
	long_press_canceled.emit()

func _refresh_content(p_name: String) -> void:
	var vbox: VBoxContainer = _ui_panels[p_name].list
	for c in vbox.get_children():
		c.queue_free()

	if p_name == "enemy_grave":
		var grave: Array = Game.deck.enemy_graveyard
		for i in range(grave.size() - 1, -1, -1):
			vbox.add_child(_create_list_item(grave[i].name, 1))
	elif p_name == "enemy_banished":
		var ban: Array = Game.deck.enemy_banished
		for i in range(ban.size() - 1, -1, -1):
			vbox.add_child(_create_list_item(ban[i].name, 1))

func _create_list_item(card_name: String, count: int) -> Button:
	var b := Button.new()
	b.text = card_name if count == 1 else card_name + " x " + str(count)
	b.set_meta("card_name", card_name)
	b.add_theme_font_size_override("font_size", 22)
	b.add_theme_color_override("font_color", Color(0.2, 0.2, 0.2, 1))
	b.add_theme_color_override("font_hover_color", Color(0.1, 0.1, 0.1, 1))
	b.add_theme_color_override("font_pressed_color", Color(0.0, 0.0, 0.0, 1))
	# PASS：让 ScrollContainer 仍能收到鼠标事件以实现拖动滚动
	b.mouse_filter = Control.MOUSE_FILTER_PASS

	var styles := ThemeFactory.list_item_styles()
	b.add_theme_stylebox_override("normal", styles.normal)
	b.add_theme_stylebox_override("hover", styles.hover)
	b.add_theme_stylebox_override("pressed", styles.pressed)
	b.add_theme_stylebox_override("focus", styles.focus)

	b.button_down.connect(_on_item_press.bind(b))
	b.button_up.connect(_on_item_release)
	b.mouse_exited.connect(_on_item_release)
	return b

func _on_item_press(btn: Button) -> void:
	long_press_requested.emit({"name": btn.get_meta("card_name", "")})

func _on_item_release() -> void:
	long_press_canceled.emit()

func toggle(p_name: String) -> void:
	if _current_open == p_name:
		close_current()
		return
	if _current_open != "":
		_snap_close(_current_open)
	_open(p_name)

func _snap_close(p_name: String) -> void:
	var entry: Dictionary = _ui_panels[p_name]
	entry.clip.visible = false
	entry.panel.offset_top = -PANEL_HEIGHT
	entry.panel.offset_bottom = 0

func _open(p_name: String) -> void:
	_current_open = p_name
	_refresh_content(p_name)
	var entry: Dictionary = _ui_panels[p_name]
	entry.clip.visible = true
	var pnl: Panel = entry.panel
	var tween := get_tree().create_tween()
	tween.tween_property(pnl, "offset_top", 0.0, SLIDE_DURATION).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(pnl, "offset_bottom", PANEL_HEIGHT, SLIDE_DURATION).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

func close_current() -> void:
	if _current_open == "":
		return
	var entry: Dictionary = _ui_panels[_current_open]
	_current_open = ""
	var pnl: Panel = entry.panel
	var clip: Control = entry.clip
	var tween := get_tree().create_tween()
	tween.tween_property(pnl, "offset_top", -PANEL_HEIGHT, SLIDE_DURATION).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.parallel().tween_property(pnl, "offset_bottom", 0.0, SLIDE_DURATION).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_callback(func(): clip.visible = false)

func is_panel_hit(global_pos: Vector2) -> bool:
	if _current_open == "":
		return false
	var pnl: Panel = _ui_panels[_current_open].panel
	return pnl.get_global_rect().has_point(global_pos)

func has_open_panel() -> bool:
	return _current_open != ""

func get_clip_nodes() -> Array:
	var out: Array = []
	for entry in _ui_panels.values():
		out.append(entry.clip)
	return out
