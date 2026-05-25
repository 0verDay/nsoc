class_name ExtraBoardController
extends Node

# 额外棋盘控制器。封装 test_main 中"动态生成第二个敌方棋盘"的所有逻辑：
# - test / move_test 按钮
# - 棋盘工厂（_create_board）
# - 滑入 / 滑出动画
# - 独立 BoardModel + HeroState
# - 独立 EnemySidePanelManager（墓地/除外）
# - 与 FrontRowSelector / TurnSystem 的注册联动
#
# 装配方式：
#   var ctrl := ExtraBoardController.new()
#   add_child(ctrl)
#   ctrl.setup({
#       "parent": self,
#       "main_enemy_nodes": _main_enemy_nodes,
#       "enemy_side_panels": enemy_side_panels,
#       "detail_panel": detail_panel,
#       "front_row_selector": front_row_selector,
#       "cell_scene": cell_scene,
#       "board_shift": BOARD_SHIFT,
#       "board_half_w": BOARD_HALF_W,
#       "board_center_gap": BOARD_CENTER_GAP,
#   })

signal board_created(board_model: BoardModel, hero_state)
signal board_destroyed(board_model: BoardModel)

# ── 依赖（setup 注入）─────────────────────────────────────────────────
var _parent: Control = null
var _main_enemy_nodes: Array = []
var _enemy_side_panels: EnemySidePanelManager = null
var _detail_panel = null
var _front_row_selector: FrontRowSelector = null
var _cell_scene: PackedScene = null
var _board_shift: float = -160.0
var _board_half_w: float = 230.0
var _board_center_gap: float = 40.0

# ── 状态 ──────────────────────────────────────────────────────────────
var _extra_board: Dictionary = {}
var _extra_board_model: BoardModel = null
var _enemy2_hero: HeroState = null
var _extra_enemy_side_panels: EnemySidePanelManager = null
var _anim_running: bool = false

func setup(deps: Dictionary) -> void:
	_parent              = deps.get("parent")
	_main_enemy_nodes    = deps.get("main_enemy_nodes", [])
	_enemy_side_panels   = deps.get("enemy_side_panels")
	_detail_panel        = deps.get("detail_panel")
	_front_row_selector  = deps.get("front_row_selector")
	_cell_scene          = deps.get("cell_scene")
	_board_shift         = float(deps.get("board_shift", -160.0))
	_board_half_w        = float(deps.get("board_half_w", 230.0))
	_board_center_gap    = float(deps.get("board_center_gap", 40.0))

	_create_test_buttons()

# ── 公开访问 ──────────────────────────────────────────────────────────
func get_extra_board_model() -> BoardModel:
	return _extra_board_model

func has_extra_board() -> bool:
	return not _extra_board.is_empty()

func get_extra_enemy_side_panels() -> EnemySidePanelManager:
	return _extra_enemy_side_panels

# 供外部 _input 调用：判断点是否落在额外棋盘的墓地/除外按钮上。
func is_extra_pile_button_hit(global_pos: Vector2) -> bool:
	for n in _extra_board.get("ui_nodes", []):
		if not is_instance_valid(n): continue
		if n.name.begins_with("EnemyGraveBtn") or n.name.begins_with("EnemyBanishedBtn"):
			if n.get_global_rect().has_point(global_pos):
				return true
	return false

