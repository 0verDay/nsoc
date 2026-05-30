class_name ObjectiveDrawer
extends PanelContainer

# 章节目标抽屉。战役章节战斗中在屏幕左上角常驻。
#
# 布局（固定高 PANEL_H px）：
#   ┌──────────────────────────┐  ← y=0（展开态顶部）
#   │  章节名（蓝色，22pt）     │
#   │  目标描述（黑，18pt）     │
#   │  X / N（金，16pt）       │
#   │  ─────────────────────── │
#   │           ⌄              │  ← 底部 EAR_H px = 耳朵（收起后唯一可见区）
#   └──────────────────────────┘
#
# 收起态：position.y = -(PANEL_H - EAR_H)  仅耳朵在屏幕顶部可见
# 展开态：position.y = 0                   完整显示
#
# 手势：
#   耳朵区向下滑 > DRAG_THRESHOLD → 展开
#   面板任意处向上滑 > DRAG_THRESHOLD → 收起
#   动画期间忽略新手势

# ── 尺寸 / 时间常量 ─────────────────────────────────────────────────────
const DRAWER_W:        float = 360.0
const DRAWER_X:        float = 12.0
const PANEL_H:         float = 160.0
const EAR_H:           float = 30.0
const COLLAPSED_Y:     float = -(PANEL_H - EAR_H)   # = -130.0
const AUTO_CLOSE_SEC:  float = 4.0
const ANIM_SEC:        float = 0.32
const DRAG_THRESHOLD:  float = 20.0

enum DrawerState {COLLAPSED, EXPANDED, ANIMATING}

# ── 状态 ─────────────────────────────────────────────────────────────────
var _state: DrawerState = DrawerState.COLLAPSED
var _chapter_label:   Label = null
var _obj_label:       Label = null
var _progress_label:  Label = null
var _ear_label:       Label = null   # 状态指示图标：收起="⌄"，展开="⌃"
var _timer:           Timer = null
var _tween:           Tween = null
var _drag_start_y:    float = 0.0
var _dragging:        bool  = false

# ── 公开 API ──────────────────────────────────────────────────────────────

# 填充内容。必须在 add_child 之后调用（_ready 已执行才有 label 节点）。
func setup(level_data: Dictionary) -> void:
	if _chapter_label == null:
		return
	_chapter_label.text = String(level_data.get("name", ""))
	_obj_label.text     = Objectives.current_description()
	_update_progress()

# ── 生命周期 ─────────────────────────────────────────────────────────────

func _ready() -> void:
	# ── 面板样式：白底 + 主蓝描边（与游戏整体风格一致）
	add_theme_stylebox_override("panel",
		ThemeFactory.panel(Color.WHITE, Color("#339af0"), 3, 16, true))
	custom_minimum_size = Vector2(DRAWER_W, PANEL_H)
	position            = Vector2(DRAWER_X, COLLAPSED_Y)
	mouse_filter        = Control.MOUSE_FILTER_STOP
	clip_contents       = false   # 允许面板在滑动中稍微超出 CanvasLayer 边界

	_build_content()

	# 自动收起定时器
	_timer = Timer.new()
	_timer.one_shot = true
	_timer.timeout.connect(_on_auto_close)
	add_child(_timer)

	# 回合结束时刷新进度
	if has_node("/root/Game") and Game.turn != null:
		Game.turn.turn_ended.connect(_update_progress)

	# 延迟一帧再展开（确保 CanvasLayer 布局已稳定）
	call_deferred("_do_expand")

# ── 内容构建 ─────────────────────────────────────────────────────────────

