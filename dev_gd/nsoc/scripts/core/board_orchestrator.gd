class_name BoardOrchestrator
extends Node

# 关卡棋盘装配编排器（阶段 4）。
#
# 职责：
#   - 根据 Game.level_data["boards"] 的元数据，遍历 enabled=true 的盘并装配
#   - 主棋盘（player_main / enemy_main）的 UI 容器已在场景树（TopGrid/BottomGrid 等），
#     由调用方注入 ui_provider 提供这些节点引用
#   - 附盘（ally_left / ally_right / enemy_left / enemy_right）的 UI 容器动态创建（SideBoardUi）
#   - 提供运行时 add_board(id) / remove_board(id)，剧情或 toggle 按钮可调
#
# 不持有 UI 动画细节；附盘滑入/滑出动画在本类内部 _animate_slide_in / _out 实现。
# 阶段 4 起替代了原 SideBoardController（已删除）。
#
# 使用：
#   var orch := BoardOrchestrator.new()
#   add_child(orch)
#   orch.setup({
#       "parent": self,
#       "cell_scene": cell_scene,
#       "detail_panel": detail_panel,
#       "on_cell_created": Callable(self, "_wire_cell"),
#       "main_center_x": BOARD_SHIFT,
#       "side_gap_x": 500.0,
#       "main_ui": {
#           "player_main": {
#               "grid": $BottomGrid, "bg": $BottomGridBg, "hero_panel": $BottomBar/PHpPnl,
#           },
#           "enemy_main": {
#               "grid": $TopGrid, "bg": $TopGridBg, "hero_panel": $EnemyHpPnl,
#           },
#       },
#   })
#   orch.boot()                 # 创建所有 enabled=true 的盘
#   orch.add_board("ally_left") # 运行时增加

signal board_added(slot: BoardSlot)
signal board_removed(slot: BoardSlot)

const SideBoardUiScript = preload("res://scripts/ui/side_board_ui.gd")
const SLIDE_DURATION: float = 0.5
const FADE_DURATION: float  = 0.3
const SLIDE_DISTANCE: float = 800.0

var _parent: Control = null
var _cell_scene: PackedScene = null
var _detail_panel = null
var _on_cell_created: Callable = Callable()
var _main_center_x: float = 0.0
var _side_gap_x: float = 500.0

# 主棋盘 id → {grid, bg, hero_panel}
var _main_ui: Dictionary = {}

# 已创建的 side（附盘）UI 缓存：id → ui dict（来自 SideBoardUi.build）
# 主棋盘不进入此表（其 UI 由场景树持有，不可销毁）
var _side_ui: Dictionary = {}

# 1v3 布局解析器（PVP 时注入；PVE/1v1 为 null）
var _resolver: BoardLayoutResolver = null

# 附盘的"墓地/除外"面板控制器：id → EnemySidePanelManager
# 仅 ENEMY 阵营附盘存在（玩家附盘不需要敌方记录面板）
var _side_panels: Dictionary = {}

# 转发：附盘 EnemySidePanelManager 的 long_press_requested / canceled 由本控制器代理转发，
# 调用方（test_main / main）连接 Orchestrator 的统一信号到 detail_panel。
signal side_panel_long_press_requested(payload)
signal side_panel_long_press_canceled

# 缓存当前已创建的 slot id 集合
var _active: Dictionary = {}

# 退场清理：场景被释放时回收所有 slot（board/spawners/hero/slot 挂在 Game autoload
# 下不会自动 free），避免下次进入时 registry 残留旧引用。
func _exit_tree() -> void:
	_cleanup_all()

