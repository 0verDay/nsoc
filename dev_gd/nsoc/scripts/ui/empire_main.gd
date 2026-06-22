extends Control

# 帝国模式 - 剧本选择界面
#
# 布局与 YanyiPanel 对齐（左侧底板 + 右侧 BackBtn 列，尺寸完全一致）：
#   ContentPnl : position=(LEFT_GAP, TOP_MARGIN), size=(W-LEFT_GAP-RIGHT_COL_W, H-TOP_MARGIN*2)
#   BackBtn    : sibling, position=(W-RIGHT_MARGIN-RIGHT_WIDTH, TOP_MARGIN), size=(RIGHT_WIDTH, BACKBTN_H)
#
#   ┌─ ContentPnl ───────────────────┐  ┌─[BackBtn]──┐
#   │  ┌─ MapThumbPnl ─────────────┐ │  └────────────┘
#   │  │  (地图缩略图·右半顶区)    │ │
#   │  └───────────────────────────┘ │
#   │  ┌─ DescPnl ─────────────────┐ │
#   │  │  (描述)                   │ │
#   │  └───────────────────────────┘ │
#   │  ┌─ CarouselPnl ─────────────┐ │
#   │  │  (轮播)                   │ │
#   │  └───────────────────────────┘ │
#   └────────────────────────────────┘

# ── 布局参数（与 YanyiPanel / SparringPanel 完全一致，确保视觉连续） ──────────
const TOP_MARGIN:   float = 20.0
const LEFT_GAP:     float = 20.0
const RIGHT_MARGIN: float = 20.0
const RIGHT_WIDTH:  float = 160.0
const BACKBTN_H:    float = 80.0

# ── ContentPnl 内部布局 ───────────────────────────────────────────────────────
const INNER_PAD: float = 20.0   # 子面板距 ContentPnl 边的留白
const GAP:       float = 20.0   # 子面板之间的间隙

# 高度分配比例（顶区 : 描述 : 轮播）
const RATIO_TOP:      float = 50.0
const RATIO_DESC:     float = 25.0
const RATIO_CAROUSEL: float = 15.0

# ── 剧本数据 ─────────────────────────────────────────────────────────────────
const EMPIRE_MAPS_DIR: String = "res://data/empire_maps/"

# ── 轮播按钮 ─────────────────────────────────────────────────────────────────
const CAROUSEL_BTN_W: float     = 320.0
const CAROUSEL_INNER_PAD: float = 12.0
const CAROUSEL_BTN_SEP: float   = 12.0
const CAROUSEL_FONT_SIZE: int   = 24

# ── 描述/缩略图样式 ──────────────────────────────────────────────────────────
const DESC_FONT_SIZE: int  = 28
const DESC_COLOR: Color    = Color("#343a40")

const MAIN_MENU_SCENE    := "res://scenes/MainMenu.tscn"
const FADE_OUT_DURATION: float = 0.35

@onready var _content_pnl: Panel   = $ContentPnl
@onready var _back_btn: Button     = $ContentPnl/BackBtn
@onready var _map_thumb_pnl: Panel = $ContentPnl/MapThumbPnl
@onready var _desc_pnl: Panel      = $ContentPnl/DescPnl
@onready var _carousel_pnl: Panel  = $ContentPnl/CarouselPnl

var _scenario_buttons: Array[Button] = []
var _desc_label: Label
var _map_thumbnail: _MapThumbnail
var _selected_idx: int = -1

# 已加载的剧本列表，每项：{"id": String, "name": String, "description": String, "map_path": String}
var _scenarios: Array = []


