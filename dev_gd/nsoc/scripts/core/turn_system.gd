class_name TurnSystem
extends Node

# 把 main.gd 的 run_turn_sequence 抽出。
# 战斗动画/伤害结算仍委托给传入的 combat_handler（保留旧 attack_cells / move_card 行为）。

signal turn_started
signal turn_ended
signal phase_started(faction: int)
signal phase_ended(faction: int)

const PLAYER: int = 0
const ENEMY: int = 1
const STEP_INTERVAL: float = 0.5

var is_running: bool = false

var _board: BoardModel
var _combat: CombatSystem               # 提供 attack_cells / move_card / apply_damage_to_hero
var _spawners: SpawnerSystem
var _card_resolver: Callable

func setup(board: BoardModel, combat: CombatSystem, spawners: SpawnerSystem, card_resolver: Callable) -> void:
	_board = board
	_combat = combat
	_spawners = spawners
	_card_resolver = card_resolver

func run() -> void:
	is_running = true
	turn_started.emit()
	await _run_phase(PLAYER)
	await _run_spawn_phase()
	await _run_phase(ENEMY)
	_board.reset_attack_flags()
	_spawners.refresh_phantoms(_board, _card_resolver)
	is_running = false
	turn_ended.emit()

func _run_phase(faction: int) -> void:
	phase_started.emit(faction)
	var for_enemy: bool = faction == ENEMY
	var step: int = 1 if faction == PLAYER else -1
	var goal_row: int = BoardModel.ENEMY_LAST_ROW if faction == PLAYER else BoardModel.PLAYER_LAST_ROW

	for cell in _board.iter_cells(faction):
		if not cell.has_card or cell.has_attacked:
			continue
		var is_my_unit: bool = (cell.is_enemy == for_enemy)
		if not is_my_unit:
			continue

		# 冲锋：仅本场首次行动触发，沿前进方向连步移动直到前方有敌再攻击。
		# 触发后置 has_charged=true 阻止后续再次触发；徽章保留作视觉提示。
		if cell.effects.has("charge") and not cell.has_charged:
			var ended_cell = await _run_charge(cell, step, for_enemy, goal_row)
			if ended_cell != null:
				ended_cell.has_attacked = true
				ended_cell.has_charged = true
			continue

		var enemies := _board.find_adjacent_enemies(cell, for_enemy)
		if enemies.size() > 0:
			await _combat.attack_cells(cell, enemies)
			cell.has_attacked = true
			continue

		if cell.row == goal_row:
			# 已到对方英雄前一行：直接攻击英雄
			_combat.apply_damage_to_hero(not for_enemy, cell.attack)
			cell.has_attacked = true
			await _combat.get_tree().create_timer(STEP_INTERVAL).timeout
			continue

		var target_r: int = cell.row - step
		if target_r >= 0 and target_r < BoardModel.ROWS:
			# "坚守"：阶段推进时不主动移动（仍可攻击邻敌/英雄）。
			if cell.effects.has("steadfast"):
				continue
			var target = _board.get_cell(Vector2(target_r, cell.col))
			if target and not target.has_card:
				await _combat.move_card(cell, target)
				target.has_attacked = true
				await _combat.get_tree().create_timer(STEP_INTERVAL).timeout
				# 警戒哨反应。移动者可能阵亡 → 终止本 cell 后续逻辑（此分支已无后续）。
				await _trigger_vigilance(target, for_enemy)

	phase_ended.emit(faction)

# 冲锋：先扫描沿 -step 方向终点，一次性移动到终点，再结算。
#   起点已在 goal_row → 直接打英雄（无移动）
#   路径全空至 goal_row → 一步移到 goal_row 后打英雄
#   遇敌 → 一步移到敌人前一格，对该敌发起攻击
#   遇己方/越界 → 一步移到障碍前一格（若起点即终点则不移动）
# 返回最终所在 cell（用于设置 has_attacked）。
func _run_charge(cell, step: int, for_enemy: bool, goal_row: int):
	# 起点已到底线：直接打英雄。
	if cell.row == goal_row:
		_combat.apply_damage_to_hero(not for_enemy, cell.attack)
		await _combat.get_tree().create_timer(STEP_INTERVAL).timeout
		return cell

	# 扫描路径，确定终点 cell + 终点动作。
	var dest = cell
	var enemy_target = null
	var hit_hero: bool = false
	var probe_r: int = cell.row - step
	while probe_r >= 0 and probe_r < BoardModel.ROWS:
		var next_cell = _board.get_cell(Vector2(probe_r, cell.col))
		if next_cell == null:
			break
		if next_cell.has_card:
			if next_cell.is_enemy == for_enemy:
				# 前方己方：停在前一格
				break
			# 前方敌方：终点为前一格，记录攻击目标
			enemy_target = next_cell
			break
		# 空格：可推进至此
		dest = next_cell
		if dest.row == goal_row:
			hit_hero = true
			break
		probe_r -= step

	# 一次性移动
	if dest != cell:
		await _combat.move_card(cell, dest)
		await _combat.get_tree().create_timer(STEP_INTERVAL).timeout
		# 警戒哨反应：移动落点的四邻敌方警戒单位先打一发。
		# 若冲锋单位被打死则终止后续结算。
		await _trigger_vigilance(dest, for_enemy)
		if not dest.has_card:
			return null

	# 终点结算
	if enemy_target != null:
		var dir_name: String = "top" if step == 1 else "bottom"
		var opp_name: String = "bottom" if step == 1 else "top"
		await _combat.attack_cells(dest, [{
			"cell": enemy_target,
			"dir": dir_name,
			"opp_dir": opp_name,
		}])
	elif hit_hero:
		_combat.apply_damage_to_hero(not for_enemy, dest.attack)
		await _combat.get_tree().create_timer(STEP_INTERVAL).timeout

	return dest

func _run_spawn_phase() -> void:
	var any_spawned := _spawners.advance(_board, _card_resolver)
	if any_spawned:
		await _combat.get_tree().create_timer(STEP_INTERVAL).timeout

# 警戒触发：扫描 entered_cell 四邻，找含 "vigilance" 且阵营与移动者相对的单位，
# 由它们对 entered_cell 各发起一次攻击。
# mover_for_enemy = true 表示移动者属于敌方阵营；警戒哨即玩家方单位（反之亦然）。
# 移动者死亡后立即停止后续警戒哨触发，避免对空格继续攻击。
func _trigger_vigilance(entered_cell, mover_for_enemy: bool) -> void:
	if entered_cell == null or not entered_cell.has_card:
		return
	var dir_name_for_mover: String  # 警戒哨相对 entered_cell 的方位 = entered_cell 受击方向
	for d in BoardModel.DIRECTIONS:
		var p: Vector2 = Vector2(entered_cell.row, entered_cell.col) + d.offset
		var sentinel = _board.get_cell(p)
		if sentinel == null or not sentinel.has_card:
			continue
		# 警戒哨阵营须与移动者相对
		if sentinel.is_enemy == mover_for_enemy:
			continue
		if not sentinel.effects.has("vigilance"):
			continue
		# 移动者已死则停止后续哨兵触发
		if not entered_cell.has_card:
			return
		# entered_cell 被击中的方向 = 警戒哨方位的对位
		dir_name_for_mover = d.opp
		await _combat.attack_cells(sentinel, [{
			"cell": entered_cell,
			"dir": d.name,
			"opp_dir": dir_name_for_mover,
		}])
