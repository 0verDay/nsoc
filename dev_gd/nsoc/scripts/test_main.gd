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
var _action_order_bar: ActionOrderBar = null

# PVP：各对手已装备的装备实例字典（本端镜像，仅用于详情面板展示，不参与战斗结算）。
# key = player_id，value = Array[EquipmentInstance]
# 1v1 中只有一个对手 pid；1v3 中 3 个攻方 / 1 个守方各自独立。
var _remote_equip_insts: Dictionary = {}   # { pid: Array[EquipmentInstance] }

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

	if Game.is_pvp:
		# ── PVP 路径：bootstrap_pvp 已由 PvpLobby 调用，不走 PVE bootstrap ──
		_inject_pvp_level_data()
	else:
		# ── PVE 路径 ─────────────────────────────────────────────────────
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
	var settings_cfg: Dictionary = {
		"create_trigger_button": false,
		"exit_action": Callable(self, "_on_exit_to_menu"),
		# PVE + PVP 均提供投降功能；面板高度自动适配（含投降按钮时 490px，不含时 400px）
		"surrender_action": Callable(self, "_on_pvp_surrender"),
	}
	settings_panel.setup(self, settings_cfg)
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

	var orchestrator_main_ui: Dictionary
	var orchestrator_resolver = null
	if Game.is_pvp and Game.pvp_match_type == "1v3":
		# 1v3：用 BoardLayoutResolver 计算布局，动态映射 slot_id → UI 节点
		var resolver := BoardLayoutResolver.new()
		var layout: Array = []
		if Game.level_data.has("pvp_slot_layout"):
			var raw = Game.level_data["pvp_slot_layout"]
			if typeof(raw) == TYPE_ARRAY:
				layout = raw
		if layout.is_empty():
			layout = _build_default_1v3_layout()
		resolver.resolve(Game.local_player_id, layout)
		orchestrator_resolver = resolver
		orchestrator_main_ui = {}
		# 本端玩家盘 → bottom grid
		if resolver.local_slot_id != "":
			orchestrator_main_ui[resolver.local_slot_id] = {
				"grid": bottom_grid,
				"bg": $BottomGridBg,
				"hero_panel": $LeftSidePnl/PHpPnl,
			}
		# 主对手盘 → top grid
		if resolver.top_slot_id != "":
			orchestrator_main_ui[resolver.top_slot_id] = {
				"grid": top_grid,
				"bg": $TopGridBg,
				"hero_panel": $EnemyHpPnl,
			}
	else:
		orchestrator_main_ui = {
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
		}

	board_orchestrator.setup({
		"parent": self,
		"cell_scene": cell_scene,
		"detail_panel": detail_panel,
		"on_cell_created": Callable(self, "_wire_cell"),
		"main_center_x": BOARD_SHIFT,
		"side_gap_x": BOARD_HALF_W * 2.0 + BOARD_CENTER_GAP,
		"main_ui": orchestrator_main_ui,
		"resolver": orchestrator_resolver,
	})
	board_orchestrator.boot()
	if Game.is_pvp:
		_setup_pvp_slots()
		Net.message_received.connect(_on_pvp_message)
	if hero_action_bar != null:
		hero_action_bar._refresh_all()
	# boot 后把主敌盘 slot 注入 enemy_side_panels 作数据源
	# 1v3：主对手盘 id 由 resolver 提供；PVE/1v1：固定 "enemy_main"
	var enemy_main_id: String = "enemy_main"
	if Game.is_pvp and Game.pvp_match_type == "1v3" and board_orchestrator._resolver != null:
		enemy_main_id = board_orchestrator._resolver.top_slot_id
	var enemy_main_slot: BoardSlot = Game.registry.get_by_id(enemy_main_id) if Game.registry != null else null
	if enemy_main_slot == null and Game.registry != null:
		# 兜底：取第一个非本端盘
		for s in Game.registry.slots:
			if s.owner_player_id != Game.local_player_id:
				enemy_main_slot = s
				break
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
		return ["", [], -1, []]
	return [hero.name_full, hero.all_ability_ids(), hero.max_health, _collect_equip_descs()]

