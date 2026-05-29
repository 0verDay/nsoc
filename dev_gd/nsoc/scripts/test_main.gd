extends Control

# TestMain —— 薄装配器。仅负责节点引用、信号连接、输入路由。
# 业务委托给 GameContext (autoload "Game") + Effects 注册表 + UI 控制器。
# test_main 相对 main 多出的部分（前排选择、额外棋盘、玩家面板拖拽）已抽出独立控制器：
#   - FrontRowSelector
#   - ExtraBoardController
#   - HeroPanelDragController

@onready var hand_container = $BottomBar/HandClip/HandContainer
@onready var enemy_health_label = $EnemyHpPnl/EnemyHealthLabel
@onready var player_health_label = $LeftSidePnl/PHpPnl/PlayerHealthLabel
@onready var mana_label = $BottomBar/ManaPnl/ManaLabel
@onready var end_turn_btn = $BottomBar/EndTurnBtn
@onready var top_grid = $TopGridBg/TopGrid
@onready var bottom_grid = $BottomGridBg/BottomGrid
@onready var hero_name_lbl = $LeftSidePnl/HeroNameLbl

var deck_btn: Button
var grave_btn: Button
var banished_btn: Button

var cell_scene := preload("res://scenes/Cell.tscn")
var hand_card_scene := preload("res://scenes/HandCard.tscn")

var hand_view: HandView
var detail_panel: DetailPanelController
var side_panels: SidePanelManager
var enemy_side_panels: EnemySidePanelManager
var settings_panel: SettingsPanelController
var play_controller: PlayController
var combat: CombatSystem

var enemy_grave_btn: Button
var enemy_banished_btn: Button
var hero_action_bar: HeroActionBar

# ── 抽出的控制器 ─────────────────────────────────────────────────────
# 用 Node 弱类型避免 class_name 全局表未刷新时的解析报错。
# 实际类型分别为 FrontRowSelector / ExtraBoardController / HeroPanelDragController。
var front_row_selector: Node
var extra_board_ctrl: Node       # 已废弃；保留字段名以防外部引用
var board_orchestrator: BoardOrchestrator   # 阶段 4：多盘装配编排器
var hero_drag_ctrl: Node

# ── 布局常量 ─────────────────────────────────────────────────────────
const BOARD_SHIFT: float = -160.0    # 主棋盘中心相对视口中心的水平偏移
const BOARD_HALF_W: float = 230.0    # 棋盘半宽（宽=460）
const BOARD_CENTER_GAP: float = 40.0 # 上下棋盘间距（同时也是两上方棋盘水平间距）

# 原敌方区域节点集合（TopGridBg + 附属按钮），ExtraBoardController 借用以做平移动画
var _main_enemy_nodes: Array = []