func _ready() -> void:
	# 白色 overlay 放在最前，消除场景切换白闪
	_maybe_play_fade_in()

	# 底板：白色 + 半透明边 + 圆角 20 + 阴影（与 YanyiPanel 完全一致）
	var board_style := ThemeFactory.panel(Color.WHITE, Color(1, 1, 1, 0.6), 1, 20, true)
	_content_pnl.add_theme_stylebox_override("panel", board_style)

	# 子面板：浅灰底 + 浅灰边 + 圆角 12
	var sub_style := ThemeFactory.panel(Color("#f8f9fa"), Color("#dee2e6"), 1, 12, false)
	for p in [_map_thumb_pnl, _desc_pnl, _carousel_pnl]:
		p.add_theme_stylebox_override("panel", sub_style.duplicate())

	# 返回按钮：蓝色主按钮风格
	ThemeFactory.apply_button_styles(_back_btn, ThemeFactory.primary_button_styles())
	_back_btn.add_theme_color_override("font_color",         Color.WHITE)
	_back_btn.add_theme_color_override("font_hover_color",   Color.WHITE)
	_back_btn.add_theme_color_override("font_pressed_color", Color.WHITE)
	_back_btn.pressed.connect(_on_back_pressed)

	_load_scenarios()
	_build_map_thumbnail()
	_build_desc_label()
	_build_carousel()

	_do_layout()
	if _scenarios.size() > 0:
		_select_scenario(0)


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_do_layout()


# ── 布局 ─────────────────────────────────────────────────────────────────────
func _do_layout() -> void:
	if _content_pnl == null or _back_btn == null:
		return
	var W: float = size.x
	var H: float = size.y
	if W <= 0.0 or H <= 0.0:
		return

	# ── ContentPnl：LEFT_GAP 左、RIGHT_MARGIN 右、TOP_MARGIN 上下 ─────────────
	# 宽 = W - LEFT_GAP - RIGHT_MARGIN，与左/右留白一致
	_content_pnl.position = Vector2(LEFT_GAP, TOP_MARGIN)
	_content_pnl.size     = Vector2(W - LEFT_GAP - RIGHT_MARGIN, H - TOP_MARGIN * 2.0)

	var pnl_W: float = _content_pnl.size.x
	var pnl_H: float = _content_pnl.size.y

	# ── BackBtn：局部坐标 (pnl_W - RIGHT_WIDTH, 0) → 屏幕 (W-180, TOP_MARGIN) ─
	# 与 YanyiPanel back_btn.position = (W - RIGHT_MARGIN - RIGHT_WIDTH, RIGHT_MARGIN) 完全一致
	_back_btn.position = Vector2(pnl_W - RIGHT_WIDTH, 0.0)
	_back_btn.size     = Vector2(RIGHT_WIDTH, BACKBTN_H)

	# ── ContentPnl 内部子面板 ─────────────────────────────────────────────────
	var inner_W: float = pnl_W - INNER_PAD * 2.0
	var inner_H: float = pnl_H - INNER_PAD * 2.0

	var available_h: float = inner_H - GAP * 2.0
	var ratio_sum: float   = RATIO_TOP + RATIO_DESC + RATIO_CAROUSEL
	var top_h:      float  = available_h * RATIO_TOP      / ratio_sum
	var desc_h:     float  = available_h * RATIO_DESC     / ratio_sum
	var carousel_h: float  = available_h * RATIO_CAROUSEL / ratio_sum

	var half_w: float = (inner_W - GAP) / 2.0
	var top_y: float  = INNER_PAD

	# MapThumbPnl：右半，顶部下移避开 BackBtn
	var map_y_offset: float = BACKBTN_H + GAP
	_map_thumb_pnl.position = Vector2(INNER_PAD + half_w + GAP, top_y + map_y_offset)
	_map_thumb_pnl.size     = Vector2(half_w, max(top_h - map_y_offset, 0.0))

	var desc_y: float = top_y + top_h + GAP
	_desc_pnl.position = Vector2(INNER_PAD, desc_y)
	_desc_pnl.size     = Vector2(inner_W, desc_h)

	var car_y: float = desc_y + desc_h + GAP
	_carousel_pnl.position = Vector2(INNER_PAD, car_y)
	_carousel_pnl.size     = Vector2(inner_W, carousel_h)