func _cleanup_all() -> void:
	if not has_node("/root/Game") or Game.registry == null:
		return
	for slot in Game.registry.slots.duplicate():
		BoardSlotFactory.destroy(slot)
	# 释放附盘面板管理器及其 clip 节点
	for mgr in _side_panels.values():
		if is_instance_valid(mgr):
			for clip in mgr.get_clip_nodes():
				if is_instance_valid(clip):
					clip.queue_free()
			mgr.queue_free()
	_side_panels.clear()
	_side_ui.clear()
	_active.clear()
	# 清空对话队列，防止残留气泡出现在主菜单
	if has_node("/root/Dialogue"):
		Dialogue.clear_queue()
	# 清 Game.turn 残留：旧 combat 节点已 free；信号连接表可能仍指向旧 FrontRowSelector
	if Game.turn != null:
		# 强制结束可能仍在运行的回合（退出时 run() 的协程被中断，is_running 可能残留 true）
		Game.turn.is_running = false
		Game.turn._combat = null
		Game.turn._card_resolver = Callable()
		Game.turn._front_row_resolve = Callable()
		# 断 front_row_action_requested 上所有连接（旧 FrontRowSelector 已 free）
		for conn in Game.turn.front_row_action_requested.get_connections():
			Game.turn.front_row_action_requested.disconnect(conn["callable"])

func setup(deps: Dictionary) -> void:
	_parent           = deps.get("parent")
	_cell_scene       = deps.get("cell_scene")
	_detail_panel     = deps.get("detail_panel")
	_on_cell_created  = deps.get("on_cell_created", Callable())
	_main_center_x    = float(deps.get("main_center_x", 0.0))
	_side_gap_x       = float(deps.get("side_gap_x", 500.0))
	_main_ui          = deps.get("main_ui", {})
	_resolver         = deps.get("resolver", null)

# 启动期：遍历 level_data.boards 创建需要在游戏开始时显示的棋盘。
# 主棋盘（player_main / enemy_main）无条件创建；
# 附盘根据数据内容自动决定：有 initial_units 或 spawners 则在开始时放好，否则不创建。
# boot 期所有棋盘均不走滑入动画（瞬时摆放）。
func boot() -> void:
	if not has_node("/root/Game"):
		return
	# 连接回合开始信号，实现 board_events 局内触发
	if Game.turn != null and not Game.turn.turn_started.is_connected(_on_turn_started):
		Game.turn.turn_started.connect(_on_turn_started)
	# 把 Orchestrator 注入 Events，供 add_board / remove_board action 使用
	if has_node("/root/Events"):
		Events.set_orchestrator(self)
	var boards: Dictionary = Game.level_data.get("boards", {})
	# 决定哪些盘是"主盘"（使用 _main_ui 中已有的 UI 节点）
	# 1v3：local_slot_id → bottom_grid, top_slot_id → top_grid（_main_ui 中已注入）
	# PVE/1v1：player_main / enemy_main
	var ordered_ids: Array = []
	if _resolver != null:
		# 1v3：先装本端盘和主对手盘（使用 scene tree UI），再装其余盘
		if _resolver.local_slot_id != "":
			ordered_ids.append(_resolver.local_slot_id)
		if _resolver.top_slot_id != "":
			ordered_ids.append(_resolver.top_slot_id)
		for extra_id in _resolver.extra_top_ids:
			if extra_id != "":
				ordered_ids.append(extra_id)
		for side_id in _resolver.side_slot_ids:
			if side_id != "":
				ordered_ids.append(side_id)
		# 确保 boards 里所有 id 都进入（容错）
		for id in boards.keys():
			if not id in ordered_ids:
				ordered_ids.append(id)
	else:
		ordered_ids = ["player_main", "enemy_main"]
		for id in boards.keys():
			if id == "player_main" or id == "enemy_main":
				continue
			ordered_ids.append(id)
	for id in ordered_ids:
		if not boards.has(id):
			continue
		var meta: Dictionary = boards[id]
		var is_main: bool = _main_ui.has(id)
		# 附盘：只看 enabled 标志。initial_units/spawners 决定内容，不决定何时创建。
		if not is_main and not bool(meta.get("enabled", false)):
			# 1v3：所有盘都要创建（extra_top_ids / side_slot_ids 无 enabled 标志）
			if _resolver == null:
				continue
			# 1v3 中所有来自 slot_layout 的盘都强制创建
		_create_slot(id, meta, false)

