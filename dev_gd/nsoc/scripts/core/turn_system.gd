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
			var target = _board.get_cell(Vector2(target_r, cell.col))
			if target and not target.has_card:
				await _combat.move_card(cell, target)
				target.has_attacked = true
				await _combat.get_tree().create_timer(STEP_INTERVAL).timeout

	phase_ended.emit(faction)

func _run_spawn_phase() -> void:
	var any_spawned := _spawners.advance(_board, _card_resolver)
	if any_spawned:
		await _combat.get_tree().create_timer(STEP_INTERVAL).timeout
