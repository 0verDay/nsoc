class_name TurnSystem
extends Node

# 回合驱动核心。多棋盘版本：完全依赖 Game.registry，不再持有单一棋盘 / spawner 引用。
#
# 公开接口：
#   setup(combat, card_resolver) —— combat 用于动画与英雄面板闪红，card_resolver 用于 spawner 推进
#   run() —— 跑一个完整回合（PLAYER 阶段 → spawn → ENEMY 阶段）
#
# 行/列遍历约定：
#   PLAYER 阶段：row 0→ROWS-1；棋盘按视觉 x 升序；col 0→COLS-1
#   ENEMY  阶段：按"距玩家英雄由近到远"纯格子排序——
#     玩家侧棋盘（已跨入 enemy）优先，row ROWS-1→0，棋盘 x 降序，col COLS-1→0；
#     再是敌方侧棋盘，顺序同上。
#     保证越靠近玩家英雄的 enemy 单位越早行动。
#
# 跨棋盘选择：仅当 cell 所属 slot 是 PLAYER 阵营，且 registry 内存在 ENEMY slot，且
#   _can_cross_board(cell) 为真时触发 front_row_action_requested 信号。

signal turn_started
signal turn_ended
signal phase_started(faction: int)
signal phase_ended(faction: int)
# 玩家前排棋子即将行动：等待外部调用 resolve_front_row_selection(target_id) 后继续。
# target_id: "" = 本棋盘（走默认逻辑），其他字符串 = 外部注册的棋盘标识。
signal front_row_action_requested(cell: Node)
# 行动顺序指示器：当前正在处理的 slot 切换时发出（每 slot 第一个有效单位时 emit）。
signal slot_action_started(slot: BoardSlot)

const PLAYER: int = 0
const ENEMY: int = 1
const STEP_INTERVAL: float = 0.5

var is_running: bool = false
var turn_number: int = 0   # 当前局内回合计数（bootstrap 后重置为 0，每次 run() 开头 +1）

var _combat: CombatSystem
var _card_resolver: Callable

# 前排选择回调：由外部（test_main）赋值。
var _front_row_resolve: Callable = Callable()
var _front_row_result: String = ""
var _front_row_resolved: bool = false

# 行动顺序指示器：缓存上一次 emit 的 slot，避免同盘连续多格重复 emit。
var _last_active_slot: BoardSlot = null

func _registry() -> BoardRegistry:
	if has_node("/root/Game"):
		return Game.registry
	return null

func setup(combat: CombatSystem, card_resolver: Callable) -> void:
	_combat = combat
	_card_resolver = card_resolver

# 兼容旧 API：返回 ENEMY 盘的 (board, hero_resolver) 数组视图。
# front_row_selector / 旧测试代码仍按此读取。
func get_extra_board_configs() -> Array:
	var out: Array = []
	var reg := _registry()
	if reg == null:
		return out
	var main_player_slot: BoardSlot = reg.main_player()
	for slot in reg.slots:
		if slot == main_player_slot:
			continue
		out.append({"board": slot.board, "hero_resolver": slot.hero_resolver})
	return out

# 兼容旧 API：把外部 BoardModel 包装为一个敌方 BoardSlot 加入 registry。
func register_extra_board(board: BoardModel, hero_resolver: Callable) -> void:
	var reg := _registry()
	if reg == null or reg.get_by_board(board) != null:
		return
	var slot := BoardSlot.new()
	slot.name = "ExtraSlot_%d" % reg.slots.size()
	add_child(slot)
	slot.setup(
		"extra_%d" % reg.slots.size(),
		BoardSlot.FACTION_ENEMY,
		BoardSlot.ROLE_ENEMY,
		board, null, null, hero_resolver,
	)
	reg.add(slot)

func unregister_extra_board(board: BoardModel) -> void:
	var reg := _registry()
	if reg == null:
		return
	var slot: BoardSlot = reg.get_by_board(board)
	if slot == null:
		return
	reg.remove(slot.id)
	if is_instance_valid(slot):
		slot.queue_free()

# 外部（test_main）调用：玩家完成棋盘选择后，传入棋盘标识（"" = 本棋盘）。
func resolve_front_row_selection(target_id: String) -> void:
	_front_row_result = target_id
	_front_row_resolved = true

# ── 1v3 跨盘选择队列（远端镜像消费）─────────────────────────────────
# 守方拥有者点 UI 选目标盘后，play_controller 广播 action/cross_board；
# 远端 test_main 接收后调 enqueue_cross_choice 入队；
# 远端 _process_cell 走到 defender 单位的跨盘点时，consume_cross_choice 取回 target_slot_id。
# WS FIFO 保证所有 cross_board 在 end_turn 前到达，消费时无需 await。
var _pending_cross_choices: Array = []   # [{source_slot_id, row, col, target_slot_id}]

func enqueue_cross_choice(payload: Dictionary) -> void:
	_pending_cross_choices.append({
		"source_slot_id": String(payload.get("source_slot_id", "")),
		"row":            int(payload.get("row", -1)),
		"col":            int(payload.get("col", -1)),
		"target_slot_id": String(payload.get("target_slot_id", "")),
	})

func consume_cross_choice(source_slot_id: String, row: int, col: int) -> String:
	for i in range(_pending_cross_choices.size()):
		var c: Dictionary = _pending_cross_choices[i]
		if c.source_slot_id == source_slot_id and c.row == row and c.col == col:
			_pending_cross_choices.remove_at(i)
			return String(c.target_slot_id)
	return ""

func clear_cross_choices() -> void:
	_pending_cross_choices.clear()