# 玩家当前已装备的描述字符串列表。格式：【装备名】效果1；效果2（剩余耐久：N）
func _collect_equip_descs() -> Array:
	if not has_node("/root/Equipments"):
		return []
	var out: Array = []
	for inst in Equipments.all():
		if inst == null or inst.card_data == null:
			continue
		var card: CardEquipment = inst.card_data
		var parts: Array = []
		for eff in card.effects:
			var desc: String = Effects.get_description(String(eff))
			if desc != "":
				parts.append(desc)
		if card.once_per_turn:
			parts.append("每回合一次")
		var desc_str: String = "；".join(parts) if parts.size() > 0 else "无效果"
		out.append("【%s】%s（剩余耐久：%d）" % [inst.display_name(), desc_str, inst.durability_left])
	return out

# 对手已装备装备的描述字符串列表（由 _remote_equip_insts 镜像字典生成）。
# pid 为空时聚合所有对手的装备列表（1v1 兼容）；非空时只取指定对手。
func _collect_remote_equip_descs(pid: String = "") -> Array:
	var out: Array = []
	var insts_to_check: Array = []
	if pid != "":
		insts_to_check = _remote_equip_insts.get(pid, [])
	else:
		for arr in _remote_equip_insts.values():
			insts_to_check.append_array(arr)
	for inst in insts_to_check:
		if inst == null or inst.card_data == null:
			continue
		var card: CardEquipment = inst.card_data
		var parts: Array = []
		for eff in card.effects:
			var desc: String = Effects.get_description(String(eff))
			if desc != "":
				parts.append(desc)
		if card.once_per_turn:
			parts.append("每回合一次")
		var desc_str: String = "；".join(parts) if parts.size() > 0 else "无效果"
		out.append("【%s】%s（剩余耐久：%d）" % [inst.display_name(), desc_str, inst.durability_left])
	return out

# ── 信号连接 ─────────────────────────────────────────────────────────
func _wire_signals() -> void:
	# 主玩家盘 / 主敌盘 hero 各自连信号到对应 UI 标签
	# 注意：HeroState 属于 Game autoload，场景切换后仍存活。
	# 必须用命名方法（非 lambda），Godot 4 才会在本节点 free 时自动断开连接。
	var p_hero: HeroState = Game.player_hero()
	if p_hero != null:
		p_hero.health_changed.connect(_on_player_health_changed)
		p_hero.died.connect(_on_player_hero_died)
	# 主对手英雄：1v3 用 resolver.top_slot_id 找对应 slot；1v1/PVE 用 enemy_main_hero()
	var e_hero: HeroState = null
	if Game.is_pvp and Game.pvp_match_type == "1v3" and is_instance_valid(board_orchestrator) \
			and board_orchestrator._resolver != null:
		var top_slot: BoardSlot = Game.registry.get_by_id(board_orchestrator._resolver.top_slot_id) \
			if Game.registry != null else null
		if top_slot != null:
			e_hero = top_slot.hero
	else:
		e_hero = Game.enemy_main_hero()
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

	# PVP：场景装配完成后立即更新回合归属按钮
	if Game.is_pvp:
		_update_pvp_turn_ui()

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
	# PVP 1v3：胜负已由 board_slot._on_hero_died → pvp_end_game 广播，此处只更新本端 UI
	if Game.is_pvp and Game.pvp_match_type == "1v3":
		# board_slot 已发 game/end，无需再发；直接显示胜负画面
		_show_game_over(is_enemy)
		return
	# PVP 1v1：通知服务器战斗结束（房间将被销毁，对手也会收到 game/end）
	if Game.is_pvp and Game.pvp_room_id != "":
		Net.send_to_room("game/end", Game.pvp_room_id, {
			"winner_id": Game.local_player_id if is_enemy else _pvp_opponent_id(),
			"reason": "hero_dead",
		})
	_show_game_over(is_enemy)

