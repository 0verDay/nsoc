extends Control

const MAP_PATH := "res://data/empire_maps/test_map.json"
const PROFILE_PANEL_SCENE := preload("res://scenes/ProfileSubPanel.tscn")

const NODE_RADIUS: float = 28.0

const SIDE_BTN_TOP: float = 120.0

# 转场参数（与主菜单一致）
const TRANSITION_DURATION: float = 0.45
const FADE_DURATION: float = 0.15
const EXPANDED_MARGIN: float = 20.0

# 转场状态
var _initial_state: Dictionary = {}        # Control → {position, size, scale, modulate, pivot}
var _transition_targets: Array = []        # [{node, dir}]  dir: -1=左滑 1=右滑 0=仅淡出
var _is_transitioning: bool = false
var _is_expanded: bool = false
var _frozen_children: Array = []
var _frozen_state: Dictionary = {}
var _current_tween: Tween
var _secondary_panel: SecondaryPanel = null
var _origin_panel: Control = null

var _info_panel: Panel = null

var _settings: SettingsPanelController
var _map_root: Node2D
var _line_layer: _LineLayer
var _shape_nodes: Array = []
var _selected_node = null

# 视角状态
var _pan_active: bool = false
var _pan_start_mouse: Vector2 = Vector2.ZERO
var _pan_start_pos: Vector2 = Vector2.ZERO

# 双指缩放
var _pinch_active: bool = false
var _pinch_last_dist: float = 0.0
var _pinch_last_center: Vector2 = Vector2.ZERO

const ZOOM_MIN: float = 0.2
const ZOOM_MAX: float = 5.0
const ZOOM_STEP: float = 1.12

var _map_world_size: Vector2 = Vector2.ZERO
var _map_world_origin: Vector2 = Vector2.ZERO


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var bg := ColorRect.new()
	bg.color = Color.WHITE
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	_map_root = Node2D.new()
	add_child(_map_root)

	_line_layer = _LineLayer.new()
	_map_root.add_child(_line_layer)

	_settings = SettingsPanelController.new()
	_settings.name = "SettingsPanel"
	add_child(_settings)
	_settings.setup(self, {
		"create_trigger_button": true,
		"button_align": "right",
		"resume_label": "继续",
		"exit_label": "退回菜单",
		"extra_buttons": [
			{"label": "存档", "action": Callable()},
		],
	})

	_build_side_panel()
	_build_info_panel()
	call_deferred("_setup_transition")
	call_deferred("_load_map")


func _build_info_panel() -> void:
	# 外层 Panel：白色背景 + 半透明白边 + 圆角20 + 阴影，与主菜单 ProfilePnl 同款
	var pnl := Panel.new()
	pnl.name = "InfoPanel"
	pnl.set_anchors_preset(Control.PRESET_TOP_LEFT)
	pnl.offset_left   = 20.0
	pnl.offset_top    = 20.0
	pnl.offset_right  = 190.0
	pnl.offset_bottom = 180.0
	pnl.add_theme_stylebox_override("panel",
		ThemeFactory.panel(Color.WHITE, Color(1, 1, 1, 0.6), 1, 20, true))

	# 内层 VBox：三行
	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left   = 16.0
	vbox.offset_top    = 14.0
	vbox.offset_right  = -16.0
	vbox.offset_bottom = -14.0
	vbox.add_theme_constant_override("separation", 8)
	pnl.add_child(vbox)

	# 第一行：势力色块 + 势力名
	var row1 := HBoxContainer.new()
	row1.add_theme_constant_override("separation", 10)
	row1.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(row1)

	var faction_dot := _FactionDot.new()
	faction_dot.init(Color("#4caf50"))   # 绿色占位
	faction_dot.custom_minimum_size = Vector2(28, 28)
	faction_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row1.add_child(faction_dot)

	var faction_lbl := Label.new()
	faction_lbl.text = "蜀汉"
	faction_lbl.add_theme_font_size_override("font_size", 22)
	faction_lbl.add_theme_color_override("font_color", Color("#1f2937"))
	faction_lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row1.add_child(faction_lbl)

	# 第二行：粮草
	var food_lbl := Label.new()
	food_lbl.text = "粮草：1 / 9"
	food_lbl.add_theme_font_size_override("font_size", 18)
	food_lbl.add_theme_color_override("font_color", Color("#374151"))
	food_lbl.size_flags_vertical = Control.SIZE_EXPAND_FILL
	food_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	vbox.add_child(food_lbl)

	# 第三行：资金
	var gold_lbl := Label.new()
	gold_lbl.text = "资金：666"
	gold_lbl.add_theme_font_size_override("font_size", 18)
	gold_lbl.add_theme_color_override("font_color", Color("#374151"))
	gold_lbl.size_flags_vertical = Control.SIZE_EXPAND_FILL
	gold_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	vbox.add_child(gold_lbl)

	add_child(pnl)
	_info_panel = pnl


