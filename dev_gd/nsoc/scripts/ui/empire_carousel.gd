class_name EmpireCarousel
extends Control

# 帝国"军队"面板专用的将领竖向无限轮播。
# 结构与 HeroCarousel 完全一致，但独立读 res://data/empire_hero.json，
# 并使用 EmpireDeckStorage 而非 DeckStorage，确保与主菜单备战面板的状态完全隔离。

signal current_hero_changed(hero_key: String)

const SNAP_RATIO: float = 0.25
const TWEEN_DURATION: float = 0.18
const DRAG_THRESHOLD_PX: float = 8.0
const PAGE_GAP_PX: float = 24.0
const PAGE_MARGIN_X: float = 16.0
const PAGE_MARGIN_Y: float = 16.0

const HERO_NAMES: Array = ["A", "B", "C"]

const EMPIRE_HERO_JSON: String = "res://data/empire_hero.json"

const SKILL_PLACEHOLDER: String = "技能"

const SKILL_TEXT_PAD_LEFT: float = 16.0
const SKILL_TEXT_PAD_RIGHT: float = 12.0
const SKILL_TEXT_PAD_TOP: float = 8.0
const SKILL_TEXT_PAD_BOTTOM: float = 8.0

const NAME_HEIGHT_RATIO: float = 0.42

var _hero_display_names: Dictionary = {}
var _hero_skills: Dictionary = {}

var _track: Control
var _pages: Array[Panel] = []
var _page_labels: Array[Label] = []
var _skill_labels: Array[Label] = []

const SKILL_MASK_RATIO: float = 0.25
const SKILL_MASK_CORNER_RADIUS: float = 20.0
const SKILL_MASK_CORNER_SEGMENTS: int = 12


class SkillMask extends Control:
	var top_color: Color = Color(1, 1, 1, 0.95)
	var bot_color: Color = Color(0.55, 0.55, 0.55, 0.9)
	var corner_radius: float = 20.0
	var corner_segments: int = 12

	func _ready() -> void:
		resized.connect(queue_redraw)

	func _draw() -> void:
		var w: float = size.x
		var h: float = size.y
		if w <= 0.0 or h <= 0.0:
			return
		var r: float = min(corner_radius, min(w * 0.5, h))
		var pts := PackedVector2Array()
		var cols := PackedColorArray()

		pts.append(Vector2(0, 0))
		cols.append(top_color)
		pts.append(Vector2(w, 0))
		cols.append(top_color)

		var steps: int = max(1, corner_segments)
		for i in range(0, steps + 1):
			var a: float = (PI * 0.5) * (float(i) / float(steps))
			var x: float = (w - r) + r * cos(a)
			var y: float = (h - r) + r * sin(a)
			pts.append(Vector2(x, y))
			cols.append(_color_at_y(y, h))

		for i in range(0, steps + 1):
			var a: float = (PI * 0.5) + (PI * 0.5) * (float(i) / float(steps))
			var x: float = r + r * cos(a)
			var y: float = (h - r) + r * sin(a)
			pts.append(Vector2(x, y))
			cols.append(_color_at_y(y, h))

		draw_polygon(pts, cols)

	func _color_at_y(y: float, h: float) -> Color:
		var t: float = clamp(y / h, 0.0, 1.0)
		return top_color.lerp(bot_color, t)


var _current_page: int = 0
var _page_h: float = 0.0

var _pressing: bool = false
var _dragging: bool = false
var _press_y: float = 0.0
var _start_track_y: float = 0.0
var _animating: bool = false


func _ready() -> void:
	_load_hero_db()
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP

	_track = Control.new()
	_track.name = "Track"
	_track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_track)

	for i in 3:
		var page := _make_page()
		_pages.append(page)
		_track.add_child(page)

	var saved_hero: String = EmpireDeckStorage.get_selected_hero()
	var saved_idx: int = HERO_NAMES.find(saved_hero)
	if saved_idx >= 0:
		_current_page = saved_idx

	gui_input.connect(_on_gui_input)
	resized.connect(_layout_pages)
	await get_tree().process_frame
	_layout_pages()