# 多队伍 PVP 跨盘选择广播（1v3 守方拥有者 / 3v3 任意拥有者）。
# 远端 test_main 收到后调 enqueue_cross_choice 入队。
func _broadcast_cross_board(source_slot_id: String, row: int, col: int, target_slot_id: String) -> void:
	if not has_node("/root/Net"):
		return
	if not has_node("/root/Game") or not Game.is_pvp:
		return
	if not Game.is_multi_team_pvp():
		return
	var payload: Dictionary = {
		"source_slot_id": source_slot_id,
		"row":            row,
		"col":            col,
		"target_slot_id": target_slot_id,
	}
	Net.send_to_room("action/cross_board", Game.pvp_room_id, payload, "all")

func run() -> void:
	is_running = true
	turn_number += 1
	turn_started.emit()
	# 等待本回合 board_events / turn_gte 触发器执行完毕（含 add_board 滑入动画），
	# 确保所有棋盘就位后再处理单位行动。
	if has_node("/root/Events") and Events.is_inside_tree():
		await Events.run_turn_events_and_wait(turn_number)
	await _run_phase(PLAYER)
	if _combat == null or _combat.aborted:
		is_running = false
		return
	await _run_spawn_phase()
	if _combat == null or _combat.aborted:
		is_running = false
		return
	await _run_phase(ENEMY)
	if _combat == null or _combat.aborted:
		is_running = false
		return
	var reg := _registry()
	if reg != null:
		for slot in reg.slots:
			if is_instance_valid(slot.board):
				slot.board.reset_attack_flags()
			if slot.spawners != null:
				slot.spawners.refresh_phantoms(slot.board, _card_resolver)
	is_running = false
	turn_ended.emit()

# PVP 专用：只跑指定阵营一侧的行动阶段。
#   faction = PLAYER(0)：本端 player_main 的单位行动（主动结束回合时调用）
#   faction = ENEMY(1) ：本端 enemy_main 的单位行动（收到对方 end_turn 时调用）
# 不跑 spawn / spell_caster / Events，不递增 turn_number，不发 turn_started/ended。
# 攻击 flag 在调用方按需重置（或等双方都完成后一次性重置）。
func run_pvp_phase(faction: int) -> void:
	if is_running:
		return
	is_running = true
	await _run_phase(faction)
	var reg := _registry()
	if reg != null:
		for slot in reg.slots:
			if is_instance_valid(slot.board) and slot.faction == faction:
				slot.board.reset_attack_flags()
	is_running = false

# 多队伍 PVP 专用（1v3 / 3v3）：只跑指定 slot_id 的行动阶段，不影响其他盘。
# 与 run_pvp_phase 区别：按 slot 而非 faction 粒度；保留 1v1 的 run_pvp_phase 不变。
func run_pvp_phase_for_slot(slot_id: String) -> void:
	if is_running:
		return
	var reg := _registry()
	if reg == null:
		return
	var slot: BoardSlot = reg.get_by_id(slot_id)
	if slot == null:
		return
	is_running = true
	await _run_phase_for_slot(slot)
	if is_instance_valid(slot) and is_instance_valid(slot.board):
		slot.board.reset_attack_flags()
	is_running = false

func _run_phase_for_slot(slot: BoardSlot) -> void:
	_last_active_slot = null
	phase_started.emit(slot.faction)
	for entry in _iter_phase_cells_of_slot(slot):
		if _combat == null or _combat.aborted:
			return
		var raw_cell = entry.get("cell")
		var raw_slot = entry.get("slot")
		if not is_instance_valid(raw_cell) or not is_instance_valid(raw_slot):
			continue
		if not is_instance_valid(raw_slot.board):
			continue
		await _process_cell(slot.faction, raw_cell, raw_slot)
		if _combat == null or _combat.aborted:
			return
	phase_ended.emit(slot.faction)

# 构建指定 slot 的行动 (cell, slot) 序列。
# 多队伍 PVP（1v3 / 3v3）：所有盘均以 row=0 为前排，统一 row 0→ROWS-1 顺序。
# PVE / 1v1 兼容：无 team_id 时按 faction 决定（PLAYER 盘 0→2，ENEMY 盘 2→0）。
func _iter_phase_cells_of_slot(slot: BoardSlot) -> Array:
	if slot.board == null:
		return []
	var out: Array = []
	var rows: Array = []
	# 多队伍 PVP：前排（row=0）单位优先行动，所有盘统一 row 0→ROWS-1
	# PVE/1v1：PLAYER 盘前排 row=0 先走，ENEMY 盘前排 row=ROWS-1 先走
	if slot.team_id != "":
		for r in range(BoardModel.ROWS):   # 0,1,2（前排先走）
			rows.append(r)
	elif slot.faction == PLAYER:
		for r in range(BoardModel.ROWS):
			rows.append(r)
	else:
		for r in range(BoardModel.ROWS - 1, -1, -1):
			rows.append(r)
	# 自家盘的单位
	for r in rows:
		for c in range(BoardModel.COLS):
			var cell = slot.board.get_cell(Vector2(r, c))
			if cell != null and cell.has_card:
				out.append({"cell": cell, "slot": slot})
	# 已跨入其他棋盘的本盘单位（owner_slot_id == slot.id）
	var reg := _registry()
	if reg != null and slot.id != "":
		for other_slot in reg.slots:
			if other_slot.id == slot.id or other_slot.board == null:
				continue
			for cell in other_slot.board.grid_cells.values():
				if is_instance_valid(cell) and cell.has_card \
						and cell.owner_slot_id == slot.id:
					out.append({"cell": cell, "slot": other_slot})
	return out