# ── 局内棋盘事件 ──────────────────────────────────────────────────────
# 每回合开始时由 turn_started 信号触发，读取 level_data["board_events"] 执行增减盘。
func _on_turn_started() -> void:
	if not has_node("/root/Game") or Game.turn == null:
		return
	var current_turn: int = Game.turn.turn_number
	var events: Array = Game.level_data.get("board_events", [])
	for ev in events:
		if int(ev.get("turn", -1)) != current_turn:
			continue
		# ── Remove ──────────────────────────────────────────────────────
		# 先同步将 slot 从 Game.registry 移除，确保本回合 _iter_phase_cells 快照
		# 不包含这些棋盘（_on_turn_started 是信号处理，与 _run_phase 并发执行）。
		# 动画和节点清理在之后 await 完成。
		var to_remove: Array = []
		for idx in ev.get("remove", []):
			var board_id: String = _slot_index_to_id(int(idx))
			if board_id == "" or not _active.has(board_id):
				continue
			to_remove.append(board_id)
			# 同步移出注册表
			if Game.registry != null:
				Game.registry.remove(board_id)
		# 再做异步动画 + 节点清理
		for board_id in to_remove:
			if _active.has(board_id):
				await remove_board(board_id)

		# ── Add ─────────────────────────────────────────────────────────
		for idx in ev.get("add", []):
			var board_id: String = _slot_index_to_id(int(idx))
			if board_id != "" and not _active.has(board_id):
				await add_board(board_id)

# slot_index → board id（动态查 level_data，不硬编码）
func _slot_index_to_id(idx: int) -> String:
	if not has_node("/root/Game"):
		return ""
	for board_id in Game.level_data.get("boards", {}).keys():
		var meta: Dictionary = Game.level_data["boards"][board_id]
		if int(meta.get("slot_index", -99)) == idx:
			return board_id
	return ""

# 供 test_main._play_intro_animation 调用：
# 对每个附盘 bg 设置起始位置偏移，返回两组数据：
#   "slides": Array of {node, target}  → 并入主棋盘的 tw_a（位移动画）
#   "fades":  Array of Node            → 并入主棋盘的 tw_b（渐显）
# 调用方在设置好 slide_specs 之后、创建 tween 之前调用本方法。
func setup_intro_nodes(slide_distance: float) -> Dictionary:
	var slides: Array = []
	var fades: Array  = []
	for id in _side_ui.keys():
		var slot: BoardSlot = _active.get(id)
		if slot == null:
			continue
		var ui: Dictionary = _side_ui[id]
		var container: Control = ui.get("container")
		if is_instance_valid(container):
			container.visible = true

		var bg: Panel = ui.get("bg")
		if is_instance_valid(bg):
			# 敌方从上方（负 y）；玩家从下方（正 y）
			var sign_dir: float = -1.0 if slot.faction == BoardSlot.FACTION_ENEMY else 1.0
			var target := bg.position
			# 设起始偏移位置，modulate 保持 1.0（与主棋盘 slide_nodes 行为一致，只位移不淡变）
			bg.position = target + Vector2(0.0, sign_dir * slide_distance)
			slides.append({"node": bg, "target": target})

		# ui_nodes（hp_pnl, grave_btn, banished_btn）并入 fade_targets，tw_b 渐显
		for n in ui.get("ui_nodes", []):
			if is_instance_valid(n):
				n.modulate.a = 0.0
				fades.append(n)

	return {"slides": slides, "fades": fades}

# ── 公开运行时 API ───────────────────────────────────────────────────
func has_board(id: String) -> bool:
	return _active.has(id)

# 运行时添加附盘（含滑入动画）。返回 BoardSlot 引用。
func add_board(id: String) -> BoardSlot:
	if _active.has(id):
		return _active[id]
	var meta: Dictionary = Game.level_data.get("boards", {}).get(id, {})
	if meta.is_empty():
		meta = DataLoader._default_board_meta(id)
	var slot: BoardSlot = _create_slot(id, meta, true)
	# 滑入动画（仅附盘）
	if slot != null and _side_ui.has(id):
		await _animate_slide_in(_side_ui[id], slot.faction)
	return slot