# ── 描述标签 ─────────────────────────────────────────────────────────────────
func _build_desc_label() -> void:
	_desc_label = Label.new()
	_desc_label.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_desc_label.offset_left   = 24
	_desc_label.offset_right  = -24
	_desc_label.offset_top    = 16
	_desc_label.offset_bottom = -16
	_desc_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_desc_label.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_desc_label.autowrap_mode        = TextServer.AUTOWRAP_WORD_SMART
	_desc_label.add_theme_font_size_override("font_size", DESC_FONT_SIZE)
	_desc_label.add_theme_color_override("font_color", DESC_COLOR)
	_desc_pnl.add_child(_desc_label)


# ── 剧本扫描与加载 ───────────────────────────────────────────────────────────
func _load_scenarios() -> void:
	_scenarios.clear()
	var dir := DirAccess.open(EMPIRE_MAPS_DIR)
	if dir == null:
		push_warning("EmpireMain: cannot open " + EMPIRE_MAPS_DIR)
		return
	dir.list_dir_begin()
	var fname := dir.get_next()
	while fname != "":
		if not dir.current_is_dir() and fname.ends_with(".json"):
			_parse_scenario_file(EMPIRE_MAPS_DIR + fname)
		fname = dir.get_next()
	dir.list_dir_end()
	_scenarios.sort_custom(func(a, b): return int(a.id) < int(b.id))


