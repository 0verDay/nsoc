extends Control

# 薄装配器。
# 责任仅限于：
#   1. 取得 scene 节点引用并交给各子模块
#   2. 连接子系统信号（UI 刷新 / 事件路由）
#   3. 处理输入路由（点击外部关闭面板）
#
# 业务全部委托给 GameContext (autoload "Game") + Effects 注册表 + UI 控制器。

@onready var hand_container = $BottomBar/HandClip/HandContainer
@onready var enemy_health_label = $EnemyHpPnl/EnemyHealthLabel
@onready var player_health_label = $LeftSidePnl/PHpPnl/PlayerHealthLabel
@onready var mana_label = $BottomBar/ManaPnl/ManaLabel
@onready var end_turn_btn = $BottomBar/EndTurnBtn
@onready var top_grid = $TopGridBg/TopGrid
@onready var bottom_grid = $BottomGridBg/BottomGrid
@onready var hero_name_lbl = $LeftSidePnl/HeroNameLbl

# 玩家"牌库 / 墓地 / 除外"按钮（动态创建，置于玩家半场底部，与敌方按钮上下对称）
var deck_btn: Button
var grave_btn: Button
var banished_btn: Button

var cell_scene := preload("res://scenes/Cell.tscn")
var hand_card_scene := preload("res://scenes/HandCard.tscn")
const FrontRowSelectorScript = preload("res://scripts/ui/front_row_selector.gd")

var hand_view: HandView
var detail_panel: DetailPanelController
var side_panels: SidePanelManager
var enemy_side_panels: EnemySidePanelManager
var settings_panel: SettingsPanelController
var play_controller: PlayController
var combat: CombatSystem
var board_orchestrator: BoardOrchestrator
var front_row_selector: Node

# 敌方"墓地 / 除外"按钮（动态创建，挂在 EnemyHpPnl 左右）
var enemy_grave_btn: Button
var enemy_banished_btn: Button

# 玩家英雄面板按钮（动态创建，挂在 LeftSidePnl 内）
var hero_action_bar: HeroActionBar

func _ready() -> void:
	# 整个根 Control 先隐藏，等入场动画把节点移到屏外起点后再显示，
	# 避免 anchor 解析帧期间渲染出完整 UI（"闪一下"）。
	visible = false
	await _apply_editor_window_scale()
	Game.bootstrap()

	_apply_styles()

	# UI 控制器（detail_panel 必须在 _init_grid 之前，因 cell 信号会连到它）
	hand_view = HandView.new(); hand_view.name = "HandView"; add_child(hand_view)
	hand_view.setup(hand_container, hand_card_scene, self)

	detail_panel = DetailPanelController.new(); detail_panel.name = "DetailPanel"; add_child(detail_panel)
	detail_panel.setup(self, hand_card_scene)

	side_panels = SidePanelManager.new(); side_panels.name = "SidePanels"; add_child(side_panels)
	side_panels.setup(self)

	enemy_side_panels = EnemySidePanelManager.new(); enemy_side_panels.name = "EnemySidePanels"; add_child(enemy_side_panels)
	enemy_side_panels.setup(self, null)

	_create_enemy_pile_buttons()
	_create_player_pile_buttons()
	_create_hero_action_bar()

	settings_panel = SettingsPanelController.new(); settings_panel.name = "SettingsPanel"; add_child(settings_panel)
	settings_panel.setup(self, {"exit_action": Callable(self, "_on_exit_to_menu")})

	# 业务控制器
	play_controller = PlayController.new(); play_controller.name = "PlayController"; add_child(play_controller)
	play_controller.setup(self, cell_scene)
	Game.play = play_controller

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
		"main_center_x": 0.0,
		"side_gap_x": 500.0,
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
	# HeroActionBar 内部自检；boot 后再刷一次确保 player_hero 就绪。
	if hero_action_bar != null:
		hero_action_bar._refresh_all()
	var enemy_main_slot: BoardSlot = Game.registry.get_by_id("enemy_main") if Game.registry != null else null
	if enemy_main_slot != null:
		enemy_side_panels.set_slot(enemy_main_slot)

	_wire_signals()

	# 初始 phantom 渲染 + UI 同步
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

	# 设置面板 + 详情面板需要显示在侧边栏之上
	for clip in side_panels.get_clip_nodes():
		clip.move_to_front()
	for clip in enemy_side_panels.get_clip_nodes():
		clip.move_to_front()
	detail_panel.get_clip().move_to_front()

	# 入场动画：滑入 → 渐显 → 按序摸牌。摸牌动画末尾才允许玩家操作。
	_play_intro_animation()
	_install_controllers()

