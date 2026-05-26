class_name EffectContext
extends RefCounted

# 传给 Effect.on_play / on_death 的轻量门面。
# 把"main_node 万能上帝对象"替换为受限接口，便于测试与替换实现。
#
# 旧代码中 effect 直接读写 main_node.banished / main_node.autophagy_counter，
# 现在改为通过 ctx 调用 banish_card() / get_counter() 等显式 API。

var game: Node                       # GameContext 引用
var target_cell = null               # 法术指向目标 cell（无目标法术为 null）
var dying_is_enemy: bool = false     # 进入 on_death 流程时由 PlayController 设置；
                                      # banish_card / send_to_graveyard 据此路由阵营牌堆。

func _init(p_game: Node) -> void:
	game = p_game

# ---- 便捷子系统访问 ----
# 多盘语义：board()/cell 反查所属 slot 的 BoardModel。无 cell 时回退到主玩家盘。
func board_of(cell) -> BoardModel:
	var slot: BoardSlot = _slot_of(cell)
	if slot != null:
		return slot.board
	var main_slot: BoardSlot = game.main_player_slot()
	return main_slot.board if main_slot != null else null

# 兼容旧调用：board() 返回 cell 所属盘；无目标 cell 时回退主玩家盘。
func board() -> BoardModel:
	return board_of(target_cell)

func combat() -> CombatSystem:
	return game.combat

func turn() -> TurnSystem:
	return game.turn

func _slot_of(cell) -> BoardSlot:
	if cell == null or game == null or game.registry == null:
		return null
	if cell.slot_id != "":
		return game.registry.get_by_id(cell.slot_id)
	return null

# ---- 棋盘查询 ----
# 返回 cell 四邻"有牌"的 cell 数组。phantom 不计入。
func get_adjacent_occupied(cell) -> Array:
	var out: Array = []
	if cell == null:
		return out
	var b: BoardModel = board_of(cell)
	if b == null:
		return out
	var base := Vector2(cell.row, cell.col)
	for d in BoardModel.DIRECTIONS:
		var p: Vector2 = base + d.offset
		var c = b.get_cell(p)
		if c != null and c.has_card:
			out.append(c)
	return out

# 返回 cell 四邻处于敌对阵营且有牌的 cell 数组。
func get_adjacent_enemies(cell) -> Array:
	var out: Array = []
	if cell == null:
		return out
	for c in get_adjacent_occupied(cell):
		if c.is_enemy != cell.is_enemy:
			out.append(c)
	return out

# 警戒哨反应：扫 entered_cell 四邻含 "vigilance" 的敌方单位，依次对其攻击。
# 与 TurnSystem._trigger_vigilance 同语义，供效果脚本（如冲阵移动后）复用。
func trigger_vigilance(entered_cell) -> void:
	if entered_cell == null or not entered_cell.has_card:
		return
	var b: BoardModel = board_of(entered_cell)
	if b == null:
		return
	var mover_for_enemy: bool = entered_cell.is_enemy
	for d in BoardModel.DIRECTIONS:
		var p: Vector2 = Vector2(entered_cell.row, entered_cell.col) + d.offset
		var sentinel = b.get_cell(p)
		if sentinel == null or not sentinel.has_card:
			continue
		if sentinel.is_enemy == mover_for_enemy:
			continue
		if not sentinel.effects.has("vigilance"):
			continue
		if not entered_cell.has_card:
			return
		await game.combat.attack_cells(sentinel, [{
			"cell": entered_cell,
			"dir": d.name,
			"opp_dir": d.opp,
		}])

# ---- 卡牌去向 ----
# 自动按 dying_is_enemy 路由：
#   玩家阵营 → game.deck（玩家个人牌堆）
#   敌方阵营 → target_cell 所属 slot 的 graveyard / banished
func banish_card(card_data) -> void:
	if dying_is_enemy:
		var slot: BoardSlot = _slot_of(target_cell)
		if slot != null:
			slot.banish(card_data)
	else:
		game.deck.banish(card_data)

func send_to_graveyard(card_data) -> void:
	if dying_is_enemy:
		var slot: BoardSlot = _slot_of(target_cell)
		if slot != null:
			slot.send_to_graveyard(card_data)
	else:
		game.deck.send_to_graveyard(card_data)

# ---- 英雄伤害 ----
# 多盘语义下默认作用于"主玩家盘 / 主敌盘"的 hero。需要指定其他盘时
# 使用 damage_slot_hero(slot_id, amount)。
func damage_player_hero(amount: int) -> void:
	var slot: BoardSlot = game.main_player_slot()
	if slot != null:
		slot.damage_hero(amount)

func damage_enemy_hero(amount: int) -> void:
	if game.registry == null:
		return
	for slot in game.registry.by_role(BoardSlot.ROLE_MAIN_ENEMY):
		slot.damage_hero(amount)
		return

func damage_slot_hero(slot_id: String, amount: int) -> void:
	if game.registry == null:
		return
	var slot: BoardSlot = game.registry.get_by_id(slot_id)
	if slot != null:
		slot.damage_hero(amount)

# ---- 通用计数器（替代 main.autophagy_counter 这种零散字段） ----
func get_counter(key: String, default_value: int = 0) -> int:
	return game.counters.get(key, default_value)

func set_counter(key: String, value: int) -> void:
	game.counters[key] = value

func inc_counter(key: String, delta: int = 1) -> int:
	var v = get_counter(key, 0) + delta
	game.counters[key] = v
	return v
