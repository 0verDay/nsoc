class_name TargetSelectorController
extends Node

# 装备/技能目标选择控制器。
# 使用方式（协程）：
#   var target_cell = await target_selector.pick_async("enemy_unit")
#   if target_cell == null: return   # 玩家取消
#
# 选择期间：
#   - 所有合法 cell 显示红色描边
#   - 全屏 overlay（MOUSE_FILTER_STOP）拦截点击
#   - 点击合法 cell → 返回该 cell
#   - 点击其他位置 → 返回 null（取消）
#   - is_running 由调用方（HeroActionBar）在 pick 前后管理

const HIGHLIGHT_COLOR: Color = Color("#fa5252")

var _parent: Control = null
var _selecting: bool = false
var _overlay: Control = null
var _highlighted_cells: Array = []

# 协程等待信号
signal _pick_resolved(cell)

func setup(parent_root: Control) -> void:
	_parent = parent_root

# 协程入口：返回玩家选中的 cell，取消返回 null。
func pick_async(filter: String):
	if _selecting:
		return null
	_selecting = true
	_begin_selection(filter)
	var result = await _pick_resolved
	return result

func _begin_selection(filter: String) -> void:
	_highlighted_cells.clear()

	# 收集合法目标
	if Game.registry != null:
		for slot in Game.registry.slots:
			if slot.board == null:
				continue
			for key in slot.board.grid_cells.keys():
				var cell = slot.board.grid_cells[key]
				if not is_instance_valid(cell) or not cell.has_card or cell.is_phantom:
					continue
				if _match_filter(cell, filter):
					_highlighted_cells.append(cell)
					cell.set_selection_highlight(true, HIGHLIGHT_COLOR)

	# 全屏透明 overlay 拦截输入
	_overlay = Control.new()
	_overlay.name = "TargetSelectorOverlay"
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_overlay.z_index = 200
	_parent.add_child(_overlay)
	_overlay.gui_input.connect(_on_overlay_input)

func _match_filter(cell, filter: String) -> bool:
	match filter:
		"enemy_unit":    return cell.is_enemy
		"friendly_unit": return not cell.is_enemy
		"any_unit":      return true
		_:               return true

func _on_overlay_input(event: InputEvent) -> void:
	if not _selecting:
		return
	if not (event is InputEventMouseButton \
			and event.button_index == MOUSE_BUTTON_LEFT \
			and event.pressed):
		return

	var mp: Vector2 = _parent.get_global_mouse_position()
	for cell in _highlighted_cells:
		if not is_instance_valid(cell):
			continue
		if cell.get_global_rect().has_point(mp):
			_end_selection(cell)
			return
	# 点击非合法目标：取消
	_end_selection(null)

func _end_selection(chosen_cell) -> void:
	_selecting = false
	# 清除所有描边
	for cell in _highlighted_cells:
		if is_instance_valid(cell):
			cell.set_selection_highlight(false)
	_highlighted_cells.clear()
	if is_instance_valid(_overlay):
		_overlay.queue_free()
		_overlay = null
	_pick_resolved.emit(chosen_cell)
