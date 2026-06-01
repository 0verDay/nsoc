extends HeroAbility

# 水淹七军——水坝（友方英雄）专属被动。
# 每个玩家回合开始：water_dam stacks["flood_charge"] +1。
# 玩家使用"决堤"法术时 → 永久剥夺 enemy_main 英雄 die_hard flag。
# 水坝英雄死亡退场时（被动触发）：
#   - 每 1 层蓄水对 enemy_main 造成 1 点 triggered 伤害
#   - 每 5 层蓄水封锁 enemy_main spawner 1 回合（向下取整）
# 注：蓄水驱动 (+1/turn) 由 ScriptedEvents board_events action 每玩家回合开始调用。
# 退场结算由 BoardSlot._on_hero_died 通过 Events.notify_hero_died → trigger 驱动。

func id() -> String:
	return "flood_dam_ability"

func display_name() -> String:
	return "水淹七军"

func description() -> String:
	return "水淹七军：每回合积累一层「蓄水」；退场时每1层蓄水对「曹仁」造成1伤害，每5层封锁敌方出兵1回合"

func can_activate(_ctx) -> bool:
	return false

const STACK_KEY: String = "flood_charge"

# 每玩家回合开始：给 ally_left 盘英雄 +1 蓄水
static func add_charge(game_node: Node) -> void:
	if game_node == null or game_node.registry == null:
		return
	for slot in game_node.registry.by_role(BoardSlot.ROLE_ALLY):
		if slot.hero == null:
			continue
		slot.hero.add_stack(STACK_KEY, 1)
		return  # 仅第一个 ally

# 结算退场：蓄水伤害 + spawner 封锁
static func release(game_node: Node) -> void:
	if game_node == null or game_node.registry == null:
		return
	# 取蓄水层数
	var stacks: int = 0
	for slot in game_node.registry.by_role(BoardSlot.ROLE_ALLY):
		if slot.hero != null:
			stacks = slot.hero.get_stack(STACK_KEY)
			# 退场后清零，不再积累
			slot.hero.set_stack(STACK_KEY, 0)
		break

	if stacks <= 0:
		return

	# 对 enemy_main 英雄造成 stacks 点 triggered 伤害
	for enemy_slot in game_node.registry.by_role(BoardSlot.ROLE_MAIN_ENEMY):
		enemy_slot.damage_hero(stacks, "triggered")
		break

	# 每 5 层封锁 spawner N 回合
	var lock_turns: int = stacks / 5
	if lock_turns > 0:
		_pause_enemy_spawners(game_node, lock_turns)

static func _pause_enemy_spawners(game_node: Node, turns: int) -> void:
	if game_node == null or game_node.registry == null:
		return
	for slot in game_node.registry.by_role(BoardSlot.ROLE_MAIN_ENEMY):
		if slot.spawners != null and slot.spawners.has_method("pause_for_turns"):
			slot.spawners.pause_for_turns(turns)
