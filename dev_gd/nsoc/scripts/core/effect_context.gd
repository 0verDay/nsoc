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
func board() -> BoardModel:
	return game.board

func combat() -> CombatSystem:
	return game.combat

func turn() -> TurnSystem:
	return game.turn

# ---- 棋盘查询 ----
# 返回 cell 四邻"有牌"的 cell 数组。phantom 不计入。
func get_adjacent_occupied(cell) -> Array:
	var out: Array = []
	if cell == null:
		return out
	var base := Vector2(cell.row, cell.col)
	for d in BoardModel.DIRECTIONS:
		var p: Vector2 = base + d.offset
		var c = game.board.get_cell(p)
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
	var mover_for_enemy: bool = entered_cell.is_enemy
	for d in BoardModel.DIRECTIONS:
		var p: Vector2 = Vector2(entered_cell.row, entered_cell.col) + d.offset
		var sentinel = game.board.get_cell(p)
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
# 自动按 dying_is_enemy 路由到玩家或敌方对应区。
func banish_card(card_data) -> void:
	if dying_is_enemy:
		game.deck.enemy_banish(card_data)
	else:
		game.deck.banish(card_data)

func send_to_graveyard(card_data) -> void:
	if dying_is_enemy:
		game.deck.enemy_send_to_graveyard(card_data)
	else:
		game.deck.send_to_graveyard(card_data)

# ---- 英雄伤害 ----
func damage_player_hero(amount: int) -> void:
	game.hero.apply_damage(false, amount)

func damage_enemy_hero(amount: int) -> void:
	game.hero.apply_damage(true, amount)

# ---- 通用计数器（替代 main.autophagy_counter 这种零散字段） ----
func get_counter(key: String, default_value: int = 0) -> int:
	return game.counters.get(key, default_value)

func set_counter(key: String, value: int) -> void:
	game.counters[key] = value

func inc_counter(key: String, delta: int = 1) -> int:
	var v = get_counter(key, 0) + delta
	game.counters[key] = v
	return v