# ── 测试按钮 ─────────────────────────────────────────────────────────
func _create_test_buttons() -> void:
	const BTN_W: float = 160.0
	const BTN_H: float = 60.0
	const MARGIN: float = 20.0
	const GAP: float = 10.0

	var test_btn := Button.new()
	test_btn.name = "TestBtn"; test_btn.text = "test"
	test_btn.anchor_left = 0.0; test_btn.anchor_right = 0.0
	test_btn.anchor_top = 0.0; test_btn.anchor_bottom = 0.0
	test_btn.offset_left = MARGIN; test_btn.offset_right = MARGIN + BTN_W
	test_btn.offset_top = MARGIN; test_btn.offset_bottom = MARGIN + BTN_H
	test_btn.add_theme_font_size_override("font_size", 28)
	test_btn.add_theme_color_override("font_color", Color.WHITE)
	ThemeFactory.apply_button_styles(test_btn, ThemeFactory.primary_button_styles())
	_parent.add_child(test_btn)
	test_btn.pressed.connect(_on_test_pressed)

	var move_btn := Button.new()
	move_btn.name = "MoveTestBtn"; move_btn.text = "move_test"
	move_btn.anchor_left = 0.0; move_btn.anchor_right = 0.0
	move_btn.anchor_top = 0.0; move_btn.anchor_bottom = 0.0
	move_btn.offset_left = MARGIN; move_btn.offset_right = MARGIN + BTN_W
	move_btn.offset_top = MARGIN + BTN_H + GAP
	move_btn.offset_bottom = MARGIN + BTN_H * 2.0 + GAP
	move_btn.add_theme_font_size_override("font_size", 24)
	move_btn.add_theme_color_override("font_color", Color.WHITE)
	ThemeFactory.apply_button_styles(move_btn, ThemeFactory.primary_button_styles())
	_parent.add_child(move_btn)
	move_btn.pressed.connect(_on_move_test_pressed)

# ── test：右移主棋盘 + 创建额外棋盘 ───────────────────────────────────
func _on_test_pressed() -> void:
	if _anim_running or has_extra_board():
		return
	_anim_running = true

	for _i in 3:
		await get_tree().process_frame

	var half_gap: float = _board_center_gap / 2.0
	var shift_amount: float = _board_half_w + half_gap

	# 主敌方棋盘右移
	var tw := _parent.create_tween()
	tw.set_parallel(true)
	for n in _main_enemy_nodes:
		if is_instance_valid(n):
			tw.tween_property(n, "position",
				n.position + Vector2(shift_amount, 0.0), 0.5) \
				.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	await tw.finished

	if is_instance_valid(_enemy_side_panels):
		_enemy_side_panels.update_clip_center_x(_board_shift + shift_amount)

	# 创建额外棋盘
	var new_center: float = _board_shift - shift_amount
	_extra_board = _build_board(new_center, "Extra")
	_extra_board_model = BoardModel.new()
	_extra_board_model.name = "ExtraBoardModel"
	_parent.add_child(_extra_board_model)
	_fill_extra_grid(_extra_board["grid_top"], _extra_board_model)

	# 第二敌方英雄
	var enemy_data: Dictionary = DataLoader.get_enemy_default()
	var e_display: String = String(enemy_data.get("display_name", "敌人"))
	var e_battle: String  = String(enemy_data.get("battle_name", e_display))
	var e_hp: int = int(enemy_data.get("max_health", 30))
	_enemy2_hero = HeroState.new()
	_enemy2_hero.name = "Enemy2HeroState"
	_parent.add_child(_enemy2_hero)
	_enemy2_hero.setup(e_hp, e_hp, "P2", e_battle, [], [], "", e_display)

	_wire_enemy2_hp_label()
	await _wire_enemy2_hp_panel()
	_create_extra_side_panels(new_center)

	await _animate_slide_in(_extra_board)

	# 注册到选择器 + 回合系统
	if is_instance_valid(_front_row_selector):
		_front_row_selector.register_target("extra",
			_extra_board.get("bg_top"), _enemy2_hero)

	_register_to_turn_system()

	board_created.emit(_extra_board_model, _enemy2_hero)
	_anim_running = false