# ---------------- 控制器装配 ----------------
func _install_controllers() -> void:
	front_row_selector = FrontRowSelectorScript.new()
	front_row_selector.name = "FrontRowSelector"
	add_child(front_row_selector)
	front_row_selector.setup(self, combat)

# ---------------- 信号连接 ----------------
func _wire_signals() -> void:
	var p_hero: HeroState = Game.player_hero()
	if p_hero != null:
		p_hero.health_changed.connect(_on_player_health_changed)
		p_hero.died.connect(_on_player_hero_died)
	var e_hero: HeroState = Game.enemy_main_hero()
	if e_hero != null:
		e_hero.health_changed.connect(_on_enemy_health_changed)
		e_hero.died.connect(_on_enemy_hero_died)
	Game.mana.mana_changed.connect(_on_mana_changed)

	end_turn_btn.pressed.connect(_on_end_turn_pressed)
	deck_btn.pressed.connect(func(): side_panels.toggle("deck"))
	grave_btn.pressed.connect(func(): side_panels.toggle("grave"))
	banished_btn.pressed.connect(func(): side_panels.toggle("banished"))
	enemy_grave_btn.pressed.connect(func(): enemy_side_panels.toggle("enemy_grave"))
	enemy_banished_btn.pressed.connect(func(): enemy_side_panels.toggle("enemy_banished"))

	# 侧栏长按 → 详情面板
	side_panels.long_press_requested.connect(detail_panel.start_long_press)
	side_panels.long_press_canceled.connect(detail_panel.cancel_long_press)
	enemy_side_panels.long_press_requested.connect(detail_panel.start_long_press)
	enemy_side_panels.long_press_canceled.connect(detail_panel.cancel_long_press)
	# 附盘 EnemySidePanelManager 的长按转发到 detail_panel
	if is_instance_valid(board_orchestrator):
		board_orchestrator.side_panel_long_press_requested.connect(detail_panel.start_long_press)
		board_orchestrator.side_panel_long_press_canceled.connect(detail_panel.cancel_long_press)

	# 手牌长按 → 详情面板
	hand_view.hand_card_long_press_requested.connect(detail_panel.start_long_press)
	hand_view.hand_card_long_press_canceled.connect(detail_panel.cancel_long_press)

	# 出牌后补手牌
	play_controller.hand_consumed.connect(hand_view.draw_into_slot)

	# HeroActionBar 自连 turn / mana / abilities / equipments；此处不再重复连。

	# 装备拖拽高亮：手牌拖装备时英雄面板显示蓝色描边。
	hand_view.equip_drag_started.connect(hero_action_bar.show_equip_drag_highlight)
	hand_view.equip_drag_ended.connect(hero_action_bar.hide_equip_drag_highlight)

	# 确保 LeftSidePnl 在节点顺序中最末（同 z_index 时后画的在上），
	# 使其在视觉和 drop 检测上始终优先于棋盘格子。
	$LeftSidePnl.move_to_front()

# ---------------- UI 刷新槽 ----------------
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

