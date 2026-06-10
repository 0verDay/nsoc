class_name AllySidePanelManager
extends Node

# 友军"墓地 / 除外"两个底部上拉面板。
# 镜像 EnemySidePanelManager，但面板从下方滑入（玩家半场一侧）。
# 每个友军盘（ally_left / ally_right）各自实例化一份。
# 数据源 = 所绑定的 BoardSlot（slot.graveyard / slot.banished）。

signal long_press_requested(payload)
signal long_press_canceled

const PANEL_NAMES: PackedStringArray = ["ally_grave", "ally_banished"]
const PANEL_TITLES: Dictionary = {"ally_grave": "友军墓地", "ally_banished": "友军除外"}
# pile 名 → 本面板 key（同时兼容 BoardSlot 的 "banished" 与 DeckManager 的 "banish"）
const PILE_TO_PANEL: Dictionary = {
	"graveyard": "ally_grave",
	"banished": "ally_banished",
	"banish": "ally_banished",
}

# clip 区域高度：从画面底部往上 CLIP_BOTTOM 留给按钮，再往上 PANEL_HEIGHT。
const CLIP_BOTTOM: float = 55.0
const PANEL_WIDTH: float = 480.0
const PANEL_HEIGHT: float = 470.0
const SLIDE_DURATION: float = 0.3

var _parent: Control
var _slot: BoardSlot = null
# 同时订阅 owner 的个人 deck（hand-origin 单位死亡入 deck.graveyard 而非 slot.graveyard，
# 跨端展示需合并两侧数据），_owner_deck 在 set_slot 时按 slot.owner_player_id 解析。
var _owner_deck: DeckManager = null
var _center_x_offset: float = 0.0
var _ui_panels: Dictionary = {}
var _current_open: String = ""

func setup(parent: Control, slot: BoardSlot = null, center_x_offset: float = 0.0) -> void:
	_parent = parent
	_center_x_offset = center_x_offset
	for p_name in PANEL_NAMES:
		_ui_panels[p_name] = _build_panel(p_name)
	if slot != null:
		set_slot(slot)

func set_slot(slot: BoardSlot) -> void:
	if _slot == slot:
		return
	if _slot != null and _slot.pile_changed.is_connected(_on_slot_pile_changed):
		_slot.pile_changed.disconnect(_on_slot_pile_changed)
	if _owner_deck != null and _owner_deck.pile_changed.is_connected(_on_slot_pile_changed):
		_owner_deck.pile_changed.disconnect(_on_slot_pile_changed)
	_slot = slot
	_owner_deck = null
	if _slot != null:
		_slot.pile_changed.connect(_on_slot_pile_changed)
		# owner 的个人 deck（PVP 中 hand-deploy 单位死亡入此 deck.graveyard）
		if _slot.owner_player_id != "" and has_node("/root/Game"):
			_owner_deck = Game.get_deck(_slot.owner_player_id)
			if _owner_deck != null:
				_owner_deck.pile_changed.connect(_on_slot_pile_changed)
	if _current_open != "":
		_refresh_content(_current_open)

func update_clip_center_x(new_center_x: float) -> void:
	_center_x_offset = new_center_x
	for entry in _ui_panels.values():
		var clip: Control = entry.clip
		clip.offset_left  = new_center_x - PANEL_WIDTH / 2.0
		clip.offset_right = new_center_x + PANEL_WIDTH / 2.0

func _on_slot_pile_changed(pile_name: String) -> void:
	var mapped: String = PILE_TO_PANEL.get(pile_name, "")
	if _current_open != "" and _current_open == mapped:
		_refresh_content(_current_open)

