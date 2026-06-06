class_name BoardModel
extends Node

# 抽象棋盘。3×3 的纯数据层，持有 grid_cells 并提供邻接查询。
# 不直接处理 UI / 阵营；由调用方（BoardSlot）注入 cell 与 faction。
#
# 行号语义（与 Orientation 协调，无视觉绑定）：
#   row 0 = 后排（back）   单位站在自家最深处
#   row 2 = 前排（front）  靠近敌人，跨棋盘起跳点
#   col 0..2 = 玩家视角左→右

const ROWS: int = 3
const COLS: int = 3

var grid_cells: Dictionary = {}    # Vector2(r,c) -> Cell node

# 四向：dir 名称 ↔ 偏移 ↔ 对位面（屏幕绝对方向，cell 邻接物理坐标）
const DIRECTIONS: Array = [
	{"name": "top",    "offset": Vector2(-1, 0), "opp": "bottom"},
	{"name": "bottom", "offset": Vector2( 1, 0), "opp": "top"},
	{"name": "left",   "offset": Vector2(0, -1), "opp": "right"},
	{"name": "right",  "offset": Vector2(0,  1), "opp": "left"},
]

# 前/后排索引按阵营决定（视觉上"前=朝向对面"、"后=自家底线/英雄所在"）：
#   玩家阵营盘：row 0=前排（视觉上/朝中线），row 2=后排（视觉下/玩家英雄所在）
#   敌方阵营盘：row 0=后排（视觉上/敌方英雄所在），row 2=前排（视觉下/朝中线）
# 单位向 front_row 推进；到达对面盘的 back_row 时攻击对面英雄。
const FACTION_PLAYER: int = 0
const FACTION_ENEMY: int = 1

static func front_row_of(faction: int) -> int:
	return 0 if faction == FACTION_PLAYER else ROWS - 1

static func back_row_of(faction: int) -> int:
	return ROWS - 1 if faction == FACTION_PLAYER else 0

# 按 BoardSlot 取前排索引。1v3 中用 team_id 决定方向；PVE 回退 faction。
# defender 盘：row 0 朝上攻击攻方 → front=0
# attacker 盘：row 2 朝下攻击守方 → front=ROWS-1
static func front_row_of_slot(slot: BoardSlot) -> int:
	if slot.team_id == "defender":
		return 0
	elif slot.team_id == "attacker":
		return 0   # 攻方也向 row=0 推进，与守方同方向（都朝上对面）
	return front_row_of(slot.faction)

static func back_row_of_slot(slot: BoardSlot) -> int:
	if slot.team_id == "defender":
		return ROWS - 1
	elif slot.team_id == "attacker":
		return ROWS - 1
	return back_row_of(slot.faction)

# 推进方向（向 front 走）：defender/attacker 均 step=-1（向 row=0）；PVE/1v1 回退 faction
static func step_of_slot(slot: BoardSlot) -> int:
	if slot.team_id == "defender" or slot.team_id == "attacker":
		return -1   # 全员向 row=0 推进（自家盘）
	return -1 if slot.faction == FACTION_PLAYER else 1

# 推进方向（向 front 走）：玩家 -1（row 减小），敌方 +1（row 增大）
static func step_of(faction: int) -> int:
	return -1 if faction == FACTION_PLAYER else 1

# 兼容旧无参数 API（若仍被外部调用）：返回不区分阵营的"上排"——保留语义最近的值。
# 新代码应使用 front_row_of(faction)。
func front_row() -> int:
	return ROWS - 1

func back_row() -> int:
	return 0

func is_front_row(r: int) -> bool:
	return r == ROWS - 1

func is_back_row(r: int) -> bool:
	return r == 0

func register_cell(cell: Node) -> void:
	grid_cells[Vector2(cell.row, cell.col)] = cell

func get_cell(pos: Vector2):
	return grid_cells.get(pos)

# 按行迭代 cell。faction=0（PLAYER）按 row 0→ROWS-1（后排到前排）；
# faction=1（ENEMY）按 row ROWS-1→0（也是从后排到前排，因为敌方盘 row=0 也是后排）。
# 注意：行内列方向沿用旧约定：PLAYER col 0→2，ENEMY col 2→0（"自身视角的左→右"）。
func iter_cells(faction: int) -> Array:
	var out: Array = []
	if faction == 0:
		for r in range(ROWS):
			for c in range(COLS):
				var key := Vector2(r, c)
				if grid_cells.has(key):
					out.append(grid_cells[key])
	else:
		for r in range(ROWS - 1, -1, -1):
			for c in range(COLS - 1, -1, -1):
				var key := Vector2(r, c)
				if grid_cells.has(key):
					out.append(grid_cells[key])
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
		# 1v3：用 team_id 判断友敌，避免同队互打
		# PVE/1v1：回退 is_enemy
		var is_hostile: bool
		if cell.team_id != "" and tgt.team_id != "":
			is_hostile = (tgt.team_id != cell.team_id)
		else:
			var is_target_enemy: bool = tgt.is_enemy
			if for_enemy and not is_target_enemy:
				is_hostile = true
			elif not for_enemy and is_target_enemy:
				is_hostile = true
			else:
				is_hostile = false
		if is_hostile:
			found.append({"cell": tgt, "dir": d.name, "opp_dir": d.opp})
	return found

func reset_attack_flags() -> void:
	for cell in grid_cells.values():
		cell.has_attacked = false
		cell.has_charged = false

# 按关卡配置摆放初始单位。configs 来自 DataLoader 输出（每盘自己的子集）。
# 配置项 positions 已是 Vector2(row,col)，row 0..2。
# is_enemy_default：当 cfg 未显式给 faction 时按本盘默认决定 cell.is_enemy。
func populate_initial_units(configs: Array, card_resolver: Callable,
		is_enemy_default: bool = false) -> void:
	for cfg in configs:
		var cdata = card_resolver.call(cfg.name)
		if cdata == null:
			continue
		var enemy_flag: bool = is_enemy_default
		if cfg.has("faction"):
			enemy_flag = (int(cfg.faction) == 1)
		for pos in cfg.positions:
			var cell = get_cell(pos)
			if cell:
				# origin = "initial"：关卡初始铺盘。死亡入 cell 所属盘墓地。
				cell.set_card(cdata.name, cdata.attack, cdata.health, enemy_flag, cdata.effects, "", "initial")

# ── 序列化（PVP 联机用）────────────────────────────────────────────
# 序列化所有 grid_cells 中的 cell 数据。键用 "r,c" 字符串（JSON 兼容）。
func to_dict() -> Dictionary:
	var cells: Dictionary = {}
	for key in grid_cells.keys():
		var cell = grid_cells[key]
		if cell == null:
			continue
		var k_str: String = "%d,%d" % [int(key.x), int(key.y)]
		cells[k_str] = cell.to_dict()
	return {"cells": cells}

# 在已建好的 board（grid_cells 已注册空 Cell）上原地恢复。
func from_dict(d: Dictionary) -> void:
	var cells = d.get("cells", {})
	if typeof(cells) != TYPE_DICTIONARY:
		return
	for k_str in cells.keys():
		var parts: PackedStringArray = String(k_str).split(",")
		if parts.size() != 2:
			continue
		var key := Vector2(int(parts[0]), int(parts[1]))
		var cell = grid_cells.get(key)
		if cell == null:
			continue
		var entry = cells[k_str]
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		cell.from_dict(entry)