# ---------------- 退出到菜单 ----------------
# 过渡动画：白覆盖渐入 → 切到黑 → 切场景。下一个场景 _ready 接力 黑→透明，
# 形成 白→黑→白 三段过渡。
const EXIT_FADE_TO_WHITE: float = 0.25   # 渐入白
const EXIT_HOLD_WHITE: float = 0.05      # 白色短暂停顿
const EXIT_FADE_TO_BLACK: float = 0.25   # 白→黑
const EXIT_DELAY: float = 1.0            # 总等待时间，覆盖战斗协程安全退出
func _on_exit_to_menu() -> void:
	if combat != null:
		combat.abort()
	if Game.turn != null:
		Game.turn.is_running = false

	var overlay := ColorRect.new()
	overlay.color = Color(1.0, 1.0, 1.0, 0.0)
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	overlay.z_index = 500
	add_child(overlay)
	var tw := create_tween()
	tw.tween_property(overlay, "color:a", 1.0, EXIT_FADE_TO_WHITE)
	tw.tween_interval(EXIT_HOLD_WHITE)
	tw.tween_property(overlay, "color", Color(0.0, 0.0, 0.0, 1.0), EXIT_FADE_TO_BLACK)

	# 标记下一个场景接力播放 黑→透明
	Game.pending_fade_in_from_black = true

	await get_tree().create_timer(EXIT_DELAY).timeout
	get_tree().change_scene_to_file("res://scenes/MainMenu.tscn")

func _show_game_over(victory: bool) -> void:
	var overlay := ColorRect.new()
	overlay.color = Color(0, 0, 0, 0.6)
	overlay.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(overlay)
	var lbl := Label.new()
	lbl.text = "胜利" if victory else "失败"
	lbl.add_theme_font_size_override("font_size", 96)
	lbl.add_theme_color_override("font_color", Color.WHITE if victory else Color("#ff6b6b"))
	lbl.set_anchors_preset(Control.PRESET_CENTER, false)
	lbl.offset_left = -200
	lbl.offset_top = -80
	lbl.offset_right = 200
	lbl.offset_bottom = 80
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	overlay.add_child(lbl)

# ---------------- 回合 ----------------
func _on_end_turn_pressed() -> void:
	end_turn_btn.disabled = true
	end_turn_btn.text = "行动中"
	await Game.turn.run()
	Game.mana.start_new_turn()
	HeroAbilities.reset_turn_usage()
	Equipments.reset_turn_usage()
	end_turn_btn.disabled = false
	end_turn_btn.text = "结束回合"

# ---------------- 初始化辅助 ----------------
# 阶段 4：主棋盘 + 附盘装配统一交由 BoardOrchestrator（_ready 中已 boot）。

func _wire_cell(cell: Node) -> void:
	cell.long_press_requested.connect(_on_cell_long_press_requested)
	cell.long_press_canceled.connect(detail_panel.cancel_long_press)
	cell.card_dropped.connect(_on_cell_card_dropped)
	cell.cleared.connect(_on_cell_cleared)

func _on_cell_long_press_requested(payload) -> void:
	detail_panel.start_long_press(payload)

func _on_cell_card_dropped(cell, data) -> void:
	play_controller.handle_drop(cell, data)

func _on_cell_cleared(cell) -> void:
	var slot: BoardSlot = Game.registry.get_by_id(cell.slot_id) if Game.registry != null else null
	if slot != null and slot.spawners != null:
		slot.spawners.refresh_phantoms(slot.board, Callable(Game, "get_card"))