# 投降：对自家英雄执行 damage_hero(100, "triggered") → 走标准阵亡流程
# → 自动触发 _on_player_hero_died → _on_hero_died(false) → 显示失败画面
# PVP 模式：还会发 game/end 给对手（对手收到后按 winner_id 显示胜利画面）。
# PVE 模式：同一阵亡流程，但不发网络消息。
func _on_pvp_surrender() -> void:
	if _game_over_shown:
		return
	if Game.registry == null:
		return
	var slots: Array = Game.registry.by_role(BoardSlot.ROLE_MAIN_PLAYER)
	if slots.is_empty():
		return
	var p_slot: BoardSlot = slots[0]
	p_slot.damage_hero(100, "triggered")

# 战役胜利目标达成（与敌方英雄死亡同语义：玩家胜利）
func _on_objective_completed() -> void:
	end_turn_btn.disabled = true
	end_turn_btn.text = "胜利"
	_show_game_over(true)

var _game_over_shown: bool = false

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

# ── 回合 ─────────────────────────────────────────────────────────────
func _on_end_turn_pressed() -> void:
	if Game.is_pvp:
		if not Game.pvp_is_my_turn():
			return
		end_turn_btn.disabled = true
		end_turn_btn.text = "行动中"
		# 跑己方 slot 的单位行动
		if Game.pvp_match_type == "1v3":
			var my_slot: BoardSlot = Game.registry.by_owner(Game.local_player_id) if Game.registry != null else null
			if my_slot != null:
				await Game.turn.run_pvp_phase_for_slot(my_slot.id)
		else:
			await Game.turn.run_pvp_phase(TurnSystem.PLAYER)
		# 本玩家结束回合：自己费用 +1
		var my_mana := Game.get_mana(Game.local_player_id)
		if my_mana != null:
			my_mana.start_new_turn()
		HeroAbilities.reset_turn_usage()
		Equipments.reset_turn_usage()
		# 广播给所有人（含自己 echo；_handle_pvp_message 过滤 from==local）
		Net.send_to_room("action/end_turn", Game.pvp_room_id, {
			"player_id":   Game.local_player_id,
			"turn_number": Game.turn.turn_number,
		}, "all")
		if Game.pvp_match_type == "1v3":
			Game.pvp_advance_turn_skip_dead()
		else:
			Game.pvp_advance_turn()
		if Game.is_round_complete():
			Game.turn.turn_number += 1
		_update_pvp_turn_ui()
		return

	# ── PVE 路径 ──────────────────────────────────────────────────────
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
	# F5 / F9 = 战斗状态快照存读档（PVP 序列化原型期开发键）
	if event is InputEventKey and event.is_pressed() and not event.ctrl_pressed:
		if event.keycode == KEY_F5:
			print("SnapshotIO.save_to_file -> ", SnapshotIO.save_to_file(), " (", SnapshotIO.SAVE_PATH, ")")
			return
		if event.keycode == KEY_F9:
			print("SnapshotIO.load_from_file -> ", SnapshotIO.load_from_file())
			return

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
		# 控制器尚未就绪（场景切换 / 异步 boot 期间）直接忽略
		if not is_instance_valid(detail_panel):
			return
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
			if is_instance_valid(side_panels) and side_panels.has_open_panel():
				if side_panels.is_panel_hit(p): return
				if deck_btn != null and deck_btn.get_global_rect().has_point(p): return
				if grave_btn != null and grave_btn.get_global_rect().has_point(p): return
				if banished_btn != null and banished_btn.get_global_rect().has_point(p): return
				side_panels.close_current()
			if is_instance_valid(enemy_side_panels) and enemy_side_panels.has_open_panel():
				if enemy_side_panels.is_panel_hit(p): return
				if enemy_grave_btn != null and enemy_grave_btn.get_global_rect().has_point(p): return
				if enemy_banished_btn != null and enemy_banished_btn.get_global_rect().has_point(p): return
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
	# PVP：退出战斗时断开网络连接，避免残留消息进入主菜单
	if Game.is_pvp and has_node("/root/Net"):
		Net.disconnect_from_server()
		Game.is_pvp = false
		Game.pvp_room_id = ""
		Game.pvp_action_order = []

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

	# 行动顺序指示器（1v3 专用，PVE/1v1 不显示）
	_action_order_bar = ActionOrderBar.new()
	_action_order_bar.name = "ActionOrderBar"
	_action_order_bar.setup(self)

	# LeftSidePnl 接受装备拖入
	for pnl in [$LeftSidePnl, $LeftSidePnl/PHpPnl]:
		pnl.set_drag_forwarding(
			Callable(),
			Callable(self, "_left_side_pnl_can_drop"),
			Callable(self, "_left_side_pnl_drop"))

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
				hero.name_full, hero.all_ability_ids(), hero.max_health,
				_collect_remote_equip_descs())
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