func _ready() -> void:
	visible = false
	await _apply_editor_window_scale()
	# test_main 专用多棋盘测试关卡；main 场景继续读默认 test_level.json。
	Game.pending_level_path = "res://data/multi_chessboard_test_level.json"
	Game.bootstrap()

	_apply_styles()

	hand_view = HandView.new(); hand_view.name = "HandView"; add_child(hand_view)
	hand_view.setup(hand_container, hand_card_scene, self)

	detail_panel = DetailPanelController.new(); detail_panel.name = "DetailPanel"; add_child(detail_panel)
	detail_panel.setup(self, hand_card_scene)

	side_panels = SidePanelManager.new(); side_panels.name = "SidePanels"; add_child(side_panels)
	side_panels.setup(self, BOARD_SHIFT)

	enemy_side_panels = EnemySidePanelManager.new(); enemy_side_panels.name = "EnemySidePanels"; add_child(enemy_side_panels)
	enemy_side_panels.setup(self, null, BOARD_SHIFT)

	_create_enemy_pile_buttons()
	_create_player_pile_buttons()
	_create_hero_action_bar()

	settings_panel = SettingsPanelController.new(); settings_panel.name = "SettingsPanel"; add_child(settings_panel)
	settings_panel.setup(self, {
		"create_trigger_button": false,
		"exit_action": Callable(self, "_on_exit_to_menu"),
	})
	_create_settings_button()

	_collect_main_enemy_nodes()

	play_controller = PlayController.new(); play_controller.name = "PlayController"; add_child(play_controller)
	play_controller.setup(self, cell_scene)
	Game.play = play_controller
	play_controller.hand_view = hand_view   # 供 discard_hand_card effect 使用

	combat = CombatSystem.new(); combat.name = "Combat"; add_child(combat)
	combat.setup(self, cell_scene, play_controller)
	Game.combat = combat

	Game.turn.setup(combat, Callable(Game, "get_card"))

	# 阶段 4：BoardOrchestrator 集中创建主棋盘 + enabled 附盘
	board_orchestrator = BoardOrchestrator.new()
	board_orchestrator.name = "BoardOrchestrator"
	add_child(board_orchestrator)
	board_orchestrator.setup({
		"parent": self,
		"cell_scene": cell_scene,
		"detail_panel": detail_panel,
		"on_cell_created": Callable(self, "_wire_cell"),
		"main_center_x": BOARD_SHIFT,
		"side_gap_x": BOARD_HALF_W * 2.0 + BOARD_CENTER_GAP,
		"main_ui": {
			"player_main": {
				"grid": bottom_grid,
				"bg": $BottomGridBg,
				"hero_panel": $LeftSidePnl/PHpPnl,
			},
			"enemy_main": {
				"grid": top_grid,
				"bg": $TopGridBg,
				"hero_panel": $EnemyHpPnl,
			},
		},
	})
	board_orchestrator.boot()
	if hero_action_bar != null:
		hero_action_bar._refresh_all()
	# boot 后把主敌盘 slot 注入 enemy_side_panels 作数据源
	var enemy_main_slot: BoardSlot = Game.registry.get_by_id("enemy_main") if Game.registry != null else null
	if enemy_main_slot != null:
		enemy_side_panels.set_slot(enemy_main_slot)

	_wire_signals()

	_install_controllers()

	# 初始 phantom 渲染 + UI 同步（所有 slot 各自刷一次）
	for slot in Game.registry.slots:
		if slot.spawners != null:
			slot.spawners.refresh_phantoms(slot.board, Callable(Game, "get_card"))
	var p_hero: HeroState = Game.player_hero()
	var e_hero: HeroState = Game.enemy_main_hero()
	if p_hero != null:
		player_health_label.text = str(p_hero.health)
		hero_name_lbl.text = p_hero.name_short
	if e_hero != null:
		enemy_health_label.text = str(e_hero.health)
	_on_mana_changed(Game.mana.current, Game.mana.maximum)

	for clip in side_panels.get_clip_nodes():
		clip.move_to_front()
	for clip in enemy_side_panels.get_clip_nodes():
		clip.move_to_front()
	detail_panel.get_clip().move_to_front()

	_play_intro_animation()

# ── 控制器装配 ───────────────────────────────────────────────────────
# 通过 load() 显式加载脚本资源，避免 class_name 全局表未刷新时的标识符解析错。
const FrontRowSelectorScript        = preload("res://scripts/ui/front_row_selector.gd")
const HeroPanelDragControllerScript = preload("res://scripts/ui/hero_panel_drag_controller.gd")
const TargetSelectorScript          = preload("res://scripts/ui/target_selector_controller.gd")
const HandPickerScript              = preload("res://scripts/ui/hand_picker_controller.gd")

func _install_controllers() -> void:
	front_row_selector = FrontRowSelectorScript.new()
	front_row_selector.name = "FrontRowSelector"
	add_child(front_row_selector)
	front_row_selector.setup(self, combat)

	var target_selector := TargetSelectorScript.new()
	target_selector.name = "TargetSelector"
	add_child(target_selector)
	target_selector.setup(self)

	var hand_picker := HandPickerScript.new()
	hand_picker.name = "HandPicker"
	add_child(hand_picker)
	hand_picker.setup(self, hand_view)

	hero_drag_ctrl = HeroPanelDragControllerScript.new()
	hero_drag_ctrl.name = "HeroDragCtrl"
	add_child(hero_drag_ctrl)
	hero_drag_ctrl.setup({
		"panel": $LeftSidePnl,
		"bottom_bar": $BottomBar,
		"detail_panel": detail_panel,
		"long_press_hero_args": Callable(self, "_get_player_hero_long_press_args"),
	})
	# 装备展开动画期间阻断 / 恢复拖拽
	if is_instance_valid(hero_action_bar):
		hero_action_bar.panel_expansion_started.connect(
			func(): hero_drag_ctrl.set_drag_blocked(true))
		hero_action_bar.panel_expansion_finished.connect(
			func(): hero_drag_ctrl.set_drag_blocked(false))
	$EnemyHpPnl.gui_input.connect(_on_enemy_hero_panel_gui_input)

	# 注入选择器到 GameContext，供 EffectContext.pick_target_async/pick_hand_card_async 使用
	Game.register_selectors(target_selector, hand_picker)