func _run_phase(faction: int) -> void:
	_last_active_slot = null
	phase_started.emit(faction)
	# 敌方阶段开始时，推进所有盘的法术施放器（在单位行动前）
	if faction == ENEMY:
		await _advance_spell_casters()
		if _combat == null or _combat.aborted:
			return
	for entry in _iter_phase_cells(faction):
		# 每次循环开头先检查：aborted 或节点已被 free（退出到菜单）
		if _combat == null or _combat.aborted:
			return
		# 先校验 entry 内的引用有效性，再赋值局部变量
		var raw_slot = entry.get("slot")
		var raw_cell = entry.get("cell")
		if not is_instance_valid(raw_cell) or not is_instance_valid(raw_slot):
			continue
		var c = raw_cell
		var s: BoardSlot = raw_slot
		# 棋盘可能在上一次 await 后被动态移除，跳过已释放的 cell/slot/board
		if not is_instance_valid(s.board):
			continue
		await _process_cell(faction, c, s)
		# await 后再次检查，防止 process_cell 内部触发退出
		if _combat == null or _combat.aborted:
			return
	phase_ended.emit(faction)

# 推进所有已注册盘的法术施放器（异步）。
func _advance_spell_casters() -> void:
	var reg := _registry()
	if reg == null:
		return
	for slot in reg.slots.duplicate():
		if _combat == null or _combat.aborted:
			return
		if not is_instance_valid(slot) or slot.spell_casters == null:
			continue
		if slot.spell_casters._casters.is_empty():
			continue
		await slot.spell_casters.advance()

# 构建本阶段的 (cell, slot) 序列。
#
# PLAYER 阶段：
#   行 0→ROWS-1，棋盘 x 升序，列 0→COLS-1（自身视角后排→前排，左→右）
#
# ENEMY 阶段（按"距玩家英雄由近到远"纯格子排序）：
#   先遍历所有玩家侧棋盘（enemy 单位已跨入，离玩家英雄更近），
#   再遍历所有敌方侧棋盘（enemy 单位尚未跨入）。
#   两组内部均：行 ROWS-1→0（敌方视角前排→后排），棋盘 x 降序，列 COLS-1→0。
#   效果：玩家盘 row2 → 玩家盘 row1 → 玩家盘 row0 →
#         敌方盘 row2 → 敌方盘 row1 → 敌方盘 row0
func _iter_phase_cells(faction: int) -> Array:
	var reg := _registry()
	if reg == null:
		return []

	var out: Array = []

	if faction == PLAYER:
		var slots: Array = reg.sorted_by_x()
		for r in range(BoardModel.ROWS):
			for slot in slots:
				if not is_instance_valid(slot.board):
					continue
				for c in range(BoardModel.COLS):
					var key := Vector2(r, c)
					if slot.board.grid_cells.has(key):
						out.append({"cell": slot.board.grid_cells[key], "slot": slot})
	else:
		# 将棋盘分成两组：玩家侧（faction=PLAYER）和敌方侧（faction=ENEMY），
		# 均按 x 降序（敌方自身视角左→右）。
		var slots_desc: Array = reg.sorted_by_x().duplicate()
		slots_desc.reverse()
		var player_slots: Array = []
		var enemy_slots: Array = []
		for s in slots_desc:
			if s.faction == BoardSlot.FACTION_PLAYER:
				player_slots.append(s)
			else:
				enemy_slots.append(s)

		# ① 玩家侧棋盘：已跨入的 enemy 单位，离玩家英雄最近，最先行动
		for r in range(BoardModel.ROWS - 1, -1, -1):
			for slot in player_slots:
				if not is_instance_valid(slot.board):
					continue
				for c in range(BoardModel.COLS - 1, -1, -1):
					var key := Vector2(r, c)
					if slot.board.grid_cells.has(key):
						out.append({"cell": slot.board.grid_cells[key], "slot": slot})

		# ② 敌方侧棋盘：尚未跨入的 enemy 单位
		for r in range(BoardModel.ROWS - 1, -1, -1):
			for slot in enemy_slots:
				if not is_instance_valid(slot.board):
					continue
				for c in range(BoardModel.COLS - 1, -1, -1):
					var key := Vector2(r, c)
					if slot.board.grid_cells.has(key):
						out.append({"cell": slot.board.grid_cells[key], "slot": slot})

	return out

