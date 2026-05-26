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
	# 释放附盘 panel 控制器
	for mgr in _side_panels.values():
		if is_instance_valid(mgr):
			mgr.queue_free()
	_side_panels.clear()
	_side_ui.clear()
	_active.clear()
	# 清 Game.turn 残留：旧 combat 节点已 free；信号连接表可能仍指向旧 FrontRowSelector
	if Game.turn != null:
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

# 启动期：遍历 level_data.boards 创建所有 enabled=true 的盘。
# 主棋盘 + boot 期附盘均不走滑入动画（瞬时摆放）。
func boot() -> void:
	if not has_node("/root/Game"):
		return
	var boards: Dictionary = Game.level_data.get("boards", {})
	var ordered_ids: Array = ["player_main", "enemy_main"]
	for id in boards.keys():
		if id == "player_main" or id == "enemy_main":
			continue
		ordered_ids.append(id)
	for id in ordered_ids:
		if not boards.has(id):
			continue
		var meta: Dictionary = boards[id]
		if not bool(meta.get("enabled", true)):
			continue
		_create_slot(id, meta, false)

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
		await _animate_slide_in(_side_ui[id])
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
		await _animate_slide_out(_side_ui[id])
	board_removed.emit(slot)
	BoardSlotFactory.destroy(slot)
	# 销毁附盘的 EnemySidePanelManager
	if _side_panels.has(id):
		var mgr = _side_panels[id]
		if is_instance_valid(mgr):
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
		var side_top: bool = (faction == BoardSlot.FACTION_ENEMY)
		var show_pile: bool = (faction == BoardSlot.FACTION_ENEMY)
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
		"initial_units": meta.get("initial_units", []),
		"spawners": meta.get("spawners", []),
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

	# 附盘：bg 已显示，但需要：1) hp 标签连血量；2) hp 面板长按详情
	if not _main_ui.has(id) and side_ui_dict.has("hp_label"):
		var lbl: Label = side_ui_dict["hp_label"]
		if slot.hero != null:
			slot.hero.health_changed.connect(func(v): lbl.text = str(v))
			lbl.text = str(slot.hero.health)
		_wire_hero_long_press(hero_panel, slot)

	# 附盘 + ENEMY 阵营：挂一个 EnemySidePanelManager 作为该盘的墓地/除外
	if not _main_ui.has(id) and faction == BoardSlot.FACTION_ENEMY \
			and side_ui_dict.has("grave_btn") and side_ui_dict.has("banished_btn"):
		_setup_side_enemy_panel(id, slot, side_ui_dict)

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

func _side_center_x_for(id: String) -> float:
	match id:
		"ally_left", "enemy_left":
			return _main_center_x - _side_gap_x
		"ally_right", "enemy_right":
			return _main_center_x + _side_gap_x
	return _main_center_x

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
					slot.hero.name_full, slot.hero.ability_id(), slot.hero.max_health)
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
func _animate_slide_in(ui: Dictionary) -> void:
	var container: Control = ui.get("container", null)
	if not is_instance_valid(container):
		return
	container.visible = true
	var bg: Panel = ui.get("bg", null)
	var nodes: Array = [bg]
	for n in ui.get("ui_nodes", []):
		nodes.append(n)
	# 中心 x < 屏中 → 从左滑入；> 屏中 → 从右
	var sign_dir: float = 1.0
	if is_instance_valid(bg):
		var bg_center_x: float = (bg.offset_left + bg.offset_right) / 2.0
		sign_dir = -1.0 if bg_center_x < 0.0 else 1.0
	var origin_offsets: Array = []
	for n in nodes:
		if is_instance_valid(n):
			origin_offsets.append(n.position)
			n.position += Vector2(sign_dir * SLIDE_DISTANCE, 0.0)
			n.modulate.a = 0.0

	var tw := _parent.create_tween()
	tw.set_parallel(true)
	for i in range(nodes.size()):
		var n = nodes[i]
		if is_instance_valid(n):
			tw.tween_property(n, "position", origin_offsets[i], SLIDE_DURATION) \
				.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
			tw.tween_property(n, "modulate:a", 1.0, FADE_DURATION)
	await tw.finished

func _animate_slide_out(ui: Dictionary) -> void:
	var bg: Panel = ui.get("bg", null)
	var nodes: Array = [bg]
	for n in ui.get("ui_nodes", []):
		nodes.append(n)
	var sign_dir: float = 1.0
	if is_instance_valid(bg):
		var bg_center_x: float = (bg.offset_left + bg.offset_right) / 2.0
		sign_dir = -1.0 if bg_center_x < 0.0 else 1.0
	var tw := _parent.create_tween()
	tw.set_parallel(true)
	for n in nodes:
		if is_instance_valid(n):
			tw.tween_property(n, "position",
				n.position + Vector2(sign_dir * SLIDE_DISTANCE, 0.0), SLIDE_DURATION) \
				.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
			tw.tween_property(n, "modulate:a", 0.0, FADE_DURATION)
	await tw.finished
