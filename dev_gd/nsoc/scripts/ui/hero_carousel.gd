class_name HeroCarousel
extends Control

# 备战面板左侧"英雄"竖向无限轮播。
# 设计：
#   - 自身作为裁剪容器（clip_contents=true），尺寸跟父 Panel。
#   - 内部固定 3 个等高占位 page（_pages[0..2]）：分别承载
#     当前页索引的 prev / current / next，高度 = self.size.y。
#   - track 任意时刻位移 -size.y，使 _pages[1]（current）刚好覆盖可视区。
#   - 拖动：实时 track.position.y += dy。
#   - 释放：
#       |dy| >= SNAP_RATIO * page_h → tween snap 到下/上一页（位移整页）
#       |dy| <  阈值              → tween 回弹到原位
#     snap 完成后重排 page 索引并重置 track.position.y = -page_h，视觉无缝。
#   - 数据：3 个固定占位英雄（"英雄#1" / "英雄#2" / "英雄#3"），循环展示。

# 翻页完成（_current_page 变化）后发出，参数 = 新当前英雄 key（HERO_NAMES 元素）。
# 用于 PreparePanel 切英雄时保存旧卡组、加载新卡组。
signal current_hero_changed(hero_key: String)

const SNAP_RATIO: float = 0.25
const TWEEN_DURATION: float = 0.18
const DRAG_THRESHOLD_PX: float = 8.0
const PAGE_GAP_PX: float = 24.0
# 单块英雄面板四周内缩，让阴影/圆角不被 HeroPnl 边界裁掉。
const PAGE_MARGIN_X: float = 16.0
const PAGE_MARGIN_Y: float = 16.0

# 占位英雄列表，循环展示。后续替换为真实数据。
const HERO_NAMES: Array = ["A", "B", "C"]

# 英雄显示名（遮罩内大字号标题）。键缺失时回落到 HERO_NAMES 中的代号。
const HERO_DISPLAY_NAMES: Dictionary = {
	"A": "往日之王：科因",
}

# 英雄技能文案表。键缺失时回落 SKILL_PLACEHOLDER。
const HERO_SKILLS: Dictionary = {
	"A": "再起：消耗 1 费用，弃置所有手牌，然后重新补满 5 张。",
}

# 技能遮罩占位文字（后续接入英雄真实技能时替换）。
const SKILL_PLACEHOLDER: String = "技能"

# 技能文字内边距（相对遮罩区域）。
const SKILL_TEXT_PAD_LEFT: float = 16.0
const SKILL_TEXT_PAD_RIGHT: float = 12.0
const SKILL_TEXT_PAD_TOP: float = 8.0
const SKILL_TEXT_PAD_BOTTOM: float = 8.0

# 遮罩内顶部"英雄名"区域所占高度比例（剩余给技能描述）。
const NAME_HEIGHT_RATIO: float = 0.42

var _track: Control
var _pages: Array[Panel] = []
var _page_labels: Array[Label] = []
var _skill_labels: Array[Label] = []

# 技能遮罩占 page 底部高度比例（25%）。
const SKILL_MASK_RATIO: float = 0.25
# 遮罩底部圆角，与 page 圆角(20) 一致以贴合卡片轮廓。
const SKILL_MASK_CORNER_RADIUS: float = 20.0
# 圆角细分段数（越大越平滑）。
const SKILL_MASK_CORNER_SEGMENTS: int = 12

# 自绘圆角渐变遮罩。Panel 圆角 + 普通 TextureRect 无法同时满足
# "底部圆角 + 竖向渐变"，故用自定义 Control 直接绘制带顶点色的圆角多边形。
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

		# 顶左 → 顶右
		pts.append(Vector2(0, 0))
		cols.append(top_color)
		pts.append(Vector2(w, 0))
		cols.append(top_color)

		# 右下圆角：圆心 (w-r, h-r)，角度 0 → 90°（顺时针描底边右段）
		var steps: int = max(1, corner_segments)
		for i in range(0, steps + 1):
			var a: float = (PI * 0.5) * (float(i) / float(steps))
			var x: float = (w - r) + r * cos(a)
			var y: float = (h - r) + r * sin(a)
			pts.append(Vector2(x, y))
			cols.append(_color_at_y(y, h))

		# 左下圆角：圆心 (r, h-r)，角度 90° → 180°
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
	# size 在初始 _ready 时可能为 0，等一帧让 anchor 生效再布局。
	await get_tree().process_frame
	_layout_pages()


func _make_page() -> Panel:
	var p := Panel.new()
	p.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 每个 page 自带"英雄面板"样式（与 HeroPnl 原样式一致）。
	# 这样滑动时整张面板（含边框/圆角/阴影）跟随位移，HeroPnl 自身保持透明仅作裁剪。
	p.add_theme_stylebox_override(
		"panel",
		ThemeFactory.panel(Color.WHITE, Color(1, 1, 1, 0.6), 1, 20, true)
	)

	# 下方 25% 灰白渐变遮罩，自带底部圆角（与 page 圆角一致）。
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

	# 遮罩上方：英雄显示名（大字号，左对齐）
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

	# 遮罩下方：技能文字（左对齐，自动换行）
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


# 重新布局 3 个 page：垂直堆叠（带 PAGE_GAP_PX 间距），每页四周 PAGE_MARGIN 让阴影/圆角可见。
# slot 步长 step = self.size.y + GAP；track 起始 y = -step，使 _pages[1]（current）位于可视区。
func _layout_pages() -> void:
	_page_h = size.y
	var step: float = _page_h + PAGE_GAP_PX
	var page_w: float = size.x - PAGE_MARGIN_X * 2.0
	var page_inner_h: float = _page_h - PAGE_MARGIN_Y * 2.0
	for i in _pages.size():
		var p: Panel = _pages[i]
		# slot 顶 = i*step；page 在 slot 内居中收缩 → +MARGIN_Y。
		p.position = Vector2(PAGE_MARGIN_X, float(i) * step + PAGE_MARGIN_Y)
		p.size = Vector2(page_w, page_inner_h)
	_track.size = Vector2(size.x, step * float(_pages.size()))
	_track.position = Vector2(0, -step)
	_refresh_labels()


# 根据 _current_page 刷新三页文字：prev / current / next。
# _current_page 取模 HERO_NAMES.size()，实现 3 个英雄循环。
# 英雄显示名查 HERO_DISPLAY_NAMES；技能文字查 HERO_SKILLS。两者缺键各自回落。
func _refresh_labels() -> void:
	if _page_labels.size() < 3:
		return
	for offset in range(-1, 2):
		var idx: int = offset + 1
		var hero_key: String = _hero_name_at(_current_page + offset)
		_page_labels[idx].text = HERO_DISPLAY_NAMES.get(hero_key, hero_key)
		if idx < _skill_labels.size():
			_skill_labels[idx].text = HERO_SKILLS.get(hero_key, SKILL_PLACEHOLDER)


# posmod 取模，处理负数，使 -1 映射到末位。
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


# 释放后判定：超阈值 → 翻页 tween；否则回弹。
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
	# 重置 track 回到中间页对齐位置，视觉无缝。
	_track.position.y = -(_page_h + PAGE_GAP_PX)
	_animating = false


# 当前显示中的英雄 key（HERO_NAMES 中的元素，如 "A"）。
func current_hero_key() -> String:
	return _hero_name_at(_current_page)
