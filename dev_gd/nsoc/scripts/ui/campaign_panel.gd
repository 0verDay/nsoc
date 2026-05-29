extends SecondaryPanel

# 战役面板。继承 SecondaryPanel 复用 BackBtn 风格 + 转场淡入淡出。
# 自身只做：
#   - 子面板风格化（CampaignPnl 透明 + 三大占位面板蓝白款）
#   - 监听 Carousel.current_campaign_changed 信号，按当前战役重建 ChapterPnl 章节圆点
#   - DescPnl 内显示当前章节标题/描述，监听水平拖动切章节（无动效）
#
# 子节点（详见 CampaignPanel.tscn）：
#   CampaignPnl  : 左 1/4，全高，作为 Carousel 的透明裁剪容器（同 PreparePanel.HeroPnl）
#   ChapterPnl   : 顶部条带，BackBtn 左侧。横向 HBox 内按当前战役章节数等分铺圆点
#   DescPnl      : 下方主区域，显示章节标题 + 描述，水平拖动切章节
#   BackBtn      : 右上，由 SecondaryPanel 处理风格 + 信号

@onready var campaign_pnl: Panel = $CampaignPnl
@onready var chapter_pnl: Panel = $ChapterPnl
@onready var desc_pnl: Panel = $DescPnl
@onready var carousel: CampaignCarousel = $CampaignPnl/Carousel

# ChapterPnl 内的按钮容器（HBoxContainer），_build_chapter_container 时缓存。
var _chapter_box: HBoxContainer

# DescPnl 内的章节标题/描述 Label，_build_desc_container 时缓存。
# 两者挂在 _desc_group（DescPnl 全填 Control）下，切章节时整体平移 + 渐隐渐显。
var _desc_group: Control
var _desc_title: Label
var _desc_body: RichTextLabel

# 切章节文本动效活跃 tween；切章节中再次切换需要 kill 上一个避免视觉错乱。
var _desc_anim_tween: Tween

# 当前战役的章节数据 + 当前展示章节索引。
# _chapters 元素结构：{"name": String, "description": String}
var _chapters: Array = []
var _current_chapter_idx: int = 0

# DescPnl 水平拖动状态。
var _desc_pressing: bool = false
var _desc_press_x: float = 0.0
var _desc_press_y: float = 0.0
var _desc_swiped: bool = false   # 本次按下已触发过切章节，避免单次拖动连切多章节
# 长按进度环 + 进度状态。
# _long_press_active：按下中且未取消（拖动/松手会清掉）。
# _long_press_elapsed：按下累计秒数。_process 推进，达到 REVEAL 才创建 ring，
# 达到 DURATION 触发业务。
# _long_press_pos：按下点的 desc_pnl 局部坐标（ring 出现位置）。
var _long_press_active: bool = false
var _long_press_elapsed: float = 0.0
var _long_press_pos: Vector2 = Vector2.ZERO
var _long_press_ring: LongPressRing


# 自绘环形进度条。progress ∈ [0, 1]：
#   - 整圈底色 RING_BG_COLOR
#   - 顶部 12 点起按 progress 顺时针绘制 RING_FG_COLOR 弧段
# 用 draw_polyline 绘制粗弧（线段拼成圆环），thickness 即线宽。
class LongPressRing extends Control:
	var progress: float = 0.0:
		set(value):
			progress = clampf(value, 0.0, 1.0)
			queue_redraw()
	var radius: float = 36.0
	var thickness: float = 6.0
	var bg_color: Color = Color(0, 0, 0, 0.18)
	var fg_color: Color = Color("#339af0")
	var segments: int = 64

	func _ready() -> void:
		mouse_filter = Control.MOUSE_FILTER_IGNORE
		# 用 size 0；自绘超出 control rect，靠父节点不裁切（DescPnl 已在更外层），
		# 但 DescPnl 视觉边界内即可。
		custom_minimum_size = Vector2.ZERO

	func _draw() -> void:
		var center := Vector2.ZERO
		# 底环：完整圆。
		var bg_pts := PackedVector2Array()
		for i in segments + 1:
			var a: float = TAU * float(i) / float(segments) - PI * 0.5
			bg_pts.append(center + Vector2(cos(a), sin(a)) * radius)
		draw_polyline(bg_pts, bg_color, thickness, true)

		# 前景弧：从 -PI/2（12 点）顺时针 progress 比例。
		if progress <= 0.0:
			return
		var fg_segs: int = max(2, int(ceil(float(segments) * progress)))
		var fg_pts := PackedVector2Array()
		for i in fg_segs + 1:
			var t: float = float(i) / float(segments)
			if t > progress:
				t = progress
			var a: float = TAU * t - PI * 0.5
			fg_pts.append(center + Vector2(cos(a), sin(a)) * radius)
		draw_polyline(fg_pts, fg_color, thickness, true)