# ---------------- 输入路由 ----------------
func _input(event) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if not event.pressed:
			detail_panel.cancel_long_press()
			detail_panel.hide_panel()
			_animate_hero_panel_release()
			_animate_enemy_hero_panel_release()
		else:
			var p := get_global_mouse_position()
			if side_panels.has_open_panel():
				if side_panels.is_panel_hit(p):
					return
				if deck_btn.get_global_rect().has_point(p): return
				if grave_btn.get_global_rect().has_point(p): return
				if banished_btn.get_global_rect().has_point(p): return
				side_panels.close_current()
			if enemy_side_panels.has_open_panel():
				if enemy_side_panels.is_panel_hit(p):
					return
				if enemy_grave_btn.get_global_rect().has_point(p): return
				if enemy_banished_btn.get_global_rect().has_point(p): return
				enemy_side_panels.close_current()
			# 附盘墓地/除外面板
			if is_instance_valid(board_orchestrator):
				if board_orchestrator.any_side_panel_open():
					if board_orchestrator.is_side_panel_hit(p): return
					if board_orchestrator.is_pile_button_hit(p): return
					board_orchestrator.close_all_side_panels()
				elif board_orchestrator.is_pile_button_hit(p):
					return

# ---------------- 样式 ----------------
# 仅在编辑器/调试运行时缩放：
# 优先尝试改窗口尺寸；若处于嵌入模式则改 root viewport 的 content_scale_factor 0.5，
# 视觉等效"半分辨率"，不依赖窗口能否 resize。
func _apply_editor_window_scale() -> void:
	if not OS.has_feature("editor"):
		return
	var win := get_window()
	if win == null:
		return
	var vp_w: int = int(ProjectSettings.get_setting("display/window/size/viewport_width"))
	var vp_h: int = int(ProjectSettings.get_setting("display/window/size/viewport_height"))
	var half: Vector2i = Vector2i(vp_w / 2, vp_h / 2)

	# 1) 尝试改物理窗口大小（浮动窗口模式有效）。
	win.size = half
	await get_tree().process_frame
	# 2) 若 size 没变（被嵌入限制），退而用内容缩放（嵌入/导出后均生效，视觉同小屏）。
	if win.size != half:
		get_tree().root.content_scale_factor = 0.5
		return

	# 浮动窗口模式：居中到主屏。
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
	hand_container.add_theme_constant_override("separation", 50)
	$LeftSidePnl/PHpPnl.add_theme_stylebox_override("panel", ThemeFactory.panel(Color.WHITE, Color("#ff6b6b"), 2, 12, true))
	$BottomBar/ManaPnl.add_theme_stylebox_override("panel", ThemeFactory.panel(Color.WHITE, Color("#339af0"), 2, 12, true))

	var styles := ThemeFactory.primary_button_styles()
	ThemeFactory.apply_button_styles(end_turn_btn, styles)
	# deck/grave/banished 三按钮在 _create_player_pile_buttons 内自行应用样式。

# 创建敌方"墓地 / 除外"两个按钮，挂在 EnemyHpPnl 左右。
# 高 40，宽度撑到棋盘左/右边沿：墓地左边对齐棋盘左、除外右边对齐棋盘右；
# 内侧仍距画面中心 GAP+EnemyHpPnl 半宽（=50）以避让血条。
func _create_enemy_pile_buttons() -> void:
	const BTN_H: float = 40.0
	const GAP: float = 10.0
	const HP_HALF_W: float = 40.0       # EnemyHpPnl 半宽（offset 见 Main.tscn）
	const BOARD_HALF_W: float = 230.0   # TopGridBg 半宽（见 Main.tscn）

	enemy_grave_btn = Button.new()
	enemy_grave_btn.name = "EnemyGraveBtn"
	enemy_grave_btn.text = "墓地"
	enemy_grave_btn.set_anchors_preset(Control.PRESET_TOP_LEFT, false)
	enemy_grave_btn.anchor_left = 0.5
	enemy_grave_btn.anchor_right = 0.5
	enemy_grave_btn.offset_left = -BOARD_HALF_W
	enemy_grave_btn.offset_right = -HP_HALF_W - GAP
	enemy_grave_btn.offset_top = 15.0
	enemy_grave_btn.offset_bottom = 15.0 + BTN_H
	add_child(enemy_grave_btn)

	enemy_banished_btn = Button.new()
	enemy_banished_btn.name = "EnemyBanishedBtn"
	enemy_banished_btn.text = "除外"
	enemy_banished_btn.set_anchors_preset(Control.PRESET_TOP_LEFT, false)
	enemy_banished_btn.anchor_left = 0.5
	enemy_banished_btn.anchor_right = 0.5
	enemy_banished_btn.offset_left = HP_HALF_W + GAP
	enemy_banished_btn.offset_right = BOARD_HALF_W
	enemy_banished_btn.offset_top = 15.0
	enemy_banished_btn.offset_bottom = 15.0 + BTN_H
	add_child(enemy_banished_btn)

	var btn_styles := ThemeFactory.primary_button_styles()
	ThemeFactory.apply_button_styles(enemy_grave_btn, btn_styles)
	ThemeFactory.apply_button_styles(enemy_banished_btn, btn_styles)

