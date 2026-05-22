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

var hand_view: HandView
var detail_panel: DetailPanelController
var side_panels: SidePanelManager
var enemy_side_panels: EnemySidePanelManager
var settings_panel: SettingsPanelController
var play_controller: PlayController
var combat: CombatSystem

# 敌方"墓地 / 除外"按钮（动态创建，挂在 EnemyHpPnl 左右）
var enemy_grave_btn: Button
var enemy_banished_btn: Button

# 玩家英雄面板按钮（动态创建，挂在 LeftSidePnl 内）
var hero_ability_btn: Button

func _ready() -> void:
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
	enemy_side_panels.setup(self)

	_create_enemy_pile_buttons()
	_create_player_pile_buttons()
	_create_hero_ability_button()

	settings_panel = SettingsPanelController.new(); settings_panel.name = "SettingsPanel"; add_child(settings_panel)
	settings_panel.setup(self)

	# 业务控制器
	play_controller = PlayController.new(); play_controller.name = "PlayController"; add_child(play_controller)
	play_controller.setup(self, cell_scene)
	Game.play = play_controller

	combat = CombatSystem.new(); combat.name = "Combat"; add_child(combat)
	combat.setup(self, cell_scene, play_controller, Callable(self, "_resolve_hero_panel"))
	Game.combat = combat

	Game.turn.setup(Game.board, combat, Game.spawners, Callable(Game, "get_card"))

	_init_grid()
	_init_units()

	_wire_signals()

	Game.spawners.refresh_phantoms(Game.board, Callable(Game, "get_card"))
	# 触发一次 UI 同步（数据先就位）
	_on_hero_health_changed(false, Game.hero.player_health)
	_on_hero_health_changed(true, Game.hero.enemy_health)
	_on_mana_changed(Game.mana.current, Game.mana.maximum)
	hero_name_lbl.text = Game.hero.player_name

	# 设置面板 + 详情面板需要显示在侧边栏之上
	for clip in side_panels.get_clip_nodes():
		clip.move_to_front()
	for clip in enemy_side_panels.get_clip_nodes():
		clip.move_to_front()
	detail_panel.get_clip().move_to_front()

	# 入场动画：滑入 → 渐显 → 按序摸牌。摸牌动画末尾才允许玩家操作。
	_play_intro_animation()

# ---------------- 信号连接 ----------------
func _wire_signals() -> void:
	Game.hero.health_changed.connect(_on_hero_health_changed)
	Game.hero.hero_died.connect(_on_hero_died)
	Game.mana.mana_changed.connect(_on_mana_changed)

	end_turn_btn.pressed.connect(_on_end_turn_pressed)
	deck_btn.pressed.connect(func(): side_panels.toggle("deck"))
	grave_btn.pressed.connect(func(): side_panels.toggle("grave"))
	banished_btn.pressed.connect(func(): side_panels.toggle("banished"))
	enemy_grave_btn.pressed.connect(func(): enemy_side_panels.toggle("enemy_grave"))
	enemy_banished_btn.pressed.connect(func(): enemy_side_panels.toggle("enemy_banished"))
	hero_ability_btn.pressed.connect(_on_hero_ability_pressed)

	# 侧栏长按 → 详情面板
	side_panels.long_press_requested.connect(detail_panel.start_long_press)
	side_panels.long_press_canceled.connect(detail_panel.cancel_long_press)
	enemy_side_panels.long_press_requested.connect(detail_panel.start_long_press)
	enemy_side_panels.long_press_canceled.connect(detail_panel.cancel_long_press)

	# 手牌长按 → 详情面板
	hand_view.hand_card_long_press_requested.connect(detail_panel.start_long_press)
	hand_view.hand_card_long_press_canceled.connect(detail_panel.cancel_long_press)

	# 出牌后补手牌
	play_controller.hand_consumed.connect(hand_view.draw_into_slot)

	# 英雄技能按钮的可用性：受回合状态/费用/每回合次数 影响。
	Game.turn.turn_started.connect(_refresh_hero_ability_button)
	Game.turn.turn_ended.connect(_refresh_hero_ability_button)
	Game.mana.mana_changed.connect(func(_c, _m): _refresh_hero_ability_button())
	HeroAbilities.ability_used.connect(func(_id): _refresh_hero_ability_button())
	HeroAbilities.turn_reset.connect(_refresh_hero_ability_button)

# ---------------- UI 刷新槽 ----------------
func _on_hero_health_changed(is_enemy: bool, new_value: int) -> void:
	if is_enemy:
		enemy_health_label.text = str(new_value)
	else:
		player_health_label.text = str(new_value)

func _on_mana_changed(current: int, maximum: int) -> void:
	mana_label.text = str(current) + "/" + str(maximum)

func _on_hero_died(is_enemy: bool) -> void:
	end_turn_btn.disabled = true
	end_turn_btn.text = "胜利" if is_enemy else "失败"
	_show_game_over(is_enemy)

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
	end_turn_btn.disabled = false
	end_turn_btn.text = "结束回合"

# ---------------- 初始化辅助 ----------------
func _init_grid() -> void:
	var split: int = int(BoardModel.ROWS / 2)
	for r in range(BoardModel.ROWS):
		for c in range(BoardModel.COLS):
			var cell = cell_scene.instantiate()
			cell.row = r
			cell.col = c
			Game.board.register_cell(cell)
			if r < split:
				top_grid.add_child(cell)
			else:
				bottom_grid.add_child(cell)
			# 解耦：cell 用信号通知主控
			cell.long_press_requested.connect(_on_cell_long_press_requested)
			cell.long_press_canceled.connect(detail_panel.cancel_long_press)
			cell.card_dropped.connect(_on_cell_card_dropped)
			cell.cleared.connect(_on_cell_cleared)

