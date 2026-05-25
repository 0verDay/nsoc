class_name FrontRowSelector
extends Node

# 玩家前排棋子行动前的"目标棋盘选择器"。
# - 接收 TurnSystem.front_row_action_requested 信号
# - 高亮所有可选棋盘背景，等待玩家点击
# - 点击后通过 TurnSystem.resolve_front_row_selection 通知；非主棋盘 id 经
#   _on_target_chosen 回调处理（攻击 / 移动）
#
# 使用方式（test_main / main 装配时）：
#   var selector := FrontRowSelector.new()
#   add_child(selector)
#   selector.setup(self, combat, _get_extra_board_model)
#   selector.register_target("main", $TopGridBg, Game.hero)
#   # 之后可动态 register/unregister 额外棋盘
#
# 依赖：
#   parent_root        : Control 容器（用于挂载拦截层 + 鼠标坐标参考）
#   combat             : CombatSystem
#   board_model_resolver: Callable(target_id) -> BoardModel  返回非 main 棋盘的模型

const ENEMY_FRONT_ROW: int = 2          # 敌方棋盘前排 row 号
const HIGHLIGHT_PULSE_DURATION: float = 0.45

var _parent: Control = null
var _combat: CombatSystem = null
var _board_resolver: Callable = Callable()

# id -> { bg_panel, hero_state }
var _targets: Dictionary = {}

# 选择状态
var _active_cell: Node = null
var _selecting: bool = false
var _overlay: Control = null
var _highlight_tweens: Array = []

func setup(parent_root: Control, combat: CombatSystem,
		board_model_resolver: Callable) -> void:
	_parent = parent_root
	_combat = combat
	_board_resolver = board_model_resolver
	if has_node("/root/Game"):
		Game.turn.front_row_action_requested.connect(_on_front_row_requested)
		Game.turn._front_row_resolve = Callable(self, "_on_target_chosen")

# ── 注册 / 注销 ──────────────────────────────────────────────────────
func register_target(id: String, bg_panel: Panel, hero_state) -> void:
	_targets[id] = {"bg_panel": bg_panel, "hero_state": hero_state}

func unregister_target(id: String) -> void:
	_targets.erase(id)

# ── 信号入口 ──────────────────────────────────────────────────────────
func _on_front_row_requested(cell: Node) -> void:
	# 只有一个目标 → 默认走本棋盘
	if _targets.size() <= 1:
		Game.turn.resolve_front_row_selection("")
		return
	_active_cell = cell
	_selecting = true
	_begin_selection()

# ── 选择 UI ──────────────────────────────────────────────────────────
func _begin_selection() -> void:
	_clear_highlights()

	_overlay = Control.new()
	_overlay.name = "FrontRowSelectionOverlay"
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_overlay.z_index = 50
	_parent.add_child(_overlay)
	_overlay.gui_input.connect(_on_overlay_input)

	# 等一帧让布局稳定后再设缩放锚点
	await get_tree().process_frame

	for id in _targets.keys():
		var bg: Panel = _targets[id].get("bg_panel", null)
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

func _on_overlay_input(event: InputEvent) -> void:
	if not _selecting:
		return
	if event is InputEventMouseButton \
			and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var mp: Vector2 = _parent.get_global_mouse_position()
		for id in _targets.keys():
			var bg: Panel = _targets[id].get("bg_panel", null)
			if not is_instance_valid(bg):
				continue
			if bg.get_global_rect().has_point(mp):
				_end_selection(id)
				return
		# 点空白：维持等待

func _end_selection(chosen_id: String) -> void:
	_selecting = false
	_clear_highlights()
	if is_instance_valid(_overlay):
		_overlay.queue_free()
		_overlay = null

	# main 视为本棋盘默认行动 → 传 ""
	var resolve_id: String = "" if chosen_id == "main" else chosen_id
	Game.turn.resolve_front_row_selection(resolve_id)

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
func _on_target_chosen(cell: Node, target_id: String) -> void:
	if not is_instance_valid(cell) or not cell.has_card:
		return
	if not _targets.has(target_id):
		return

	var board_model: BoardModel = _resolve_board_model(target_id)
	if board_model == null:
		return
	var front_enemy = board_model.get_cell(Vector2(ENEMY_FRONT_ROW, cell.col))
	var has_enemy: bool = is_instance_valid(front_enemy) and front_enemy.has_card

	if has_enemy:
		# 原地攻击，不移动
		cell.play_attack_effect()
		await get_tree().create_timer(CombatSystem.ATTACK_HIT_DELAY).timeout
		if not is_instance_valid(cell) or not cell.has_card:
			return
		await _combat.attack_cells(cell, [{
			"cell": front_enemy, "dir": "bottom", "opp_dir": "top",
		}])
	else:
		# 移动到目标棋盘前排
		var target_cell = board_model.get_cell(Vector2(ENEMY_FRONT_ROW, cell.col))
		if not is_instance_valid(target_cell) or target_cell.has_card:
			return
		await _combat.move_card(cell, target_cell)
		if is_instance_valid(target_cell):
			target_cell.has_attacked = true

func _resolve_board_model(target_id: String) -> BoardModel:
	if target_id == "main":
		return Game.board
	if _board_resolver.is_valid():
		var bm = _board_resolver.call(target_id)
		if bm is BoardModel:
			return bm
	return null