func _build_content() -> void:
	# 根 VBoxContainer 填满面板
	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", 0)
	add_child(vbox)

	# ── 内容区（EXPAND_FILL 撑满，耳朵以外的空间）
	var content_margin := MarginContainer.new()
	content_margin.size_flags_vertical = Control.SIZE_EXPAND_FILL
	content_margin.add_theme_constant_override("margin_left",   16)
	content_margin.add_theme_constant_override("margin_right",  16)
	content_margin.add_theme_constant_override("margin_top",    14)
	content_margin.add_theme_constant_override("margin_bottom",  8)
	vbox.add_child(content_margin)

	var inner := VBoxContainer.new()
	inner.add_theme_constant_override("separation", 6)
	content_margin.add_child(inner)

	_chapter_label = Label.new()
	_chapter_label.add_theme_color_override("font_color", Color("#1c7ed6"))
	_chapter_label.add_theme_font_size_override("font_size", 22)
	inner.add_child(_chapter_label)

	_obj_label = Label.new()
	_obj_label.add_theme_color_override("font_color", Color("#1f2937"))
	_obj_label.add_theme_font_size_override("font_size", 18)
	_obj_label.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	inner.add_child(_obj_label)

	_progress_label = Label.new()
	_progress_label.add_theme_color_override("font_color", Color("#ffd43b"))
	_progress_label.add_theme_font_size_override("font_size", 16)
	inner.add_child(_progress_label)

	# ── 分隔线
	var sep := HSeparator.new()
	sep.custom_minimum_size = Vector2(0, 1)
	sep.add_theme_color_override("color", Color("#cde4ff"))
	vbox.add_child(sep)

	# ── 耳朵区（始终在面板底部，收起时唯一可见区域）
	_ear_label = Label.new()
	_ear_label.text = "⌄"   # 初始收起态：尖端朝下（提示可下拉展开）
	_ear_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_ear_label.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_ear_label.custom_minimum_size  = Vector2(0, EAR_H - 1)
	_ear_label.add_theme_color_override("font_color", Color("#339af0"))
	_ear_label.add_theme_font_size_override("font_size", 16)
	_ear_label.mouse_filter = Control.MOUSE_FILTER_IGNORE  # 父节点接收事件
	vbox.add_child(_ear_label)

# ── 手势输入 ─────────────────────────────────────────────────────────────
# 使用 _input()（非 _gui_input），使热区与面板视觉位置解耦。
# 热区固定为 Rect2(DRAWER_X, 0, DRAWER_W, PANEL_H)——面板展开时完整覆盖，
# 收起时亦覆盖整块原始区域，移动端只需在该区域内下滑即可触发展开。
# 只在手势超过阈值后才调用 set_input_as_handled()，避免拦截普通点击。

func _input(event: InputEvent) -> void:
	# 固定热区：对应面板完整展开时的屏幕区域
	var hot_zone := Rect2(DRAWER_X, 0.0, DRAWER_W, PANEL_H)

	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				if hot_zone.has_point(mb.global_position):
					_drag_start_y = mb.global_position.y
					_dragging     = true
			else:
				_dragging = false

	elif event is InputEventMouseMotion and _dragging:
		var delta_y: float = \
			(event as InputEventMouseMotion).global_position.y - _drag_start_y
		if _state == DrawerState.COLLAPSED and delta_y > DRAG_THRESHOLD:
			_dragging = false
			_do_expand()
			get_viewport().set_input_as_handled()
		elif _state == DrawerState.EXPANDED and delta_y < -DRAG_THRESHOLD:
			_dragging = false
			_do_collapse()
			get_viewport().set_input_as_handled()

# ── 动画 ─────────────────────────────────────────────────────────────────

func _do_expand() -> void:
	if _state == DrawerState.ANIMATING:
		return
	_state = DrawerState.ANIMATING
	_timer.stop()
	_kill_tween()
	# 立即更新图标：展开态尖端朝上（提示可上滑收起）
	if _ear_label:
		_ear_label.text = "⌃"
	_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_property(self, "position:y", 0.0, ANIM_SEC)
	_tween.tween_callback(func() -> void:
		_state = DrawerState.EXPANDED
		_timer.start(AUTO_CLOSE_SEC)
	)

func _do_collapse() -> void:
	if _state == DrawerState.ANIMATING:
		return
	_state = DrawerState.ANIMATING
	_timer.stop()
	_kill_tween()
	# 立即更新图标：收起态尖端朝下（提示可下滑展开）
	if _ear_label:
		_ear_label.text = "⌄"
	_tween = create_tween().set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_tween.tween_property(self, "position:y", COLLAPSED_Y, ANIM_SEC)
	_tween.tween_callback(func() -> void:
		_state = DrawerState.COLLAPSED
	)

func _kill_tween() -> void:
	if _tween and _tween.is_valid():
		_tween.kill()

# ── 槽函数 ───────────────────────────────────────────────────────────────

func _on_auto_close() -> void:
	_do_collapse()

func _update_progress() -> void:
	if _progress_label == null:
		return
	_progress_label.text = Objectives.current_progress_text()