# ── PVP 专属辅助 ─────────────────────────────────────────────────────

# bootstrap_pvp 调用前向 Game.level_data 注入 PVP 用的虚拟棋盘元数据。
# BoardOrchestrator.boot() 读 level_data.boards，此函数让它拿到正确的双盘结构。
func _inject_pvp_level_data() -> void:
	if Game.pvp_match_type == "1v3":
		_inject_1v3_level_data()
	else:
		_inject_1v1_level_data()

func _inject_1v1_level_data() -> void:
	var local_pid: String = Game.local_player_id
	var opponent_pid: String = _find_opponent_pid(local_pid)
	var local_spec: Dictionary = Game.hero_specs.get(local_pid, _pvp_default_hero_spec())
	var opp_spec: Dictionary   = Game.hero_specs.get(opponent_pid, _pvp_default_hero_spec())
	Game.level_data = {
		"boards": {
			"player_main": {
				"faction": 0, "role": "main_player", "slot_index": 0,
				"hero": local_spec,
				"initial_units": [], "spawners": [], "spell_casters": [],
			},
			"enemy_main": {
				"faction": 1, "role": "main_enemy", "slot_index": 1,
				"hero": opp_spec,
				"initial_units": [], "spawners": [], "spell_casters": [],
			},
		},
	}

# 1v3：按 slot_layout（来自 bootstrap_pvp 写入的 level_data.pvp_slot_layout）构建 boards 字典。
# slot_layout 格式：[{ slot_id, owner_pid, team_id, slot_index }]（服务器 game/start 下发）
func _inject_1v3_level_data() -> void:
	var layout: Array = []
	if Game.level_data.has("pvp_slot_layout"):
		var raw = Game.level_data["pvp_slot_layout"]
		if typeof(raw) == TYPE_ARRAY:
			layout = raw

	# 无服务器下发时，按 pvp_action_order 自动推断（本地测试用）
	if layout.is_empty():
		layout = _build_default_1v3_layout()

	var boards: Dictionary = {}
	for entry in layout:
		var slot_id: String = String(entry.get("slot_id", ""))
		var owner_pid: String = String(entry.get("owner_pid", ""))
		var tid: String = String(entry.get("team_id", ""))
		var sidx: int = int(entry.get("slot_index", 0))
		if slot_id == "":
			continue
		var hero_spec: Dictionary = Game.hero_specs.get(owner_pid, _pvp_default_hero_spec())
		# 本端自己的盘 → faction=0（PLAYER），其余 → faction=1（ENEMY）
		var faction: int = 0 if owner_pid == Game.local_player_id else 1
		var role: String = "main_player" if owner_pid == Game.local_player_id else "main_enemy"
		boards[slot_id] = {
			"faction": faction, "role": role, "slot_index": sidx,
			"team_id": tid, "owner_player_id": owner_pid,
			"hero": hero_spec,
			"initial_units": [], "spawners": [], "spell_casters": [],
		}
	Game.level_data = {"boards": boards, "pvp_slot_layout": layout}

# 本地测试用：无服务器时按 pvp_action_order 自动生成 1v3 的 slot_layout。
# 第 0 号 = defender，1-3 号 = attacker。
func _build_default_1v3_layout() -> Array:
	var order: Array = Game.pvp_action_order
	var layout: Array = []
	for i in range(order.size()):
		var pid: String = String(order[i])
		var tid: String = "defender" if i == 0 else "attacker"
		layout.append({
			"slot_id": "slot_" + pid,
			"owner_pid": pid,
			"team_id": tid,
			"slot_index": i,
		})
	return layout