# ── 转场系统（与主菜单一致）─────────────────────────────────────────────────

func _setup_transition() -> void:
	# 收集参与转场的所有顶层节点，记录初始状态，拍平 anchor
	var side_panel := get_node_or_null("SidePanel")
	var end_btn    := get_node_or_null("EndTurnBtn")
	# SettingsPanelController 的触发按钮直接挂在场景根下
	var settings_btn: Control = get_node_or_null("SettingsBtn")

	_transition_targets = []
	# info_panel：向左滑出（但它是被展开目标，只在"其余面板"滑出逻辑里参与）
	if _info_panel:
		_transition_targets.append({"node": _info_panel, "dir": -1})
	if side_panel:
		_transition_targets.append({"node": side_panel, "dir": 1})
	if end_btn:
		_transition_targets.append({"node": end_btn, "dir": 1})
	if settings_btn:
		_transition_targets.append({"node": settings_btn, "dir": 1})

	for entry in _transition_targets:
		_record_initial(entry.node)

	# 安装 InfoPanel 点击代理按钮
	if _info_panel:
		call_deferred("_install_info_panel_button", _info_panel)


func _record_initial(ctrl: Control) -> void:
	if ctrl == null:
		return
	var gpos := ctrl.position
	var gsize := ctrl.size
	ctrl.set_anchors_preset(Control.PRESET_TOP_LEFT, false)
	ctrl.position = gpos
	ctrl.size = gsize
	ctrl.pivot_offset = gsize * 0.5
	_initial_state[ctrl] = {
		"position": gpos, "size": gsize,
		"scale": ctrl.scale, "modulate": ctrl.modulate,
		"pivot": ctrl.pivot_offset,
	}


func _install_info_panel_button(pnl: Panel) -> void:
	pnl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_disable_mouse_recursive(pnl)

	var btn := Button.new()
	btn.name = "ClickArea"
	btn.flat = true
	btn.focus_mode = Control.FOCUS_NONE
	btn.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	btn.mouse_filter = Control.MOUSE_FILTER_STOP
	btn.set_meta("transition_skip", true)
	var empty := StyleBoxEmpty.new()
	for slot in ["normal", "hover", "pressed", "focus", "disabled", "hover_pressed"]:
		btn.add_theme_stylebox_override(slot, empty)
	pnl.add_child(btn)

	btn.button_down.connect(func():
		if _is_transitioning or _is_expanded: return
		var t := pnl.create_tween()
		t.tween_property(pnl, "scale", Vector2(0.98, 0.98), 0.08))
	btn.button_up.connect(func():
		if _is_transitioning or _is_expanded: return
		var t := pnl.create_tween()
		t.tween_property(pnl, "scale", Vector2.ONE, 0.08))
	btn.pressed.connect(func(): _trigger_transition(_info_panel))


