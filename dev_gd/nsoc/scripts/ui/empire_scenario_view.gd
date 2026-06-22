class_name EmpireScenarioView
extends Control

# 剧本选择视图。
# 作为子节点填充 YanyiPanel.left_content_pnl，由 YanyiPanel 管理进出动画和返回按钮。
# 布局（填满父节点）：
#   ┌─ MapThumbPnl ─────────────────┐  (右半顶区)
#   ├─ DescPnl ─────────────────────┤  (整宽)
#   └─ CarouselPnl ─────────────────┘  (整宽)

const EMPIRE_MAPS_DIR: String = "res://data/empire_maps/"

# 与 YanyiPanel 对齐的布局参数
const INNER_PAD:  float = 20.0
const GAP:        float = 20.0
const BACKBTN_H:  float = 80.0   # 顶部避让 BackBtn 高度

const RATIO_TOP:      float = 50.0
const RATIO_DESC:     float = 25.0
const RATIO_CAROUSEL: float = 15.0

const CAROUSEL_BTN_W: float     = 320.0
const CAROUSEL_INNER_PAD: float = 12.0
const CAROUSEL_BTN_SEP: float   = 12.0
const CAROUSEL_FONT_SIZE: int   = 24

const DESC_FONT_SIZE: int = 28
const DESC_COLOR: Color   = Color("#343a40")
const ACCENT: Color       = Color(0.109804, 0.494118, 0.839216, 1)

@onready var _map_thumb_pnl: Panel = $MapThumbPnl
@onready var _desc_pnl: Panel      = $DescPnl
@onready var _carousel_pnl: Panel  = $CarouselPnl

var _scenario_buttons: Array[Button] = []
var _desc_label: Label
var _map_thumbnail: _MapThumbnail
var _selected_idx: int = -1
var _scenarios: Array = []


func _ready() -> void:
	# 子区域：与 SparringPanel 子面板同款（淡蓝底 + 蓝边 + 2px + 圆角16 + 阴影）
	# 与 CampaignPanel 子面板同款：白底 + 半透明白边 + 圆角 20 + 阴影
	var sub_style := ThemeFactory.panel(Color.WHITE, Color(1, 1, 1, 0.6), 1, 20, true)
	for p in [_map_thumb_pnl, _desc_pnl, _carousel_pnl]:
		p.add_theme_stylebox_override("panel", sub_style.duplicate())

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


func _do_layout() -> void:
	if _map_thumb_pnl == null:
		return
	var W: float = size.x
	var H: float = size.y
	if W <= 0.0 or H <= 0.0:
		return

	var inner_W: float = W - INNER_PAD * 2.0
	var inner_H: float = H - INNER_PAD * 2.0

	var available_h: float = inner_H - GAP * 2.0
	var ratio_sum: float   = RATIO_TOP + RATIO_DESC + RATIO_CAROUSEL
	var top_h:      float  = available_h * RATIO_TOP      / ratio_sum
	var desc_h:     float  = available_h * RATIO_DESC     / ratio_sum
	var carousel_h: float  = available_h * RATIO_CAROUSEL / ratio_sum

	var half_w: float = (inner_W - GAP) / 2.0
	var top_y: float  = INNER_PAD

	# MapThumbPnl：右半，顶部下移避开 BackBtn（BackBtn 同在 YanyiPanel 顶右）
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
	_desc_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	_desc_label.vertical_alignment   = VERTICAL_ALIGNMENT_TOP
	_desc_label.autowrap_mode        = TextServer.AUTOWRAP_WORD_SMART
	_desc_label.add_theme_font_size_override("font_size", DESC_FONT_SIZE)
	_desc_label.add_theme_color_override("font_color", DESC_COLOR)
	_desc_pnl.add_child(_desc_label)


# ── 地图缩略图 ───────────────────────────────────────────────────────────────
func _build_map_thumbnail() -> void:
	_map_thumbnail = _MapThumbnail.new()
	_map_thumbnail.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_map_thumb_pnl.add_child(_map_thumbnail)


# ── 剧本加载 ─────────────────────────────────────────────────────────────────
func _load_scenarios() -> void:
	_scenarios.clear()
	var dir := DirAccess.open(EMPIRE_MAPS_DIR)
	if dir == null:
		push_warning("EmpireScenarioView: cannot open " + EMPIRE_MAPS_DIR)
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


const EMPIRE_TEST_SCENE := "res://scenes/EmpireTest.tscn"

func _on_scenario_pressed(idx: int) -> void:
	if idx == _selected_idx:
		# 再次点击已选中的剧本 → 进入地图（玩家默认 Ap 势力）
		_enter_map(idx)
	else:
		_select_scenario(idx)