# 章节圆点视觉参数。
const CHAPTER_PAD_X: float = 16.0
const CHAPTER_PAD_Y: float = 12.0
const CHAPTER_GAP: int = 12
const CHAPTER_DOT_SIZE: int = 16
const CHAPTER_DOT_COLOR := Color("#339af0")
const CHAPTER_DOT_INACTIVE_COLOR := Color("#bcd8f0")
# 切战役后新章节圆点渐显时长（与 CampaignCarousel.TWEEN_DURATION 同量级）。
const CHAPTER_FADE_IN_DURATION: float = 0.18

# DescPnl 文本布局/字号。
const DESC_PAD: float = 32.0
const DESC_TITLE_FONT_SIZE: int = 36
const DESC_BODY_FONT_SIZE: int = 22
const DESC_TITLE_HEIGHT: float = 80.0

# DescPnl 水平拖动切章节阈值（像素）。
const DESC_SWIPE_THRESHOLD_PX: float = 80.0

# DescPnl 长按进入章节阈值（秒）。
# 总时长 DESC_LONG_PRESS_DURATION 进度环走满 → 触发 _on_chapter_long_pressed。
# 前 DESC_LONG_PRESS_REVEAL 秒为"决策窗口"：
#   - 进度环不显示（计时仍在走）
#   - 玩家可在此期间拖动触发滑动切章节，会取消长按
# 越过 REVEAL 仍未拖动 → 进度环渐显（此时已走过 REVEAL/DURATION 进度），
# 之后不再响应拖动切章节，视为玩家已锁定长按意图。
const DESC_LONG_PRESS_DURATION: float = 3.0
const DESC_LONG_PRESS_REVEAL: float = 1.0
const DESC_LONG_PRESS_FADE_IN: float = 0.18

# 长按环形进度条视觉。
const RING_RADIUS: float = 56.0
const RING_THICKNESS: float = 8.0
const RING_BG_COLOR := Color(0.0, 0.0, 0.0, 0.18)
const RING_FG_COLOR := Color("#339af0")
const RING_SEGMENTS: int = 64

# 切章节文本动效：水平位移 + 渐隐渐显。
# 出场组从 0 移到 ±OFFSET（同滑动方向）+ alpha 1→0；
# 入场组从 ∓OFFSET 移到 0 + alpha 0→1。
const DESC_ANIM_OFFSET_PX: float = 60.0
const DESC_ANIM_DURATION: float = 0.18

# 底部提示文字。
const DESC_FOOTER_TEXT: String = "————长按进入章节————"
const DESC_FOOTER_FONT_SIZE: int = 20
const DESC_FOOTER_HEIGHT: float = 40.0
const DESC_FOOTER_BOTTOM_PAD: float = 16.0


func _apply_styles() -> void:
	# CampaignPnl 不应用样式：作为透明裁剪容器，由 CampaignCarousel 内的每个 page
	# 自带"白底 + 边框 + 圆角 + 阴影"，与 PreparePanel.HeroPnl 一致。
	campaign_pnl.add_theme_stylebox_override("panel", StyleBoxEmpty.new())

	# ChapterPnl / DescPnl 与备战界面 ReviewPnl 同款：白底 + 浅边 + 圆角 + 投影。
	var pnl_style := ThemeFactory.panel(Color.WHITE, Color(1, 1, 1, 0.6), 1, 20, true)
	chapter_pnl.add_theme_stylebox_override("panel", pnl_style)
	desc_pnl.add_theme_stylebox_override("panel", pnl_style)

	_build_chapter_container()
	_build_desc_container()

	# 战役切换 → 重建章节圆点 + 重置章节索引到 0 + 刷新描述。
	if carousel:
		carousel.current_campaign_changed.connect(_on_campaign_changed)
		carousel.drag_progress.connect(_on_drag_progress)
		# 初次进入也要渲染：以 carousel 当前页 key 为初始战役。
		_refresh_chapters(carousel.current_campaign_key())