func _make_page() -> Panel:
	var p := Panel.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	p.add_theme_stylebox_override(
		"panel",
		ThemeFactory.panel(Color.WHITE, Color(1, 1, 1, 0.6), 1, 20, true)
	)

	var mask := SkillMask.new()
	mask.name = "SkillMask"
	mask.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mask.corner_radius = SKILL_MASK_CORNER_RADIUS
	mask.corner_segments = SKILL_MASK_CORNER_SEGMENTS
	mask.anchor_top = 1.0 - SKILL_MASK_RATIO
	mask.anchor_bottom = 1.0
	mask.anchor_left = 0.0
	mask.anchor_right = 1.0
	mask.offset_left = 0.0
	mask.offset_right = 0.0
	mask.offset_top = 0.0
	mask.offset_bottom = 0.0
	p.add_child(mask)

	var name_lbl := Label.new()
	name_lbl.name = "HeroName"
	name_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	name_lbl.add_theme_font_size_override("font_size", 34)
	name_lbl.add_theme_color_override("font_color", Color(0.1, 0.1, 0.1))
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	name_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	name_lbl.clip_text = true
	name_lbl.anchor_left = 0.0
	name_lbl.anchor_right = 1.0
	name_lbl.anchor_top = 0.0
	name_lbl.anchor_bottom = NAME_HEIGHT_RATIO
	name_lbl.offset_left = SKILL_TEXT_PAD_LEFT
	name_lbl.offset_right = -SKILL_TEXT_PAD_RIGHT
	name_lbl.offset_top = SKILL_TEXT_PAD_TOP
	name_lbl.offset_bottom = 0.0
	mask.add_child(name_lbl)
	_page_labels.append(name_lbl)

	var skill_lbl := Label.new()
	skill_lbl.name = "Skill"
	skill_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	skill_lbl.text = SKILL_PLACEHOLDER
	skill_lbl.add_theme_font_size_override("font_size", 20)
	skill_lbl.add_theme_color_override("font_color", Color(0.2, 0.2, 0.2))
	skill_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	skill_lbl.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	skill_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	skill_lbl.clip_text = true
	skill_lbl.anchor_left = 0.0
	skill_lbl.anchor_right = 1.0
	skill_lbl.anchor_top = NAME_HEIGHT_RATIO
	skill_lbl.anchor_bottom = 1.0
	skill_lbl.offset_left = SKILL_TEXT_PAD_LEFT
	skill_lbl.offset_right = -SKILL_TEXT_PAD_RIGHT
	skill_lbl.offset_top = 0.0
	skill_lbl.offset_bottom = -SKILL_TEXT_PAD_BOTTOM
	mask.add_child(skill_lbl)
	_skill_labels.append(skill_lbl)
	return p


func _layout_pages() -> void:
	_page_h = size.y
	var step: float = _page_h + PAGE_GAP_PX
	var page_w: float = size.x - PAGE_MARGIN_X * 2.0
	var page_inner_h: float = _page_h - PAGE_MARGIN_Y * 2.0
	for i in _pages.size():
		var p: Panel = _pages[i]
		p.position = Vector2(PAGE_MARGIN_X, float(i) * step + PAGE_MARGIN_Y)
		p.size = Vector2(page_w, page_inner_h)
	_track.size = Vector2(size.x, step * float(_pages.size()))
	_track.position = Vector2(0, -step)
	_refresh_labels()


func _refresh_labels() -> void:
	if _page_labels.size() < 3:
		return
	for offset in range(-1, 2):
		var idx: int = offset + 1
		var hero_key: String = _hero_name_at(_current_page + offset)
		_page_labels[idx].text = String(_hero_display_names.get(hero_key, hero_key))
		if idx < _skill_labels.size():
			var skill_text: String = String(_hero_skills.get(hero_key, ""))
			if skill_text == "":
				skill_text = SKILL_PLACEHOLDER
			_skill_labels[idx].text = skill_text


# 直接读 empire_hero.json，不走 DataLoader.load_hero_db（其路径写死 hero.json）。
func _load_hero_db() -> void:
	_hero_display_names.clear()
	_hero_skills.clear()
	if not FileAccess.file_exists(EMPIRE_HERO_JSON):
		push_warning("EmpireCarousel: missing " + EMPIRE_HERO_JSON)
		return
	var f := FileAccess.open(EMPIRE_HERO_JSON, FileAccess.READ)
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	var heroes = parsed.get("heroes", {})
	if typeof(heroes) != TYPE_DICTIONARY:
		return
	for key in heroes.keys():
		var data: Dictionary = heroes[key]
		if data.has("display_name"):
			_hero_display_names[String(key)] = String(data["display_name"])
		if data.has("skill_text"):
			_hero_skills[String(key)] = String(data["skill_text"])


func _hero_name_at(idx: int) -> String:
	var n: int = HERO_NAMES.size()
	return HERO_NAMES[posmod(idx, n)]


func _on_gui_input(event: InputEvent) -> void:
	if _animating:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_pressing = true
			_dragging = false
			_press_y = event.global_position.y
			_start_track_y = _track.position.y
		else:
			if _pressing:
				_pressing = false
				if _dragging:
					_dragging = false
					accept_event()
					_settle()
	elif event is InputEventMouseMotion and _pressing:
		var dy: float = event.global_position.y - _press_y
		if not _dragging and absf(dy) >= DRAG_THRESHOLD_PX:
			_dragging = true
		if _dragging:
			_track.position.y = _start_track_y + dy
			accept_event()


func _settle() -> void:
	var step: float = _page_h + PAGE_GAP_PX
	var delta: float = _track.position.y - (-step)
	var snap: float = _page_h * SNAP_RATIO
	if delta <= -snap:
		_animate_to(-step * 2.0, +1)
	elif delta >= snap:
		_animate_to(0.0, -1)
	else:
		_animate_to(-step, 0)


func _animate_to(target_y: float, page_delta: int) -> void:
	_animating = true
	var tw := create_tween()
	tw.tween_property(_track, "position:y", target_y, TWEEN_DURATION).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	await tw.finished
	if page_delta != 0:
		_current_page += page_delta
		_refresh_labels()
		current_hero_changed.emit(current_hero_key())
	_track.position.y = -(_page_h + PAGE_GAP_PX)
	_animating = false


func current_hero_key() -> String:
	return _hero_name_at(_current_page)