func _build_panel(p_name: String) -> Dictionary:
	# clip：固定在玩家半场底部，水平居中于 _center_x_offset。
	var clip_node := Control.new()
	clip_node.name = p_name + "_clip"
	_parent.add_child(clip_node)
	clip_node.set_anchors_preset(Control.PRESET_BOTTOM_WIDE, false)
	clip_node.anchor_left = 0.5
	clip_node.anchor_right = 0.5
	clip_node.offset_left  = _center_x_offset - PANEL_WIDTH / 2.0
	clip_node.offset_right = _center_x_offset + PANEL_WIDTH / 2.0
	clip_node.offset_top = -CLIP_BOTTOM - PANEL_HEIGHT
	clip_node.offset_bottom = -CLIP_BOTTOM
	clip_node.mouse_filter = Control.MOUSE_FILTER_IGNORE
	clip_node.clip_contents = true
	clip_node.visible = false
	clip_node.z_index = 200

	# panel：clip 内从下方滑入。初始 offset_top = PANEL_HEIGHT（藏在 clip 下方）。
	var pnl := Panel.new()
	pnl.name = p_name + "_panel"
	clip_node.add_child(pnl)
	pnl.set_anchors_preset(Control.PRESET_TOP_WIDE, false)
	pnl.offset_left = 0
	pnl.offset_right = 0
	pnl.offset_top = PANEL_HEIGHT
	pnl.offset_bottom = PANEL_HEIGHT * 2.0
	pnl.mouse_filter = Control.MOUSE_FILTER_STOP
	pnl.add_theme_stylebox_override("panel",
		ThemeFactory.panel(Color(0.94, 0.95, 0.96, 1.0), Color(1, 1, 1, 1.0), 1, 20))

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

	var helper := DragScrollHelper.new()
	helper.name = "DragScroll"
	scroll.add_child(helper)
	helper.setup(scroll, Callable(self, "_emit_long_press_canceled"))

	return {"clip": clip_node, "panel": pnl, "list": vbox}

func _emit_long_press_canceled() -> void:
	long_press_canceled.emit()

func _refresh_content(p_name: String) -> void:
	var vbox: VBoxContainer = _ui_panels[p_name].list
	if not is_instance_valid(vbox):
		return
	# 同步 free 避免 queue_free 延迟导致同帧新旧节点共存
	for c in vbox.get_children():
		c.free()
	if _slot == null or not is_instance_valid(_slot):
		return
	if p_name == "ally_grave":
		var grave: Array = []
		grave.append_array(_slot.graveyard)
		if _owner_deck != null:
			grave.append_array(_owner_deck.graveyard)
		for i in range(grave.size() - 1, -1, -1):
			vbox.add_child(_create_list_item(grave[i].name, 1))
	elif p_name == "ally_banished":
		var ban: Array = []
		ban.append_array(_slot.banished)
		if _owner_deck != null:
			ban.append_array(_owner_deck.banished)
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
	entry.panel.offset_top = PANEL_HEIGHT
	entry.panel.offset_bottom = PANEL_HEIGHT * 2.0

func _open(p_name: String) -> void:
	_current_open = p_name
	_refresh_content(p_name)
	var entry: Dictionary = _ui_panels[p_name]
	entry.clip.visible = true
	var pnl: Panel = entry.panel
	var tween := get_tree().create_tween()
	tween.tween_property(pnl, "offset_top", 0.0, SLIDE_DURATION) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(pnl, "offset_bottom", PANEL_HEIGHT, SLIDE_DURATION) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

func close_current() -> void:
	if _current_open == "":
		return
	var entry: Dictionary = _ui_panels[_current_open]
	_current_open = ""
	var pnl: Panel = entry.panel
	var clip: Control = entry.clip
	if not is_instance_valid(pnl) or not is_instance_valid(clip):
		return
	var tween := get_tree().create_tween()
	tween.tween_property(pnl, "offset_top", PANEL_HEIGHT, SLIDE_DURATION) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.parallel().tween_property(pnl, "offset_bottom", PANEL_HEIGHT * 2.0, SLIDE_DURATION) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_callback(func():
		if is_instance_valid(clip):
			clip.visible = false)

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