# 在 ChapterPnl 内建一个填满的 HBoxContainer 作为章节圆点容器。
# 后续 _refresh_chapters 只往 _chapter_box 加/清子节点。
func _build_chapter_container() -> void:
	for c in chapter_pnl.get_children():
		c.queue_free()
	var box := HBoxContainer.new()
	box.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	box.offset_left = CHAPTER_PAD_X
	box.offset_right = -CHAPTER_PAD_X
	box.offset_top = CHAPTER_PAD_Y
	box.offset_bottom = -CHAPTER_PAD_Y
	box.add_theme_constant_override("separation", CHAPTER_GAP)
	box.alignment = BoxContainer.ALIGNMENT_CENTER
	chapter_pnl.add_child(box)
	_chapter_box = box


# 在 DescPnl 内建标题 + 描述两层 Label，外加 gui_input 监听做水平滑动切章节。
# DescPnl 自身 mouse_filter 设为 STOP，确保拖动事件落在它身上而非透到下层。
# title/body 都挂在 _desc_group 下，切章节时对 group 整体做位移 + alpha tween。
func _build_desc_container() -> void:
	for c in desc_pnl.get_children():
		c.queue_free()
	desc_pnl.mouse_filter = Control.MOUSE_FILTER_STOP
	# 注意：clip_contents 设在 desc_pnl 上会连带裁掉自身 stylebox 的圆角阴影外溢。
	# 改设在内层 _desc_group：仅裁切平移中的文字，DescPnl 圆角/阴影正常渲染。
	if not desc_pnl.gui_input.is_connected(_on_desc_gui_input):
		desc_pnl.gui_input.connect(_on_desc_gui_input)

	var group := Control.new()
	group.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	group.mouse_filter = Control.MOUSE_FILTER_IGNORE
	group.clip_contents = true
	desc_pnl.add_child(group)
	_desc_group = group

	var title := Label.new()
	title.set_anchors_preset(Control.PRESET_TOP_WIDE, false)
	title.offset_left = DESC_PAD
	title.offset_right = -DESC_PAD
	title.offset_top = DESC_PAD
	title.offset_bottom = DESC_PAD + DESC_TITLE_HEIGHT
	title.add_theme_font_size_override("font_size", DESC_TITLE_FONT_SIZE)
	title.add_theme_color_override("font_color", Color(0.1, 0.1, 0.1))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	group.add_child(title)
	_desc_title = title

	var body := RichTextLabel.new()
	body.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	body.offset_left = DESC_PAD
	body.offset_right = -DESC_PAD
	body.offset_top = DESC_PAD * 2.0 + DESC_TITLE_HEIGHT
	body.offset_bottom = -DESC_PAD
	body.add_theme_font_size_override("normal_font_size", DESC_BODY_FONT_SIZE)
	body.add_theme_color_override("default_color", Color(0.25, 0.25, 0.25))
	body.bbcode_enabled = true
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.scroll_active = false
	body.fit_content = false
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	group.add_child(body)
	_desc_body = body

	# 底部提示："————长按进入章节————"。
	# 不放进 _desc_group：切章节动效只对 group 平移渐变，提示文字保持静止。
	var footer := Label.new()
	footer.text = DESC_FOOTER_TEXT
	footer.set_anchors_preset(Control.PRESET_BOTTOM_WIDE, false)
	footer.offset_left = DESC_PAD
	footer.offset_right = -DESC_PAD
	footer.offset_top = -(DESC_FOOTER_HEIGHT + DESC_FOOTER_BOTTOM_PAD)
	footer.offset_bottom = -DESC_FOOTER_BOTTOM_PAD
	footer.add_theme_font_size_override("font_size", DESC_FOOTER_FONT_SIZE)
	footer.add_theme_color_override("font_color", Color(0.45, 0.45, 0.45))
	footer.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	footer.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	footer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	desc_pnl.add_child(footer)


# 启动长按计时：仅记按下点 + 标记 active，进度环延迟到 _process 内 elapsed
# 达到 REVEAL 才创建（误触不闪环）。
func _start_long_press(local_pos: Vector2) -> void:
	_cancel_long_press()
	_long_press_active = true
	_long_press_elapsed = 0.0
	_long_press_pos = local_pos