func _enter_map(idx: int) -> void:
	var sc: Dictionary = _scenarios[idx]
	EmpireTest.pending_map_path = sc.map_path
	get_tree().change_scene_to_file(EMPIRE_TEST_SCENE)


func _select_scenario(idx: int) -> void:
	if idx < 0 or idx >= _scenario_buttons.size():
		return
	_selected_idx = idx
	for i in _scenario_buttons.size():
		_apply_btn_style(_scenario_buttons[i], i == idx)
	var sc: Dictionary = _scenarios[idx]
	if _desc_label:
		_desc_label.text = sc.description
	if _map_thumbnail:
		_map_thumbnail.load_from_file(sc.map_path)


func _apply_btn_style(btn: Button, selected: bool) -> void:
	if selected:
		ThemeFactory.apply_button_styles(btn, ThemeFactory.primary_button_styles())
		btn.add_theme_color_override("font_color",         Color.WHITE)
		btn.add_theme_color_override("font_hover_color",   Color.WHITE)
		btn.add_theme_color_override("font_pressed_color", Color.WHITE)
	else:
		ThemeFactory.apply_button_styles(btn, _unselected_styles())
		btn.add_theme_color_override("font_color",         DESC_COLOR)
		btn.add_theme_color_override("font_hover_color",   DESC_COLOR)
		btn.add_theme_color_override("font_pressed_color", DESC_COLOR)


static func _unselected_styles() -> Dictionary:
	return {
		"normal":   ThemeFactory.panel(Color("#e9ecef"), Color("#ced4da"), 1, 12, false),
		"hover":    ThemeFactory.panel(Color("#dee2e6"), Color("#adb5bd"), 1, 12, false),
		"pressed":  ThemeFactory.panel(Color("#ced4da"), Color("#adb5bd"), 1, 12, false),
		"disabled": ThemeFactory.panel(Color("#f1f3f5"), Color("#dee2e6"), 1, 12, false),
	}


# ───────────────────────────────────────────────────────────────────────────
# 内部类：地图缩略图
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
			return
		var json := JSON.new()
		if json.parse(file.get_as_text()) != OK:
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
		var min_x: float = INF;  var max_x: float = -INF
		var min_y: float = INF;  var max_y: float = -INF
		for s in _shapes:
			var x: float = float(s.get("x", 0.0)); var y: float = float(s.get("y", 0.0))
			min_x = min(min_x, x); max_x = max(max_x, x)
			min_y = min(min_y, y); max_y = max(max_y, y)
		var src_w: float = max(max_x - min_x, 1.0)
		var src_h: float = max(max_y - min_y, 1.0)
		var avail_w: float = size.x - PADDING * 2.0
		var avail_h: float = size.y - PADDING * 2.0
		if avail_w <= 0.0 or avail_h <= 0.0:
			return
		var sc: float = min(avail_w / src_w, avail_h / src_h)
		var off_x: float = PADDING + (avail_w - src_w * sc) * 0.5
		var off_y: float = PADDING + (avail_h - src_h * sc) * 0.5

		var id_to_pos: Dictionary = {}
		for s in _shapes:
			id_to_pos[int(s.get("id", -1))] = Vector2(
				off_x + (float(s.get("x", 0.0)) - min_x) * sc,
				off_y + (float(s.get("y", 0.0)) - min_y) * sc)

		for conn in _connections:
			var f := int(conn.get("from", -1)); var t := int(conn.get("to", -1))
			if id_to_pos.has(f) and id_to_pos.has(t):
				draw_line(id_to_pos[f], id_to_pos[t], LINE_COLOR, LINE_WIDTH, true)

		for s in _shapes:
			var pos: Vector2 = id_to_pos[int(s.get("id", -1))]
			var color: Color = _faction_colors.get(int(s.get("faction", 0)), Color.GRAY)
			var kind: String = str(s.get("kind", "circle"))
			var r: float = DOT_RADIUS
			match kind:
				"circle":
					draw_circle(pos, r, color)
					draw_arc(pos, r, 0.0, TAU, 32, Color(0,0,0,0.4), 1.2, true)
				"triangle":
					var pts := PackedVector2Array([
						pos + Vector2(0.0, -r*1.15), pos + Vector2(r, r*0.65), pos + Vector2(-r, r*0.65)])
					draw_colored_polygon(pts, color)
					draw_polyline(PackedVector2Array([pts[0],pts[1],pts[2],pts[0]]), Color(0,0,0,0.4), 1.2, true)
				_:
					var half: float = r * 0.9
					var rect := Rect2(pos - Vector2(half, half), Vector2(half*2.0, half*2.0))
					draw_rect(rect, color)
					draw_rect(rect, Color(0,0,0,0.4), false, 1.2)


