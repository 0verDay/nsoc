class_name TurnSystem
extends Node

# 把 main.gd 的 run_turn_sequence 抽出。
# 战斗动画/伤害结算仍委托给传入的 combat_handler（保留旧 attack_cells / move_card 行为）。

signal turn_started
signal turn_ended
signal phase_started(faction: int)
signal phase_ended(faction: int)
# 玩家前排棋子即将行动：等待外部调用 resolve_front_row_selection(target_id) 后继续。
# target_id: "" = 本棋盘（走默认逻辑），其他字符串 = 外部注册的棋盘标识。
signal front_row_action_requested(cell: Node)

const PLAYER: int = 0
const ENEMY: int = 1
const STEP_INTERVAL: float = 0.5

# 玩家前排：玩家半场紧邻中线的行
const PLAYER_FRONT_ROW: int = 3

var is_running: bool = false

var _board: BoardModel
var _combat: CombatSystem               # 提供 attack_cells / move_card / apply_damage_to_hero
var _spawners: SpawnerSystem
var _card_resolver: Callable

# 前排选择回调：由外部（test_main）赋值。
var _front_row_resolve: Callable = Callable()
# 前排选择结果：外部 resolve 写入，_run_front_row_selection 轮询读取。
var _front_row_result: String = ""
var _front_row_resolved: bool = false

# 额外棋盘列表。每项：{ "board": BoardModel, "hero_resolver": Callable }
# hero_resolver(is_enemy: bool, damage: int) —— 单位到达 goal_row 时调用。
var _extra_board_configs: Array = []

func setup(board: BoardModel, combat: CombatSystem, spawners: SpawnerSystem, card_resolver: Callable) -> void:
	_board = board
	_combat = combat
	_spawners = spawners
	_card_resolver = card_resolver

# 注册额外棋盘参与遍历。hero_resolver 处理该棋盘的英雄伤害。
func register_extra_board(board: BoardModel, hero_resolver: Callable) -> void:
	for cfg in _extra_board_configs:
		if cfg["board"] == board:
			return   # 已注册，幂等
	_extra_board_configs.append({"board": board, "hero_resolver": hero_resolver})

# 注销额外棋盘。
func unregister_extra_board(board: BoardModel) -> void:
	_extra_board_configs = _extra_board_configs.filter(
		func(cfg): return cfg["board"] != board)

# 外部（test_main）调用：玩家完成棋盘选择后，传入棋盘标识（"" = 本棋盘）。
func resolve_front_row_selection(target_id: String) -> void:
	_front_row_result = target_id
	_front_row_resolved = true

func run() -> void:
	is_running = true
	turn_started.emit()
	await _run_phase(PLAYER)
	await _run_spawn_phase()
	await _run_phase(ENEMY)
	_board.reset_attack_flags()
	for cfg in _extra_board_configs:
		if is_instance_valid(cfg["board"]):
			cfg["board"].reset_attack_flags()
	_spawners.refresh_phantoms(_board, _card_resolver)
	is_running = false
	turn_ended.emit()

func _run_phase(faction: int) -> void:
	phase_started.emit(faction)

	# 主棋盘
	await _run_phase_on_board(faction, _board,
		Callable(_combat, "apply_damage_to_hero"))

	# 额外棋盘（按注册顺序遍历）
	for cfg in _extra_board_configs:
		if is_instance_valid(cfg["board"]):
			await _run_phase_on_board(faction, cfg["board"], cfg["hero_resolver"])

	phase_ended.emit(faction)