# HeroPanelDragController 的 long_press_hero_args 回调。
func _get_player_hero_long_press_args() -> Array:
	var hero: HeroState = Game.player_hero()
	if hero == null:
		return ["", "", -1]
	return [hero.name_full, hero.ability_id(), hero.max_health]

# ── 信号连接 ─────────────────────────────────────────────────────────
func _wire_signals() -> void:
	# 主玩家盘 / 主敌盘 hero 各自连信号到对应 UI 标签
	# 注意：HeroState 属于 Game autoload，场景切换后仍存活。
	# 必须用命名方法（非 lambda），Godot 4 才会在本节点 free 时自动断开连接。
	var p_hero: HeroState = Game.player_hero()
	if p_hero != null:
		p_hero.health_changed.connect(_on_player_health_changed)
		p_hero.died.connect(_on_player_hero_died)
	var e_hero: HeroState = Game.enemy_main_hero()
	if e_hero != null:
		e_hero.health_changed.connect(_on_enemy_health_changed)
		e_hero.died.connect(_on_enemy_hero_died)
	Game.mana.mana_changed.connect(_on_mana_changed)

	# 战役胜利目标：达成时与击杀敌方英雄同路径触发胜利
	if has_node("/root/Objectives"):
		Objectives.objective_completed.connect(_on_objective_completed)

	end_turn_btn.pressed.connect(_on_end_turn_pressed)
	deck_btn.pressed.connect(func(): side_panels.toggle("deck"))
	grave_btn.pressed.connect(func(): side_panels.toggle("grave"))
	banished_btn.pressed.connect(func(): side_panels.toggle("banished"))
	enemy_grave_btn.pressed.connect(func(): enemy_side_panels.toggle("enemy_grave"))
	enemy_banished_btn.pressed.connect(func(): enemy_side_panels.toggle("enemy_banished"))

	side_panels.long_press_requested.connect(detail_panel.start_long_press)
	side_panels.long_press_canceled.connect(detail_panel.cancel_long_press)
	enemy_side_panels.long_press_requested.connect(detail_panel.start_long_press)
	enemy_side_panels.long_press_canceled.connect(detail_panel.cancel_long_press)
	# 阶段 5：附盘 EnemySidePanelManager 的长按转发到 detail_panel
	if is_instance_valid(board_orchestrator):
		board_orchestrator.side_panel_long_press_requested.connect(detail_panel.start_long_press)
		board_orchestrator.side_panel_long_press_canceled.connect(detail_panel.cancel_long_press)
	hand_view.hand_card_long_press_requested.connect(detail_panel.start_long_press)
	hand_view.hand_card_long_press_canceled.connect(detail_panel.cancel_long_press)
	play_controller.hand_consumed.connect(hand_view.draw_into_slot)

	# HeroActionBar 自连 turn / mana / abilities / equipments；不再重复连。

	# 装备拖拽高亮
	hand_view.equip_drag_started.connect(hero_action_bar.show_equip_drag_highlight)
	hand_view.equip_drag_ended.connect(hero_action_bar.hide_equip_drag_highlight)

	# 确保 LeftSidePnl 在节点顺序最末（同 z_index 时后画的在上），
	# 视觉和 drop 检测始终优先于棋盘格子。
	$LeftSidePnl.move_to_front()

# ── UI 刷新槽 ────────────────────────────────────────────────────────
func _on_mana_changed(current: int, maximum: int) -> void:
	mana_label.text = str(current) + "/" + str(maximum)

# 命名方法替代 lambda，确保节点 free 时 Godot 自动断开与 HeroState 的连接
func _on_player_health_changed(v: int) -> void:
	player_health_label.text = str(v)
func _on_enemy_health_changed(v: int) -> void:
	enemy_health_label.text = str(v)
func _on_player_hero_died() -> void:
	_on_hero_died(false)
func _on_enemy_hero_died() -> void:
	_on_hero_died(true)

func _on_hero_died(is_enemy: bool) -> void:
	end_turn_btn.disabled = true
	end_turn_btn.text = "胜利" if is_enemy else "失败"
	_show_game_over(is_enemy)

# 战役胜利目标达成（与敌方英雄死亡同语义：玩家胜利）
func _on_objective_completed() -> void:
	end_turn_btn.disabled = true
	end_turn_btn.text = "胜利"
	_show_game_over(true)