func _trigger_transition(origin_panel: Control) -> void:
	if _is_transitioning or _is_expanded:
		return
	_is_transitioning = true
	_origin_panel = origin_panel

	if _current_tween and _current_tween.is_valid():
		_current_tween.kill()
	_current_tween = create_tween()
	_current_tween.set_parallel(true)
	_current_tween.set_trans(Tween.TRANS_CUBIC)
	_current_tween.set_ease(Tween.EASE_IN_OUT)

	var screen := get_viewport_rect().size

	# 1) origin_panel 内可见子控件淡出（跳过 transition_skip）
	var fade_targets := _collect_fade_targets(origin_panel)
	_frozen_children = fade_targets.duplicate()
	_frozen_state.clear()
	for c in fade_targets:
		var gpos: Vector2 = c.global_position
		var csize: Vector2 = c.size
		_frozen_state[c] = {"gpos": gpos, "size": csize}
		c.top_level = true
		c.global_position = gpos
		c.size = csize
	for b in fade_targets:
		_current_tween.tween_property(b, "modulate:a", 0.0, FADE_DURATION)

	# 2) 地图淡出
	if _map_root:
		_current_tween.tween_property(_map_root, "modulate:a", 0.0, TRANSITION_DURATION)

	# 3) 其余面板/按钮滑出 + 淡出
	for entry in _transition_targets:
		var node: Control = entry.node
		if node == null or node == origin_panel:
			continue
		var dir: int = entry.dir
		var init: Dictionary = _initial_state.get(node, {})
		if init.is_empty():
			continue
		if dir > 0:
			_current_tween.tween_property(node, "position",
				Vector2(init.position.x + screen.x, init.position.y), TRANSITION_DURATION)
		elif dir < 0:
			_current_tween.tween_property(node, "position",
				Vector2(init.position.x - node.size.x - 40.0, init.position.y), TRANSITION_DURATION)
		_current_tween.tween_property(node, "modulate:a", 0.0, TRANSITION_DURATION)

	# 4) origin_panel 展开至全屏
	var expanded_size := screen - Vector2(EXPANDED_MARGIN * 2.0, EXPANDED_MARGIN * 2.0)
	var expanded_pos  := Vector2(EXPANDED_MARGIN, EXPANDED_MARGIN)
	origin_panel.move_to_front()
	_current_tween.tween_property(origin_panel, "size",         expanded_size,         TRANSITION_DURATION)
	_current_tween.tween_property(origin_panel, "position",     expanded_pos,          TRANSITION_DURATION)
	_current_tween.tween_property(origin_panel, "pivot_offset", expanded_size * 0.5,   TRANSITION_DURATION)

	await _current_tween.finished
	_is_transitioning = false
	_is_expanded = true

	for c in _frozen_children:
		if is_instance_valid(c) and c is Control:
			(c as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE

	# attach 二级面板
	if _secondary_panel and is_instance_valid(_secondary_panel):
		_secondary_panel.queue_free()
	_secondary_panel = PROFILE_PANEL_SCENE.instantiate()
	_secondary_panel.back_pressed.connect(_trigger_reverse)
	_secondary_panel.attach(origin_panel)


func _trigger_reverse() -> void:
	if _current_tween and _current_tween.is_valid():
		_current_tween.kill()
	if _secondary_panel and is_instance_valid(_secondary_panel):
		_secondary_panel.detach_with_fade(TRANSITION_DURATION)
		_secondary_panel = null

	_is_transitioning = true
	_is_expanded = false

	# 解冻子控件
	for c in _frozen_children:
		if is_instance_valid(c):
			c.top_level = false
			if c is Control:
				(c as Control).mouse_filter = Control.MOUSE_FILTER_STOP
	_frozen_children.clear()
	_frozen_state.clear()

	_current_tween = create_tween()
	_current_tween.set_parallel(true)
	_current_tween.set_trans(Tween.TRANS_CUBIC)
	_current_tween.set_ease(Tween.EASE_IN_OUT)

	# 地图淡回
	if _map_root:
		_current_tween.tween_property(_map_root, "modulate:a", 1.0, TRANSITION_DURATION)

	# 所有节点回初始状态
	for node in _initial_state.keys():
		var init: Dictionary = _initial_state[node]
		_current_tween.tween_property(node, "position",     init.position,  TRANSITION_DURATION)
		_current_tween.tween_property(node, "size",         init.size,      TRANSITION_DURATION)
		_current_tween.tween_property(node, "scale",        init.scale,     TRANSITION_DURATION)
		_current_tween.tween_property(node, "pivot_offset", init.pivot,     TRANSITION_DURATION)
		_current_tween.tween_property(node, "modulate",     init.modulate,  TRANSITION_DURATION)

	# 面板内子控件延迟淡回
	var fade_delay := TRANSITION_DURATION - FADE_DURATION
	if _origin_panel:
		for b in _collect_fade_targets(_origin_panel):
			b.modulate.a = 0.0
			_current_tween.tween_property(b, "modulate:a", 1.0, FADE_DURATION).set_delay(fade_delay)

	await _current_tween.finished
	_is_transitioning = false


func _collect_fade_targets(root: Node) -> Array:
	var out: Array = []
	if root.has_meta("transition_skip"):
		return out
	if root is Button or root is Label or root is TextureRect or root is _FactionDot:
		out.append(root)
		return out
	for child in root.get_children():
		if child is Node and child.has_meta("transition_skip"):
			continue
		if child is Button or child is Label or child is TextureRect or child is _FactionDot:
			out.append(child)
		elif child is Node:
			out.append_array(_collect_fade_targets(child))
	return out


static func _disable_mouse_recursive(c: Control) -> void:
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for sub in c.get_children():
		if sub is Control:
			_disable_mouse_recursive(sub)


func _build_side_panel() -> void:
	const BTN_SIZE    := 340.0   # 结束回合按钮宽度
	const END_BTN_H   := 140.0    # 结束回合按钮高度
	const GAP         := 12.0    # 两区域间距
	const RIGHT_MARGIN := 20.0

	# ── 三个方形按钮容器（宽 160px，右边距 20px，与选项按钮对齐）
	var container := Control.new()
	container.name = "SidePanel"
	container.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	container.offset_left   = -180.0
	container.offset_right  = -20.0
	container.offset_top    = SIDE_BTN_TOP
	container.offset_bottom = -(RIGHT_MARGIN + END_BTN_H + GAP)
	add_child(container)

	var vbox := VBoxContainer.new()
	vbox.name = "SideVBox"
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 8)
	container.add_child(vbox)

	for lbl in ["军\n队", "人\n才", "方\n略"]:
		var btn := Button.new()
		btn.text = lbl
		btn.size_flags_vertical = Control.SIZE_EXPAND_FILL
		btn.add_theme_font_size_override("font_size", 26)
		btn.add_theme_color_override("font_color", Color.WHITE)
		ThemeFactory.apply_button_styles(btn, ThemeFactory.primary_button_styles())
		vbox.add_child(btn)

	# ── "结束回合"按钮：单独锚定右下角，横宽竖窄方形
	var end_btn := Button.new()
	end_btn.name = "EndTurnBtn"
	end_btn.text = "结束回合"
	end_btn.add_theme_font_size_override("font_size", 26)
	end_btn.add_theme_color_override("font_color", Color.WHITE)
	ThemeFactory.apply_button_styles(end_btn, ThemeFactory.primary_button_styles())
	end_btn.set_anchor(SIDE_RIGHT,  1.0)
	end_btn.set_anchor(SIDE_LEFT,   1.0)
	end_btn.set_anchor(SIDE_BOTTOM, 1.0)
	end_btn.set_anchor(SIDE_TOP,    1.0)
	end_btn.offset_right  = -RIGHT_MARGIN
	end_btn.offset_left   = -RIGHT_MARGIN - BTN_SIZE
	end_btn.offset_bottom = -RIGHT_MARGIN
	end_btn.offset_top    = -RIGHT_MARGIN - END_BTN_H
	add_child(end_btn)