func _init_units() -> void:
	Game.board.populate_initial_units(Game.initial_units, Callable(Game, "get_card"))

func _on_cell_long_press_requested(payload) -> void:
	detail_panel.start_long_press(payload)

func _on_cell_card_dropped(cell, data) -> void:
	play_controller.handle_drop(cell, data)

func _on_cell_cleared(_cell) -> void:
	Game.spawners.refresh_phantoms(Game.board, Callable(Game, "get_card"))

func _resolve_hero_panel(is_enemy: bool) -> Panel:
	return $EnemyHpPnl if is_enemy else $BottomBar/PHpPnl

# ---------------- 输入路由 ----------------
func _input(event) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if not event.pressed:
			detail_panel.cancel_long_press()
			detail_panel.hide_panel()
			_animate_hero_panel_release()
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

	var btns: Array[Button] = [deck_btn, grave_btn, banished_btn]
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

# 创建玩家英雄面板按钮，挂在 LeftSidePnl 底部居中。
# 复用 ThemeFactory.primary_button_styles 与项目蓝色主按钮风格一致。
func _create_hero_ability_button() -> void:
	const BTN_W: float = 240.0
	const BTN_H: float = 56.0
	const BOTTOM_MARGIN: float = 30.0

	hero_ability_btn = Button.new()
	hero_ability_btn.name = "HeroAbilityBtn"
	hero_ability_btn.text = _get_player_ability_label()
	# 锚定到 LeftSidePnl 底部水平居中。
	hero_ability_btn.anchor_left = 0.5
	hero_ability_btn.anchor_right = 0.5
	hero_ability_btn.anchor_top = 1.0
	hero_ability_btn.anchor_bottom = 1.0
	hero_ability_btn.offset_left = -BTN_W * 0.5
	hero_ability_btn.offset_right = BTN_W * 0.5
	hero_ability_btn.offset_top = -BTN_H - BOTTOM_MARGIN
	hero_ability_btn.offset_bottom = -BOTTOM_MARGIN
	hero_ability_btn.add_theme_font_size_override("font_size", 22)
	hero_ability_btn.add_theme_color_override("font_color", Color.WHITE)
	hero_ability_btn.add_theme_color_override("font_hover_color", Color.WHITE)
	hero_ability_btn.add_theme_color_override("font_pressed_color", Color.WHITE)
	$LeftSidePnl.add_child(hero_ability_btn)

	ThemeFactory.apply_button_styles(hero_ability_btn, ThemeFactory.primary_button_styles())

	# 初始刷新一次按钮状态（费用够用 + 非运行中 + 未用过 → 可用）。
	_refresh_hero_ability_button()

	# LeftSidePnl 长按监听（按钮区由按钮自身消费事件，不会冒泡到 panel）。
	$LeftSidePnl.gui_input.connect(_on_player_hero_panel_gui_input)

# 玩家英雄面板长按 → 详情面板显示英雄名字。
func _on_player_hero_panel_gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		# 详情面板用完整名（player_full_name），与英雄面板上的 battle_name 区分
		detail_panel.start_long_press_hero(Game.hero.player_full_name, Game.hero.player_ability_id(), Game.hero.player_max_health)
		_animate_hero_panel_press()

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

# 英雄能力按钮点击处理。委托给 HeroAbilityRegistry.activate。
func _on_hero_ability_pressed() -> void:
	var ability_id: String = Game.hero.player_ability_id()
	if ability_id == "" or not HeroAbilities.has(ability_id):
		return
	var ctx := {"main": self, "hand_view": hand_view, "hero": Game.hero}
	if not HeroAbilities.can_activate(ability_id, ctx):
		return
	await HeroAbilities.activate(ability_id, ctx)

# 取按钮显示文字：仅技能名，未注册则回退默认。
func _get_player_ability_label() -> String:
	var ability_id: String = Game.hero.player_ability_id()
	if ability_id != "" and HeroAbilities.has(ability_id):
		return HeroAbilities.get_display_name(ability_id)
	return "英雄能力"

# 刷新英雄技能按钮 disabled 状态：回合运行中、费用不足、本回合用过 都置灰。
# 信号源：turn_started / turn_ended / mana_changed / ability_used / turn_reset。
func _refresh_hero_ability_button() -> void:
	if hero_ability_btn == null:
		return
	var ability_id: String = Game.hero.player_ability_id()
	if ability_id == "" or not HeroAbilities.has(ability_id):
		hero_ability_btn.disabled = true
		return
	var ctx := {"main": self, "hand_view": hand_view, "hero": Game.hero}
	hero_ability_btn.disabled = not HeroAbilities.can_activate(ability_id, ctx)


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

	# 滑入组：记录原位 → 把节点平移到屏外起点。
	# 通过 position 偏移实现（不动 anchor / offset）。
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
	# 多等几帧让 anchor 布局完全稳定，避免 size 为 0 导致 from 计算错。
	for _i in INTRO_LAYOUT_SETTLE_FRAMES:
		await get_tree().process_frame
	for s in slide_specs:
		s["origin"] = s.node.position
		s.node.position = s.origin + s.from

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