func _cancel_long_press() -> void:
	_long_press_active = false
	_long_press_elapsed = 0.0
	if _long_press_ring and is_instance_valid(_long_press_ring):
		_long_press_ring.queue_free()
	_long_press_ring = null


# 每帧推进长按进度。仅在 _long_press_active 时工作；
# elapsed 越过 REVEAL → 创建 ring 渐显；越过 DURATION → 触发业务。
# ring 的 progress 实时同步 elapsed/DURATION，保证视觉与计时一致。
func _process(delta: float) -> void:
	if not _long_press_active:
		return
	_long_press_elapsed += delta

	# 越过显示阈值：创建 ring + alpha 0→1 渐显。
	if _long_press_ring == null and _long_press_elapsed >= DESC_LONG_PRESS_REVEAL:
		var ring := LongPressRing.new()
		ring.radius = RING_RADIUS
		ring.thickness = RING_THICKNESS
		ring.bg_color = RING_BG_COLOR
		ring.fg_color = RING_FG_COLOR
		ring.segments = RING_SEGMENTS
		ring.position = _long_press_pos
		ring.modulate.a = 0.0
		desc_pnl.add_child(ring)
		_long_press_ring = ring
		var tw := create_tween()
		tw.tween_property(ring, "modulate:a", 1.0, DESC_LONG_PRESS_FADE_IN).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)

	# 同步 ring 进度。
	if _long_press_ring and is_instance_valid(_long_press_ring):
		_long_press_ring.progress = clampf(_long_press_elapsed / DESC_LONG_PRESS_DURATION, 0.0, 1.0)

	# 达到总时长 → 业务触发，结束。
	if _long_press_elapsed >= DESC_LONG_PRESS_DURATION:
		var idx: int = _current_chapter_idx
		_cancel_long_press()
		_on_chapter_long_pressed(idx)


# 按 campaign_key 从 campaigns.json 取章节数组并重建圆点 + 缓存章节数据。
# 每次切战役都重置当前章节索引为 0 + 刷新 DescPnl 文本。
func _refresh_chapters(campaign_key: String) -> void:
	_chapters.clear()
	_current_chapter_idx = 0

	if _chapter_box != null:
		for c in _chapter_box.get_children():
			c.queue_free()

	var db: Dictionary = DataLoader.load_campaign_db()
	var campaigns: Dictionary = db.get("campaigns", {})
	var entry = campaigns.get(campaign_key, null)
	if typeof(entry) == TYPE_DICTIONARY:
		var chapters_raw = entry.get("chapters", [])
		if typeof(chapters_raw) == TYPE_ARRAY:
			for ch in chapters_raw:
				if typeof(ch) == TYPE_DICTIONARY:
					_chapters.append({
						"name": String(ch.get("name", "")),
						"description": String(ch.get("description", "")),
						"scene": String(ch.get("scene", "")),
					})
				else:
					_chapters.append({"name": String(ch), "description": "", "scene": ""})

	# 圆点 add_child 时直接按当前 idx 标 active/inactive 颜色，避免事后查找
	# get_node("Dot") 在某些时序下可能拿不到（之前的写法是 bug 来源）。
	if _chapter_box != null:
		for i in _chapters.size():
			var is_active: bool = (i == _current_chapter_idx)
			_chapter_box.add_child(_make_chapter_dot(is_active))
	# 切战役：杀掉可能在跑的章节切换 tween，复位 group 的 position/alpha，
	# 然后直接刷新文本（不走章节切换动画，新战役章节全新）。
	if _desc_anim_tween and _desc_anim_tween.is_valid():
		_desc_anim_tween.kill()
	if _desc_group != null:
		_desc_group.position.x = 0.0
		_desc_group.modulate.a = 1.0
	_refresh_desc_text()