func _on_shape_clicked(node) -> void:
	if _selected_node == node:
		_selected_node.set_selected(false)
		_selected_node = null
	else:
		if _selected_node != null:
			_selected_node.set_selected(false)
		_selected_node = node
		_selected_node.set_selected(true)


func _load_map() -> void:
	var file := FileAccess.open(MAP_PATH, FileAccess.READ)
	if file == null:
		push_error("EmpireTest: cannot open " + MAP_PATH)
		return
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		push_error("EmpireTest: JSON parse error: " + json.get_error_message())
		file.close()
		return
	file.close()
	_build_map(json.get_data())


func _build_map(data: Dictionary) -> void:
	var shapes_data: Array = data.get("shapes", [])
	var connections_data: Array = data.get("connections", [])
	if shapes_data.is_empty():
		return

	var vp: Vector2 = get_viewport_rect().size
	var margin: float = 80.0

	var xs: Array = shapes_data.map(func(s): return float(s.get("x", 0.0)))
	var ys: Array = shapes_data.map(func(s): return float(s.get("y", 0.0)))
	var min_x: float = xs.min();  var max_x: float = xs.max()
	var min_y: float = ys.min();  var max_y: float = ys.max()
	var span_x: float = max(max_x - min_x, 1.0)
	var span_y: float = max(max_y - min_y, 1.0)
	var usable_w: float = vp.x - margin * 2.0
	var usable_h: float = vp.y - margin * 2.0
	var sc: float = min(usable_w / span_x, usable_h / span_y)
	var ox: float = margin + (usable_w - span_x * sc) * 0.5
	var oy: float = margin + (usable_h - span_y * sc) * 0.5

	var id_to_pos: Dictionary = {}
	for s in shapes_data:
		var sid: int = s.get("id", 0)
		var pos := Vector2(
			ox + (float(s.get("x", 0.0)) - min_x) * sc,
			oy + (float(s.get("y", 0.0)) - min_y) * sc
		)
		id_to_pos[sid] = pos

		var node := _MapShapeNode.new()
		var cat_label: String = ""
		if s.get("kind", "") == "square":
			var cat = s.get("category", null)
			if cat != null:
				var cat_int: int = int(cat)
				var cat_map: Dictionary = {1: "大", 2: "商", 3: "农", 4: "军"}
				if cat_map.has(cat_int):
					cat_label = cat_map[cat_int]
		node.init(sid, s.get("kind", "circle"), cat_label, pos, NODE_RADIUS)
		node.clicked.connect(_on_shape_clicked)
		_map_root.add_child(node)
		_shape_nodes.append(node)

	_line_layer.set_data(id_to_pos, connections_data)
	# 地图内容 bounding box（world 坐标，即 _map_root 本地坐标）
	var content_min := Vector2(ox - NODE_RADIUS, oy - NODE_RADIUS)
	var content_max := Vector2(ox + span_x * sc + NODE_RADIUS, oy + span_y * sc + NODE_RADIUS)
	_map_world_origin = content_min
	_map_world_size   = content_max - content_min
	_line_layer.set_bounds(content_min, content_max)