# 单 cell 行动结算。slot 是 cell 所属盘。
#
# 行动方向语义（多盘）：
#   单位推进方向取决于 cell.is_enemy（unit_faction）：
#     PLAYER 单位 step=-1（向 row 减小）
#     ENEMY  单位 step=+1（向 row 增大）
#   "目标行"取决于单位所在盘相对自身阵营是"自家盘"还是"敌方盘"：
#     自家盘（slot.faction == unit_faction）：
#         goal_row = 自家 front_row（= 朝中线 = 跨盘起跳点）；到达后不打英雄，
#         转入跨棋盘流程（玩家走 UI 选择，敌方自动跨）
#     敌方盘（slot.faction != unit_faction）：
#         goal_row = 该盘 back_row（= 对方英雄所在）；到达后调 hero_resolver 打英雄
func _process_cell(faction: int, cell, slot: BoardSlot) -> void:
	var for_enemy: bool = faction == ENEMY
	var board: BoardModel = slot.board

	if not cell.has_card or cell.has_attacked:
		return
	# 多队伍 PVP 中按 team_id 判断是否是本轮处理的单位（同队即处理）；PVE/1v1 回退 is_enemy
	var is_my_unit: bool
	if cell.team_id != "" and slot.team_id != "":
		is_my_unit = (cell.team_id == slot.team_id)
	else:
		is_my_unit = (cell.is_enemy == for_enemy)
	if not is_my_unit:
		return

	# 行动顺序指示器：slot 切换时 emit（同盘连续多格只 emit 一次）
	if slot != _last_active_slot:
		_last_active_slot = slot
		slot_action_started.emit(slot)

	var unit_faction: int = BoardSlot.FACTION_ENEMY if cell.is_enemy else BoardSlot.FACTION_PLAYER
	var on_home_board: bool = (slot.faction == unit_faction)
	# 多队伍 PVP：用 team_id 判断"自家盘"更准确（1v3 / 3v3 通用）
	if slot.team_id != "":
		var unit_team: String = cell.team_id
		on_home_board = (slot.team_id == unit_team and unit_team != "")
	# 步进方向：多队伍 PVP 自家盘 step=-1（向 row=0），敌方盘 step=+1（向 row=2）
	# PVE/1v1 回退 unit_faction
	var step: int
	if cell.team_id != "" and slot.team_id != "":
		step = -1 if on_home_board else 1
	else:
		step = BoardModel.step_of(unit_faction)
	# 自家盘：goal = front_row（跨盘起跳）；敌方盘：goal = 该盘 back_row（对方英雄）
	var goal_row: int = BoardModel.front_row_of_slot(slot) if on_home_board \
		else BoardModel.back_row_of_slot(slot)
	# hero_resolver：仅在敌方盘上到达 goal 才生效
	var hero_resolver: Callable = slot.hero_resolver if (not on_home_board) else Callable()

	# ── 先攻：有邻敌则直接攻击，冲锋作废 ─────────────────────────────
	var enemies := board.find_adjacent_enemies(cell, for_enemy)
	if enemies.size() > 0:
		await _combat.attack_cells(cell, enemies)
		if _combat == null or _combat.aborted:
			return
		if is_instance_valid(cell) and cell.has_card:
			cell.has_attacked = true
		return

	# ── 跨棋盘选择（本端当前行动玩家的盘）：cell 在自家盘 + 存在敌方盘 + 可跨条件成立
	var reg := _registry()
	# enemy_slots：1v3 按 team_id 取敌队所有盘；1v1/PVE 仍用旧 FACTION_ENEMY 路径
	var owner_pid: String = slot.owner_player_id
	var enemy_slots: Array
	if reg != null and slot.team_id != "" and owner_pid != "":
		enemy_slots = reg.adjacent_enemy_slots(owner_pid, cell.col)
	else:
		enemy_slots = reg.enemy_targets() if reg != null else []
	var player_slots: Array = reg.by_faction(BoardSlot.FACTION_PLAYER) if reg != null else []

	# ── 跨盘路径分发 ───────────────────────────────────────────────────────
	# 1v3 defender：拥有者走 UI 选盘 + 广播；远端从队列消费；落点用镜像列。
	# 1v3 attacker：拥有者 + 远端 均走自动跨盘到守方盘（单一目标），落点用镜像列。
	# 3v3（team_a / team_b）：所有玩家均走 UI 选盘 + 广播，落点用镜像列。
	# PVE/1v1（team_id == ""）：保留原 UI / auto-cross 路径，同列规则不变。
	var front_row_target_id: String = ""
	if slot.team_id == "defender" and on_home_board \
			and not enemy_slots.is_empty() \
			and _can_cross_board(cell, slot):
		if faction == PLAYER:
			# 1v3 守方拥有者：UI 选盘，选定后广播给远端
			front_row_target_id = await _run_front_row_selection(cell)
			if front_row_target_id != "":
				_broadcast_cross_board(slot.id, cell.row, cell.col, front_row_target_id)
		else:
			# 1v3 守方远端镜像：从队列消费拥有者的选择
			front_row_target_id = consume_cross_choice(slot.id, cell.row, cell.col)
			if front_row_target_id == "" and enemy_slots.size() > 0:
				# 消息丢失兜底：取第一个敌队盘，避免卡死
				front_row_target_id = String(enemy_slots[0].id)
				push_warning("TurnSystem: cross_choice queue miss for %s(%d,%d); fallback %s" \
					% [slot.id, cell.row, cell.col, front_row_target_id])
	elif slot.team_id in ["team_a", "team_b"] and on_home_board \
			and not enemy_slots.is_empty() \
			and _can_cross_board(cell, slot):
		# 3v3：所有玩家均走 UI 路径（拥有者选盘广播，远端消费队列）
		if owner_pid == Game.local_player_id:
			front_row_target_id = await _run_front_row_selection(cell)
			if front_row_target_id != "":
				_broadcast_cross_board(slot.id, cell.row, cell.col, front_row_target_id)
		else:
			front_row_target_id = consume_cross_choice(slot.id, cell.row, cell.col)
			if front_row_target_id == "" and enemy_slots.size() > 0:
				front_row_target_id = String(enemy_slots[0].id)
				push_warning("TurnSystem: 3v3 cross_choice queue miss for %s(%d,%d); fallback %s" \
					% [slot.id, cell.row, cell.col, front_row_target_id])
	elif slot.team_id == "" \
			and faction == PLAYER \
			and slot.faction == BoardSlot.FACTION_PLAYER \
			and not enemy_slots.is_empty() \
			and _can_cross_board(cell, slot):
		# PVE / 1v1 旧 UI 路径
		front_row_target_id = await _run_front_row_selection(cell)

	if front_row_target_id != "" and _front_row_resolve.is_valid():
		var result = await _front_row_resolve.call(cell, front_row_target_id)
		var handled: bool = typeof(result) == TYPE_DICTIONARY \
			and bool(result.get("handled", false))
		if handled:
			if result.has("crossed_cell"):
				# 跨入对面盘后继续冲锋穿透：goal_row = 对面盘的 back_row（对面英雄所在）
				var crossed = result["crossed_cell"]
				var target_board: BoardModel = result["board_model"]
				var target_hero: Callable = result.get("hero_resolver", Callable())
				var target_slot: BoardSlot = reg.get_by_board(target_board) if reg != null else null
				if is_instance_valid(target_board) and target_hero.is_valid() \
						and target_slot != null:
					# 玩家跨入敌方盘，继续冲锋穿透
					# 步进方向：与 front_row_of_slot 相反（朝 back_row）
					var x_step: int
					var x_goal: int
					if target_slot.team_id != "":
						x_goal = BoardModel.back_row_of_slot(target_slot)
						x_step = 1 if x_goal > BoardModel.front_row_of_slot(target_slot) else -1
					else:
						x_step = -BoardModel.step_of(target_slot.faction)
						x_goal = BoardModel.back_row_of(target_slot.faction)
					if result.get("deferred_move", false):
						# 延迟移动：探查敌方盘上的冲锋终点，从原格一次性冲到位（无中间停顿）
						var source_cell = result.get("source_cell", null)
						if not is_instance_valid(source_cell) or not source_cell.has_card:
							cell.has_attacked = true
							return
						# 从 crossed（敌方盘 front_row）开始向内探查冲锋终点
						var probe_dest = crossed
						var probe_enemy = null
						var probe_hit_hero: bool = false
						var probe_r: int = crossed.row + x_step
						while probe_r >= 0 and probe_r < BoardModel.ROWS:
							var nc = target_board.get_cell(Vector2(probe_r, crossed.col))
							if nc == null:
								break
							if nc.has_card:
								if not nc.is_enemy:  # 同阵营（友军）阻挡
									break
								probe_enemy = nc
								break
							probe_dest = nc
							if probe_dest.row == x_goal:
								probe_hit_hero = true
								break
							probe_r += x_step
						# 一次性从源格直接冲到终点，消除中间停顿
						await _combat.move_card(source_cell, probe_dest)
						if _combat == null or _combat.aborted:
							return
						if not is_instance_valid(probe_dest) or not probe_dest.has_card:
							cell.has_attacked = true
							return
						probe_dest.slot_id = target_slot.id
						await _trigger_vigilance_on_board(probe_dest, false, target_board)
						if _combat == null or _combat.aborted:
							return
						if not is_instance_valid(target_board) or not is_instance_valid(probe_dest) \
								or not probe_dest.has_card:
							cell.has_attacked = true
							return
						if probe_enemy != null:
							var dir_name: String = "bottom" if x_step > 0 else "top"
							var opp_name: String = "top" if x_step > 0 else "bottom"
							await _combat.attack_cells(probe_dest, [{
								"cell": probe_enemy, "dir": dir_name, "opp_dir": opp_name,
							}])
							if _combat == null or _combat.aborted:
								return
						elif probe_hit_hero and target_hero.is_valid():
							target_hero.call(probe_dest.attack, "unit_direct")
							await get_tree().create_timer(STEP_INTERVAL).timeout
						if is_instance_valid(probe_dest) and probe_dest.has_card:
							probe_dest.has_attacked = true
							probe_dest.has_charged = true
					else:
						if is_instance_valid(crossed) and crossed.has_card:
							# 冲锋落地后先触发 vigilance（落点附近可能有敌方警戒单位）
							await _trigger_vigilance_on_board(crossed, false, target_board)
							if _combat == null or _combat.aborted:
								return
							if not is_instance_valid(target_board) or not is_instance_valid(crossed) \
									or not crossed.has_card:
								cell.has_attacked = true
								return
							var ended_cell_x = await _run_charge_on_board(crossed,
								x_step, false, x_goal,
								target_board, target_hero)
							if ended_cell_x != null:
								ended_cell_x.has_attacked = true
								ended_cell_x.has_charged = true
			else:
				# 普通跨盘（非冲锋，handled=true，无 crossed_cell）：落地触发警戒。
				# _on_target_chosen 在此路径返回 {"landed_cell", "board_model"}。
				var landed = result.get("landed_cell")
				var landed_board: BoardModel = result.get("board_model")
				if is_instance_valid(landed) and landed.has_card \
						and is_instance_valid(landed_board):
					await _trigger_vigilance_on_board(landed, false, landed_board)
		else:
			# handled=false：跨盘失败（目标格被占或无效），回退本棋盘默认行动
			cell.has_attacked = true
			if cell.effects.has("charge"):
				cell.has_charged = true
		return

	# ── 敌方/攻方自动跨盘：cell 在自家盘 front_row + 存在敌队盘
	# 1v3：攻方单位（无论本端还是远端）到达 front_row 后自动跨入守方盘；守方走 UI 路径已在上文处理。
	# 3v3：已在 UI 路径处理，不走 auto-cross。
	# PVE/1v1：维持旧 FACTION_ENEMY front_row 判断
	var is_auto_cross_candidate: bool
	var auto_cross_target_slots: Array
	if on_home_board and slot.team_id in ["team_a", "team_b"]:
		# 3v3：UI 路径已处理，禁用 auto-cross
		is_auto_cross_candidate = false
		auto_cross_target_slots = []
	elif on_home_board and slot.team_id == "attacker":
		# 1v3 攻方：拥有者 / 远端镜像都走 _enemy_auto_cross（确定性，单一目标=守方盘）
		var front_r := BoardModel.front_row_of_slot(slot)
		is_auto_cross_candidate = (cell.row == front_r and not enemy_slots.is_empty())
		auto_cross_target_slots = enemy_slots
	elif on_home_board and slot.team_id == "defender":
		# 1v3 守方：UI 路径已在 defender_cross_path 中处理；防止落入 auto-cross
		is_auto_cross_candidate = false
		auto_cross_target_slots = []
	else:
		# 旧路径（PVE/1v1）
		is_auto_cross_candidate = (on_home_board \
			and faction == ENEMY \
			and slot.faction == BoardSlot.FACTION_ENEMY \
			and cell.row == BoardModel.front_row_of(BoardSlot.FACTION_ENEMY) \
			and not player_slots.is_empty())
		auto_cross_target_slots = player_slots
	if is_auto_cross_candidate:
		if await _enemy_auto_cross(cell, slot, auto_cross_target_slots):
			return

	# ── 冲锋 ────────────────────────────────────────────────────────
	# steadfast 单位即使有 charge 也不移动
	if cell.effects.has("charge") and not cell.has_charged and not cell.effects.has("steadfast"):
		var ended_cell = await _run_charge_on_board(cell, step, for_enemy,
			goal_row, board, hero_resolver)
		if ended_cell != null:
			ended_cell.has_attacked = true
			ended_cell.has_charged = true
		return

	# 已到 goal_row：
	#   自家盘上 = 自家 front_row → idle（跨盘已处理）
	#   敌方盘上 = 该盘 back_row → 打英雄（"unit_direct" 来源）
	# PVP 锁步说明：hero_resolver 只修改本端对应 HeroState，无需广播。
	#   run_pvp_phase(PLAYER) 在 A 端打 A 的 enemy hero（对手）；
	#   run_pvp_phase(ENEMY)  在 B 端打 B 的 player hero（自己）。
	#   两端各打各端的 hero_resolver，结果对称，已验证。
	if cell.row == goal_row:
		if not on_home_board and hero_resolver.is_valid():
			hero_resolver.call(cell.attack, "unit_direct")
		cell.has_attacked = true
		await get_tree().create_timer(STEP_INTERVAL).timeout
		return

	# 向 goal_row 推进一格
	var target_r: int = cell.row + step
	if target_r < 0 or target_r >= BoardModel.ROWS:
		return
	var target = board.get_cell(Vector2(target_r, cell.col))
	if target and not target.has_card:
		if cell.effects.has("steadfast"):
			return
		await _combat.move_card(cell, target)
		# await 后检查 aborted 或节点失效
		if _combat == null or _combat.aborted:
			return
		if not is_instance_valid(board) or not is_instance_valid(target):
			return
		target.has_attacked = true
		await get_tree().create_timer(STEP_INTERVAL).timeout
		if _combat == null or _combat.aborted or not is_instance_valid(board) or not is_instance_valid(target):
			return
		await _trigger_vigilance_on_board(target, for_enemy, board)