# ───────────────────────────────────────────────────────────────────────────
# 内部类：水平弹性滚动容器
# ───────────────────────────────────────────────────────────────────────────
class _ElasticHScroll extends Control:
	const OVERSCROLL_RESISTANCE: float  = 0.55
	const OVERSCROLL_SETTLE_TIME: float = 0.28
	const DRAG_THRESHOLD_PX: float      = 18.0
	const WHEEL_STEP_PX: float          = 60.0

	var _content: Control; var _hbox: HBoxContainer; var _drag_overlay: Control
	var _logical_offset: float = 0.0
	var _pressing: bool = false; var _is_scrolling: bool = false
	var _press_x: float = 0.0;  var _start_offset: float = 0.0
	var _settle_tween: Tween = null

	func _ready() -> void:
		clip_contents = true
		mouse_filter  = Control.MOUSE_FILTER_STOP
		_content = Control.new(); _content.name = "_content"
		_content.mouse_filter = Control.MOUSE_FILTER_PASS
		add_child(_content)
		_hbox = HBoxContainer.new(); _hbox.name = "_hbox"
		_hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
		_content.add_child(_hbox)
		resized.connect(_schedule_layout)
		_hbox.minimum_size_changed.connect(_schedule_layout)

	func get_content_box() -> HBoxContainer: return _hbox

	func _schedule_layout() -> void: call_deferred("_do_layout")

	func _do_layout() -> void:
		if not is_instance_valid(_hbox): return
		var min_w: float = _hbox.get_combined_minimum_size().x
		_content.size = Vector2(max(min_w, size.x), size.y)
		_hbox.size    = _content.size
		_logical_offset = clamp(_logical_offset, 0.0, _max_scroll())
		_apply_offset()

	func _max_scroll() -> float:
		return max(0.0, _content.size.x - size.x) if _content else 0.0

	func _to_display(l: float) -> float:
		var m := _max_scroll()
		if l < 0.0: return -_rubber(-l)
		if l > m:   return m + _rubber(l - m)
		return l

	func _rubber(x: float) -> float:
		var d: float = max(1.0, size.x); var c: float = OVERSCROLL_RESISTANCE
		return (x * c * d) / (d + c * x)

	func _apply_offset() -> void:
		if _content: _content.position.x = -_to_display(_logical_offset)

	func _attach_drag_overlay() -> void:
		if is_instance_valid(_drag_overlay): return
		_drag_overlay = Control.new()
		_drag_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
		_drag_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
		_drag_overlay.z_index = 100; add_child(_drag_overlay)

	func _remove_drag_overlay() -> void:
		if is_instance_valid(_drag_overlay): _drag_overlay.queue_free()
		_drag_overlay = null

	func _settle_to_clamped() -> void:
		if _settle_tween and _settle_tween.is_valid(): _settle_tween.kill()
		var target: float = clamp(_logical_offset, 0.0, _max_scroll())
		if absf(target - _logical_offset) < 0.5:
			_logical_offset = target; _apply_offset(); return
		_settle_tween = create_tween() as Tween
		_settle_tween.tween_method(_set_offset, _logical_offset, target, OVERSCROLL_SETTLE_TIME) \
			.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

	func _set_offset(v: float) -> void: _logical_offset = v; _apply_offset()

	func _input(event: InputEvent) -> void:
		if event is InputEventMouseButton:
			var mb := event as InputEventMouseButton
			if get_global_rect().has_point(mb.global_position):
				if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
					if _settle_tween and _settle_tween.is_valid(): _settle_tween.kill()
					_logical_offset -= WHEEL_STEP_PX; _apply_offset()
					_settle_to_clamped(); get_viewport().set_input_as_handled(); return
				if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
					if _settle_tween and _settle_tween.is_valid(): _settle_tween.kill()
					_logical_offset += WHEEL_STEP_PX; _apply_offset()
					_settle_to_clamped(); get_viewport().set_input_as_handled(); return
			if mb.button_index == MOUSE_BUTTON_LEFT:
				if mb.pressed:
					if get_global_rect().has_point(mb.global_position):
						_pressing = true; _is_scrolling = false
						_press_x = mb.global_position.x; _start_offset = _logical_offset
						if _settle_tween and _settle_tween.is_valid(): _settle_tween.kill()
				else:
					if _pressing:
						if _is_scrolling:
							_settle_to_clamped(); get_viewport().set_input_as_handled()
						_remove_drag_overlay(); _pressing = false; _is_scrolling = false
		elif event is InputEventMouseMotion and _pressing:
			var mm := event as InputEventMouseMotion
			var dx: float = mm.global_position.x - _press_x
			if not _is_scrolling and absf(dx) >= DRAG_THRESHOLD_PX:
				_is_scrolling = true; _attach_drag_overlay()
			if _is_scrolling:
				_logical_offset = _start_offset - dx; _apply_offset()
				get_viewport().set_input_as_handled()