func _show_game_over(victory: bool) -> void:
	# CanvasLayer 独立渲染层，layer=100 保证覆盖所有游戏内元素（棋子/英雄面板等）。
	# z_index 方案在多层级节点混杂时不可靠；CanvasLayer 完全隔离。
	var canvas := CanvasLayer.new()
	canvas.layer = 100
	add_child(canvas)

	var overlay := ColorRect.new()
	overlay.color = Color(0, 0, 0, 0.75)
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	canvas.add_child(overlay)

	# ── 主标题（胜利 / 失败）────────────────────────────────────────────
	var lbl := Label.new()
	lbl.text = "胜利" if victory else "失败"
	lbl.add_theme_font_size_override("font_size", 96)
	lbl.add_theme_color_override("font_color", Color.WHITE if victory else Color("#ff6b6b"))
	lbl.set_anchors_preset(Control.PRESET_CENTER, false)
	lbl.offset_left = -200; lbl.offset_top = -80
	lbl.offset_right = 200; lbl.offset_bottom = 80
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	overlay.add_child(lbl)

	# ── 点击提示（居中偏下）────────────────────────────────────────────
	var hint := Label.new()
	hint.text = "————点击离开战役————"
	hint.add_theme_font_size_override("font_size", 28)
	hint.add_theme_color_override("font_color", Color(1, 1, 1, 0.65))
	hint.set_anchors_preset(Control.PRESET_CENTER, false)
	hint.offset_left = -300; hint.offset_top = 80
	hint.offset_right = 300; hint.offset_bottom = 130
	hint.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	overlay.add_child(hint)

	# ── 点击空白处退回主菜单 ─────────────────────────────────────────────
	overlay.gui_input.connect(func(event: InputEvent) -> void:
		if event is InputEventMouseButton \
				and event.button_index == MOUSE_BUTTON_LEFT \
				and event.pressed:
			_on_exit_to_menu()
	)

# ── 回合 ─────────────────────────────────────────────────────────────
func _on_end_turn_pressed() -> void:
	end_turn_btn.disabled = true
	end_turn_btn.text = "行动中"
	await Game.turn.run()
	Game.mana.start_new_turn()
	HeroAbilities.reset_turn_usage()
	Equipments.reset_turn_usage()
	end_turn_btn.disabled = false
	end_turn_btn.text = "结束回合"

# ── 棋盘初始化 ───────────────────────────────────────────────────────
# 阶段 4：主棋盘 + 附盘装配统一交由 BoardOrchestrator 处理（_ready 中已 boot）。
# DataLoader 按 faction 路由旧 JSON 到 boards.player_main / boards.enemy_main，
# Orchestrator 读 boards.<id> 元数据完成创建。

# 每个 cell 创建后由 BoardSlotFactory 回调，绑定交互信号。
func _wire_cell(cell: Node) -> void:
	cell.long_press_requested.connect(_on_cell_long_press_requested)
	cell.long_press_canceled.connect(detail_panel.cancel_long_press)
	cell.card_dropped.connect(_on_cell_card_dropped)
	cell.cleared.connect(_on_cell_cleared)

func _on_cell_long_press_requested(payload) -> void:
	detail_panel.start_long_press(payload)

func _on_cell_card_dropped(cell, data) -> void:
	play_controller.handle_drop(cell, data)

# cell 被清空时刷新所属盘的 phantom 预告（避免残留）
func _on_cell_cleared(cell) -> void:
	var slot: BoardSlot = Game.registry.get_by_id(cell.slot_id) if Game.registry != null else null
	if slot != null and slot.spawners != null:
		slot.spawners.refresh_phantoms(slot.board, Callable(Game, "get_card"))

