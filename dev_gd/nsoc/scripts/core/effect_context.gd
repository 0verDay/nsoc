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
# 英雄技能上下文
var hand_view = null                 # HandView 引用（restart 等技能用）
var hero: HeroState = null           # 本次激活的 HeroState

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

# 取单位"原属盘"。死亡入墓 / banish 等去向相关查询应优先用此函数，
# 跨盘冲锋后单位死亡时按归属入原属盘墓地，而非新盘。
# 原属盘已销毁时返回 null（调用方按需静默丢弃）。
func _owner_slot_of(cell) -> BoardSlot:
	if cell == null or game == null or game.registry == null:
		return null
	var owner_id: String = cell.owner_slot_id if cell.owner_slot_id != "" else cell.slot_id
	if owner_id == "":
		return null
	return game.registry.get_by_id(owner_id)

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
		# 退出到菜单时中止
		if game.combat == null or game.combat.aborted:
			return

# ---- 卡牌去向 ----
# 按 target_cell.origin 路由：
#   "hand"    → game.deck（玩家个人牌堆，不论阵营）
#   其他      → target_cell 的"原属盘"（owner_slot_id）的 graveyard / banished
# 原属盘已销毁则静默丢弃，与 PlayController.handle_unit_death 语义一致。
# 兜底：target_cell 为空时按旧 dying_is_enemy 路由（玩家→deck，敌方→原属盘）。
func banish_card(card_data) -> void:
	if target_cell != null and target_cell.origin == "hand":
		if game.is_pvp and target_cell.is_enemy:
			# PVP：對手單位除外入 enemy_main slot
			var e_slots: Array = game.registry.by_role(BoardSlot.ROLE_MAIN_ENEMY) \
				if game.registry != null else []
			if e_slots.size() > 0:
				e_slots[0].banish(card_data)
		else:
			game.deck.banish(card_data)
		return
	if target_cell != null:
		var slot: BoardSlot = _owner_slot_of(target_cell)
		if slot != null:
			slot.banish(card_data)
		return
	# 无 target_cell 兜底
	game.deck.banish(card_data)

func send_to_graveyard(card_data) -> void:
	if target_cell != null and target_cell.origin == "hand":
		if game.is_pvp and target_cell.is_enemy:
			# PVP：對手單位入 enemy_main slot 墓地
			var e_slots: Array = game.registry.by_role(BoardSlot.ROLE_MAIN_ENEMY) \
				if game.registry != null else []
			if e_slots.size() > 0:
				e_slots[0].send_to_graveyard(card_data)
		else:
			game.deck.send_to_graveyard(card_data)
		return
	if target_cell != null:
		var slot: BoardSlot = _owner_slot_of(target_cell)
		if slot != null:
			slot.send_to_graveyard(card_data)
		return
	# 无 target_cell 兜底（理论上 on_death 必有 target_cell）
	game.deck.send_to_graveyard(card_data)

# ---- 英雄伤害 ----
# 多盘语义下默认作用于"主玩家盘 / 主敌盘"的 hero。需要指定其他盘时
# 使用 damage_slot_hero(slot_id, amount)。
# source 标签同 BoardSlot.damage_hero：""/"unit_direct"/"spell_direct"/"triggered"
func damage_player_hero(amount: int, source: String = "") -> void:
	var slot: BoardSlot = game.main_player_slot()
	if slot != null:
		slot.damage_hero(amount, source)

func damage_enemy_hero(amount: int, source: String = "") -> void:
	if game.registry == null:
		return
	for slot in game.registry.by_role(BoardSlot.ROLE_MAIN_ENEMY):
		slot.damage_hero(amount, source)
		return

func damage_slot_hero(slot_id: String, amount: int, source: String = "") -> void:
	if game.registry == null:
		return
	var slot: BoardSlot = game.registry.get_by_id(slot_id)
	if slot != null:
		slot.damage_hero(amount, source)

# 按英雄名称（name_short 或 name_full）定位并造成伤害。
# 遍历所有已注册 slot；多盘同名时全部受到伤害。
func damage_hero_by_name(hero_name: String, amount: int, source: String = "") -> void:
	if game.registry == null:
		return
	for slot in game.registry.slots:
		if slot.hero == null:
			continue
		if slot.hero.name_short == hero_name or slot.hero.name_full == hero_name:
			slot.damage_hero(amount, source)

# ---- 通用计数器（替代 main.autophagy_counter 这种零散字段） ----
func get_counter(key: String, default_value: int = 0) -> int:
	return game.counters.get(key, default_value)

func set_counter(key: String, value: int) -> void:
	game.counters[key] = value

func inc_counter(key: String, delta: int = 1) -> int:
	var v = get_counter(key, 0) + delta
	game.counters[key] = v
	return v

# ---- 交互式目标/手牌选择（装备效果用）----
# 由 main / test_main 在装配时注入对应控制器节点。
var _target_selector: Node = null   # TargetSelectorController
var _hand_picker: Node    = null    # HandPickerController

# 选择一个合法 cell 目标，返回 Cell 或 null（玩家取消）。
func pick_target_async(filter: String):
	if _target_selector == null:
		return null
	return await _target_selector.pick_async(filter)

# 选择一张手牌，返回 HandCard 或 null（玩家取消）。
func pick_hand_card_async():
	if _hand_picker == null:
		return null
	return await _hand_picker.pick_async()