# 对单块棋盘执行一个阵营的行动阶段。
# hero_resolver: Callable(is_enemy: bool, damage: int)
func _run_phase_on_board(faction: int, board: BoardModel,
		hero_resolver: Callable) -> void:
	var for_enemy: bool = faction == ENEMY
	var step: int = 1 if faction == PLAYER else -1
	var goal_row: int = BoardModel.ENEMY_LAST_ROW if faction == PLAYER else BoardModel.PLAYER_LAST_ROW

	for cell in board.iter_cells(faction):
		if not cell.has_card or cell.has_attacked:
			continue
		var is_my_unit: bool = (cell.is_enemy == for_enemy)
		if not is_my_unit:
			continue

		# ── 前排选择机制（仅主棋盘玩家前排触发）──────────────────────
		var front_row_target_id: String = ""
		if faction == PLAYER and board == _board and cell.row == PLAYER_FRONT_ROW:
			front_row_target_id = await _run_front_row_selection(cell)

		if front_row_target_id != "":
			if _front_row_resolve.is_valid():
				await _front_row_resolve.call(cell, front_row_target_id)
			cell.has_attacked = true
			continue

		# ── 冲锋 ────────────────────────────────────────────────────────
		if cell.effects.has("charge") and not cell.has_charged:
			var ended_cell = await _run_charge_on_board(cell, step, for_enemy,
				goal_row, board, hero_resolver)
			if ended_cell != null:
				ended_cell.has_attacked = true
				ended_cell.has_charged = true
			continue

		# ── 常规：攻击 → 打英雄 → 移动 ────────────────────────────────
		var enemies := board.find_adjacent_enemies(cell, for_enemy)
		if enemies.size() > 0:
			await _combat.attack_cells(cell, enemies)
			cell.has_attacked = true
			continue

		if cell.row == goal_row:
			hero_resolver.call(not for_enemy, cell.attack)
			cell.has_attacked = true
			await _combat.get_tree().create_timer(STEP_INTERVAL).timeout
			continue

		var target_r: int = cell.row - step
		var target = board.get_cell(Vector2(target_r, cell.col))
		if target and not target.has_card:
			if cell.effects.has("steadfast"):
				continue
			await _combat.move_card(cell, target)
			target.has_attacked = true
			await _combat.get_tree().create_timer(STEP_INTERVAL).timeout
			await _trigger_vigilance_on_board(target, for_enemy, board)

# ── 前排选择等待 ──────────────────────────────────────────────────────
func _run_front_row_selection(cell: Node) -> String:
	_front_row_resolved = false
	_front_row_result = ""
	front_row_action_requested.emit(cell)
	while not _front_row_resolved:
		await _combat.get_tree().process_frame
	return _front_row_result

# ── 冲锋（board 参数化版本）─────────────────────────────────────────
func _run_charge_on_board(cell, step: int, for_enemy: bool, goal_row: int,
		board: BoardModel, hero_resolver: Callable):
	if cell.row == goal_row:
		hero_resolver.call(not for_enemy, cell.attack)
		await _combat.get_tree().create_timer(STEP_INTERVAL).timeout
		return cell

	var dest = cell
	var enemy_target = null
	var hit_hero: bool = false
	var probe_r: int = cell.row - step
	while probe_r >= 0 and probe_r < BoardModel.ROWS:
		var next_cell = board.get_cell(Vector2(probe_r, cell.col))
		if next_cell == null:
			break
		if next_cell.has_card:
			if next_cell.is_enemy == for_enemy:
				break
			enemy_target = next_cell
			break
		dest = next_cell
		if dest.row == goal_row:
			hit_hero = true
			break
		probe_r -= step

	if dest != cell:
		await _combat.move_card(cell, dest)
		await _combat.get_tree().create_timer(STEP_INTERVAL).timeout
		await _trigger_vigilance_on_board(dest, for_enemy, board)
		if not dest.has_card:
			return null

	if enemy_target != null:
		var dir_name: String = "top" if step == 1 else "bottom"
		var opp_name: String = "bottom" if step == 1 else "top"
		await _combat.attack_cells(dest, [{
			"cell": enemy_target, "dir": dir_name, "opp_dir": opp_name,
		}])
	elif hit_hero:
		hero_resolver.call(not for_enemy, dest.attack)
		await _combat.get_tree().create_timer(STEP_INTERVAL).timeout

	return dest

func _run_spawn_phase() -> void:
	var any_spawned := _spawners.advance(_board, _card_resolver)
	if any_spawned:
		await _combat.get_tree().create_timer(STEP_INTERVAL).timeout

# ── 警戒触发（board 参数化版本）─────────────────────────────────────
func _trigger_vigilance_on_board(entered_cell, mover_for_enemy: bool,
		board: BoardModel) -> void:
	if entered_cell == null or not entered_cell.has_card:
		return
	for d in BoardModel.DIRECTIONS:
		var p: Vector2 = Vector2(entered_cell.row, entered_cell.col) + d.offset
		var sentinel = board.get_cell(p)
		if sentinel == null or not sentinel.has_card:
			continue
		if sentinel.is_enemy == mover_for_enemy:
			continue
		if not sentinel.effects.has("vigilance"):
			continue
		if not entered_cell.has_card:
			return
		await _combat.attack_cells(sentinel, [{
			"cell": entered_cell,
			"dir": d.name,
			"opp_dir": d.opp,
		}])

# 旧接口兼容 —— 主棋盘版本，供外部直接调用
func _trigger_vigilance(entered_cell, mover_for_enemy: bool) -> void:
	await _trigger_vigilance_on_board(entered_cell, mover_for_enemy, _board)

func _run_charge(cell, step: int, for_enemy: bool, goal_row: int):
	return await _run_charge_on_board(cell, step, for_enemy, goal_row,
		_board, Callable(_combat, "apply_damage_to_hero"))
