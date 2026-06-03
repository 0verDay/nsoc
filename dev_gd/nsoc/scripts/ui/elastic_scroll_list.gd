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
#
# ── 子元素 mouse_filter 问题与解法 ──────────────────────────────────────────
# 子元素（PanelContainer / Button 等）mouse_filter = STOP，会吃掉 MouseMotion，
# gui_input 收不到拖拽事件，导致列表无法滚动。
# 解决方案：
#   1. 改用全局 _input 处理拖拽（绕过子元素 filter）。
#   2. 拖动阈值确认后在列表上方挂一个透明 _drag_overlay（MOUSE_FILTER_STOP），
#      拦截后续 gui_input，防止松手时命中「加入」等按钮触发 pressed 信号。

# ── 参数 ─────────────────────────────────────────────────────────────────────
const OVERSCROLL_RESISTANCE: float = 0.55   # rubber band 强度（越小阻力越大）
const OVERSCROLL_SETTLE_TIME: float = 0.28  # 释放后回弹时长（秒）
const SCROLL_THRESHOLD_PX: float   = 18.0  # 判定为滚动手势的最小位移
const WHEEL_STEP_PX: float         = 60.0  # 滚轮单步像素

# ── 内部节点 ─────────────────────────────────────────────────────────────────
var _content: Control        # 可越界平移的内容根
var _vbox: VBoxContainer     # 实际放子项的容器
var _drag_overlay: Control   # 拖动时挂在最上层，拦截子元素 gui_input

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
	mouse_filter = Control.MOUSE_FILTER_STOP   # 接收鼠标事件（滚轮等）

	_content = Control.new()
	_content.name = "_content"
	_content.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(_content)

	_vbox = VBoxContainer.new()
	_vbox.name = "_vbox"
	_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_vbox.add_theme_constant_override("separation", 8)
	_content.add_child(_vbox)

	resized.connect(_schedule_layout)
	_vbox.minimum_size_changed.connect(_schedule_layout)
	# 注意：使用全局 _input 而非 gui_input，避免子元素 STOP filter 拦截 MouseMotion。


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

	_logical_offset = clamp(_logical_offset, 0.0, _max_scroll())
	_apply_offset()


# ── 滚动数学 ─────────────────────────────────────────────────────────────────
## 内容最大可滚距离（≥0；内容短于视口时为 0）。
func _max_scroll() -> float:
	if _content == null:
		return 0.0
	return max(0.0, _content.size.y - size.y)


## rubber band 公式：f(x) = (x·c·d)/(d + c·x)
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


# ── 覆盖层（拖动期间阻止子元素触发 pressed） ────────────────────────────────
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


# ── 回弹 ─────────────────────────────────────────────────────────────────────
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


# ── 输入处理（全局 _input） ──────────────────────────────────────────────────
func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton

		# 滚轮：仅在本控件矩形内响应
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
				# 仅在本控件范围内按下才开始追踪
				if get_global_rect().has_point(mb.global_position):
					_pressing     = true
					_is_scrolling = false
					_press_y      = mb.global_position.y
					_start_offset = _logical_offset
					_kill_settle_tween()
			else:
				# 抬起：无论位置都结束追踪（拖出控件外松手也能 settle）
				if _pressing:
					if _is_scrolling:
						_settle_to_clamped()
						get_viewport().set_input_as_handled()
					_remove_drag_overlay()
					_pressing     = false
					_is_scrolling = false

	elif event is InputEventMouseMotion and _pressing:
		var mm := event as InputEventMouseMotion
		var dy: float = mm.global_position.y - _press_y

		if not _is_scrolling and absf(dy) >= SCROLL_THRESHOLD_PX:
			_is_scrolling = true
			# 确认滚动后挂覆盖层，阻止 gui_input 到达子元素（防止松手触发按钮）
			_attach_drag_overlay()

		if _is_scrolling:
			_logical_offset = _start_offset - dy
			_apply_offset()
			get_viewport().set_input_as_handled()