# 创建玩家"牌库 / 墓地 / 除外"三按钮，置于玩家半场底部，与敌方上方两按钮上下对称。
# 三按钮等宽平分棋盘宽度，高度同敌方按钮 (40)。
func _create_player_pile_buttons() -> void:
	const BTN_H: float = 40.0
	const GAP: float = 10.0
	const BOARD_HALF_W: float = 230.0   # BottomGridBg 半宽
	const BTN_W: float = (BOARD_HALF_W * 2.0 - GAP * 2.0) / 3.0   # ≈ 146.67
	const BOTTOM_OFFSET: float = 15.0   # 距画面底部，与敌方按钮顶部 15.0 对称

	deck_btn = Button.new()
	deck_btn.name = "DeckBtn"
	deck_btn.text = "牌库"
	grave_btn = Button.new()
	grave_btn.name = "GraveBtn"
	grave_btn.text = "墓地"
	banished_btn = Button.new()
	banished_btn.name = "BanishedBtn"
	banished_btn.text = "除外"

	# 视觉顺序：墓地 | 牌库 | 除外
	var btns: Array[Button] = [grave_btn, deck_btn, banished_btn]
	var x_start: float = -BOARD_HALF_W
	for i in btns.size():
		var b: Button = btns[i]
		b.set_anchors_preset(Control.PRESET_TOP_LEFT, false)
		b.anchor_left = 0.5
		b.anchor_right = 0.5
		b.anchor_top = 1.0
		b.anchor_bottom = 1.0
		b.offset_left = x_start + (BTN_W + GAP) * float(i)
		b.offset_right = b.offset_left + BTN_W
		b.offset_top = -BOTTOM_OFFSET - BTN_H
		b.offset_bottom = -BOTTOM_OFFSET
		b.add_theme_font_size_override("font_size", 22)
		add_child(b)

	var pile_styles := ThemeFactory.primary_button_styles()
	ThemeFactory.apply_button_styles(deck_btn, pile_styles)
	ThemeFactory.apply_button_styles(grave_btn, pile_styles)
	ThemeFactory.apply_button_styles(banished_btn, pile_styles)

# 创建玩家英雄行动条（技能 + 装备按钮）。挂在 LeftSidePnl 底部居中。
func _create_hero_action_bar() -> void:
	hero_action_bar = HeroActionBar.new()
	hero_action_bar.name = "HeroActionBar"
	hero_action_bar.setup($LeftSidePnl, Callable(self, "_make_hero_ability_ctx"), detail_panel, hand_card_scene)

	# LeftSidePnl 长按监听（按钮区由按钮自身消费事件，不会冒泡到 panel）。
	$LeftSidePnl.gui_input.connect(_on_player_hero_panel_gui_input)
	# EnemyHpPnl 长按监听
	$EnemyHpPnl.gui_input.connect(_on_enemy_hero_panel_gui_input)

	# LeftSidePnl 接受装备拖入：转给 PlayController.handle_equip。
	# 子 PHpPnl 会拦截鼠标事件，需同步挂 forwarding 才能在英雄头像上释放。
	for pnl in [$LeftSidePnl, $LeftSidePnl/PHpPnl]:
		pnl.set_drag_forwarding(
			Callable(),
			Callable(self, "_left_side_pnl_can_drop"),
			Callable(self, "_left_side_pnl_drop"))

