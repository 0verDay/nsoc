class_name CampaignCarousel
extends Control

# 战役面板左侧"战役"竖向无限轮播。
# 设计沿用 HeroCarousel：
#   - 自身作为裁剪容器（clip_contents=true），尺寸跟父 Panel。
#   - 内部固定 3 个等高占位 page（_pages[0..2]）：分别承载
#     当前页索引的 prev / current / next，高度 = self.size.y。
#   - track 任意时刻位移 -size.y，使 _pages[1]（current）刚好覆盖可视区。
#   - 拖动：实时 track.position.y += dy。
#   - 释放：
#       |dy| >= SNAP_RATIO * page_h → tween snap 到下/上一页（位移整页）
#       |dy| <  阈值              → tween 回弹到原位
#     snap 完成后重排 page 索引并重置 track.position.y = -page_h，视觉无缝。
#   - 数据：3 个固定占位战役（"战役一" / "战役二" / "战役三"），循环展示。
#     未来接入 res://data/campaigns.json 时，把 CAMPAIGN_KEYS 改为运行时数组 +
#     新增 _load_campaign_db()（参 HeroCarousel._load_hero_db）。

# 翻页完成（_current_page 变化）后发出，参数 = 新当前战役 key（CAMPAIGN_KEYS 元素）。
# CampaignPanel 后续可据此刷新右侧描述/章节。
signal current_campaign_changed(campaign_key: String)

# 拖动 / 回弹 / snap 期间持续发出，progress ∈ [-1, 1]：
#   - 0 = 完全停在当前页（章节圆点全显）
#   - ±1 = 已达到 snap 阈值（章节圆点全隐）
#   - 中间值线性比例 = |dy| / (page_h * SNAP_RATIO)，clamp 到 1
# 翻页 tween 完成后会再发一次 0（已切到新页，新页对应圆点全显）。
signal drag_progress(progress: float)

const SNAP_RATIO: float = 0.25
const TWEEN_DURATION: float = 0.18
const DRAG_THRESHOLD_PX: float = 8.0
const PAGE_GAP_PX: float = 24.0
const PAGE_MARGIN_X: float = 16.0
const PAGE_MARGIN_Y: float = 16.0

# 战役 key 列表（循环顺序）。运行时由 _load_campaign_db 从 campaigns.json 读取键序填充；
# JSON 缺失/损坏时回落到 FALLBACK_KEYS 占位。
var CAMPAIGN_KEYS: Array = []
const FALLBACK_KEYS: Array = ["c1", "c2", "c3"]

# 战役显示名 / 描述：运行时从 campaigns.json 加载（_load_campaign_db），
# 缺失时各自回落到 DESC_PLACEHOLDER 与 key 自身。
var _campaign_display_names: Dictionary = {}
var _campaign_descs: Dictionary = {}

const DESC_PLACEHOLDER: String = "暂无描述"

const TEXT_PAD_LEFT: float = 16.0
const TEXT_PAD_RIGHT: float = 12.0
const TEXT_PAD_TOP: float = 8.0
const TEXT_PAD_BOTTOM: float = 8.0

# 遮罩内顶部"战役名"区域所占高度比例（剩余给描述）。
const NAME_HEIGHT_RATIO: float = 0.42

var _track: Control
var _pages: Array[Panel] = []
var _page_labels: Array[Label] = []
var _desc_labels: Array[Label] = []

# 描述遮罩占 page 底部高度比例（25%）。
const DESC_MASK_RATIO: float = 0.25
const DESC_MASK_CORNER_RADIUS: float = 20.0
const DESC_MASK_CORNER_SEGMENTS: int = 12