# ── 跨棋盘可行性判定 ──────────────────────────────────────────────────
# 仅判断玩家本回合行动后是否"可能"跨入另一棋盘，是否真有目标棋盘交由
# FrontRowSelector / resolver 决定。
#   普通棋子：当前已在自家 front_row，下一步即跨界
#   冲锋棋子（且本回合冲锋未用）：从当前 row 到 front_row 的同列全空 且
#       cell 行的同行三列邻格全空（即 "九宫格" 全空），可冲到前排再跨
# ── 敌方阵营自动跨盘 ──────────────────────────────────────────────────
# 敌方单位站在自家 front_row 时自动跨入对面 PLAYER 阵营盘的同列 front_row。
# - 优先选择"同列对面盘存在玩家单位"的目标盘进行跨盘攻击（多盘时取第一个匹配）
# - 同列空 → 选第一个有空格 cell 的玩家盘跨入（落到该盘 row=0 同列）
# 返回 true 表示已处理（外层 _process_cell 应 return）；false 表示未处理
func _enemy_auto_cross(cell, slot: BoardSlot, target_slots: Array) -> bool:
	if cell == null or not cell.has_card:
		return false
	# steadfast 单位不移动，不跨盘
	if cell.effects.has("steadfast"):
		return false
	# 落点列：多队伍 PVP（1v3/3v3）用镜像（拥有者视觉同列）；PVE/1v1（无 team_id）保持同列
	var src_col: int = cell.col
	var dst_col: int
	if cell.team_id != "" and target_slots.size() > 0 \
			and (target_slots[0] as BoardSlot).team_id != "":
		dst_col = BoardModel.COLS - 1 - src_col
	else:
		dst_col = src_col

	# 目标盘的"前排"（攻方/敌方单位跨入后落点）与"后排"（对方英雄所在）
	# 1v3：守方盘 front=0/back=2；攻方盘 front=2/back=0
	# PVE/1v1：PLAYER 盘 front=0/back=2，step=+1（敌方单位在玩家盘内前进方向）
	# 统一从第一个目标盘取，所有目标盘应一致。
	var first_target: BoardSlot = target_slots[0] if target_slots.size() > 0 else null
	var tgt_front: int
	var tgt_back: int
	var tgt_step: int
	if first_target != null and first_target.team_id != "":
		tgt_front = BoardModel.front_row_of_slot(first_target)
		tgt_back  = BoardModel.back_row_of_slot(first_target)
		tgt_step  = 1 if tgt_back > tgt_front else -1
	else:
		tgt_front = BoardModel.front_row_of(BoardSlot.FACTION_PLAYER)
		tgt_back  = BoardModel.back_row_of(BoardSlot.FACTION_PLAYER)
		tgt_step  = -BoardModel.step_of(BoardSlot.FACTION_PLAYER)  # +1，敌方在玩家盘内前进方向

	# 1) 收集所有"目标盘 (tgt_front, dst_col) 有敌方单位"的候选盘
	var attack_candidates: Array = []
	for tgt_slot in target_slots:
		var pb: BoardModel = tgt_slot.board
		var tgt = pb.get_cell(Vector2(tgt_front, dst_col))
		if tgt != null and tgt.has_card:
			var tgt_is_hostile: bool
			if tgt.team_id != "" and cell.team_id != "":
				tgt_is_hostile = (tgt.team_id != cell.team_id)
			else:
				tgt_is_hostile = not tgt.is_enemy
			if tgt_is_hostile:
				attack_candidates.append({"slot": tgt_slot, "cell": tgt})
	if attack_candidates.size() > 0:
		var pick: Dictionary = attack_candidates[randi() % attack_candidates.size()]
		var tgt = pick["cell"]
		await get_tree().create_timer(CombatSystem.ATTACK_HIT_DELAY).timeout
		if _combat == null or _combat.aborted or not is_instance_valid(cell) or not cell.has_card:
			cell.has_attacked = true
			return true
		# 攻击方向：从自家盘朝目标盘的方向（tgt_step>0 表示向下=底部攻击，反之向上）
		var dir_name: String = "bottom" if tgt_step > 0 else "top"
		var opp_name: String = "top"    if tgt_step > 0 else "bottom"
		await _combat.attack_cells(cell, [{
			"cell": tgt, "dir": dir_name, "opp_dir": opp_name,
		}])
		if _combat == null or _combat.aborted:
			return true
		cell.has_attacked = true
		return true

	# 2) 收集所有"目标盘 (tgt_front, dst_col) 为空"的候选盘
	var move_candidates: Array = []
	for tgt_slot in target_slots:
		var pb2: BoardModel = tgt_slot.board
		var tgt2 = pb2.get_cell(Vector2(tgt_front, dst_col))
		if tgt2 != null and not tgt2.has_card:
			move_candidates.append({"slot": tgt_slot, "cell": tgt2})
	if move_candidates.size() > 0:
		var pick2: Dictionary = move_candidates[randi() % move_candidates.size()]
		var ply_slot2: BoardSlot = pick2["slot"]
		var tgt2 = pick2["cell"]
		var pb2: BoardModel = ply_slot2.board

		# 冲锋单位（steadfast 不触发）：探查目标盘上的终点，一次性冲到位
		if cell.effects.has("charge") and not cell.has_charged and not cell.effects.has("steadfast"):
			var probe_dest = tgt2
			var probe_enemy = null
			var probe_hit_hero: bool = false
			var probe_r: int = tgt2.row + tgt_step
			while probe_r >= 0 and probe_r < BoardModel.ROWS:
				var nc = pb2.get_cell(Vector2(probe_r, dst_col))
				if nc == null:
					break
				if nc.has_card:
					# 友军（同队）阻挡
					var nc_is_friendly: bool
					if nc.team_id != "" and cell.team_id != "":
						nc_is_friendly = (nc.team_id == cell.team_id)
					else:
						nc_is_friendly = nc.is_enemy
					if nc_is_friendly:
						break
					probe_enemy = nc
					break
				probe_dest = nc
				if probe_dest.row == tgt_back:
					probe_hit_hero = true
					break
				probe_r += tgt_step
			await _combat.move_card(cell, probe_dest)
			if _combat == null or _combat.aborted:
				return true
			if not is_instance_valid(probe_dest) or not probe_dest.has_card:
				return true
			probe_dest.slot_id = ply_slot2.id
			await _trigger_vigilance_on_board(probe_dest, true, pb2)
			if _combat == null or _combat.aborted:
				return true
			if not is_instance_valid(pb2) or not is_instance_valid(probe_dest) or not probe_dest.has_card:
				return true
			if probe_enemy != null:
				var charge_dir: String    = "bottom" if tgt_step > 0 else "top"
				var charge_opp_dir: String = "top"    if tgt_step > 0 else "bottom"
				await _combat.attack_cells(probe_dest, [{
					"cell": probe_enemy, "dir": charge_dir, "opp_dir": charge_opp_dir,
				}])
				if _combat == null or _combat.aborted:
					return true
			elif probe_hit_hero and ply_slot2.hero_resolver.is_valid():
				ply_slot2.hero_resolver.call(probe_dest.attack, "unit_direct")
				await get_tree().create_timer(STEP_INTERVAL).timeout
			if is_instance_valid(probe_dest) and probe_dest.has_card:
				probe_dest.has_attacked = true
				probe_dest.has_charged = true
			return true

		# 普通单位：跨入 → 落地触发 vigilance → idle
		await _combat.move_card(cell, tgt2)
		if _combat == null or _combat.aborted:
			return true
		if not is_instance_valid(tgt2) or not tgt2.has_card:
			return true
		if not is_instance_valid(ply_slot2) or not is_instance_valid(pb2):
			return true
		tgt2.has_attacked = true
		tgt2.slot_id = ply_slot2.id
		await _trigger_vigilance_on_board(tgt2, true, pb2)
		if not is_instance_valid(pb2) or not is_instance_valid(tgt2) or not tgt2.has_card:
			return true
		return true

	# 3) 所有玩家盘同列都已被敌方单位/空缺占据 → idle
	return false

