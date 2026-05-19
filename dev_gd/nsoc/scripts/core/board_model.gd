class_name BoardModel
extends Node

# 抽象棋盘。持有 grid_cells 引用并提供邻接查询。
# 不直接处理 UI；由调用方传入 cell 节点。

const ROWS: int = 6
const COLS: int = 3
const PLAYER_LAST_ROW: int = 5     # 玩家可下单位区域最大 row（>=3 即玩家半场）
const ENEMY_LAST_ROW: int = 0      # 攻击英雄的判定行

var grid_cells: Dictionary = {}    # Vector2(r,c) -> Cell node

# 四向：dir 名称 ↔ 偏移 ↔ 对位面
const DIRECTIONS: Array = [
	{"name": "top",    "offset": Vector2(-1, 0), "opp": "bottom"},
	{"name": "bottom", "offset": Vector2( 1, 0), "opp": "top"},
	{"name": "left",   "offset": Vector2(0, -1), "opp": "right"},
	{"name": "right",  "offset": Vector2(0,  1), "opp": "left"},
]

func register_cell(cell: Node) -> void:
	grid_cells[Vector2(cell.row, cell.col)] = cell

func get_cell(pos: Vector2):
	return grid_cells.get(pos)

# 按行迭代 cell。faction=0 玩家正向(0→5)，faction=1 敌方逆向(5→0)。
func iter_cells(faction: int) -> Array:
	var out: Array = []
	if faction == 0:
		for r in range(ROWS):
			for c in range(COLS):
				out.append(grid_cells[Vector2(r, c)])
	else:
		for r in range(ROWS - 1, -1, -1):
			for c in range(COLS - 1, -1, -1):
				out.append(grid_cells[Vector2(r, c)])
	return out

# 寻找相邻敌人。for_enemy=true 表示发起者是敌方。
func find_adjacent_enemies(cell, for_enemy: bool) -> Array:
	var found: Array = []
	var base := Vector2(cell.row, cell.col)
	for d in DIRECTIONS:
		var p: Vector2 = base + d.offset
		if not grid_cells.has(p):
			continue
		var tgt = grid_cells[p]
		if not tgt.has_card:
			continue
		var is_target_enemy: bool = tgt.is_enemy
		if for_enemy and not is_target_enemy:
			found.append({"cell": tgt, "dir": d.name, "opp_dir": d.opp})
		elif not for_enemy and is_target_enemy:
			found.append({"cell": tgt, "dir": d.name, "opp_dir": d.opp})
	return found

func reset_attack_flags() -> void:
	for cell in grid_cells.values():
		cell.has_attacked = false
