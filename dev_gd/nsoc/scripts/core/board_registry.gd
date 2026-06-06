class_name BoardRegistry
extends Node

# 集中管理所有活跃 BoardSlot。负责增删与查询。
# autoload Game 持有一个实例，TurnSystem / FrontRowSelector / PlayController 等
# 通过本注册表替代旧的 (Game.board, Game.hero, Game.spawners) 单例视图。

signal slot_added(slot: BoardSlot)
signal slot_removed(slot: BoardSlot)

var slots: Array = []             # Array[BoardSlot]
var _by_id: Dictionary = {}       # id -> BoardSlot

func add(slot: BoardSlot) -> void:
	if slot == null or slot.id == "":
		push_warning("BoardRegistry.add: invalid slot")
		return
	if _by_id.has(slot.id):
		return
	slots.append(slot)
	_by_id[slot.id] = slot
	slot_added.emit(slot)

func remove(slot_id: String) -> void:
	if not _by_id.has(slot_id):
		return
	var slot: BoardSlot = _by_id[slot_id]
	_by_id.erase(slot_id)
	slots.erase(slot)
	slot_removed.emit(slot)

func get_by_id(slot_id: String) -> BoardSlot:
	return _by_id.get(slot_id)

func get_by_board(board: BoardModel) -> BoardSlot:
	for s in slots:
		if s.board == board:
			return s
	return null

func by_faction(faction: int) -> Array:
	var out: Array = []
	for s in slots:
		if s.faction == faction:
			out.append(s)
	return out

func by_role(role: int) -> Array:
	var out: Array = []
	for s in slots:
		if s.role == role:
			out.append(s)
	return out

# 玩家本人盘（手牌锚点 / 英雄技能默认目标）。当前实现：取第一个 ROLE_MAIN_PLAYER。
func main_player() -> BoardSlot:
	for s in slots:
		if s.role == BoardSlot.ROLE_MAIN_PLAYER:
			return s
	return null

# 玩家可部署的盘（包含 MAIN_PLAYER + ALLY）
func deployable_for_player() -> Array:
	var out: Array = []
	for s in slots:
		if s.allow_player_deploy:
			out.append(s)
	return out

# 玩家单位可作为跨盘行动目标的盘（即所有敌方盘）
func enemy_targets() -> Array:
	return by_faction(BoardSlot.FACTION_ENEMY)

# 阶段遍历用排序：按视觉 x 升序（左→右）
func sorted_by_x() -> Array:
	var out: Array = slots.duplicate()
	out.sort_custom(func(a, b): return a.visual_x() < b.visual_x())
	return out

func clear() -> void:
	for s in slots.duplicate():
		remove(s.id)

# ── 多队伍扩展（1v3 / 3v3）──────────────────────────────────────────

# 取指定 team_id 的全部 slot
func by_team(team_id: String) -> Array:
	var out: Array = []
	for s in slots:
		if s.team_id == team_id:
			out.append(s)
	return out

# 按玩家 uuid 取其所属 slot（1v3 每人一盘）
func by_owner(player_id: String) -> BoardSlot:
	for s in slots:
		if s.owner_player_id == player_id:
			return s
	return null

# 取 viewer_pid 对面（敌队）中与给定列对齐的所有 slot。
# 同列跨盘攻击候选：守方→返回 3 攻方盘；攻方→返回 1 守方盘。
# 若 team_id 为空（PVE）回退到旧 FACTION_ENEMY 逻辑。
func adjacent_enemy_slots(viewer_pid: String, _col: int) -> Array:
	var viewer_team: String = Game.team_of_player(viewer_pid)
	if viewer_team == "":
		# PVE 兼容：返回全部 FACTION_ENEMY 盘
		return by_faction(BoardSlot.FACTION_ENEMY)
	var out: Array = []
	for s in slots:
		if s.team_id != "" and s.team_id != viewer_team:
			out.append(s)
	return out