# 圆点：透明 wrapper 等分槽位 + 内部 Panel 全圆角填色。
# active=true → 主蓝；false → 浅蓝。
func _make_chapter_dot(active: bool = false) -> Control:
	var wrapper := Control.new()
	wrapper.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	wrapper.size_flags_vertical = Control.SIZE_EXPAND_FILL
	wrapper.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var dot := Panel.new()
	dot.name = "Dot"
	dot.custom_minimum_size = Vector2(CHAPTER_DOT_SIZE, CHAPTER_DOT_SIZE)
	dot.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	dot.set_anchors_preset(Control.PRESET_CENTER, false)
	dot.offset_left = -CHAPTER_DOT_SIZE * 0.5
	dot.offset_right = CHAPTER_DOT_SIZE * 0.5
	dot.offset_top = -CHAPTER_DOT_SIZE * 0.5
	dot.offset_bottom = CHAPTER_DOT_SIZE * 0.5
	dot.mouse_filter = Control.MOUSE_FILTER_IGNORE
	var color: Color = CHAPTER_DOT_COLOR if active else CHAPTER_DOT_INACTIVE_COLOR
	dot.add_theme_stylebox_override("panel", ThemeFactory.pill(color, int(CHAPTER_DOT_SIZE * 0.5), true))
	wrapper.add_child(dot)
	return wrapper


# 切章节后高亮当前圆点（原地刷 stylebox，不重建）。
# 用于 DescPnl 滑动切章节时同步圆点。切战役走 _refresh_chapters，那条路径
# 在 _make_chapter_dot 里直接按 idx 染色，不走此函数。
func _refresh_chapter_dots_active() -> void:
	if _chapter_box == null:
		return
	var children := _chapter_box.get_children()
	for i in children.size():
		var wrapper := children[i] as Control
		if wrapper == null:
			continue
		var dot := wrapper.get_node_or_null("Dot") as Panel
		if dot == null:
			continue
		var color: Color = CHAPTER_DOT_COLOR if i == _current_chapter_idx else CHAPTER_DOT_INACTIVE_COLOR
		dot.add_theme_stylebox_override("panel", ThemeFactory.pill(color, int(CHAPTER_DOT_SIZE * 0.5), true))


# 当前章节索引对应文本写入 DescPnl 的 Label。无章节时显示空。
func _refresh_desc_text() -> void:
	if _desc_title == null or _desc_body == null:
		return
	if _chapters.is_empty():
		_desc_title.text = ""
		_desc_body.text = ""
		return
	var idx: int = clampi(_current_chapter_idx, 0, _chapters.size() - 1)
	var ch: Dictionary = _chapters[idx]
	_desc_title.text = String(ch.get("name", ""))
	_desc_body.text = MarkupParser.parse(String(ch.get("description", "")))


# DescPnl 水平拖动切章节 + 长按进入章节。
# 长按与划动互斥（按时间分阶段而非空间）：
#   阶段 1（按下 ~ REVEAL 秒）：进度环不显，允许拖动；
#       拖动 |dx|/|dy| ≥ swipe 阈值半 → 取消长按
#       拖动 |dx| ≥ swipe 阈值 → 切章节（已自带取消）
#   阶段 2（REVEAL ~ DURATION 秒）：进度环显，**不再响应拖动切章节**；
#       松手中断长按；不松手 → 进度满触发业务
# _desc_swiped 标记单次按下最多切一章节，避免长拖连切。
func _on_desc_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_desc_pressing = true
			_desc_swiped = false
			_desc_press_x = event.global_position.x
			_desc_press_y = event.global_position.y
			# event.position 是相对 desc_pnl 的本地坐标，直接用作 ring.position。
			_start_long_press(event.position)
		else:
			_desc_pressing = false
			_desc_swiped = false
			_cancel_long_press()
	elif event is InputEventMouseMotion and _desc_pressing:
		# 阶段 2 已锁定长按（ring 已现身），不再处理任何移动相关取消/切章节。
		if _long_press_ring != null:
			return
		var dx: float = event.global_position.x - _desc_press_x
		var dy: float = event.global_position.y - _desc_press_y
		# 阶段 1：移动半阈值 → 取消长按计时（视为划动意图）。
		if absf(dx) >= DESC_SWIPE_THRESHOLD_PX * 0.5 or absf(dy) >= DESC_SWIPE_THRESHOLD_PX * 0.5:
			_cancel_long_press()
		if _desc_swiped:
			return
		if dx <= -DESC_SWIPE_THRESHOLD_PX:
			_swipe_chapter(+1)
			_desc_swiped = true
		elif dx >= DESC_SWIPE_THRESHOLD_PX:
			_swipe_chapter(-1)
			_desc_swiped = true