# ── 跨棋盘可行性判定 ──────────────────────────────────────────────────
# 普通棋子：当前已在自家 front_row，下一步即跨界
# 冲锋棋子（且本回合冲锋未用）：从当前 row 到 front_row 的同列全空
# 邻列/邻格不作限制（邻敌由 _process_cell 开头的先攻判断拦截）
func _can_cross_board(cell, slot: BoardSlot) -> bool:
	if cell == null or not cell.has_card or slot == null:
		return false
	if cell.effects.has("steadfast"):
		return false
	var board: BoardModel = slot.board
	# 1v3：用 front_row_of_slot；PVE/1v1：front_row_of(faction)
	var front_row: int = BoardModel.front_row_of_slot(slot)
	# _can_cross_board 只在自家盘调用，step 始终向 front 走
	var step: int
	if cell.team_id != "":
		step = -1   # 自家盘统一 step=-1
	else:
		step = BoardModel.step_of(slot.faction)
	if cell.row == front_row:
		return true
	if not (cell.effects.has("charge") and not cell.has_charged):
		return false
	# 同列：从 cell.row 沿 step 方向至 front_row（含）全空
	var r: int = cell.row + step
	while r != front_row + step:
		var c = board.get_cell(Vector2(r, cell.col))
		if c == null or c.has_card:
			return false
		r += step
	return true