func _make_hero_ability_ctx() -> Dictionary:
	return {"main": self, "hand_view": hand_view, "hero": Game.player_hero()}

# LeftSidePnl 拖入裁决：仅装备类。play_controller 此时可能尚未创建（_ready 顺序）。
func _left_side_pnl_can_drop(_pos: Vector2, data) -> bool:
	if play_controller == null:
		return false
	return play_controller.can_equip(data)

func _left_side_pnl_drop(_pos: Vector2, data) -> void:
	if play_controller == null:
		return
	play_controller.handle_equip(data)

# 玩家英雄面板长按 → 详情面板显示英雄名字。
func _on_player_hero_panel_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var hero: HeroState = Game.player_hero()
		if hero != null:
			detail_panel.start_long_press_hero(
				hero.name_full, hero.ability_id(), hero.max_health)
		_animate_hero_panel_press()

# 敌方英雄面板长按 → 详情面板显示敌人英雄名字。
func _on_enemy_hero_panel_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var hero: HeroState = Game.enemy_main_hero()
		if hero != null:
			detail_panel.start_long_press_hero(
				hero.name_full, hero.ability_id(), hero.max_health)
		_animate_enemy_hero_panel_press()

# 复用 hand_card / cell 长按按压的放大动画（0.1s 缩放到 1.08）。
func _animate_hero_panel_press() -> void:
	var pnl: Control = $LeftSidePnl
	var tween := pnl.create_tween()
	tween.tween_property(pnl, "scale", Vector2(1.08, 1.08), 0.1)

func _animate_hero_panel_release() -> void:
	var pnl: Control = $LeftSidePnl
	if pnl.scale == Vector2.ONE:
		return
	var tween := pnl.create_tween()
	tween.tween_property(pnl, "scale", Vector2.ONE, 0.1)

func _animate_enemy_hero_panel_press() -> void:
	var pnl: Control = $EnemyHpPnl
	pnl.pivot_offset = pnl.size / 2.0
	var tween := pnl.create_tween()
	tween.tween_property(pnl, "scale", Vector2(1.08, 1.08), 0.1)

func _animate_enemy_hero_panel_release() -> void:
	var pnl: Control = $EnemyHpPnl
	if pnl.scale == Vector2.ONE:
		return
	pnl.pivot_offset = pnl.size / 2.0
	var tween := pnl.create_tween()
	tween.tween_property(pnl, "scale", Vector2.ONE, 0.1)

# 英雄能力按钮逻辑已迁移至 HeroActionBar。


# ---------------- 入场动画 ----------------

const INTRO_SLIDE_DURATION: float = 0.5
const INTRO_FADE_DURATION: float = 0.3
const INTRO_DRAW_INTERVAL: float = 0.15
const INTRO_LAYOUT_SETTLE_FRAMES: int = 3   # 等几帧让 anchor 布局稳定，再读 position


