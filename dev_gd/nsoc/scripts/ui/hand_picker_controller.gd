class_name HandPickerController
extends Node

# 手牌选择控制器。
# 使用方式（协程）：
#   var hand_card = await hand_picker.pick_async()
#   if hand_card == null: return   # 玩家取消
#
# 选择期间：
#   - 所有手牌显示红色描边
#   - 全屏 overlay（MOUSE_FILTER_STOP）拦截点击
#   - 点击某张手牌 → 返回该 hand_card 节点
#   - 点击其他位置 → 返回 null（取消）

const HIGHLIGHT_COLOR: Color = Color("#fa5252")

var _parent: Control    = null
var _hand_view: Node    = null   # HandView
var _selecting: bool    = false
var _overlay: Control   = null
var _highlighted: Array = []

signal _pick_resolved(hand_card)

func setup(parent_root: Control, hand_view: Node) -> void:
	_parent    = parent_root
	_hand_view = hand_view

# 协程入口：返回玩家选中的 HandCard 节点，取消返回 null。
func pick_async():
	if _selecting:
		return null
	_selecting = true
	_begin_selection()
	var result = await _pick_resolved
	return result

func _begin_selection() -> void:
	_highlighted.clear()
	if _hand_view == null:
		_end_selection(null)
		return

	# 给所有手牌加红描边
	var hand_container = null
	if _hand_view != null and _hand_view.has_method("get_hand_container"):
		hand_container = _hand_view.get_hand_container()
	if hand_container == null:
		push_warning("HandPickerController: cannot access hand container")
		_end_selection(null)
		return

	for child in hand_container.get_children():
		if not is_instance_valid(child):
			continue
		if child.get_meta("consumed", false):
			continue
		if child.has_method("set_selection_highlight"):
			child.set_selection_highlight(true, HIGHLIGHT_COLOR)
		_highlighted.append(child)

	if _highlighted.is_empty():
		# 无可选手牌：直接取消
		_end_selection(null)
		return

	# 全屏 overlay
	_overlay = Control.new()
	_overlay.name = "HandPickerOverlay"
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_overlay.z_index = 200
	_parent.add_child(_overlay)
	_overlay.gui_input.connect(_on_overlay_input)

func _on_overlay_input(event: InputEvent) -> void:
	if not _selecting:
		return
	if not (event is InputEventMouseButton \
			and event.button_index == MOUSE_BUTTON_LEFT \
			and event.pressed):
		return

	var mp: Vector2 = _parent.get_global_mouse_position()
	for card in _highlighted:
		if not is_instance_valid(card):
			continue
		if card.get_global_rect().has_point(mp):
			_end_selection(card)
			return
	# 点击其他位置：取消
	_end_selection(null)

func _end_selection(chosen_card) -> void:
	_selecting = false
	for card in _highlighted:
		if is_instance_valid(card) and card.has_method("set_selection_highlight"):
			card.set_selection_highlight(false)
	_highlighted.clear()
	if is_instance_valid(_overlay):
		_overlay.queue_free()
		_overlay = null
	_pick_resolved.emit(chosen_card)