# ── move_test：销毁额外棋盘 + 主棋盘复位 ──────────────────────────────
func _on_move_test_pressed() -> void:
	if _anim_running or not has_extra_board():
		return
	_anim_running = true

	await _animate_slide_out(_extra_board)

	if is_instance_valid(_front_row_selector):
		_front_row_selector.unregister_target("extra")

	if is_instance_valid(_extra_board_model) and has_node("/root/Game"):
		Game.turn.unregister_extra_board(_extra_board_model)

	board_destroyed.emit(_extra_board_model)

	if is_instance_valid(_enemy2_hero):
		_enemy2_hero.queue_free()
	_enemy2_hero = null

	if _extra_board.has("container") and is_instance_valid(_extra_board["container"]):
		_extra_board["container"].queue_free()
	for n in _extra_board.get("ui_nodes", []):
		if is_instance_valid(n):
			n.queue_free()
	_extra_board.clear()

	if is_instance_valid(_extra_board_model):
		_extra_board_model.queue_free()
	_extra_board_model = null

	# 主棋盘左移复位
	var shift_amount: float = _board_half_w + _board_center_gap / 2.0
	var tw := _parent.create_tween()
	tw.set_parallel(true)
	for n in _main_enemy_nodes:
		if is_instance_valid(n):
			tw.tween_property(n, "position",
				n.position + Vector2(-shift_amount, 0.0), 0.5) \
				.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	await tw.finished

	if is_instance_valid(_enemy_side_panels):
		_enemy_side_panels.update_clip_center_x(_board_shift)

	if is_instance_valid(_extra_enemy_side_panels):
		_extra_enemy_side_panels.queue_free()
	_extra_enemy_side_panels = null

	_anim_running = false

# ── 棋盘工厂 ─────────────────────────────────────────────────────────
func _build_board(center_offset: float, suffix: String) -> Dictionary:
	const BOARD_HALF_W_LOC: float = 230.0
	const TOP_NEAR: float = 20.0
	const TOP_FAR: float  = 470.0
	const BTN_H: float = 40.0
	const GAP: float = 10.0
	const BTN_W: float = (BOARD_HALF_W_LOC * 2.0 - GAP * 2.0) / 3.0
	const TOP_BTN_Y: float = 15.0
	var grid_bg_style := ThemeFactory.panel(Color("#f0f3f5"), Color("#e1e8ed"), 1, 16)
	var ui_nodes: Array = []

	var container := Control.new()
	container.name = "BoardContainer" + suffix
	container.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	container.visible = false
	_parent.add_child(container)

	var bg_top := Panel.new()
	bg_top.name = "TopGridBg" + suffix
	bg_top.anchor_left = 0.5; bg_top.anchor_top = 0.5
	bg_top.anchor_right = 0.5; bg_top.anchor_bottom = 0.5
	bg_top.offset_left   = center_offset - BOARD_HALF_W_LOC
	bg_top.offset_right  = center_offset + BOARD_HALF_W_LOC
	bg_top.offset_top    = -TOP_FAR
	bg_top.offset_bottom = -TOP_NEAR
	bg_top.grow_horizontal = 2; bg_top.grow_vertical = 2
	bg_top.add_theme_stylebox_override("panel", grid_bg_style)
	container.add_child(bg_top)

	var grid_top := GridContainer.new()
	grid_top.name = "TopGrid" + suffix
	grid_top.anchor_left = 0.5; grid_top.anchor_top = 0.5
	grid_top.anchor_right = 0.5; grid_top.anchor_bottom = 0.5
	grid_top.offset_left = -205.0; grid_top.offset_right = 205.0
	grid_top.offset_top  = -205.0; grid_top.offset_bottom = 205.0
	grid_top.grow_horizontal = 2; grid_top.grow_vertical = 2
	grid_top.add_theme_constant_override("h_separation", 25)
	grid_top.add_theme_constant_override("v_separation", 25)
	grid_top.columns = 3
	bg_top.add_child(grid_top)

	# 顶部 UI
	var hp_top := Panel.new()
	hp_top.name = "EnemyHpPnl" + suffix
	hp_top.anchor_left = 0.5; hp_top.anchor_right = 0.5
	hp_top.offset_left  = center_offset - BTN_W / 2.0
	hp_top.offset_right = center_offset + BTN_W / 2.0
	hp_top.offset_top = TOP_BTN_Y; hp_top.offset_bottom = TOP_BTN_Y + BTN_H
	hp_top.add_theme_stylebox_override("panel",
		ThemeFactory.panel(Color.WHITE, Color("#ff6b6b"), 2, 12, true))
	_parent.add_child(hp_top); ui_nodes.append(hp_top)
	var lbl := Label.new()
	lbl.name = "EnemyHealthLabel" + suffix
	lbl.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	lbl.add_theme_color_override("font_color", Color(1, 0.419608, 0.419608, 1))
	lbl.add_theme_font_size_override("font_size", 22)
	lbl.text = "30"
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hp_top.add_child(lbl)

	var grave_btn := Button.new()
	grave_btn.name = "EnemyGraveBtn" + suffix; grave_btn.text = "墓地"
	grave_btn.anchor_left = 0.5; grave_btn.anchor_right = 0.5
	grave_btn.offset_left  = center_offset - BOARD_HALF_W_LOC
	grave_btn.offset_right = center_offset - BOARD_HALF_W_LOC + BTN_W
	grave_btn.offset_top = TOP_BTN_Y; grave_btn.offset_bottom = TOP_BTN_Y + BTN_H
	grave_btn.add_theme_font_size_override("font_size", 22)
	ThemeFactory.apply_button_styles(grave_btn, ThemeFactory.primary_button_styles())
	_parent.add_child(grave_btn); ui_nodes.append(grave_btn)

	var banished_btn := Button.new()
	banished_btn.name = "EnemyBanishedBtn" + suffix; banished_btn.text = "除外"
	banished_btn.anchor_left = 0.5; banished_btn.anchor_right = 0.5
	banished_btn.offset_left  = center_offset + BOARD_HALF_W_LOC - BTN_W
	banished_btn.offset_right = center_offset + BOARD_HALF_W_LOC
	banished_btn.offset_top = TOP_BTN_Y; banished_btn.offset_bottom = TOP_BTN_Y + BTN_H
	banished_btn.add_theme_font_size_override("font_size", 22)
	ThemeFactory.apply_button_styles(banished_btn, ThemeFactory.primary_button_styles())
	_parent.add_child(banished_btn); ui_nodes.append(banished_btn)

	return {
		"container": container,
		"bg_top": bg_top, "grid_top": grid_top,
		"ui_nodes": ui_nodes,
		"hp_panel": hp_top,
		"hp_label": lbl,
	}