# boot() 完成后把 owner_player_id 注入两个主盘。
# PlayController / TurnSystem 通过 Game.deck_of_slot / mana_of_slot 反查该玩家的牌库费用。
func _setup_pvp_slots() -> void:
	if Game.registry == null:
		return
	if Game.pvp_match_type == "1v3":
		_setup_pvp_slots_1v3()
	else:
		_setup_pvp_slots_1v1()

func _setup_pvp_slots_1v1() -> void:
	var local_pid: String  = Game.local_player_id
	var opponent_pid: String = _find_opponent_pid(local_pid)
	var p_slot: BoardSlot = Game.registry.get_by_id("player_main")
	if p_slot != null:
		p_slot.owner_player_id = local_pid
	var e_slot: BoardSlot = Game.registry.get_by_id("enemy_main")
	if e_slot != null:
		e_slot.owner_player_id = opponent_pid

# 1v3：按 level_data.pvp_slot_layout 为每个 slot 写入 owner_player_id / team_id。
func _setup_pvp_slots_1v3() -> void:
	var layout: Array = []
	if Game.level_data.has("pvp_slot_layout"):
		var raw = Game.level_data["pvp_slot_layout"]
		if typeof(raw) == TYPE_ARRAY:
			layout = raw
	for entry in layout:
		var slot_id: String = String(entry.get("slot_id", ""))
		var owner_pid: String = String(entry.get("owner_pid", ""))
		var tid: String = String(entry.get("team_id", ""))
		var slot: BoardSlot = Game.registry.get_by_id(slot_id)
		if slot != null:
			slot.owner_player_id = owner_pid
			slot.team_id = tid

func _find_opponent_pid(local_pid: String) -> String:
	for pid in Game.decks.keys():
		if pid != local_pid:
			return pid
	return ""

func _pvp_opponent_id() -> String:
	for id in Game.pvp_action_order:
		if id != Game.local_player_id:
			return id
	return ""

# 远端英雄技能激活：仅做必要的状态镜像（视觉一致性 / 锁步关键状态）。
# 不调用 HeroAbilities.activate，因为对端不该执行对手英雄的逻辑（如 hand_view 操作自家手牌）。
func _handle_remote_activate_hero(payload: Dictionary) -> void:
	var ability_id: String = String(payload.get("ability_id", ""))
	match ability_id:
		"restart":
			# 把对手弃的手牌名加入 ROLE_MAIN_ENEMY slot.graveyard（视觉同步）
			# 对端 enemy_side_panels 监听 _slot.pile_changed，自动刷新墓地面板
			if Game.registry == null:
				return
			var enemy_slots: Array = Game.registry.by_role(BoardSlot.ROLE_MAIN_ENEMY)
			if enemy_slots.is_empty():
				return
			var e_slot: BoardSlot = enemy_slots[0]
			var discarded = payload.get("discarded", [])
			if typeof(discarded) != TYPE_ARRAY:
				return
			for n in discarded:
				var c = Game.get_card(String(n))
				if c != null:
					e_slot.graveyard.append(c)
			e_slot.pile_changed.emit("graveyard")
		"test_discard":
			# 把对手弃的单张加入 ROLE_MAIN_ENEMY slot.graveyard（视觉同步）
			if Game.registry == null:
				return
			var enemy_slots: Array = Game.registry.by_role(BoardSlot.ROLE_MAIN_ENEMY)
			if enemy_slots.is_empty():
				return
			var e_slot: BoardSlot = enemy_slots[0]
			var discarded = payload.get("discarded", [])
			if typeof(discarded) != TYPE_ARRAY:
				return
			for n in discarded:
				var name_str: String = String(n)
				if name_str == "":
					continue
				var c = Game.get_card(name_str)
				if c != null:
					e_slot.graveyard.append(c)
			e_slot.pile_changed.emit("graveyard")
		_:
			# 其他 ability 暂不实现（PVP 默认英雄=A，仅 restart 会被触发）
			push_warning("PVP: unhandled ability_id=" + ability_id)

