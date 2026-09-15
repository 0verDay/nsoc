extends Control

# 战斗场景脚本基类（app 层 · 允许碰场景树）。
#
# main.gd（战役 / 单盘）与 test_main.gd（多人 / 多盘 PVE）共用的"薄装配器"骨架：
# 节点引用、公共成员、控制器装配、棋盘格信号、胜负面板、设置按钮、牌库/墓地按钮、
# 英雄技能上下文与左侧面板拖放判定。
#
# 之所以提出来：这两个文件原本各有一份**逐字相同**的实现（18 个函数 / 约 200 行），
# 改一处忘一处就是真 bug（重构文档.md §7 阶段 2「main ⟷ test_main 合一」）。
# 子类只保留各自独有的装配差异（战役 AI / PVP 槽位与消息 / 载入流程 / 输入路由）。
#
# 约定：基类只承载"两边完全一致"的部分；任何需要分支的行为一律做成子类重写的方法
# （如 _get_player_hero_long_press_args / _on_hero_died / _on_exit_to_menu），
# 由基类调用、子类实现。


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
const FrontRowSelectorScript       = preload("res://scripts/ui/front_row_selector.gd")
const HeroPanelDragControllerScript = preload("res://scripts/ui/hero_panel_drag_controller.gd")
const TargetSelectorScript          = preload("res://scripts/ui/target_selector_controller.gd")
const HandPickerScript              = preload("res://scripts/ui/hand_picker_controller.gd")

var hand_view: HandView
var detail_panel: DetailPanelController
var side_panels: SidePanelManager
var enemy_side_panels: EnemySidePanelManager
var settings_panel: SettingsPanelController
var play_controller: PlayController
var combat: CombatSystem
var _game_over_shown: bool = false
var board_orchestrator: BoardOrchestrator
var front_row_selector: Node
var hero_drag_ctrl: Node

# 玩家英雄行动条（技能 + 装备按钮）
var hero_action_bar: HeroActionBar

# ── 布局常量 ─────────────────────────────────────────────────────────
const BOARD_SHIFT: float = -160.0    # 主棋盘中心相对视口中心的水平偏移
const BOARD_HALF_W: float = 230.0    # 棋盘半宽（宽=460）
const BOARD_CENTER_GAP: float = 40.0 # 上下棋盘间距

# 原敌方区域节点集合（BoardOrchestrator 附盘动画时整体平移）
var _main_enemy_nodes: Array = []

# ── 子类必须重写的钩子 ───────────────────────────────────────────────
# 基类的公共骨架会调用这些方法，但两边实现不同（战役 / PVP 分支），
# 因此这里只声明空实现；GDScript 要求被 self 调用的方法在声明类里存在。
# 子类一律覆盖它们（main.gd / test_main.gd 各有一份）。

func _on_hero_died(_is_enemy: bool) -> void:
	pass

func _on_exit_to_menu() -> void:
	pass

func _on_enemy_hero_panel_gui_input(_event: InputEvent) -> void:
	pass

func _exit_tree() -> void:
	AiManager.clear()

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

func _on_mana_changed(current: int, maximum: int) -> void:
	mana_label.text = str(current) + "/" + str(maximum)

func _on_player_health_changed(v: int) -> void:
	player_health_label.text = str(v)
func _on_enemy_health_changed(v: int) -> void:
	enemy_health_label.text = str(v)
func _on_player_hero_died() -> void:
	_on_hero_died(false)
func _on_enemy_hero_died() -> void:
	_on_hero_died(true)

func _show_game_over(victory: bool) -> void:
	_game_over_shown = true
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

func _on_cell_long_press_requested(payload) -> void:
	detail_panel.start_long_press(payload)

func _on_cell_card_dropped(cell, data) -> void:
	play_controller.handle_drop(cell, data)

func _on_cell_cleared(cell) -> void:
	var slot: BoardSlot = Game.registry.get_by_id(cell.slot_id) if Game.registry != null else null
	if slot != null and slot.spawners != null:
		slot.spawners.refresh_phantoms(slot.board, Callable(Game, "get_card"))

func _collect_main_enemy_nodes() -> void:
	_main_enemy_nodes.clear()
	if is_instance_valid($TopGridBg):
		_main_enemy_nodes.append($TopGridBg)
	if is_instance_valid($EnemyHpPnl):
		_main_enemy_nodes.append($EnemyHpPnl)
	for name_str in ["EnemyGraveBtn", "EnemyBanishedBtn"]:
		var n = get_node_or_null(name_str)
		if n: _main_enemy_nodes.append(n)

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

func _create_enemy_pile_buttons() -> void:
	const BTN_H: float = 40.0
	const TOTAL_W: float = BOARD_HALF_W * 2.0
	const TOP_OFFSET: float = 15.0

	# 敌方血量面板：横向充满主棋盘宽度，居中于 BOARD_SHIFT
	var hp_pnl: Panel = $EnemyHpPnl
	hp_pnl.anchor_left = 0.5; hp_pnl.anchor_right = 0.5
	hp_pnl.offset_left  = BOARD_SHIFT - TOTAL_W / 2.0
	hp_pnl.offset_right = BOARD_SHIFT + TOTAL_W / 2.0
	hp_pnl.offset_top = TOP_OFFSET; hp_pnl.offset_bottom = TOP_OFFSET + BTN_H
	hp_pnl.pivot_offset = Vector2(TOTAL_W / 2.0, BTN_H / 2.0)

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

func _make_hero_ability_ctx() -> EffectContext:
	var ctx: EffectContext = Game.make_effect_context_with_selectors()
	ctx.target_cell = null
	ctx.hand_view   = hand_view
	ctx.hero        = Game.player_hero()
	return ctx

func _left_side_pnl_can_drop(_pos: Vector2, data) -> bool:
	if play_controller == null:
		return false
	return play_controller.can_equip(data)

func _left_side_pnl_drop(_pos: Vector2, data) -> void:
	if play_controller == null:
		return
	play_controller.handle_equip(data)