# 运行时移除附盘（含滑出动画）。
func remove_board(id: String) -> void:
	if not _active.has(id):
		return
	var slot: BoardSlot = _active[id]
	if slot.role == BoardSlot.ROLE_MAIN_PLAYER \
			or slot.role == BoardSlot.ROLE_MAIN_ENEMY:
		push_warning("BoardOrchestrator: refuse to remove main slot %s" % id)
		return
	if _side_ui.has(id):
		await _animate_slide_out(_side_ui[id], slot.faction)
	board_removed.emit(slot)
	BoardSlotFactory.destroy(slot)
	# 销毁附盘面板管理器及其 clip 节点（clip 挂在 _parent 下，不随 mgr.queue_free 自动释放）
	if _side_panels.has(id):
		var mgr = _side_panels[id]
		if is_instance_valid(mgr):
			for clip in mgr.get_clip_nodes():
				if is_instance_valid(clip):
					clip.queue_free()
			mgr.queue_free()
		_side_panels.erase(id)
	if _side_ui.has(id):
		var ui: Dictionary = _side_ui[id]
		if ui.has("container") and is_instance_valid(ui["container"]):
			ui["container"].queue_free()
		for n in ui.get("ui_nodes", []):
			if is_instance_valid(n):
				n.queue_free()
		_side_ui.erase(id)
	_active.erase(id)

# 切换：未存在则添加，已存在则移除（test_main 4 个 toggle 按钮直调）。
func toggle(id: String) -> void:
	if _active.has(id):
		await remove_board(id)
	else:
		await add_board(id)

# ── 私有 ─────────────────────────────────────────────────────────────
func _create_slot(id: String, meta: Dictionary, _animate: bool = false) -> BoardSlot:
	var faction: int = int(meta.get("faction", 1))
	var role: int = _parse_role(String(meta.get("role", "enemy")))
	var slot_index: int = int(meta.get("slot_index", -1))
	var team_id: String = String(meta.get("team_id", ""))
	var owner_player_id: String = String(meta.get("owner_player_id", ""))

	var grid: Node = null
	var bg: Panel = null
	var hero_panel: Panel = null
	var side_ui_dict: Dictionary = {}

	if _main_ui.has(id):
		# 主棋盘：UI 容器已在场景树
		var ui_ref: Dictionary = _main_ui[id]
		grid = ui_ref.get("grid")
		bg = ui_ref.get("bg")
		hero_panel = ui_ref.get("hero_panel")
	else:
		# 附盘：动态构造 UI
		var center_x: float = _side_center_x_for(id)
		# 1v3：用 team_id 判断上/下位置：与本端不同队的盘放上方，同队（队友）盘放下方侧边
		# PVE/1v1：回退到 faction 判断
		var side_top: bool
		var local_team: String = Game.team_of_player(Game.local_player_id) if Game.registry != null else ""
		if team_id != "" and local_team != "":
			side_top = (team_id != local_team)
		else:
			side_top = (faction == BoardSlot.FACTION_ENEMY)
		var show_pile: bool = true
		side_ui_dict = SideBoardUiScript.build(_parent, center_x, side_top,
			"_" + id, show_pile)
		grid = side_ui_dict["grid"]
		bg = side_ui_dict["bg"]
		hero_panel = side_ui_dict["hp_panel"]
		_side_ui[id] = side_ui_dict

	# hero spec：JSON 优先，空时回退到 Game.hero_specs（player_main / enemy_main）
	var hero_spec: Dictionary = meta.get("hero", {})
	if hero_spec.is_empty() and Game.hero_specs.has(id):
		hero_spec = Game.hero_specs[id]
	if hero_spec.is_empty():
		hero_spec = _fallback_hero_spec(faction)

	var level_section := {
		"initial_units":  meta.get("initial_units", []),
		"spawners":       meta.get("spawners", []),
		"spell_casters":  meta.get("spell_casters", []),
	}

	var slot: BoardSlot = BoardSlotFactory.create_main(
		id, faction, role,
		grid, bg, hero_panel,
		_cell_scene,
		hero_spec,
		level_section,
		_on_cell_created,
	)
	if slot == null:
		return null
	if slot_index >= 0:
		slot.slot_index = slot_index
	# 1v3 多人扩展：写入 team_id / owner_player_id
	if team_id != "":
		slot.team_id = team_id
	if owner_player_id != "":
		slot.owner_player_id = owner_player_id

	# ── 视觉翻转：对手棋盘从己方视角观看时，行列均需逆序显示 ────────────────
	# 原理：所有棋盘的 row=0 均为前排（朝对面）。从"对面"看时，需把 row=0 显示在视觉底部，
	# 这样自家放在 row=2（右下角）的单位，对方看到的是左上角，与 1v1 行为一致。
	# 仅在 PVP 1v3 模式下，且当前盘不是本端所在队伍时触发；PVE/1v1 不触发。
	if Game.pvp_match_type == "1v3" and team_id != "":
		var local_team: String = Game.team_of_player(Game.local_player_id)
		if local_team != "" and local_team != team_id and slot.grid_node != null:
			_reverse_grid_cells(slot.grid_node)

	# 附盘：bg 已显示，但需要：1) hp 标签连血量；2) hp 面板长按详情
	if not _main_ui.has(id) and side_ui_dict.has("hp_label"):
		var lbl: Label = side_ui_dict["hp_label"]
		if slot.hero != null:
			slot.hero.health_changed.connect(func(v): lbl.text = str(v))
			lbl.text = str(slot.hero.health)
		_wire_hero_long_press(hero_panel, slot)

	# 附盘 ENEMY 阵营：挂一个 EnemySidePanelManager 作为该盘的墓地/除外
	if not _main_ui.has(id) and faction == BoardSlot.FACTION_ENEMY \
			and side_ui_dict.has("grave_btn") and side_ui_dict.has("banished_btn"):
		_setup_side_enemy_panel(id, slot, side_ui_dict)

	# 附盘 ALLY 阵营：挂一个 AllySidePanelManager 作为该盘的墓地/除外
	if not _main_ui.has(id) and faction == BoardSlot.FACTION_PLAYER \
			and side_ui_dict.has("grave_btn") and side_ui_dict.has("banished_btn"):
		_setup_side_ally_panel(id, slot, side_ui_dict)

	# phantom 预告
	if slot.spawners != null:
		slot.spawners.refresh_phantoms(slot.board, Callable(Game, "get_card"))

	_active[id] = slot
	board_added.emit(slot)
	return slot