# 入场动画总编排：
#   阶段 A：四个主面板从屏外滑入（并行 0.5s）
#     - 左上"选项"按钮 ←  从左
#     - BottomBar         ←  从右
#     - LeftSidePnl       ←  从下
#     - TopGridBg         ←  从上
#     - BottomGridBg      ←  从下
#   阶段 B：上下方按钮 + 敌方血量渐显（并行 0.3s）
#     - EnemyHpPnl
#     - 敌方墓地 / 除外 按钮
#     - 玩家牌堆 / 墓地 / 除外 按钮
#   阶段 C：手牌按序摸 5 张（每张间隔 0.15s，从右侧顶出）
# 全程锁输入：
#   - set_process_input(false) 屏蔽全局 _input 回调
#   - 全屏透明 InputBlocker (Control + MOUSE_FILTER_STOP) 吞掉所有 UI 点击
func _play_intro_animation() -> void:
	# 0. 上锁：全屏拦截 + 关 _input
	set_process_input(false)
	var blocker := Control.new()
	blocker.name = "IntroInputBlocker"
	blocker.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	blocker.mouse_filter = Control.MOUSE_FILTER_STOP
	# z_index 高于 detail_panel(200) / drag preview(300)，确保不被任何节点穿透。
	blocker.z_index = 1000
	add_child(blocker)

	# 1. 收集需要参与动画的节点引用，记录原位 + 切到隐藏起点。
	var settings_btn: Button = settings_panel.get_trigger_button() if settings_panel else null
	var bottom_bar: Panel = $BottomBar
	var left_side: Panel = $LeftSidePnl
	var top_grid_bg: Panel = $TopGridBg
	var bottom_grid_bg: Panel = $BottomGridBg
	var enemy_hp_pnl: Panel = $EnemyHpPnl

	# 立刻把所有参与动画的节点设 visible=false / modulate.a=0，
	# 防止 anchor 解析期间已渲染出完整 UI 一帧（"闪一下"）。
	# visible=false 仍保留布局参与，anchor 仍会算 size/position。
	var slide_nodes: Array = []
	for n in [settings_btn, bottom_bar, left_side, top_grid_bg, bottom_grid_bg]:
		if n != null:
			slide_nodes.append(n)
			n.visible = false

	# 渐显组：先全部 modulate.a = 0，阶段 B 一起 tween 到 1
	var fade_targets: Array = []
	if enemy_hp_pnl: fade_targets.append(enemy_hp_pnl)
	if enemy_grave_btn: fade_targets.append(enemy_grave_btn)
	if enemy_banished_btn: fade_targets.append(enemy_banished_btn)
	if deck_btn: fade_targets.append(deck_btn)
	if grave_btn: fade_targets.append(grave_btn)
	if banished_btn: fade_targets.append(banished_btn)
	for n in fade_targets:
		n.modulate.a = 0.0

	# 多等几帧让 anchor 布局完全稳定，避免 size 为 0 导致 from 计算错。
	for _i in INTRO_LAYOUT_SETTLE_FRAMES:
		await get_tree().process_frame

	# 滑入组：记录原位 → 把节点平移到屏外起点。
	var slide_specs: Array = []
	var vp_w: float = float(ProjectSettings.get_setting("display/window/size/viewport_width", 1920))
	var vp_h: float = float(ProjectSettings.get_setting("display/window/size/viewport_height", 1080))
	if settings_btn:
		slide_specs.append({"node": settings_btn, "from": Vector2(-settings_btn.size.x - 40, 0)})
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
	# 位移到屏外后才显示，避免任何一帧出现在原位
	for n in slide_nodes:
		n.visible = true
	# 整个根此前在 _ready 内置 visible=false，现在节点都已就位，可显示。
	visible = true

	# 阶段 A：四个面板并行滑回原位（0.5s）
	var tween_a := create_tween()
	tween_a.set_parallel(true)
	for s in slide_specs:
		tween_a.tween_property(s.node, "position", s.origin, INTRO_SLIDE_DURATION).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	await tween_a.finished

	# 阶段 B：渐显（0.3s）
	if not fade_targets.is_empty():
		var tween_b := create_tween()
		tween_b.set_parallel(true)
		for n in fade_targets:
			tween_b.tween_property(n, "modulate:a", 1.0, INTRO_FADE_DURATION).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		await tween_b.finished

	# 阶段 C：按序摸 5 张（每张间隔 INTRO_DRAW_INTERVAL）
	await hand_view.draw_initial_with_anim(INTRO_DRAW_INTERVAL)

	# 解锁
	if is_instance_valid(blocker):
		blocker.queue_free()
	set_process_input(true)