static func _pvp_default_hero_spec() -> Dictionary:
	# 兜底：读本地选中英雄（bootstrap_pvp 的 hero_specs 未命中时使用）
	var hero_key: String = DeckStorage.get_selected_hero()
	var spec := DataLoader.get_hero(hero_key)
	if spec.is_empty():
		# hero.json 解析失败时硬兜底为 A（科因）
		spec = DataLoader.get_hero("A")
	if spec.is_empty():
		return {"hp": 30, "name_short": "科因", "name_full": "往日之王：科因", "abilities": ["restart"]}
	var ab_raw = spec.get("abilities", [])
	var ab: Array = []
	if typeof(ab_raw) == TYPE_ARRAY:
		for v in ab_raw:
			ab.append(String(v))
	var display: String = String(spec.get("display_name", hero_key))
	return {
		"hp":         int(spec.get("max_health", 30)),
		"name_short": String(spec.get("battle_name", display)),
		"name_full":  display,
		"abilities":  ab,
	}

# ── PVP 网络消息处理 ─────────────────────────────────────────────────

# 所有来自 Net 的消息（战斗中）都经此分发。
# 仅处理与战斗逻辑相关的 action/* 类型；大厅/房间消息已在 pvp_lobby 处理。
# ── PVP 消息隊列（保证順序处理，避免 await 並發導致格子状态错乱）───────────
var _pvp_msg_queue: Array = []
var _pvp_processing: bool = false

func _on_pvp_message(msg: Dictionary) -> void:
	_pvp_msg_queue.append(msg)
	if not _pvp_processing:
		_drain_pvp_queue()

func _drain_pvp_queue() -> void:
	_pvp_processing = true
	while _pvp_msg_queue.size() > 0:
		var msg: Dictionary = _pvp_msg_queue.pop_front()
		await _handle_pvp_message(msg)
	_pvp_processing = false

func _handle_pvp_message(msg: Dictionary) -> void:
	var type: String = String(msg.get("type", ""))
	var from: String = String(msg.get("from", ""))
	var payload = msg.get("payload", {})
	if typeof(payload) != TYPE_DICTIONARY:
		payload = {}
	if from == Game.local_player_id:
		return
	match type:
		"action/play_card":
			await play_controller.handle_remote_play_card(payload)
		"action/play_equip":
			# 记录对手装备实例（仅用于详情面板展示，不加入 Equipments 单例）。
			var card_name: String = String(payload.get("card_name", ""))
			if card_name != "" and from != "":
				var card = Game.get_card(card_name)
				if card is CardEquipment:
					if not _remote_equip_insts.has(from):
						_remote_equip_insts[from] = []
					_remote_equip_insts[from].append(EquipmentInstance.new(card))
		"action/activate_equip":
			# 对手激活装备 → 本端镜像执行 effect（仅白名单 effect 实际发包）
			await play_controller.handle_remote_activate_equip(payload)
			# 同步扣减对手装备耐久（破损则从镜像字典移除）
			var eq_name: String = String(payload.get("equip_name", ""))
			if eq_name != "" and from != "":
				var insts: Array = _remote_equip_insts.get(from, [])
				for i in range(insts.size() - 1, -1, -1):
					var inst: EquipmentInstance = insts[i]
					if inst.display_name() == eq_name:
						inst.durability_left -= 1
						if inst.durability_left <= 0:
							insts.remove_at(i)
						break
		"action/end_turn":
			await _on_remote_end_turn(payload)
		"action/cross_board":
			# 1v3 守方拥有者广播的跨盘目标盘选择；远端入队，等待 _on_remote_end_turn
			# 回放守方阶段时由 TurnSystem.consume_cross_choice 消费。
			Game.turn.enqueue_cross_choice(payload)
		"action/activate_hero":
			# 对手激活英雄技能 → 本端镜像必要状态变更
			_handle_remote_activate_hero(payload)
		"disconnect/notify":
			# 对手断线：走标准阵亡流程（damage_hero 100 → hero.died → 胜负结算）
			# 1v3 / 1v1 统一按 dead_player_id 路由到对应 slot
			var nick: String = String(payload.get("nickname", "对手"))
			var disc_uuid: String = String(payload.get("dead_player_id",
				String(payload.get("uuid", ""))))   # 向后兼容旧字段名
			if disc_uuid == Game.local_player_id:
				pass
			elif _game_over_shown:
				pass
			else:
				end_turn_btn.text = nick + " 已断线"
				end_turn_btn.disabled = true
				if Game.registry != null:
					var dead_slot: BoardSlot = Game.registry.by_owner(disc_uuid)
					if dead_slot != null:
						dead_slot.damage_hero(100, "triggered")
					else:
						# 向后兼容：1v1 旧逻辑按 ROLE_MAIN_ENEMY 查
						var enemy_slots: Array = Game.registry.by_role(BoardSlot.ROLE_MAIN_ENEMY)
						if enemy_slots.size() > 0:
							enemy_slots[0].damage_hero(100, "triggered")
		"game/end":
			# 本端已显示胜负画面 → 跳过
			if not _game_over_shown:
				var winning_team: String = String(payload.get("winning_team", ""))
				var winner_id: String    = String(payload.get("winner_id", ""))  # 1v1 旧字段兼容
				var local_win: bool = false
				if winning_team != "":
					# 1v3：按队伍判断
					local_win = (Game.team_of_player(Game.local_player_id) == winning_team)
				elif winner_id != "":
					# 1v1 旧路径
					local_win = (winner_id == Game.local_player_id)
				else:
					_on_exit_to_menu()
					return
				_show_game_over(local_win)