# 为 ENEMY 附盘创建独立 EnemySidePanelManager 并接 grave/banished 按钮
func _setup_side_enemy_panel(id: String, slot: BoardSlot, ui: Dictionary) -> void:
	var center_x: float = _side_center_x_for(id)
	var mgr := EnemySidePanelManager.new()
	mgr.name = "EnemySidePanels_" + id
	add_child(mgr)
	mgr.setup(_parent, slot, center_x)
	# 转发长按信号到统一出口（调用方接 detail_panel）
	mgr.long_press_requested.connect(func(p): side_panel_long_press_requested.emit(p))
	mgr.long_press_canceled.connect(func(): side_panel_long_press_canceled.emit())
	# 把面板的 clip 提升到 detail_panel 同级（与主敌盘 enemy_side_panels 一致）
	for clip in mgr.get_clip_nodes():
		clip.move_to_front()
	# 接按钮
	var grave_btn: Button = ui["grave_btn"]
	var banished_btn: Button = ui["banished_btn"]
	if is_instance_valid(grave_btn):
		grave_btn.pressed.connect(func(): mgr.toggle("enemy_grave"))
	if is_instance_valid(banished_btn):
		banished_btn.pressed.connect(func(): mgr.toggle("enemy_banished"))
	_side_panels[id] = mgr