# 长按进入章节业务入口。
# 流程：
#   1. 取章节 scene 路径（来自 campaigns.json 的 scene 字段）
#   2. 整个面板（含主菜单底层 → 整个 root）渐隐
#   3. 渐隐完成后 change_scene_to_file 切到章节场景
# 路径缺失 → 静默忽略（设计期友好，避免误触崩溃）。
func _on_chapter_long_pressed(chapter_idx: int) -> void:
	if chapter_idx < 0 or chapter_idx >= _chapters.size():
		return
	var scene_path: String = String(_chapters[chapter_idx].get("scene", ""))
	if scene_path == "" or not ResourceLoader.exists(scene_path):
		push_warning("CampaignPanel: chapter scene missing → " + scene_path)
		return
	# 屏蔽后续输入，防止动画期再触发长按/拖动。
	desc_pnl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# 渐隐整棵当前场景树（root viewport 内容），切场景前给视觉过渡。
	# 用 self.modulate 即可：本面板已 attach 到 MainMenu 内的 origin_panel，
	# self 渐隐 → 玩家看到的当前界面整体淡出；MainMenu 底层会被 change_scene 替换。
	var root := get_tree().current_scene
	if root != null:
		var tw := create_tween()
		tw.tween_property(root, "modulate:a", 0.0, 1.0).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
		await tw.finished
	get_tree().change_scene_to_file(scene_path)


# delta = +1 = 向左滑（看下一章节）；-1 = 向右滑（看上一章节）。
# clamp 边界，不循环。
func _swipe_chapter(delta: int) -> void:
	if _chapters.is_empty():
		return
	var next_idx: int = _current_chapter_idx + delta
	if next_idx < 0 or next_idx >= _chapters.size():
		return
	_current_chapter_idx = next_idx
	_animate_desc_change(delta)
	_refresh_chapter_dots_active()


# 切章节文本的两段动效：
# 阶段 A（half）：主组沿滑动方向移出 + alpha 1→0
# 阶段 B（half）：换文本 + 主组跳到对侧位置 + 移回 0 + alpha 0→1
# direction = +1 表示新章节"从右进入"（手指向左滑），-1 反之。
# 期间再次切章 → kill 旧 tween；_refresh_chapters 切战役也会 kill 并复位。
func _animate_desc_change(direction: int) -> void:
	if _desc_group == null:
		_refresh_desc_text()
		return
	if _desc_anim_tween and _desc_anim_tween.is_valid():
		_desc_anim_tween.kill()

	var out_x: float = -DESC_ANIM_OFFSET_PX * float(direction)
	var in_x: float = DESC_ANIM_OFFSET_PX * float(direction)
	var half: float = DESC_ANIM_DURATION * 0.5

	_desc_group.position.x = 0.0
	_desc_group.modulate.a = 1.0

	# 阶段 A：移出 + 渐隐（并行）。
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(_desc_group, "position:x", out_x, half).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	tw.tween_property(_desc_group, "modulate:a", 0.0, half).set_trans(Tween.TRANS_LINEAR)
	_desc_anim_tween = tw
	await tw.finished

	# 切章节中途被 kill（如玩家又滑了一次）：放弃后续。
	if _desc_anim_tween != tw:
		return

	# 阶段 B：换文本 + 跳对侧 + 移回 + 渐显。
	_refresh_desc_text()
	_desc_group.position.x = in_x
	var tw2 := create_tween()
	tw2.set_parallel(true)
	tw2.tween_property(_desc_group, "position:x", 0.0, half).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw2.tween_property(_desc_group, "modulate:a", 1.0, half).set_trans(Tween.TRANS_LINEAR)
	_desc_anim_tween = tw2


func _on_campaign_changed(campaign_key: String) -> void:
	_refresh_chapters(campaign_key)
	# 新页章节圆点从 0 渐显到 1，与 carousel 翻页 tween 衔接：
	# 翻页前 _on_drag_progress 已把 box.modulate.a 拉到 0，重建后保持 0，
	# 然后此处 tween 回 1，视觉上"旧圆点隐 → 新圆点显"无突变。
	if _chapter_box == null:
		return
	_chapter_box.modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(_chapter_box, "modulate:a", 1.0, CHAPTER_FADE_IN_DURATION).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


# carousel 拖动/snap 期间持续触发：progress ∈ [-1, 1]。
# |progress| = 0 → 圆点全显；|progress| ≥ 1 → 圆点全隐。
func _on_drag_progress(progress: float) -> void:
	if _chapter_box == null:
		return
	_chapter_box.modulate.a = clampf(1.0 - absf(progress), 0.0, 1.0)

