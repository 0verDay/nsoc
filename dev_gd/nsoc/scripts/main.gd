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
@onready var player_health_label = $BottomBar/PHpPnl/PlayerHealthLabel
@onready var mana_label = $BottomBar/ManaPnl/ManaLabel
@onready var end_turn_btn = $BottomBar/EndTurnBtn
@onready var deck_btn = $BottomBar/SideButtonsBox/DeckBtn
@onready var grave_btn = $BottomBar/SideButtonsBox/GraveBtn
@onready var banished_btn = $BottomBar/SideButtonsBox/BanishedBtn
@onready var top_grid = $TopGridBg/TopGrid
@onready var bottom_grid = $BottomGridBg/BottomGrid

var cell_scene := preload("res://scenes/Cell.tscn")
var hand_card_scene := preload("res://scenes/HandCard.tscn")

var hand_view: HandView
var detail_panel: DetailPanelController
var side_panels: SidePanelManager
var settings_panel: SettingsPanelController
var play_controller: PlayController
var combat: CombatSystem

func _ready() -> void:
	Game.bootstrap()

	_apply_styles()

	# UI 控制器（detail_panel 必须在 _init_grid 之前，因 cell 信号会连到它）
	hand_view = HandView.new(); hand_view.name = "HandView"; add_child(hand_view)
	hand_view.setup(hand_container, hand_card_scene)

	detail_panel = DetailPanelController.new(); detail_panel.name = "DetailPanel"; add_child(detail_panel)
	detail_panel.setup(self, hand_card_scene)

	side_panels = SidePanelManager.new(); side_panels.name = "SidePanels"; add_child(side_panels)
	side_panels.setup(self)

	settings_panel = SettingsPanelController.new(); settings_panel.name = "SettingsPanel"; add_child(settings_panel)
	settings_panel.setup(self)

	# 业务控制器
	play_controller = PlayController.new(); play_controller.name = "PlayController"; add_child(play_controller)
	play_controller.setup(self, cell_scene)
	Game.play = play_controller

	combat = CombatSystem.new(); combat.name = "Combat"; add_child(combat)
	combat.setup(self, cell_scene, play_controller, Callable(self, "_resolve_hero_panel"))

	Game.turn.setup(Game.board, combat, Game.spawners, Callable(Game, "get_card"))

	_init_grid()
	_init_units()

	_wire_signals()

	Game.spawners.refresh_phantoms(Game.board, Callable(Game, "get_card"))
	hand_view.ensure_min_hand_size()

	# 触发一次 UI 同步
	_on_hero_health_changed(false, Game.hero.player_health)
	_on_hero_health_changed(true, Game.hero.enemy_health)
	_on_mana_changed(Game.mana.current, Game.mana.maximum)

	# 设置面板 + 详情面板需要显示在侧边栏之上
	for clip in side_panels.get_clip_nodes():
		clip.move_to_front()
	detail_panel.get_clip().move_to_front()

# ---------------- 信号连接 ----------------
func _wire_signals() -> void:
	Game.hero.health_changed.connect(_on_hero_health_changed)
	Game.hero.hero_died.connect(_on_hero_died)
	Game.mana.mana_changed.connect(_on_mana_changed)

	end_turn_btn.pressed.connect(_on_end_turn_pressed)
	deck_btn.pressed.connect(func(): side_panels.toggle("deck"))
	grave_btn.pressed.connect(func(): side_panels.toggle("grave"))
	banished_btn.pressed.connect(func(): side_panels.toggle("banished"))

	# 侧栏长按 → 详情面板
	side_panels.long_press_requested.connect(detail_panel.start_long_press)
	side_panels.long_press_canceled.connect(detail_panel.cancel_long_press)

	# 手牌长按 → 详情面板
	hand_view.hand_card_long_press_requested.connect(detail_panel.start_long_press)
	hand_view.hand_card_long_press_canceled.connect(detail_panel.cancel_long_press)

	# 出牌后补手牌
	play_controller.hand_consumed.connect(hand_view.ensure_min_hand_size)

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
		else:
			if side_panels.has_open_panel():
				var p := get_global_mouse_position()
				if side_panels.is_panel_hit(p):
					return
				if deck_btn.get_global_rect().has_point(p): return
				if grave_btn.get_global_rect().has_point(p): return
				if banished_btn.get_global_rect().has_point(p): return
				side_panels.close_current()

# ---------------- 样式 ----------------
func _apply_styles() -> void:
	$Bg.add_theme_stylebox_override("panel", ThemeFactory.panel(Color.WHITE, Color("#e1e8ed"), 1, 0))
	$EnemyHpPnl.add_theme_stylebox_override("panel", ThemeFactory.panel(Color.WHITE, Color("#ff6b6b"), 2, 20, true))
	var grid_bg_style := ThemeFactory.panel(Color("#f0f3f5"), Color("#e1e8ed"), 1, 16)
	$TopGridBg.add_theme_stylebox_override("panel", grid_bg_style)
	$BottomGridBg.add_theme_stylebox_override("panel", grid_bg_style)
	$BottomBar.add_theme_stylebox_override("panel", ThemeFactory.panel(Color(0.94, 0.95, 0.96, 0.85), Color(1, 1, 1, 0.6), 1, 20))
	hand_container.add_theme_constant_override("separation", 50)
	$BottomBar/PHpPnl.add_theme_stylebox_override("panel", ThemeFactory.panel(Color.WHITE, Color("#ff6b6b"), 2, 12, true))
	$BottomBar/ManaPnl.add_theme_stylebox_override("panel", ThemeFactory.panel(Color.WHITE, Color("#339af0"), 2, 12, true))

	var styles := ThemeFactory.primary_button_styles()
	ThemeFactory.apply_button_styles(end_turn_btn, styles)
	ThemeFactory.apply_button_styles(deck_btn, styles)
	ThemeFactory.apply_button_styles(grave_btn, styles)
	ThemeFactory.apply_button_styles(banished_btn, styles)