# 收到对手结束回合消息：运行 TurnSystem（锁步）→ 推进回合 → 恢复按钮
func _on_remote_end_turn(payload: Dictionary) -> void:
	if Game.pvp_is_my_turn():
		push_warning("_on_remote_end_turn: called on my turn (idx=%d), skipping" % Game.pvp_active_idx)
		return
	end_turn_btn.disabled = true
	end_turn_btn.text = "结算中"
	# 确定本消息发送方的 slot
	var sender_pid: String = String(payload.get("player_id", ""))
	if Game.pvp_match_type == "1v3":
		var sender_slot: BoardSlot = Game.registry.by_owner(sender_pid) if (Game.registry != null and sender_pid != "") else null
		if sender_slot != null:
			await Game.turn.run_pvp_phase_for_slot(sender_slot.id)
		else:
			await play_controller.handle_remote_end_turn()
		# 对端玩家费用 +1
		var opp_mana: ManaSystem = Game.get_mana(sender_pid if sender_pid != "" else Game.pvp_active_player_id())
		if opp_mana != null:
			opp_mana.start_new_turn()
		Game.pvp_advance_turn_skip_dead()
		if Game.is_round_complete():
			Game.turn.turn_number += 1
	else:
		await play_controller.handle_remote_end_turn()
		Game.pvp_advance_turn()
	_update_pvp_turn_ui()

# 更新"结束回合"按钮状态与标签，反映当前回合归属。
# 同时强制刷新英雄技能按钮（turn_reset / mana_changed 信号在 pvp_advance_turn 之前触发，
# 不主动刷新则按钮仍停留在前一回合的状态）。
func _update_pvp_turn_ui() -> void:
	var my_turn: bool = Game.pvp_is_my_turn()
	end_turn_btn.disabled = not my_turn
	if my_turn:
		end_turn_btn.text = "结束回合"
	else:
		end_turn_btn.text = "等待对方"
	if is_instance_valid(hero_action_bar):
		hero_action_bar._refresh_ability_button()
	if my_turn:
		end_turn_btn.text = "结束回合"
	else:
		end_turn_btn.text = "等待对方"
	# 强制刷新英雄技能按钮，避免回合切换后按钮残留旧状态
	if is_instance_valid(hero_action_bar):
		hero_action_bar._refresh_ability_button()
	# 刷新行动顺序指示器
	if is_instance_valid(_action_order_bar):
		_action_order_bar.refresh()