# ── 输入路由 ─────────────────────────────────────────────────────────
func _input(event) -> void:
	# Ctrl+数字 快捷键控制附盘开关
	if event is InputEventKey and event.is_pressed() and event.ctrl_pressed:
		var orch: BoardOrchestrator = board_orchestrator
		if not is_instance_valid(orch):
			return
		match event.keycode:
			KEY_0: orch.toggle("enemy_left")
			KEY_2: orch.toggle("enemy_right")
			KEY_3: orch.toggle("ally_left")
			KEY_5: orch.toggle("ally_right")
		return

	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if not event.pressed:
			detail_panel.cancel_long_press()
			detail_panel.hide_panel()
			if $EnemyHpPnl.scale != Vector2.ONE:
				$EnemyHpPnl.pivot_offset = $EnemyHpPnl.size / 2.0
				var t := $EnemyHpPnl.create_tween()
				t.tween_property($EnemyHpPnl, "scale", Vector2.ONE, 0.1)
			if is_instance_valid(hero_drag_ctrl):
				hero_drag_ctrl.handle_global_release()
		else:
			var p := get_global_mouse_position()
			# 英雄面板拖拽：附盘 ui_nodes 覆盖会拦截 gui_input，改为在全局 _input 中
			# 检测 LeftSidePnl 命中并直接转发给 hero_drag_ctrl，绕过覆盖层
			if is_instance_valid(hero_drag_ctrl) and $LeftSidePnl.get_global_rect().has_point(p):
				hero_drag_ctrl.on_gui_input(event)
				return
			if side_panels.has_open_panel():
				if side_panels.is_panel_hit(p): return
				if deck_btn.get_global_rect().has_point(p): return
				if grave_btn.get_global_rect().has_point(p): return
				if banished_btn.get_global_rect().has_point(p): return
				side_panels.close_current()
			if enemy_side_panels.has_open_panel():
				if enemy_side_panels.is_panel_hit(p): return
				if enemy_grave_btn.get_global_rect().has_point(p): return
				if enemy_banished_btn.get_global_rect().has_point(p): return
				enemy_side_panels.close_current()
			# 阶段 5：附盘墓地/除外面板
			if is_instance_valid(board_orchestrator):
				if board_orchestrator.any_side_panel_open():
					if board_orchestrator.is_side_panel_hit(p): return
					if board_orchestrator.is_pile_button_hit(p): return
					board_orchestrator.close_all_side_panels()
				elif board_orchestrator.is_pile_button_hit(p):
					return

	# 鼠标移动时同步转发给 hero_drag_ctrl（附盘覆盖层同样会拦截 MouseMotion gui_input）
	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		if is_instance_valid(hero_drag_ctrl):
			hero_drag_ctrl.on_gui_input(event)

# ── 样式 ─────────────────────────────────────────────────────────────
func _apply_editor_window_scale() -> void:
	if not OS.has_feature("editor"):
		return
	var win := get_window()
	if win == null:
		return
	var vp_w: int = int(ProjectSettings.get_setting("display/window/size/viewport_width"))
	var vp_h: int = int(ProjectSettings.get_setting("display/window/size/viewport_height"))
	var half: Vector2i = Vector2i(vp_w / 2, vp_h / 2)
	win.size = half
	await get_tree().process_frame
	if win.size != half:
		get_tree().root.content_scale_factor = 0.5
		return
	var screen_size: Vector2i = DisplayServer.screen_get_size(DisplayServer.SCREEN_PRIMARY)
	var screen_pos: Vector2i = DisplayServer.screen_get_position(DisplayServer.SCREEN_PRIMARY)
	win.position = screen_pos + (screen_size - half) / 2

func _apply_styles() -> void:
	$Bg.add_theme_stylebox_override("panel", ThemeFactory.panel(Color.WHITE, Color("#e1e8ed"), 1, 0))
	$EnemyHpPnl.add_theme_stylebox_override("panel", ThemeFactory.panel(Color.WHITE, Color("#ff6b6b"), 2, 20, true))
	var grid_bg_style := ThemeFactory.panel(Color("#f0f3f5"), Color("#e1e8ed"), 1, 16)
	$TopGridBg.add_theme_stylebox_override("panel", grid_bg_style)
	$BottomGridBg.add_theme_stylebox_override("panel", grid_bg_style)
	$BottomBar.add_theme_stylebox_override("panel", ThemeFactory.panel(Color(0.94, 0.95, 0.96, 0.85), Color(1, 1, 1, 0.6), 1, 20))
	$LeftSidePnl.add_theme_stylebox_override("panel", ThemeFactory.panel(Color.WHITE, Color(1, 1, 1, 0.6), 1, 20, true))
	$LeftSidePnl.z_index = 10
	hand_container.add_theme_constant_override("separation", 50)
	$LeftSidePnl/PHpPnl.add_theme_stylebox_override("panel", ThemeFactory.panel(Color.WHITE, Color("#ff6b6b"), 2, 12, true))
	$BottomBar/ManaPnl.add_theme_stylebox_override("panel", ThemeFactory.panel(Color.WHITE, Color("#339af0"), 2, 12, true))
	$EnemyHpPnl.add_theme_stylebox_override("panel", ThemeFactory.panel(Color.WHITE, Color("#ff6b6b"), 2, 12, true))
	ThemeFactory.apply_button_styles(end_turn_btn, ThemeFactory.primary_button_styles())

