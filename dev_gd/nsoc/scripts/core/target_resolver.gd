class_name TargetResolver
extends RefCounted

# 目标解析工具。根据策略字符串 + 可选参数，从当前战场解析出目标 cell 或 HeroState。
# 全部为 static 方法，无状态，可直接调用。
#
# 行列约定（与 TurnSystem / BoardSlotFactory 一致）：
#   player_main row 2 = 前排（最靠近敌方）；row 0 = 后排
#   enemy_main  row 2 = 前排（最靠近玩家）；row 0 = 后排
# "frontmost" = 该阵营中 row 最大的有单位格（前排优先）。

# ── Cell 目标 ──────────────────────────────────────────────────────────────
# 返回 Cell 节点或 null。
static func resolve_cell(strategy: String, params: Dictionary = {}):
	match strategy:
		"frontmost_player_unit":
			return _frontmost_unit(BoardSlot.FACTION_PLAYER)
		"frontmost_enemy_unit":
			return _frontmost_unit(BoardSlot.FACTION_ENEMY)
		"random_player_unit":
			return _random_unit(BoardSlot.FACTION_PLAYER)
		"random_enemy_unit":
			return _random_unit(BoardSlot.FACTION_ENEMY)
		"fixed_cell":
			return _fixed_cell(params)
		_:
			if strategy != "":
				push_warning("TargetResolver: unknown strategy: " + strategy)
			return null

# 随机空格（用于 spawn_unit 的 "any_empty" 策略）。
# board_id 指定要找哪个盘的空格。
static func resolve_empty_cell(board_id: String):
	if not _has_game():
		return null
	var slot: BoardSlot = Game.registry.get_by_id(board_id)
	if slot == null or slot.board == null:
		return null
	var empties: Array = []
	for cell in slot.board.grid_cells.values():
		if is_instance_valid(cell) and not cell.has_card and not cell.is_phantom:
			empties.append(cell)
	if empties.is_empty():
		return null
	return empties[randi() % empties.size()]

# ── Hero 目标 ──────────────────────────────────────────────────────────────
# 返回 HeroState 或 null。
static func resolve_hero(strategy: String, _params: Dictionary = {}):
	if not _has_game():
		return null
	match strategy:
		"player_hero":
			return Game.player_hero()
		"enemy_hero":
			return Game.enemy_main_hero()
		_:
			return null

# ── 私有 ──────────────────────────────────────────────────────────────────

# 最前方单位（对阵营对手来说最靠近的那枚）。
#
# ◆ 棋盘方向约定（与 TurnSystem 注释吻合）：
#   player_main GridContainer：row 0 在视觉顶部（靠近场地中线/敌方），
#                               row 2 在视觉底部（靠近玩家英雄）。
#     → 玩家单位"推进度"：row 越小 = 越靠近敌方 = 得分越高。
#   enemy_main  GridContainer：row 0 在视觉顶部（靠近敌方英雄），
#                               row 2 在视觉底部（靠近场地中线/玩家）。
#     → 敌方单位"推进度"：row 越大 = 越靠近玩家 = 得分越高。
#
# ◆ 跨盘单位：已入侵对方棋盘的单位得分总高于待在本方棋盘的同阵营单位。
#   扫描范围：全盘（不限 slot.faction），用 cell.faction 识别阵营。
#
# 返回推进分数最高（分数相同随机取列）的 Cell；无则返回 null。
static func _frontmost_unit(faction: int):
	if not _has_game():
		return null
	var best_score: int = -1
	var candidates:  Array = []
	for slot in Game.registry.slots:
		if not is_instance_valid(slot) or slot.board == null:
			continue
		var is_home_board: bool = (slot.faction == faction)
		for cell in slot.board.grid_cells.values():
			if not is_instance_valid(cell) or not cell.has_card or cell.is_phantom:
				continue
			# cell.faction 识别阵营（排除跨盘入侵的对方单位）
			if cell.faction != faction:
				continue
			var score: int = _front_score(cell.row, is_home_board, faction)
			if score > best_score:
				best_score = score
				candidates = [cell]
			elif score == best_score:
				candidates.append(cell)
	if candidates.is_empty():
		return null
	return candidates[randi() % candidates.size()]

# 计算单位的"推进分数"（分数越高 = 越靠近对手 = 越应被优先选为目标）。
# is_home_board：该格子所属盘是否为本阵营主盘；跨入对方盘的单位分数自动高于本方盘。
const _ROWS: int = 3
static func _front_score(row: int, is_home_board: bool, faction: int) -> int:
	if faction == BoardSlot.FACTION_PLAYER:
		# 玩家单位：row 越小 = 越靠近敌方；跨入敌盘 = 额外加 _ROWS 偏移
		var base: int = (_ROWS - 1) - row   # row 0 → 2, row 2 → 0
		return base if is_home_board else (_ROWS + base)
	else:
		# 敌方单位：row 越大 = 越靠近玩家；跨入玩家盘 = 额外加 _ROWS 偏移
		var base: int = row                  # row 0 → 0, row 2 → 2
		return base if is_home_board else (_ROWS + base)

# 随机有单位格（指定阵营，扫全盘，cell.faction 过滤）。
static func _random_unit(faction: int):
	if not _has_game():
		return null
	var cells: Array = []
	for slot in Game.registry.slots:
		if not is_instance_valid(slot) or slot.board == null:
			continue
		for cell in slot.board.grid_cells.values():
			if not is_instance_valid(cell) or not cell.has_card or cell.is_phantom:
				continue
			if cell.faction != faction:
				continue
			cells.append(cell)
	if cells.is_empty():
		return null
	return cells[randi() % cells.size()]

# 固定坐标格：params 需含 board / row / col。
static func _fixed_cell(params: Dictionary):
	if not _has_game():
		return null
	var board_id: String = String(params.get("board", ""))
	var row: int         = int(params.get("row", 0))
	var col: int         = int(params.get("col", 0))
	var slot: BoardSlot  = Game.registry.get_by_id(board_id)
	if slot == null or slot.board == null:
		return null
	return slot.board.get_cell(Vector2(row, col))

static func _has_game() -> bool:
	var loop = Engine.get_main_loop()
	return loop != null and loop.root != null and loop.root.has_node("/root/Game")