# ── 输入：平移 + 滚轮缩放 + 双指缩放 ─────────────────────────────────────────
func _gui_input(event: InputEvent) -> void:
	# 滚轮缩放
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_at(event.position, ZOOM_STEP)
			accept_event()
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_at(event.position, 1.0 / ZOOM_STEP)
			accept_event()

func _input(event: InputEvent) -> void:
	# 左键拖拽平移（全局输入，不受子节点遮挡影响）
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_pan_active = true
			_pan_start_mouse = event.position
			_pan_start_pos = _map_root.position
		else:
			_pan_active = false

	elif event is InputEventMouseMotion and _pan_active and (event.button_mask & MOUSE_BUTTON_MASK_LEFT):
		var delta: Vector2 = event.position - _pan_start_mouse
		if delta.length() > 4.0:
			_map_root.position = _clamp_pan(_pan_start_pos + delta)

	elif event is InputEventMagnifyGesture:
		_zoom_at(event.position, event.factor)
		accept_event()

	elif event is InputEventPanGesture:
		_map_root.position = _clamp_pan(_map_root.position - event.delta * 2.0)
		accept_event()


func _zoom_at(screen_pos: Vector2, factor: float) -> void:
	var vp: Vector2 = get_viewport_rect().size
	var old_scale: float = _map_root.scale.x
	# 缩放下限：地图全貌刚好适配视口（取较小轴，保证全部可见）
	var min_scale: float = ZOOM_MIN
	if _map_world_size.x > 0 and _map_world_size.y > 0:
		min_scale = max(ZOOM_MIN,
			min(vp.x / _map_world_size.x, vp.y / _map_world_size.y))
	var new_scale: float = clamp(old_scale * factor, min_scale, ZOOM_MAX)
	var real_factor: float = new_scale / old_scale
	var new_pos: Vector2 = screen_pos + (_map_root.position - screen_pos) * real_factor
	_map_root.position = _clamp_pan(new_pos, new_scale)
	_map_root.scale = Vector2(new_scale, new_scale)


