class_name FrontRowSelector
extends Node

# 玩家前排棋子行动前的"目标棋盘选择器"。
#
# 多盘体系（阶段 2A 起）：
# - 完全走 BoardRegistry，自动把所有 ENEMY 阵营 slot 作为可选 target
# - 选中 slot.id：尝试跨棋盘攻击 / 移动；若同列前排无敌，回退本盘默认
# - 点击空白：维持等待（与旧行为一致）
# - 仅 1 个 ENEMY slot 时仍弹选择 UI（玩家可选不跨过去：选其它非敌方区域 = 取消）
#   ── 当前实现：若 ENEMY slot 数 == 0，直接 resolve("")，否则进入选择
#
# 依赖：
#   parent_root : Control 容器（用于挂载拦截层 + 鼠标坐标参考）
#   combat      : CombatSystem

const HIGHLIGHT_PULSE_DURATION: float = 0.45

var _parent: Control = null
var _combat: CombatSystem = null

# 选择状态
var _active_cell: Node = null
var _selecting: bool = false
var _overlay: Control = null
var _highlight_tweens: Array = []
# 本次选择中高亮的 (slot, bg) 对，用于点击命中判定
var _selection_targets: Array = []

func setup(parent_root: Control, combat: CombatSystem) -> void:
	_parent = parent_root
	_combat = combat
	if has_node("/root/Game"):
		Game.turn.front_row_action_requested.connect(_on_front_row_requested)
		Game.turn._front_row_resolve = Callable(self, "_on_target_chosen")

# ── 信号入口 ──────────────────────────────────────────────────────────
func _on_front_row_requested(cell: Node) -> void:
	var enemy_slots: Array = _enemy_slots_with_panel()
	if enemy_slots.is_empty():
		Game.turn.resolve_front_row_selection("")
		return
	# 仅 1 个 ENEMY slot：无需弹 UI，自动选中该 slot 作为跨盘目标
	if enemy_slots.size() == 1:
		Game.turn.resolve_front_row_selection(enemy_slots[0].id)
		return
	_active_cell = cell
	_selecting = true
	_begin_selection(enemy_slots)

# ── 选择 UI ──────────────────────────────────────────────────────────
func _begin_selection(enemy_slots: Array) -> void:
	_clear_highlights()
	_selection_targets.clear()

	_overlay = Control.new()
	_overlay.name = "FrontRowSelectionOverlay"
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_overlay.z_index = 50
	_parent.add_child(_overlay)
	_overlay.gui_input.connect(_on_overlay_input)

	# 等一帧让布局稳定后再设缩放锚点
	await get_tree().process_frame

	for slot in enemy_slots:
		var bg: Panel = slot.bg_panel
		if not is_instance_valid(bg):
			continue
		bg.add_theme_stylebox_override("panel",
			ThemeFactory.panel(Color("#e8f4fd"), Color("#339af0"), 3, 16))
		bg.pivot_offset = bg.size * 0.5
		var tw := bg.create_tween()
		tw.set_loops()
		tw.tween_property(bg, "scale", Vector2(1.015, 1.015), HIGHLIGHT_PULSE_DURATION) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		tw.tween_property(bg, "scale", Vector2.ONE, HIGHLIGHT_PULSE_DURATION) \
			.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
		_highlight_tweens.append({"node": bg, "tween": tw})
		_selection_targets.append({"slot": slot, "bg": bg})

func _on_overlay_input(event: InputEvent) -> void:
	if not _selecting:
		return
	if event is InputEventMouseButton \
			and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var mp: Vector2 = _parent.get_global_mouse_position()
		for entry in _selection_targets:
			var bg: Panel = entry["bg"]
			if not is_instance_valid(bg):
				continue
			if bg.get_global_rect().has_point(mp):
				_end_selection(entry["slot"].id)
				return
		# 点空白：维持等待

func _end_selection(chosen_slot_id: String) -> void:
	_selecting = false
	_clear_highlights()
	if is_instance_valid(_overlay):
		_overlay.queue_free()
		_overlay = null
	Game.turn.resolve_front_row_selection(chosen_slot_id)

func _clear_highlights() -> void:
	for entry in _highlight_tweens:
		var tw = entry.get("tween")
		if tw and tw.is_running():
			tw.kill()
		var n: Panel = entry.get("node")
		if is_instance_valid(n):
			n.scale = Vector2.ONE
			n.pivot_offset = Vector2.ZERO
			n.add_theme_stylebox_override("panel",
				ThemeFactory.panel(Color("#f0f3f5"), Color("#e1e8ed"), 1, 16))
	_highlight_tweens.clear()

# ── 行动结算 ──────────────────────────────────────────────────────────
# TurnSystem 回调：玩家选择了非本棋盘 id。
# 返回 Dictionary：
#   {handled: false}                                       回退到本棋盘默认逻辑
#   {handled: true}                                        已完成动作
#   {handled: true, crossed_cell, board_model, hero_resolver}
#       冲锋单位已跨入目标棋盘，由 TurnSystem 继续在目标棋盘冲锋穿透
func _on_target_chosen(cell: Node, target_id: String) -> Dictionary:
	if not is_instance_valid(cell) or not cell.has_card:
		return {"handled": true}
	if Game.registry == null:
		return {"handled": false}
	var slot: BoardSlot = Game.registry.get_by_id(target_id)
	if slot == null or not is_instance_valid(slot.board):
		return {"handled": false}
	var board_model: BoardModel = slot.board
	# 跨盘目标盘的 front_row：玩家单位跨过去落在敌方盘的 front_row（朝玩家那侧 = row 2）
	var enemy_front_row: int = BoardModel.front_row_of(slot.faction)
	var front_enemy = board_model.get_cell(Vector2(enemy_front_row, cell.col))
	var has_enemy: bool = is_instance_valid(front_enemy) and front_enemy.has_card

	if has_enemy:
		# 同列前排有敌 → 原地攻击（不论是否冲锋单位）
		await get_tree().create_timer(CombatSystem.ATTACK_HIT_DELAY).timeout
		if not is_instance_valid(cell) or not cell.has_card:
			return {"handled": true}
		# 玩家盘 row 0 视觉上方紧贴敌方盘 row 2 视觉下方：
		# 攻方朝 top，受击者 bottom 面（敌方单位视角已通过 Orientation 自动翻转）
		await _combat.attack_cells(cell, [{
			"cell": front_enemy, "dir": "top", "opp_dir": "bottom",
		}])
		return {"handled": true}

	# 同列前排无敌 → 移动到目标棋盘前排（同列 row=front_row）
	var target_cell = board_model.get_cell(Vector2(enemy_front_row, cell.col))
	if not is_instance_valid(target_cell) or target_cell.has_card:
		return {"handled": false}

	var is_charge_unit: bool = cell.effects.has("charge") and not cell.has_charged
	await _combat.move_card(cell, target_cell)
	if not is_instance_valid(target_cell) or not target_cell.has_card:
		return {"handled": true}
	target_cell.has_attacked = true
	target_cell.slot_id = slot.id   # 跨入新盘后更新 slot 归属

	if is_charge_unit:
		return {
			"handled": true,
			"crossed_cell": target_cell,
			"board_model": board_model,
			"hero_resolver": slot.hero_resolver,
		}
	return {"handled": true}

# 当前所有有 bg_panel 的 ENEMY slot
func _enemy_slots_with_panel() -> Array:
	var out: Array = []
	if Game.registry == null:
		return out
	for slot in Game.registry.enemy_targets():
		if is_instance_valid(slot.bg_panel):
			out.append(slot)
	return out