# ── 前排选择等待 ──────────────────────────────────────────────────────
func _run_front_row_selection(cell: Node) -> String:
	_front_row_resolved = false
	_front_row_result = ""
	front_row_action_requested.emit(cell)
	while not _front_row_resolved:
		if _combat == null or _combat.aborted:
			return ""
		await _combat.get_tree().process_frame
	return _front_row_result

# 冲锋（参数化版本）。
# step: 行进方向（-1=row 减小=玩家阵营盘内方向；+1=row 增大=敌方阵营盘内方向）
# goal_row: 命中即停的目标行；hero_resolver 非空时到达 goal_row 视为打英雄。
#           hero_resolver 为空时仅停下（用于自家盘内冲锋撞到 front_row 不打英雄）
# attack 朝向（dir/opp_dir）按 step 方向决定。
func _run_charge_on_board(cell, step: int, for_enemy: bool, goal_row: int,
		board: BoardModel, hero_resolver: Callable):
	if cell.row == goal_row:
		if hero_resolver.is_valid():
			hero_resolver.call(cell.attack, "unit_direct")
		await get_tree().create_timer(STEP_INTERVAL).timeout
		if _combat == null or _combat.aborted:
			return null
		return cell

	var dest = cell
	var enemy_target = null
	var hit_hero: bool = false
	var probe_r: int = cell.row + step
	while probe_r >= 0 and probe_r < BoardModel.ROWS:
		var next_cell = board.get_cell(Vector2(probe_r, cell.col))
		if next_cell == null:
			break
		if next_cell.has_card:
			# 同阵营阻挡：1v3 用 team_id；PVE/1v1 用 is_enemy
			var is_friendly: bool
			if next_cell.team_id != "" and cell.team_id != "":
				is_friendly = (next_cell.team_id == cell.team_id)
			else:
				is_friendly = (next_cell.is_enemy == for_enemy)
			if is_friendly:
				break
			enemy_target = next_cell
			break
		dest = next_cell
		if dest.row == goal_row:
			hit_hero = true
			break
		probe_r += step

	if dest != cell:
		await _combat.move_card(cell, dest)
		# await 后检查 aborted 或节点失效
		if _combat == null or _combat.aborted:
			return null
		if not is_instance_valid(board) or not is_instance_valid(dest):
			return null
		await _trigger_vigilance_on_board(dest, for_enemy, board)
		if _combat == null or _combat.aborted:
			return null
		if not is_instance_valid(board) or not is_instance_valid(dest) or not dest.has_card:
			return null

	if enemy_target != null:
		# step=+1 → 攻方朝 bottom 方向；step=-1 → 朝 top
		var dir_name: String = "bottom" if step > 0 else "top"
		var opp_name: String = "top" if step > 0 else "bottom"
		await _combat.attack_cells(dest, [{
			"cell": enemy_target, "dir": dir_name, "opp_dir": opp_name,
		}])
		if _combat == null or _combat.aborted:
			return null
	elif hit_hero and hero_resolver.is_valid():
		# PVP 锁步：见 _process_cell 同处注释，hero_resolver 天然对称，无需广播。
		hero_resolver.call(dest.attack, "unit_direct")
		await get_tree().create_timer(STEP_INTERVAL).timeout
		if _combat == null or _combat.aborted:
			return null

	return dest

