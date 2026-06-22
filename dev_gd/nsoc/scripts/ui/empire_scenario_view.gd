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
var _map_thumbnail: EmpireMapThumbnail
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
	_map_thumbnail = EmpireMapThumbnail.new()
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
