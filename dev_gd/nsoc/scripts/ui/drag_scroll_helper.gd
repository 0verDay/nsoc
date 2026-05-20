class_name DragScrollHelper
extends Node

# 给 ScrollContainer 增加"按住拖动滚动"行为（手机端 / emulate_touch_from_mouse 场景）。
# 用法:
#   var helper := DragScrollHelper.new()
#   helper.setup(scroll, on_drag_start_callable)
#   scroll.add_child(helper)
#
# on_drag_start: 拖动判定生效时调用一次（用于取消长按等副作用）。可为 Callable() 空。

const DRAG_THRESHOLD_PX: float = 8.0

var _scroll: ScrollContainer
var _on_drag_start: Callable = Callable()

var _pressing: bool = false
var _dragging: bool = false
var _press_y: float = 0.0
var _start_scroll: int = 0

func setup(scroll: ScrollContainer, on_drag_start: Callable = Callable()) -> void:
	_scroll = scroll
	_on_drag_start = on_drag_start
	scroll.gui_input.connect(_on_scroll_input)

func _on_scroll_input(event: InputEvent) -> void:
	if _scroll == null:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_pressing = true
			_dragging = false
			_press_y = event.global_position.y
			_start_scroll = _scroll.scroll_vertical
		else:
			# 拖动结束：若已确认拖动则吃掉本次释放，避免子 Button 误触发 button_up
			if _dragging:
				_scroll.accept_event()
			_pressing = false
			_dragging = false
	elif event is InputEventMouseMotion and _pressing:
		var dy: float = event.global_position.y - _press_y
		if not _dragging and absf(dy) >= DRAG_THRESHOLD_PX:
			_dragging = true
			if _on_drag_start.is_valid():
				_on_drag_start.call()
		if _dragging:
			_scroll.scroll_vertical = _start_scroll - int(dy)
			_scroll.accept_event()