# 为 ALLY 附盘创建独立 AllySidePanelManager 并接 grave/banished 按钮
func _setup_side_ally_panel(id: String, slot: BoardSlot, ui: Dictionary) -> void:
	var center_x: float = _side_center_x_for(id)
	var mgr := AllySidePanelManager.new()
	mgr.name = "AllySidePanels_" + id
	add_child(mgr)
	mgr.setup(_parent, slot, center_x)
	# 转发长按信号到统一出口
	mgr.long_press_requested.connect(func(p): side_panel_long_press_requested.emit(p))
	mgr.long_press_canceled.connect(func(): side_panel_long_press_canceled.emit())
	# 提升 clip 层级，确保面板覆盖棋盘
	for clip in mgr.get_clip_nodes():
		clip.move_to_front()
	# 接按钮
	var grave_btn: Button = ui["grave_btn"]
	var banished_btn: Button = ui["banished_btn"]
	if is_instance_valid(grave_btn):
		grave_btn.pressed.connect(func(): mgr.toggle("ally_grave"))
	if is_instance_valid(banished_btn):
		banished_btn.pressed.connect(func(): mgr.toggle("ally_banished"))
	_side_panels[id] = mgr

func _side_center_x_for(id: String) -> float:
	match id:
		"ally_left", "enemy_left", "enemy_xuhuang":
			return _main_center_x - _side_gap_x
		"ally_right", "enemy_right":
			return _main_center_x + _side_gap_x
	# 1v3：slot_<pid> 格式，按 extra_top_ids 位置映射（第 0 个=左，第 2 个=右）
	if id.begins_with("slot_") and _resolver != null:
		var extras: Array = _resolver.extra_top_ids
		if extras.size() >= 2:
			if id == extras[0]:
				return _main_center_x - _side_gap_x
			if id == extras[1]:
				return _main_center_x + _side_gap_x
		var sides: Array = _resolver.side_slot_ids
		if sides.size() >= 1 and id == sides[0]:
			return _main_center_x - _side_gap_x
		if sides.size() >= 2 and id == sides[1]:
			return _main_center_x + _side_gap_x
	return _main_center_x

# 将 GridContainer 中的子节点顺序完全倒置。
# 视觉效果：(row=0,col=0) 显示在右下，(row=ROWS-1,col=COLS-1) 显示在左上。
# 数据不变，格子自身的 row/col 属性不受影响，游戏逻辑坐标不改变。
static func _reverse_grid_cells(grid_node: Node) -> void:
	if grid_node == null:
		return
	var children: Array = grid_node.get_children()
	if children.is_empty():
		return
	for child in children:
		grid_node.remove_child(child)
	children.reverse()
	for child in children:
		grid_node.add_child(child)

static func _parse_role(role_str: String) -> int:
	match role_str:
		"main_player": return BoardSlot.ROLE_MAIN_PLAYER
		"main_enemy":  return BoardSlot.ROLE_MAIN_ENEMY
		"ally":        return BoardSlot.ROLE_ALLY
	return BoardSlot.ROLE_ENEMY

static func _fallback_hero_spec(faction: int) -> Dictionary:
	if faction == BoardSlot.FACTION_PLAYER:
		return {"hp": 30, "name_short": "盟友", "name_full": "盟友", "abilities": []}
	return {"hp": 30, "name_short": "敌人", "name_full": "敌人", "abilities": []}

# ── HP 面板长按详情 ────────────────────────────────────────────────
func _wire_hero_long_press(hp_pnl: Panel, slot: BoardSlot) -> void:
	if not is_instance_valid(hp_pnl) or _detail_panel == null:
		return
	hp_pnl.gui_input.connect(_make_hero_panel_input_handler(hp_pnl, slot))

func _make_hero_panel_input_handler(hp_pnl: Panel, slot: BoardSlot) -> Callable:
	return func(event: InputEvent) -> void:
		if event is InputEventMouseButton \
				and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
			if slot.hero != null and _detail_panel != null:
				_detail_panel.start_long_press_hero(
					slot.hero.name_full, slot.hero.all_ability_ids(), slot.hero.max_health)
			hp_pnl.pivot_offset = hp_pnl.size / 2.0
			var tw_p := hp_pnl.create_tween()
			tw_p.tween_property(hp_pnl, "scale", Vector2(1.08, 1.08), 0.1)
		elif event is InputEventMouseButton \
				and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
			if _detail_panel != null:
				_detail_panel.cancel_long_press()
			if hp_pnl.scale != Vector2.ONE:
				hp_pnl.pivot_offset = hp_pnl.size / 2.0
				var tw_r := hp_pnl.create_tween()
				tw_r.tween_property(hp_pnl, "scale", Vector2.ONE, 0.1)