# ── 退出到菜单 ────────────────────────────────────────────────────────
# 立即标记 combat.aborted = true，所有正在 await 的协程在下一个 resume 点安全退出，
# 过渡动画：白色渐入盖满 → 立即切场景；下一场景接力白→透明淡出。
const EXIT_FADE_TO_WHITE: float = 0.25
func _on_exit_to_menu() -> void:
	# 标记中止：所有 combat/turn await 后检查此 flag 并立即 return
	if combat != null:
		combat.abort()
	if Game.turn != null:
		Game.turn.is_running = false

	# CanvasLayer(200) 确保覆盖所有游戏元素及结算界面(layer=100)
	var canvas := CanvasLayer.new()
	canvas.layer = 200
	add_child(canvas)
	var overlay := ColorRect.new()
	overlay.color = Color(1.0, 1.0, 1.0, 0.0)
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	canvas.add_child(overlay)
	var tw := canvas.create_tween()
	tw.tween_property(overlay, "color:a", 1.0, EXIT_FADE_TO_WHITE) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	await tw.finished

	# 标记下一个场景接力播放 白→透明
	Game.pending_fade_in_from_white = true
	get_tree().change_scene_to_file("res://scenes/MainMenu.tscn")

func _create_settings_button() -> void:
	const SIDEBAR_W: float = 310.0
	const GAP: float = 10.0
	const BTN_W: float = (SIDEBAR_W - GAP) / 2.0

	var interact_btn := Button.new()
	interact_btn.name = "InteractBtn"
	interact_btn.text = "互动"
	interact_btn.add_theme_font_size_override("font_size", 32)
	interact_btn.set_anchors_preset(Control.PRESET_TOP_RIGHT, false)
	interact_btn.anchor_left = 1.0; interact_btn.anchor_right = 1.0
	interact_btn.offset_left = -320.0; interact_btn.offset_top = 20.0
	interact_btn.offset_right = -320.0 + BTN_W; interact_btn.offset_bottom = 100.0
	interact_btn.add_theme_color_override("font_color", Color.WHITE)
	ThemeFactory.apply_button_styles(interact_btn, ThemeFactory.primary_button_styles())
	add_child(interact_btn)

	var btn := Button.new()
	btn.name = "SettingsBtn"
	btn.text = "选项"
	btn.add_theme_font_size_override("font_size", 32)
	btn.set_anchors_preset(Control.PRESET_TOP_RIGHT, false)
	btn.anchor_left = 1.0; btn.anchor_right = 1.0
	btn.offset_left = -10.0 - BTN_W; btn.offset_top = 20.0
	btn.offset_right = -10.0; btn.offset_bottom = 100.0
	btn.add_theme_color_override("font_color", Color.WHITE)
	ThemeFactory.apply_button_styles(btn, ThemeFactory.primary_button_styles())
	add_child(btn)
	btn.pressed.connect(settings_panel.open)

# 敌方主棋盘附属按钮（三等分，整体对齐 BOARD_SHIFT）
func _create_enemy_pile_buttons() -> void:
	const BTN_H: float = 40.0
	const GAP: float = 10.0
	const TOTAL_W: float = BOARD_HALF_W * 2.0
	const BTN_W: float = (TOTAL_W - GAP * 2.0) / 3.0
	const TOP_OFFSET: float = 15.0

	var hp_pnl: Panel = $EnemyHpPnl
	hp_pnl.anchor_left = 0.5; hp_pnl.anchor_right = 0.5
	hp_pnl.offset_left  = BOARD_SHIFT - BTN_W / 2.0
	hp_pnl.offset_right = BOARD_SHIFT + BTN_W / 2.0
	hp_pnl.offset_top = TOP_OFFSET; hp_pnl.offset_bottom = TOP_OFFSET + BTN_H
	hp_pnl.pivot_offset = Vector2(BTN_W / 2.0, BTN_H / 2.0)

	enemy_grave_btn = Button.new()
	enemy_grave_btn.name = "EnemyGraveBtn"
	enemy_grave_btn.text = "墓地"
	enemy_grave_btn.anchor_left = 0.5; enemy_grave_btn.anchor_right = 0.5
	enemy_grave_btn.offset_left  = BOARD_SHIFT - BOARD_HALF_W
	enemy_grave_btn.offset_right = BOARD_SHIFT - BOARD_HALF_W + BTN_W
	enemy_grave_btn.offset_top = TOP_OFFSET; enemy_grave_btn.offset_bottom = TOP_OFFSET + BTN_H
	enemy_grave_btn.add_theme_font_size_override("font_size", 22)
	add_child(enemy_grave_btn)

	enemy_banished_btn = Button.new()
	enemy_banished_btn.name = "EnemyBanishedBtn"
	enemy_banished_btn.text = "除外"
	enemy_banished_btn.anchor_left = 0.5; enemy_banished_btn.anchor_right = 0.5
	enemy_banished_btn.offset_left  = BOARD_SHIFT + BOARD_HALF_W - BTN_W
	enemy_banished_btn.offset_right = BOARD_SHIFT + BOARD_HALF_W
	enemy_banished_btn.offset_top = TOP_OFFSET; enemy_banished_btn.offset_bottom = TOP_OFFSET + BTN_H
	enemy_banished_btn.add_theme_font_size_override("font_size", 22)
	add_child(enemy_banished_btn)

	ThemeFactory.apply_button_styles(enemy_grave_btn, ThemeFactory.primary_button_styles())
	ThemeFactory.apply_button_styles(enemy_banished_btn, ThemeFactory.primary_button_styles())

