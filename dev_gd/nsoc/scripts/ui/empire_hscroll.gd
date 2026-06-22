class_name EmpireHScroll
extends Control

# 水平弹性滚动容器。
# 复刻 ElasticScrollList 的 rubber band（过界阻力）+ 释放回弹（cubic ease out），
# 改为水平方向；clip_contents=true 自带裁切，无滚动条。
# 供 EmpireMain、EmpireScenarioView 等共享复用。

const OVERSCROLL_RESISTANCE: float  = 0.55
const OVERSCROLL_SETTLE_TIME: float = 0.28
const DRAG_THRESHOLD_PX: float      = 18.0
const WHEEL_STEP_PX: float          = 60.0

var _content: Control
var _hbox: HBoxContainer
var _drag_overlay: Control

var _logical_offset: float = 0.0
var _pressing: bool        = false
var _is_scrolling: bool    = false
var _press_x: float        = 0.0
var _start_offset: float   = 0.0
var _settle_tween: Tween   = null


func _ready() -> void:
	clip_contents = true
	mouse_filter  = Control.MOUSE_FILTER_STOP

	_content = Control.new()
	_content.name = "_content"
	_content.mouse_filter = Control.MOUSE_FILTER_PASS
	add_child(_content)

	_hbox = HBoxContainer.new()
	_hbox.name = "_hbox"
	_hbox.size_flags_vertical = Control.SIZE_EXPAND_FILL
	_content.add_child(_hbox)

	resized.connect(_schedule_layout)
	_hbox.minimum_size_changed.connect(_schedule_layout)


func get_content_box() -> HBoxContainer:
	return _hbox


func _schedule_layout() -> void:
	call_deferred("_do_layout")


func _do_layout() -> void:
	if not is_instance_valid(_hbox) or not is_instance_valid(_content):
		return
	var min_w: float     = _hbox.get_combined_minimum_size().x
	var view_w: float    = size.x
	var content_w: float = max(min_w, view_w)

	_content.size = Vector2(content_w, size.y)
	_hbox.size    = _content.size

	_logical_offset = clamp(_logical_offset, 0.0, _max_scroll())
	_apply_offset()


# ── 滚动数学 ────────────────────────────────────────────────────────────────

func _max_scroll() -> float:
	if _content == null:
		return 0.0
	return max(0.0, _content.size.x - size.x)


func _to_display(logical: float) -> float:
	var max_s: float = _max_scroll()
	if logical < 0.0:
		return -_rubber(-logical)
	if logical > max_s:
		return max_s + _rubber(logical - max_s)
	return logical


func _rubber(x: float) -> float:
	var d: float = max(1.0, size.x)
	var c: float = OVERSCROLL_RESISTANCE
	return (x * c * d) / (d + c * x)


func _apply_offset() -> void:
	if _content:
		_content.position.x = -_to_display(_logical_offset)


func _scroll_by(dx: float) -> void:
	_logical_offset += dx
	_apply_offset()


# ── 拖动覆盖层（防止释放误触按钮） ──────────────────────────────────────────

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


# ── 回弹 ────────────────────────────────────────────────────────────────────

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


# ── 输入（全局 _input 绕开子按钮的 mouse_filter=STOP） ──────────────────────

func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton

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
				if get_global_rect().has_point(mb.global_position):
					_pressing     = true
					_is_scrolling = false
					_press_x      = mb.global_position.x
					_start_offset = _logical_offset
					_kill_settle_tween()
			else:
				if _pressing:
					if _is_scrolling:
						_settle_to_clamped()
						get_viewport().set_input_as_handled()
					_remove_drag_overlay()
					_pressing     = false
					_is_scrolling = false

	elif event is InputEventMouseMotion and _pressing:
		var mm := event as InputEventMouseMotion
		var dx: float = mm.global_position.x - _press_x

		if not _is_scrolling and absf(dx) >= DRAG_THRESHOLD_PX:
			_is_scrolling = true
			_attach_drag_overlay()

		if _is_scrolling:
			_logical_offset = _start_offset - dx
			_apply_offset()
			get_viewport().set_input_as_handled()
