class_name ElasticScrollList
extends Control

# 弹性滚动列表容器。
# 支持过度拉动（rubber band 阻力）+ 释放后平滑回弹，行为与备战界面卡牌列表一致。
#
# 用法：
#   var list := ElasticScrollList.new()
#   parent.add_child(list)
#   list.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
#   list.get_content_box()  →  返回内部 VBoxContainer，往里 add_child 即可
#   list.set_item_separation(px)  →  调整列表项间距（默认 8）
#
# 与 DragScrollHelper 的区别：DragScrollHelper 附在原生 ScrollContainer 上，
# 无越界；本类完全自行管理 clip + offset，支持 rubber band 回弹。

# ── 参数（与 PreparePenal 同款） ─────────────────────────────────────────────
const OVERSCROLL_RESISTANCE: float = 0.55   # rubber band 强度（越小阻力越大）
const OVERSCROLL_SETTLE_TIME: float = 0.28  # 释放后回弹时长（秒）
const SCROLL_THRESHOLD_PX: float   = 18.0  # 判定为滚动手势的最小位移
const WHEEL_STEP_PX: float         = 60.0  # 滚轮单步像素

# ── 内部节点 ─────────────────────────────────────────────────────────────────
var _content: Control        # 可越界平移的内容根
var _vbox: VBoxContainer     # 实际放子项的容器

# ── 滚动状态 ─────────────────────────────────────────────────────────────────
var _logical_offset: float = 0.0   # 允许越界（<0 顶部过拉；>max 底部过拉）
var _pressing: bool = false
var _is_scrolling: bool = false
var _press_y: float = 0.0
var _start_offset: float = 0.0
var _settle_tween: Tween = null


# ── 初始化 ───────────────────────────────────────────────────────────────────
func _ready() -> void:
	clip_contents = true
	mouse_filter = Control.MOUSE_FILTER_STOP   # 接收鼠标事件

	# 内容根：允许超出裁剪区范围移动
	_content = Control.new()
	_content.name = "_content"
	_content.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(_content)

	# 实际列表容器
	_vbox = VBoxContainer.new()
	_vbox.name = "_vbox"
	_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vbox.add_theme_constant_override("separation", 8)
	_content.add_child(_vbox)

	resized.connect(_schedule_layout)
	_vbox.minimum_size_changed.connect(_schedule_layout)
	gui_input.connect(_on_gui_input)


# ── 公开 API ─────────────────────────────────────────────────────────────────
## 返回内部 VBoxContainer，调用方往里 add_child 添加列表项。
func get_content_box() -> VBoxContainer:
	return _vbox

## 调整列表项间距。
func set_item_separation(px: int) -> void:
	if _vbox:
		_vbox.add_theme_constant_override("separation", px)


# ── 布局刷新 ─────────────────────────────────────────────────────────────────
func _schedule_layout() -> void:
	call_deferred("_do_layout")


func _do_layout() -> void:
	if not is_instance_valid(_vbox) or not is_instance_valid(_content):
		return
	var min_h: float = _vbox.get_combined_minimum_size().y
	var view_h: float = size.y
	var content_h: float = max(min_h, view_h)

	_content.size = Vector2(size.x, content_h)
	_vbox.size    = _content.size

	# 布局变化后确保 offset 仍在合法范围
	_logical_offset = clamp(_logical_offset, 0.0, _max_scroll())
	_apply_offset()


# ── 滚动数学 ─────────────────────────────────────────────────────────────────
## 内容最大可滚距离（≥0；内容短于视口时为 0）。
func _max_scroll() -> float:
	if _content == null:
		return 0.0
	return max(0.0, _content.size.y - size.y)


## 把 logical_offset（允许越界）映射为实际视觉位移（rubber band 衰减越界量）。
## rubber band 公式：f(x) = (x·c·d)/(d + c·x)
##   x = 越界量；d = 视口高；c = OVERSCROLL_RESISTANCE
##   x→0 时 ≈ c·x；x→∞ 时趋近 d，视觉上永不超过视口高。
func _to_display(logical: float) -> float:
	var max_s: float = _max_scroll()
	if logical < 0.0:
		return -_rubber(-logical)
	if logical > max_s:
		return max_s + _rubber(logical - max_s)
	return logical


func _rubber(x: float) -> float:
	var d: float = max(1.0, size.y)
	var c: float = OVERSCROLL_RESISTANCE
	return (x * c * d) / (d + c * x)


func _apply_offset() -> void:
	if _content == null:
		return
	_content.position.y = -_to_display(_logical_offset)


func _scroll_by(dy: float) -> void:
	_logical_offset += dy
	_apply_offset()


# ── 回弹 ─────────────────────────────────────────────────────────────────────
## 将 logical_offset 以 cubic ease-out 动画归位到合法范围。
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


# ── 输入处理 ─────────────────────────────────────────────────────────────────
func _on_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton

		# 滚轮：滚动一步后立即 settle（保持越界回弹手感）
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_kill_settle_tween()
			_scroll_by(-WHEEL_STEP_PX)
			_settle_to_clamped()
			accept_event()
			return
		if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_kill_settle_tween()
			_scroll_by(WHEEL_STEP_PX)
			_settle_to_clamped()
			accept_event()
			return

		# 鼠标左键按下 / 抬起
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_pressing      = true
				_is_scrolling  = false
				_press_y       = mb.global_position.y
				_start_offset  = _logical_offset
				_kill_settle_tween()
			else:
				if _is_scrolling:
					accept_event()
					_settle_to_clamped()
				_pressing     = false
				_is_scrolling = false

	elif event is InputEventMouseMotion and _pressing:
		var mm := event as InputEventMouseMotion
		var dy: float = mm.global_position.y - _press_y

		# 超过阈值后确认为滚动手势
		if not _is_scrolling and absf(dy) >= SCROLL_THRESHOLD_PX:
			_is_scrolling = true

		if _is_scrolling:
			_logical_offset = _start_offset - dy
			_apply_offset()
			accept_event()


## 全局鼠标释放捕获：拖出容器外也能触发 settle。
func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and \
			event.button_index == MOUSE_BUTTON_LEFT and \
			not event.pressed and _pressing:
		if _is_scrolling:
			_settle_to_clamped()
		_pressing     = false
		_is_scrolling = false