func _create_player_pile_buttons() -> void:
	const BTN_H: float = 40.0
	const GAP: float = 10.0
	const BTN_W: float = (BOARD_HALF_W * 2.0 - GAP * 2.0) / 3.0
	const BOTTOM_OFFSET: float = 15.0

	deck_btn = Button.new(); deck_btn.name = "DeckBtn"; deck_btn.text = "牌库"
	grave_btn = Button.new(); grave_btn.name = "GraveBtn"; grave_btn.text = "墓地"
	banished_btn = Button.new(); banished_btn.name = "BanishedBtn"; banished_btn.text = "除外"

	# 视觉顺序：墓地 | 牌库 | 除外
	var btns: Array[Button] = [grave_btn, deck_btn, banished_btn]
	var x_start: float = BOARD_SHIFT - BOARD_HALF_W
	for i in btns.size():
		var b: Button = btns[i]
		b.anchor_left = 0.5; b.anchor_right = 0.5
		b.anchor_top = 1.0; b.anchor_bottom = 1.0
		b.offset_left  = x_start + (BTN_W + GAP) * float(i)
		b.offset_right = b.offset_left + BTN_W
		b.offset_top = -BOTTOM_OFFSET - BTN_H; b.offset_bottom = -BOTTOM_OFFSET
		b.add_theme_font_size_override("font_size", 22)
		add_child(b)
		ThemeFactory.apply_button_styles(b, ThemeFactory.primary_button_styles())

func _create_hero_action_bar() -> void:
	hero_action_bar = HeroActionBar.new()
	hero_action_bar.name = "HeroActionBar"
	hero_action_bar.setup($LeftSidePnl, Callable(self, "_make_hero_ability_ctx"), detail_panel, hand_card_scene)

	# LeftSidePnl 接受装备拖入
	for pnl in [$LeftSidePnl, $LeftSidePnl/PHpPnl]:
		pnl.set_drag_forwarding(
			Callable(),
			Callable(self, "_left_side_pnl_can_drop"),
			Callable(self, "_left_side_pnl_drop"))

func _make_hero_ability_ctx() -> EffectContext:
	var ctx: EffectContext = Game.make_effect_context_with_selectors()
	ctx.target_cell = null
	return ctx

func _left_side_pnl_can_drop(_pos: Vector2, data) -> bool:
	if play_controller == null:
		return false
	return play_controller.can_equip(data)

func _left_side_pnl_drop(_pos: Vector2, data) -> void:
	if play_controller == null:
		return
	play_controller.handle_equip(data)

# ── 收集原敌方区域节点（test 动画时整体右移）────────────────────────
func _collect_main_enemy_nodes() -> void:
	_main_enemy_nodes.clear()
	if is_instance_valid($TopGridBg):
		_main_enemy_nodes.append($TopGridBg)
	if is_instance_valid($EnemyHpPnl):
		_main_enemy_nodes.append($EnemyHpPnl)
	for name_str in ["EnemyGraveBtn", "EnemyBanishedBtn"]:
		var n = get_node_or_null(name_str)
		if n: _main_enemy_nodes.append(n)