# ── 命中判定（与原 SideBoardController 兼容）─────────────────────────
func is_pile_button_hit(global_pos: Vector2) -> bool:
	for ui in _side_ui.values():
		for n in ui.get("ui_nodes", []):
			if not is_instance_valid(n): continue
			if n.name.begins_with("GraveBtn") or n.name.begins_with("BanishedBtn"):
				if n.get_global_rect().has_point(global_pos):
					return true
	return false

# 附盘 EnemySidePanelManager：是否有任何打开的面板？
func any_side_panel_open() -> bool:
	for mgr in _side_panels.values():
		if is_instance_valid(mgr) and mgr.has_open_panel():
			return true
	return false

# 命中任一附盘 panel？
func is_side_panel_hit(global_pos: Vector2) -> bool:
	for mgr in _side_panels.values():
		if is_instance_valid(mgr) and mgr.has_open_panel() and mgr.is_panel_hit(global_pos):
			return true
	return false

# 关闭所有附盘 panel
func close_all_side_panels() -> void:
	for mgr in _side_panels.values():
		if is_instance_valid(mgr) and mgr.has_open_panel():
			mgr.close_current()

# ── 滑入 / 滑出动画 ──────────────────────────────────────────────────
func _animate_slide_in(ui: Dictionary, faction: int = BoardSlot.FACTION_ENEMY) -> void:
	var container: Control = ui.get("container", null)
	if not is_instance_valid(container):
		return
	container.visible = true

	var bg: Panel = ui.get("bg", null)
	var ui_nodes: Array = ui.get("ui_nodes", [])

	# 附属按钮/面板先隐藏，棋盘到位后再渐显
	for n in ui_nodes:
		if is_instance_valid(n):
			n.modulate.a = 0.0

	# 阶段①：棋盘 bg 滑入
	# 敌方侧：从上方落下（负 y）；玩家侧：从下方升起（正 y）
	var sign_dir: float = -1.0 if faction == BoardSlot.FACTION_ENEMY else 1.0
	if is_instance_valid(bg):
		var origin := bg.position
		bg.position += Vector2(0.0, sign_dir * SLIDE_DISTANCE)
		bg.modulate.a = 0.0
		var tw1 := _parent.create_tween()
		tw1.set_parallel(true)
		tw1.tween_property(bg, "position", origin, SLIDE_DURATION) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tw1.tween_property(bg, "modulate:a", 1.0, FADE_DURATION)
		await tw1.finished

	# 阶段②：附属按钮和面板渐显
	if ui_nodes.is_empty():
		return
	var tw2 := _parent.create_tween()
	tw2.set_parallel(true)
	for n in ui_nodes:
		if is_instance_valid(n):
			tw2.tween_property(n, "modulate:a", 1.0, FADE_DURATION)
	await tw2.finished

func _animate_slide_out(ui: Dictionary, faction: int = BoardSlot.FACTION_ENEMY) -> void:
	var bg: Panel = ui.get("bg", null)
	var ui_nodes: Array = ui.get("ui_nodes", [])

	# 阶段①：附属按钮和面板渐隐
	if not ui_nodes.is_empty():
		var tw1 := _parent.create_tween()
		tw1.set_parallel(true)
		for n in ui_nodes:
			if is_instance_valid(n):
				tw1.tween_property(n, "modulate:a", 0.0, FADE_DURATION)
		await tw1.finished

	# 阶段②：棋盘 bg 向上/下滑出
	var sign_dir: float = -1.0 if faction == BoardSlot.FACTION_ENEMY else 1.0
	if is_instance_valid(bg):
		var tw2 := _parent.create_tween()
		tw2.set_parallel(true)
		tw2.tween_property(bg, "position",
			bg.position + Vector2(0.0, sign_dir * SLIDE_DISTANCE), SLIDE_DURATION) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		tw2.tween_property(bg, "modulate:a", 0.0, FADE_DURATION)
		await tw2.finished
