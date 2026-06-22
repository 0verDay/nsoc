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
var _map_thumbnail: EmpireMapThumbnail
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
	_map_thumbnail = EmpireMapThumbnail.new()
	_map_thumbnail.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_map_thumb_pnl.add_child(_map_thumbnail)


# ── 轮播按钮 ─────────────────────────────────────────────────────────────────
func _build_carousel() -> void:
	var scroll := EmpireHScroll.new()
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