# ── Spawn 阶段：每盘各自 advance ─────────────────────────────────────
func _run_spawn_phase() -> void:
	var reg := _registry()
	if reg == null:
		return
	var any_spawned: bool = false
	for slot in reg.slots:
		if slot.spawners == null or not is_instance_valid(slot.board):
			continue
		if slot.spawners.advance(slot.board, _card_resolver):
			any_spawned = true
	if any_spawned:
		await get_tree().create_timer(STEP_INTERVAL).timeout
# ── 警戒触发 ────────────────────────────────────────────────────────
func _trigger_vigilance_on_board(entered_cell, mover_for_enemy: bool,
		board: BoardModel) -> void:
	if not is_instance_valid(board) or entered_cell == null or not entered_cell.has_card:
		return
	for d in BoardModel.DIRECTIONS:
		var p: Vector2 = Vector2(entered_cell.row, entered_cell.col) + d.offset
		var sentinel = board.get_cell(p)
		if sentinel == null or not sentinel.has_card:
			continue
		# 哨兵只对敌方进入者反击：1v3 用 team_id；PVE/1v1 用 is_enemy
		var mover_is_hostile: bool
		if sentinel.team_id != "" and entered_cell.team_id != "":
			mover_is_hostile = (sentinel.team_id != entered_cell.team_id)
		else:
			mover_is_hostile = (sentinel.is_enemy != mover_for_enemy)
		if not mover_is_hostile:
			continue
		if not sentinel.effects.has("vigilance"):
			continue
		if not is_instance_valid(board) or not entered_cell.has_card:
			return
		await _combat.attack_cells(sentinel, [{
			"cell": entered_cell,
			"dir": d.name,
			"opp_dir": d.opp,
		}])
		# await 后检查 aborted 或节点失效
		if _combat == null or _combat.aborted:
			return
		if not is_instance_valid(board) or not is_instance_valid(entered_cell):
			return