func _fill_extra_grid(grid_top: GridContainer, board_model: BoardModel) -> void:
	for r in range(3):
		for c in range(3):
			var cell = _cell_scene.instantiate()
			cell.row = r; cell.col = c
			cell.is_enemy = true
			board_model.register_cell(cell)
			grid_top.add_child(cell)
			if is_instance_valid(_detail_panel):
				cell.long_press_canceled.connect(_detail_panel.cancel_long_press)

# ── HP 标签 / 面板按压 ───────────────────────────────────────────────
func _wire_enemy2_hp_label() -> void:
	var hp_label: Label = _extra_board.get("hp_label", null)
	if not is_instance_valid(hp_label):
		return
	_enemy2_hero.health_changed.connect(func(is_enemy: bool, val: int) -> void:
		if is_enemy and is_instance_valid(hp_label):
			hp_label.text = str(val))
	hp_label.text = str(_enemy2_hero.enemy_health)

func _wire_enemy2_hp_panel() -> void:
	var hp_panel: Panel = _extra_board.get("hp_panel", null)
	if not is_instance_valid(hp_panel):
		return
	await get_tree().process_frame
	hp_panel.pivot_offset = hp_panel.size * 0.5
	hp_panel.gui_input.connect(_make_hp_panel_input_handler(hp_panel))

func _make_hp_panel_input_handler(hp_panel: Panel) -> Callable:
	return func(event: InputEvent) -> void:
		if event is InputEventMouseButton \
				and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			if is_instance_valid(_detail_panel) and is_instance_valid(_enemy2_hero):
				_detail_panel.start_long_press_hero(
					_enemy2_hero.enemy_full_name,
					_enemy2_hero.enemy_ability_id(),
					_enemy2_hero.enemy_max_health)
			var tw_press := hp_panel.create_tween()
			tw_press.tween_property(hp_panel, "scale", Vector2(1.08, 1.08), 0.1)
		elif event is InputEventMouseButton \
				and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
			if is_instance_valid(_detail_panel):
				_detail_panel.cancel_long_press()
			if hp_panel.scale != Vector2.ONE:
				var tw_rel := hp_panel.create_tween()
				tw_rel.tween_property(hp_panel, "scale", Vector2.ONE, 0.1)