# 自绘圆角渐变遮罩，参见 HeroCarousel.SkillMask 同款实现。
class DescMask extends Control:
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
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP

	_load_campaign_db()

	_track = Control.new()
	_track.name = "Track"
	_track.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_track)

	for i in 3:
		var page := _make_page()
		_pages.append(page)
		_track.add_child(page)

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

	var mask := DescMask.new()
	mask.name = "DescMask"
	mask.mouse_filter = Control.MOUSE_FILTER_IGNORE
	mask.corner_radius = DESC_MASK_CORNER_RADIUS
	mask.corner_segments = DESC_MASK_CORNER_SEGMENTS
	mask.anchor_top = 1.0 - DESC_MASK_RATIO
	mask.anchor_bottom = 1.0
	mask.anchor_left = 0.0
	mask.anchor_right = 1.0
	mask.offset_left = 0.0
	mask.offset_right = 0.0
	mask.offset_top = 0.0
	mask.offset_bottom = 0.0
	p.add_child(mask)

	var name_lbl := Label.new()
	name_lbl.name = "CampaignName"
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
	name_lbl.offset_left = TEXT_PAD_LEFT
	name_lbl.offset_right = -TEXT_PAD_RIGHT
	name_lbl.offset_top = TEXT_PAD_TOP
	name_lbl.offset_bottom = 0.0
	mask.add_child(name_lbl)
	_page_labels.append(name_lbl)

	var desc_lbl := Label.new()
	desc_lbl.name = "Desc"
	desc_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	desc_lbl.text = DESC_PLACEHOLDER
	desc_lbl.add_theme_font_size_override("font_size", 20)
	desc_lbl.add_theme_color_override("font_color", Color(0.2, 0.2, 0.2))
	desc_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	desc_lbl.vertical_alignment = VERTICAL_ALIGNMENT_TOP
	desc_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	desc_lbl.clip_text = true
	desc_lbl.anchor_left = 0.0
	desc_lbl.anchor_right = 1.0
	desc_lbl.anchor_top = NAME_HEIGHT_RATIO
	desc_lbl.anchor_bottom = 1.0
	desc_lbl.offset_left = TEXT_PAD_LEFT
	desc_lbl.offset_right = -TEXT_PAD_RIGHT
	desc_lbl.offset_top = 0.0
	desc_lbl.offset_bottom = -TEXT_PAD_BOTTOM
	mask.add_child(desc_lbl)
	_desc_labels.append(desc_lbl)
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
		var key: String = _campaign_key_at(_current_page + offset)
		_page_labels[idx].text = String(_campaign_display_names.get(key, key))
		if idx < _desc_labels.size():
			var desc_text: String = String(_campaign_descs.get(key, ""))
			if desc_text == "":
				desc_text = DESC_PLACEHOLDER
			_desc_labels[idx].text = desc_text


func _campaign_key_at(idx: int) -> String:
	var n: int = CAMPAIGN_KEYS.size()
	return CAMPAIGN_KEYS[posmod(idx, n)]


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
			_emit_drag_progress()
			accept_event()


# 当前 _track.position.y 相对静止位（-page_h-gap）的偏移 → 进度 [-1, 1]。
# 上滑（dy < 0，向下一页）→ progress > 0；下滑 → progress < 0。
# 字典层只关心 |progress|（用于 alpha），方向供调用方按需解读。
func _drag_progress_value() -> float:
	if _page_h <= 0.0:
		return 0.0
	var step: float = _page_h + PAGE_GAP_PX
	var delta: float = _track.position.y - (-step)
	var thresh: float = _page_h * SNAP_RATIO
	if thresh <= 0.0:
		return 0.0
	# delta < 0 = 向上滑（页面上移）= 准备翻到下一页 → progress > 0
	return clampf(-delta / thresh, -1.0, 1.0)


func _emit_drag_progress() -> void:
	drag_progress.emit(_drag_progress_value())


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
	tw.set_parallel(true)
	tw.tween_property(_track, "position:y", target_y, TWEEN_DURATION).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	# tween 同步驱动 drag_progress：snap 期间圆点继续渐隐到 0/±1，
	# 回弹（page_delta=0）期间圆点渐显回到 1。
	# 切到新页前先发 ±1（视觉到达），再切 + 立即发 0（新页满显）。
	tw.tween_method(func(_t): _emit_drag_progress(), 0.0, 1.0, TWEEN_DURATION)
	await tw.finished
	if page_delta != 0:
		_current_page += page_delta
		_refresh_labels()
		current_campaign_changed.emit(current_campaign_key())
		# 翻页：圆点的渐显由 campaign_panel 接 current_campaign_changed 后自管 tween。
		# 此处不再发 drag_progress(0)，避免与那段 tween 起冲突。
	else:
		# 回弹：tween 已把 _track 拉回原位，再发一次 0 兜底（防累计误差），
		# 让 box.modulate.a 完全回到 1。
		drag_progress.emit(0.0)
	_track.position.y = -(_page_h + PAGE_GAP_PX)
	_animating = false


# 当前显示中的战役 key（CAMPAIGN_KEYS 中的元素，如 "c1"）。
func current_campaign_key() -> String:
	return _campaign_key_at(_current_page)


# 从 res://data/campaigns.json 装填战役 key 顺序、显示名与描述。
# 失败时 CAMPAIGN_KEYS 回落到 FALLBACK_KEYS，文案字典保持空，
# _refresh_labels 会显示 key 自身 + DESC_PLACEHOLDER 兜底。
func _load_campaign_db() -> void:
	CAMPAIGN_KEYS.clear()
	_campaign_display_names.clear()
	_campaign_descs.clear()
	var db: Dictionary = DataLoader.load_campaign_db()
	var campaigns: Dictionary = db.get("campaigns", {})
	for key in campaigns.keys():
		var key_str := String(key)
		CAMPAIGN_KEYS.append(key_str)
		var data = campaigns[key]
		if typeof(data) != TYPE_DICTIONARY:
			continue
		if data.has("display_name"):
			_campaign_display_names[key_str] = String(data["display_name"])
		if data.has("description"):
			_campaign_descs[key_str] = String(data["description"])
	if CAMPAIGN_KEYS.is_empty():
		CAMPAIGN_KEYS = FALLBACK_KEYS.duplicate()