# ── 敌方英雄面板长按 ─────────────────────────────────────────────────
func _on_enemy_hero_panel_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton \
			and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var hero: HeroState = Game.enemy_main_hero()
		if hero != null:
			detail_panel.start_long_press_hero(
				hero.name_full, hero.ability_id(), hero.max_health)
		var pnl: Panel = $EnemyHpPnl
		pnl.pivot_offset = pnl.size / 2.0
		var tween := pnl.create_tween()
		tween.tween_property(pnl, "scale", Vector2(1.08, 1.08), 0.1)

# ── 英雄技能 ────────────────────────────────────────────────────────
# 已迁移至 HeroActionBar。

# ── 入场动画 ─────────────────────────────────────────────────────────
const INTRO_SLIDE_DURATION: float = 0.5
const INTRO_FADE_DURATION: float  = 0.3
const INTRO_DRAW_INTERVAL: float  = 0.15
const INTRO_LAYOUT_SETTLE_FRAMES: int = 3

func _play_intro_animation() -> void:
	set_process_input(false)
	var blocker := Control.new()
	blocker.name = "IntroInputBlocker"
	blocker.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	blocker.z_index = 1000
	add_child(blocker)

	var settings_btn: Button = get_node_or_null("SettingsBtn")
	var interact_btn: Button = get_node_or_null("InteractBtn")
	var bottom_bar: Panel  = $BottomBar
	var left_side: Panel   = $LeftSidePnl
	var top_grid_bg: Panel = $TopGridBg
	var bottom_grid_bg: Panel = $BottomGridBg
	var enemy_hp_pnl: Panel = $EnemyHpPnl

	var slide_nodes: Array = []
	for n in [settings_btn, interact_btn, bottom_bar, left_side, top_grid_bg, bottom_grid_bg]:
		if n != null:
			slide_nodes.append(n); n.visible = false

	var fade_targets: Array = []
	for n in [enemy_hp_pnl, enemy_grave_btn, enemy_banished_btn,
			deck_btn, grave_btn, banished_btn]:
		if n: fade_targets.append(n)
	for n in fade_targets:
		n.modulate.a = 0.0

	for _i in INTRO_LAYOUT_SETTLE_FRAMES:
		await get_tree().process_frame

	var vp_w: float = float(ProjectSettings.get_setting("display/window/size/viewport_width", 1920))
	var vp_h: float = float(ProjectSettings.get_setting("display/window/size/viewport_height", 1080))
	var slide_specs: Array = []
	# 选项按钮：从右往左滑入
	if settings_btn:
		slide_specs.append({"node": settings_btn, "from": Vector2(vp_w, 0)})
	# 互动按钮：从上往下滑入
	if interact_btn:
		slide_specs.append({"node": interact_btn, "from": Vector2(0, -interact_btn.size.y - 40)})
	if bottom_bar:
		slide_specs.append({"node": bottom_bar, "from": Vector2(vp_w, 0)})
	if left_side:
		slide_specs.append({"node": left_side, "from": Vector2(0, vp_h)})
	if top_grid_bg:
		slide_specs.append({"node": top_grid_bg, "from": Vector2(0, -vp_h)})
	if bottom_grid_bg:
		slide_specs.append({"node": bottom_grid_bg, "from": Vector2(0, vp_h)})
	for s in slide_specs:
		s["origin"] = s.node.position
		s.node.position = s.origin + s.from

	# 附盘节点在 visible=true 之前设好起始偏移，避免闪烁
	if is_instance_valid(board_orchestrator):
		var extra := board_orchestrator.setup_intro_nodes(vp_h)
		for entry in extra.get("slides", []):
			slide_specs.append({"node": entry["node"], "origin": entry["target"],
				"from": Vector2.ZERO})
		for n in extra.get("fades", []):
			fade_targets.append(n)

	for n in slide_nodes:
		n.visible = true
	visible = true

	var tw_a := create_tween()
	tw_a.set_parallel(true)
	for s in slide_specs:
		tw_a.tween_property(s.node, "position", s.origin, INTRO_SLIDE_DURATION) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	await tw_a.finished

	if not fade_targets.is_empty():
		var tw_b := create_tween()
		tw_b.set_parallel(true)
		for n in fade_targets:
			tw_b.tween_property(n, "modulate:a", 1.0, INTRO_FADE_DURATION) \
				.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		await tw_b.finished

	await hand_view.draw_initial_with_anim(INTRO_DRAW_INTERVAL)

	if is_instance_valid(blocker):
		blocker.queue_free()
	set_process_input(true)