func _parse_scenario_file(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		return
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		return
	var data: Dictionary = json.data
	var sc: Dictionary = data.get("scenario", {})
	if sc.is_empty():
		return
	_scenarios.append({
		"id":          str(sc.get("id", "")),
		"name":        str(sc.get("name", "")),
		"description": str(sc.get("description", "")),
		"map_path":    path,
	})


# ── 地图缩略图 ───────────────────────────────────────────────────────────────
func _build_map_thumbnail() -> void:
	_map_thumbnail = _MapThumbnail.new()
	_map_thumbnail.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_map_thumb_pnl.add_child(_map_thumbnail)


# ── 轮播按钮 ─────────────────────────────────────────────────────────────────
func _build_carousel() -> void:
	var scroll := _ElasticHScroll.new()
	scroll.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	scroll.offset_left   = CAROUSEL_INNER_PAD
	scroll.offset_right  = -CAROUSEL_INNER_PAD
	scroll.offset_top    = CAROUSEL_INNER_PAD
	scroll.offset_bottom = -CAROUSEL_INNER_PAD
	_carousel_pnl.add_child(scroll)

	var hbox: HBoxContainer = scroll.get_content_box()
	hbox.add_theme_constant_override("separation", int(CAROUSEL_BTN_SEP))

	_scenario_buttons.clear()
	for i in _scenarios.size():
		var sc: Dictionary = _scenarios[i]
		var btn := Button.new()
		btn.text = sc.name
		btn.custom_minimum_size = Vector2(CAROUSEL_BTN_W, 0.0)
		btn.size_flags_vertical = Control.SIZE_EXPAND_FILL
		btn.add_theme_font_size_override("font_size", CAROUSEL_FONT_SIZE)
		btn.pressed.connect(_on_scenario_pressed.bind(i))
		hbox.add_child(btn)
		_scenario_buttons.append(btn)


# ── 选中与样式 ───────────────────────────────────────────────────────────────
func _on_scenario_pressed(idx: int) -> void:
	if idx == _selected_idx:
		return
	_select_scenario(idx)


func _select_scenario(idx: int) -> void:
	if idx < 0 or idx >= _scenario_buttons.size():
		return
	_selected_idx = idx
	for i in _scenario_buttons.size():
		_apply_scenario_btn_style(_scenario_buttons[i], i == idx)
	var sc: Dictionary = _scenarios[idx]
	if _desc_label:
		_desc_label.text = sc.description
	if _map_thumbnail:
		_map_thumbnail.load_from_file(sc.map_path)


func _maybe_play_fade_in() -> void:
	if not has_node("/root/Game"):
		return
	if not Game.pending_fade_in_from_white:
		return
	Game.pending_fade_in_from_white = false
	var canvas := CanvasLayer.new()
	canvas.layer = 200
	add_child(canvas)
	var overlay := ColorRect.new()
	overlay.color = Color(1, 1, 1, 1)
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	canvas.add_child(overlay)
	var tw := canvas.create_tween()
	tw.tween_property(overlay, "color:a", 0.0, FADE_OUT_DURATION) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_callback(canvas.queue_free)


func _on_back_pressed() -> void:
	_back_btn.disabled = true
	var tw := create_tween()
	tw.set_parallel(true)
	tw.set_trans(Tween.TRANS_QUAD)
	tw.set_ease(Tween.EASE_IN_OUT)
	for node in [_map_thumb_pnl, _desc_pnl, _carousel_pnl]:
		if is_instance_valid(node):
			tw.tween_property(node, "modulate:a", 0.0, FADE_OUT_DURATION)
	await tw.finished
	if has_node("/root/Game"):
		Game.pending_fade_in_from_white = true
	MainMenu.pending_open_btn     = "JourneyBtn"
	MainMenu.pending_open_instant = true
	get_tree().change_scene_to_file(MAIN_MENU_SCENE)


func _apply_scenario_btn_style(btn: Button, selected: bool) -> void:
	if selected:
		ThemeFactory.apply_button_styles(btn, ThemeFactory.primary_button_styles())
		btn.add_theme_color_override("font_color",         Color.WHITE)
		btn.add_theme_color_override("font_hover_color",   Color.WHITE)
		btn.add_theme_color_override("font_pressed_color", Color.WHITE)
	else:
		ThemeFactory.apply_button_styles(btn, _scenario_unselected_styles())
		btn.add_theme_color_override("font_color",         DESC_COLOR)
		btn.add_theme_color_override("font_hover_color",   DESC_COLOR)
		btn.add_theme_color_override("font_pressed_color", DESC_COLOR)


static func _scenario_unselected_styles() -> Dictionary:
	return {
		"normal":   ThemeFactory.panel(Color("#e9ecef"), Color("#ced4da"), 1, 12, false),
		"hover":    ThemeFactory.panel(Color("#dee2e6"), Color("#adb5bd"), 1, 12, false),
		"pressed":  ThemeFactory.panel(Color("#ced4da"), Color("#adb5bd"), 1, 12, false),
		"disabled": ThemeFactory.panel(Color("#f1f3f5"), Color("#dee2e6"), 1, 12, false),
	}


# ───────────────────────────────────────────────────────────────────────────
# 内部类：地图缩略图（Control + _draw 直接读 JSON 绘制）
# ───────────────────────────────────────────────────────────────────────────
class _MapThumbnail extends Control:
	const PADDING: float    = 12.0
	const DOT_RADIUS: float = 8.0
	const LINE_WIDTH: float = 1.5
	const LINE_COLOR: Color = Color(0.4, 0.4, 0.4, 0.7)

	var _shapes: Array = []
	var _connections: Array = []
	var _faction_colors: Dictionary = {}

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _notification(what: int) -> void:
		if what == NOTIFICATION_RESIZED:
			queue_redraw()

	func load_from_file(path: String) -> void:
		var file := FileAccess.open(path, FileAccess.READ)
		if file == null:
			push_warning("MapThumbnail: cannot open " + path)
			return
		var json := JSON.new()
		var err := json.parse(file.get_as_text())
		if err != OK:
			push_warning("MapThumbnail: JSON parse error in " + path)
			return
		var data: Dictionary = json.data
		_shapes = data.get("shapes", [])
		_connections = data.get("connections", [])
		_faction_colors.clear()
		for f in data.get("factions", []):
			_faction_colors[int(f.get("id", -1))] = Color(f.get("color", "#808080"))
		queue_redraw()

	func _draw() -> void:
		if _shapes.is_empty():
			return
		# 计算源坐标包围盒
		var min_x: float = INF
		var max_x: float = -INF
		var min_y: float = INF
		var max_y: float = -INF
		for s in _shapes:
			var x: float = float(s.get("x", 0.0))
			var y: float = float(s.get("y", 0.0))
			min_x = min(min_x, x)
			max_x = max(max_x, x)
			min_y = min(min_y, y)
			max_y = max(max_y, y)
		var src_w: float = max(max_x - min_x, 1.0)
		var src_h: float = max(max_y - min_y, 1.0)

		var avail_w: float = size.x - PADDING * 2.0
		var avail_h: float = size.y - PADDING * 2.0
		if avail_w <= 0.0 or avail_h <= 0.0:
			return
		var sc: float = min(avail_w / src_w, avail_h / src_h)
		var off_x: float = PADDING + (avail_w - src_w * sc) * 0.5
		var off_y: float = PADDING + (avail_h - src_h * sc) * 0.5

		# id → 局部坐标
		var id_to_pos: Dictionary = {}
		for s in _shapes:
			var lp := Vector2(
				off_x + (float(s.get("x", 0.0)) - min_x) * sc,
				off_y + (float(s.get("y", 0.0)) - min_y) * sc
			)
			id_to_pos[int(s.get("id", -1))] = lp

		# 先连线
		for conn in _connections:
			var f := int(conn.get("from", -1))
			var t := int(conn.get("to", -1))
			if id_to_pos.has(f) and id_to_pos.has(t):
				draw_line(id_to_pos[f], id_to_pos[t], LINE_COLOR, LINE_WIDTH, true)

		# 再点（按 kind 绘制对应形状）
		for s in _shapes:
			var pos: Vector2   = id_to_pos[int(s.get("id", -1))]
			var fid: int       = int(s.get("faction", 0))
			var color: Color   = _faction_colors.get(fid, Color.GRAY)
			var kind: String   = str(s.get("kind", "circle"))
			var r: float       = DOT_RADIUS
			var outline: Color = Color(0, 0, 0, 0.4)

			match kind:
				"circle":
					draw_circle(pos, r, color)
					draw_arc(pos, r, 0.0, TAU, 32, outline, 1.2, true)
				"triangle":
					var pts := PackedVector2Array([
						pos + Vector2(0.0,        -r * 1.15),
						pos + Vector2( r, r * 0.65),
						pos + Vector2(-r, r * 0.65),
					])
					draw_colored_polygon(pts, color)
					draw_polyline(PackedVector2Array([pts[0], pts[1], pts[2], pts[0]]), outline, 1.2, true)
				"square", _:
					var half: float = r * 0.9
					var rect := Rect2(pos - Vector2(half, half), Vector2(half * 2.0, half * 2.0))
					draw_rect(rect, color)
					draw_rect(rect, outline, false, 1.2)


# ───────────────────────────────────────────────────────────────────────────
# 内部类：水平弹性滚动容器
# 复刻 ElasticScrollList 的 rubber band（过界阻力）+ 释放回弹（cubic ease out），
# 改为水平方向；clip_contents=true 自带裁切，无滚动条。
# ───────────────────────────────────────────────────────────────────────────
class _ElasticHScroll extends Control:
	const OVERSCROLL_RESISTANCE: float  = 0.55
	const OVERSCROLL_SETTLE_TIME: float = 0.28
	const DRAG_THRESHOLD_PX: float      = 18.0
	const WHEEL_STEP_PX: float          = 60.0

	var _content: Control
	var _hbox: HBoxContainer
	var _drag_overlay: Control

	var _logical_offset: float = 0.0
	var _pressing: bool        = false
	var _is_scrolling: bool    = false
	var _press_x: float        = 0.0
	var _start_offset: float   = 0.0
	var _settle_tween: Tween   = null


	func _ready() -> void:
		clip_contents = true
		mouse_filter  = Control.MOUSE_FILTER_STOP

		_content = Control.new()
		_content.name = "_content"
		_content.mouse_filter = Control.MOUSE_FILTER_PASS
		add_child(_content)

		_hbox = HBoxContainer.new()
		_hbox.name = "_hbox"
		_hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_content.add_child(_hbox)

		resized.connect(_schedule_layout)
		_hbox.minimum_size_changed.connect(_schedule_layout)


	func get_content_box() -> HBoxContainer:
		return _hbox


	func _schedule_layout() -> void:
		call_deferred("_do_layout")


	func _do_layout() -> void:
		if not is_instance_valid(_hbox) or not is_instance_valid(_content):
			return
		var min_w: float    = _hbox.get_combined_minimum_size().x
		var view_w: float   = size.x
		var content_w: float = max(min_w, view_w)

		_content.size = Vector2(content_w, size.y)
		_hbox.size    = _content.size

		_logical_offset = clamp(_logical_offset, 0.0, _max_scroll())
		_apply_offset()


	# ── 滚动数学 ────────────────────────────────────────────────────────────
	func _max_scroll() -> float:
		if _content == null:
			return 0.0
		return max(0.0, _content.size.x - size.x)


	func _to_display(logical: float) -> float:
		var max_s: float = _max_scroll()
		if logical < 0.0:
			return -_rubber(-logical)
		if logical > max_s:
			return max_s + _rubber(logical - max_s)
		return logical


	func _rubber(x: float) -> float:
		var d: float = max(1.0, size.x)
		var c: float = OVERSCROLL_RESISTANCE
		return (x * c * d) / (d + c * x)


	func _apply_offset() -> void:
		if _content:
			_content.position.x = -_to_display(_logical_offset)


	func _scroll_by(dx: float) -> void:
		_logical_offset += dx
		_apply_offset()


	# ── 拖动覆盖层（防止释放误触按钮） ──────────────────────────────────────
	func _attach_drag_overlay() -> void:
		if is_instance_valid(_drag_overlay):
			return
		_drag_overlay = Control.new()
		_drag_overlay.name = "_drag_overlay"
		_drag_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
		_drag_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
		_drag_overlay.z_index = 100
		add_child(_drag_overlay)


	func _remove_drag_overlay() -> void:
		if is_instance_valid(_drag_overlay):
			_drag_overlay.queue_free()
		_drag_overlay = null


	# ── 回弹 ────────────────────────────────────────────────────────────────
	func _settle_to_clamped() -> void:
		_kill_settle_tween()
		var target: float = clamp(_logical_offset, 0.0, _max_scroll())
		if absf(target - _logical_offset) < 0.5:
			_logical_offset = target
			_apply_offset()
			return
		_settle_tween = create_tween()
		_settle_tween.tween_method(
			_set_logical_offset, _logical_offset, target, OVERSCROLL_SETTLE_TIME
		).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


	func _set_logical_offset(v: float) -> void:
		_logical_offset = v
		_apply_offset()


	func _kill_settle_tween() -> void:
		if _settle_tween and _settle_tween.is_valid():
			_settle_tween.kill()
		_settle_tween = null


	# ── 输入（全局 _input 绕开子按钮的 mouse_filter=STOP） ──────────────────
	func _input(event: InputEvent) -> void:
		if event is InputEventMouseButton:
			var mb := event as InputEventMouseButton

			# 滚轮：仅在本控件矩形内响应（横向滚轮 → 水平滚）
			if get_global_rect().has_point(mb.global_position):
				if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
					_kill_settle_tween()
					_scroll_by(-WHEEL_STEP_PX)
					_settle_to_clamped()
					get_viewport().set_input_as_handled()
					return
				if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
					_kill_settle_tween()
					_scroll_by(WHEEL_STEP_PX)
					_settle_to_clamped()
					get_viewport().set_input_as_handled()
					return

			if mb.button_index == MOUSE_BUTTON_LEFT:
				if mb.pressed:
					if get_global_rect().has_point(mb.global_position):
						_pressing     = true
						_is_scrolling = false
						_press_x      = mb.global_position.x
						_start_offset = _logical_offset
						_kill_settle_tween()
				else:
					if _pressing:
						if _is_scrolling:
							_settle_to_clamped()
							get_viewport().set_input_as_handled()
						_remove_drag_overlay()
						_pressing     = false
						_is_scrolling = false

		elif event is InputEventMouseMotion and _pressing:
			var mm := event as InputEventMouseMotion
			var dx: float = mm.global_position.x - _press_x

			if not _is_scrolling and absf(dx) >= DRAG_THRESHOLD_PX:
				_is_scrolling = true
				_attach_drag_overlay()

			if _is_scrolling:
				_logical_offset = _start_offset - dx
				_apply_offset()
				get_viewport().set_input_as_handled()