# ── 额外棋盘的墓地/除外侧边面板 ─────────────────────────────────────
func _create_extra_side_panels(center_x: float) -> void:
	_extra_enemy_side_panels = EnemySidePanelManager.new()
	_extra_enemy_side_panels.name = "EnemySidePanelsExtra"
	_parent.add_child(_extra_enemy_side_panels)
	_extra_enemy_side_panels.setup(_parent, center_x)
	if is_instance_valid(_detail_panel):
		_extra_enemy_side_panels.long_press_requested.connect(_detail_panel.start_long_press)
		_extra_enemy_side_panels.long_press_canceled.connect(_detail_panel.cancel_long_press)

	for n in _extra_board.get("ui_nodes", []):
		if not is_instance_valid(n): continue
		if n.name.begins_with("EnemyGraveBtn"):
			n.pressed.connect(func(): _extra_enemy_side_panels.toggle("enemy_grave"))
		elif n.name.begins_with("EnemyBanishedBtn"):
			n.pressed.connect(func(): _extra_enemy_side_panels.toggle("enemy_banished"))

	for clip in _extra_enemy_side_panels.get_clip_nodes():
		clip.move_to_front()

# ── 注册到 TurnSystem（参与回合遍历 + 英雄伤害）─────────────────────
func _register_to_turn_system() -> void:
	if not is_instance_valid(_extra_board_model) or not is_instance_valid(_enemy2_hero):
		return
	var hp_panel: Panel = _extra_board.get("hp_panel", null)
	var resolver := func(is_enemy: bool, damage: int) -> void:
		if is_instance_valid(_enemy2_hero):
			_enemy2_hero.apply_damage(is_enemy, damage)
		if is_instance_valid(hp_panel):
			hp_panel.self_modulate = Color("#ffc9c9")
			var flash_tw := hp_panel.create_tween()
			flash_tw.tween_property(hp_panel, "self_modulate",
				Color.WHITE, CombatSystem.HERO_HIT_FADE)
	if has_node("/root/Game"):
		Game.turn.register_extra_board(_extra_board_model, resolver)

# ── 棋盘动画 ────────────────────────────────────────────────────────
func _animate_slide_in(board_dict: Dictionary,
		slide_duration: float = 0.5, fade_duration: float = 0.3) -> void:
	if board_dict.is_empty():
		return
	var container: Control = board_dict.get("container", null)
	if not is_instance_valid(container):
		return

	var vp_h: float = float(ProjectSettings.get_setting(
		"display/window/size/viewport_height", 1080))

	var ui_nodes: Array = board_dict.get("ui_nodes", [])
	for n in ui_nodes:
		if is_instance_valid(n):
			n.modulate.a = 0.0

	await get_tree().process_frame

	var origin: Vector2 = container.position
	container.position = origin + Vector2(0.0, -vp_h)
	container.visible = true

	var tw_a := _parent.create_tween()
	tw_a.tween_property(container, "position", origin, slide_duration) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	await tw_a.finished

	if not ui_nodes.is_empty():
		var tw_b := _parent.create_tween()
		tw_b.set_parallel(true)
		for n in ui_nodes:
			if is_instance_valid(n):
				tw_b.tween_property(n, "modulate:a", 1.0, fade_duration) \
					.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		await tw_b.finished

func _animate_slide_out(board_dict: Dictionary,
		slide_duration: float = 0.5, fade_duration: float = 0.3) -> void:
	if board_dict.is_empty():
		return
	var container: Control = board_dict.get("container", null)
	if not is_instance_valid(container):
		return

	var vp_h: float = float(ProjectSettings.get_setting(
		"display/window/size/viewport_height", 1080))
	var ui_nodes: Array = board_dict.get("ui_nodes", [])

	if not ui_nodes.is_empty():
		var tw_a := _parent.create_tween()
		tw_a.set_parallel(true)
		for n in ui_nodes:
			if is_instance_valid(n):
				tw_a.tween_property(n, "modulate:a", 0.0, fade_duration) \
					.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		await tw_a.finished

	var tw_b := _parent.create_tween()
	tw_b.tween_property(container, "position",
		container.position + Vector2(0.0, -vp_h), slide_duration) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	await tw_b.finished