# 限制平移：屏幕中心 (vp/2) 始终在地图内容范围内
# 内容左边屏幕坐标 = pos + origin*sc，右边 = pos + (origin+size)*sc
# 要求左边 <= vp/2 <= 右边：
#   pos <= vp/2 - origin*sc
#   pos >= vp/2 - (origin+size)*sc
func _clamp_pan(pos: Vector2, sc: float = -1.0) -> Vector2:
	var vp: Vector2 = get_viewport_rect().size
	if sc < 0.0:
		sc = _map_root.scale.x
	if _map_world_size == Vector2.ZERO:
		return pos
	var half: Vector2 = vp * 0.5
	var max_pos := half - _map_world_origin * sc
	var min_pos := half - (_map_world_origin + _map_world_size) * sc
	return Vector2(clamp(pos.x, min_pos.x, max_pos.x), clamp(pos.y, min_pos.y, max_pos.y))


# ── connection line layer ─────────────────────────────────────────────────────
class _LineLayer extends Node2D:
	var _id_to_pos: Dictionary = {}
	var _connections: Array = []
	var _bounds_min: Vector2 = Vector2.ZERO
	var _bounds_max: Vector2 = Vector2.ZERO

	func set_data(id_to_pos: Dictionary, connections: Array) -> void:
		_id_to_pos = id_to_pos
		_connections = connections
		queue_redraw()

	func set_bounds(bmin: Vector2, bmax: Vector2) -> void:
		_bounds_min = bmin
		_bounds_max = bmax
		queue_redraw()

	func _draw() -> void:
		for conn in _connections:
			var a: Vector2 = _id_to_pos.get(int(conn.get("from", -1)), Vector2.ZERO)
			var b: Vector2 = _id_to_pos.get(int(conn.get("to",   -1)), Vector2.ZERO)
			draw_line(a, b, Color("#7ec8e3"), 2.0, true)


# ── individual map shape node ─────────────────────────────────────────────────
class _MapShapeNode extends Control:
	signal clicked(node)

	var _id: int
	var _kind: String
	var _cat_label: String = ""
	var _radius: float
	var _fill: Color
	var _selected: bool = false

	func init(id: int, kind: String, cat_label: String, center: Vector2, radius: float) -> void:
		_id = id
		_kind = kind
		_cat_label = cat_label
		_radius = radius
		match kind:
			"triangle": _fill = Color.GRAY
			"circle":   _fill = Color.GRAY
			"square":   _fill = Color.GRAY
			_:          _fill = Color.GRAY
		var d: float = radius * 2.0
		size = Vector2(d, d)
		position = center - Vector2(radius, radius)

	func _ready() -> void:
		if _kind == "square" and _cat_label != "":
			var lbl := Label.new()
			lbl.text = _cat_label
			lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			lbl.add_theme_font_size_override("font_size", int(_radius * 1.0))
			lbl.add_theme_color_override("font_color", Color.WHITE)
			lbl.add_theme_font_override("font", load("res://assets/NotoSerifCJKsc-Regular.otf"))
			lbl.size = Vector2(_radius * 2.0, _radius * 2.0)
			lbl.position = Vector2.ZERO
			lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
			add_child(lbl)

	func set_selected(val: bool) -> void:
		_selected = val
		queue_redraw()

	func _draw() -> void:
		var r: float = _radius
		var c: Vector2 = Vector2(r, r)
		var outline: Color = Color("#ffe066") if _selected else Color.WHITE

		match _kind:
			"circle":
				draw_circle(c, r, _fill)
				draw_arc(c, r, 0.0, TAU, 48, outline, 2.0, true)
			"square":
				draw_rect(Rect2(Vector2.ZERO, size), _fill)
				draw_rect(Rect2(Vector2.ZERO, size), outline, false, 2.0)
			"triangle":
				var pts := PackedVector2Array([
					c + Vector2(0.0, -r),
					c + Vector2(-r,  r),
					c + Vector2( r,  r),
				])
				draw_colored_polygon(pts, _fill)
				draw_polyline(PackedVector2Array([pts[0], pts[1], pts[2], pts[0]]),
					outline, 2.0, true)

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			clicked.emit(self)
			get_viewport().set_input_as_handled()


# ── 势力色块：纯色圆 + 细白描边 ──────────────────────────────────────────────
class _FactionDot extends Control:
	var _color: Color = Color.GREEN

	func init(c: Color) -> void:
		_color = c
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var r: float = min(size.x, size.y) * 0.5
		var c := Vector2(size.x * 0.5, size.y * 0.5)
		draw_circle(c, r, _color)
		draw_arc(c, r, 0.0, TAU, 32, Color(1, 1, 1, 0.7), 1.5, true)
