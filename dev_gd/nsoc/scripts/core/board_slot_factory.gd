class_name BoardSlotFactory
extends RefCounted

# 创建并装配 BoardSlot 的工厂方法集合。
# 把"建 BoardModel + 实例化 cell + 挂入 grid 容器 + 注册 cell + 入 registry +
# 配 spawners + 摆初始单位"的步骤集中。
#
# 使用方式（test_main / main 装配时）：
#   var slot := BoardSlotFactory.create_main(
#       id="player_main",
#       faction=BoardSlot.FACTION_PLAYER,
#       role=BoardSlot.ROLE_MAIN_PLAYER,
#       grid_node=$BottomGrid,
#       bg_panel=$BottomGridBg,
#       hero_panel=$LeftSidePnl/PHpPnl,
#       cell_scene=cell_scene,
#       hero=player_hero_state,
#       level_section=Game.level_data["boards"]["player_main"],
#       on_cell_created=Callable(self, "_wire_cell"),
#   )

# 创建一个标准 3×3 主棋盘 slot。
# level_section: {"initial_units": Array, "spawners": Array} 来自 DataLoader 输出。
# on_cell_created: 每生成一个 cell 后回调（用于绑定 long_press / cleared 等信号），
#                  签名 Callable(cell: Cell) -> void。
static func create_main(
		id: String,
		faction: int,
		role: int,
		grid_node: Node,
		bg_panel: Panel,
		hero_panel: Panel,
		cell_scene: PackedScene,
		hero_spec: Dictionary,
		level_section: Dictionary,
		on_cell_created: Callable = Callable()) -> BoardSlot:

	if not has_game():
		push_error("BoardSlotFactory.create_main: Game autoload not available")
		return null

	var board := BoardModel.new()
	board.name = "BoardModel_%s" % id
	Game.add_child(board)

	var spawners := SpawnerSystem.new()
	spawners.name = "Spawners_%s" % id
	Game.add_child(spawners)
	if level_section != null and level_section.has("spawners"):
		spawners.setup(level_section["spawners"])

	# 该盘法术施放器（SpellCasterSystem）
	var spell_casters := SpellCasterSystem.new()
	spell_casters.name = "SpellCasters_%s" % id
	Game.add_child(spell_casters)
	if level_section != null and level_section.has("spell_casters"):
		spell_casters.setup(level_section["spell_casters"] as Array)

	# 该盘 HeroState
	var hero := HeroState.new()
	hero.name = "Hero_%s" % id
	Game.add_child(hero)
	if hero_spec != null and not hero_spec.is_empty():
		hero.setup(
			int(hero_spec.get("hp", 30)),
			String(hero_spec.get("name_short", "Hero")),
			String(hero_spec.get("name_full", "")),
			hero_spec.get("abilities", []),
		)
		# 初始 flags（如 die_hard）：来自 hero.json flags 数组或 hero_spec.flags
		var flags_arr = hero_spec.get("flags", [])
		if typeof(flags_arr) == TYPE_ARRAY:
			for flag_id in flags_arr:
				hero.set_flag(String(flag_id), true)

	# 生成 3×3 cell 节点
	for r in range(BoardModel.ROWS):
		for c in range(BoardModel.COLS):
			var cell = cell_scene.instantiate()
			cell.row = r
			cell.col = c
			cell.slot_id = id
			grid_node.add_child(cell)
			board.register_cell(cell)
			if on_cell_created.is_valid():
				on_cell_created.call(cell)

	var slot := BoardSlot.new()
	slot.name = "Slot_%s" % id
	Game.add_child(slot)
	# hero_resolver 留空 → BoardSlot.setup 内自动绑定到 self.damage_hero
	slot.setup(id, faction, role, board, hero, spawners)
	slot.bg_panel = bg_panel
	slot.hero_panel = hero_panel
	slot.grid_node = grid_node
	slot.allow_player_deploy = (faction == BoardSlot.FACTION_PLAYER)
	slot.spell_casters = spell_casters
	Game.registry.add(slot)

	# 摆放初始单位（盘内 row/col 已是 0..2 视角）
	if level_section != null and level_section.has("initial_units"):
		board.populate_initial_units(
			level_section["initial_units"],
			Callable(Game, "get_card"),
			faction == BoardSlot.FACTION_ENEMY)

	return slot

static func has_game() -> bool:
	if Engine.get_main_loop() == null:
		return false
	var root: Node = Engine.get_main_loop().root
	return root != null and root.has_node("/root/Game")

# 销毁一个 slot：完整清理并释放。
# 清理顺序：
#   1. 场上残存单位 → 直接除外（不走死亡流程）
#   2. 把该 slot 的除外数据转移到对应阵营主盘（enemy→enemy_main，player→Game.deck）
#   3. 清空 slot 自身数据
#   4. 断开信号
#   5. 注销 registry + 释放子节点
static func destroy(slot: BoardSlot) -> void:
	if slot == null:
		return

	# 1. 场上残存单位 → 直接除外到对应阵营目标
	# 路由规则按**单位阵营**而非盘阵营决定（盘上可能有跨盘的异阵营单位）：
	#   玩家单位 + origin="hand"  → Game.deck.banished
	#   玩家单位 + 其他 origin   → player_main.banished
	#   敌方单位 (is_enemy=true)  → enemy_main.banished
	if is_instance_valid(slot.board) and has_game():
		var cells_snapshot: Array = slot.board.grid_cells.values().duplicate()
		for cell in cells_snapshot:
			if not is_instance_valid(cell) or not cell.has_card or cell.is_phantom:
				continue
			var cname: String = cell.card_name
			var orig: String  = cell.origin
			var is_enemy_unit: bool = cell.is_enemy
			cell.clear_card()
			var cdata = Game.get_card(cname)
			if is_enemy_unit:
				# 敌方单位 → enemy_main.banished
				var enemy_main = _main_slot_for_faction(BoardSlot.FACTION_ENEMY)
				if enemy_main != null and is_instance_valid(enemy_main):
					if cdata != null:
						enemy_main.banished.append(cdata)
					else:
						enemy_main.banished.append({"name": cname})
			elif orig == "hand":
				# 玩家手牌 → 玩家牌库除外
				if cdata != null and Game.deck != null:
					Game.deck.banished.append(cdata)
				elif Game.deck != null:
					Game.deck.banished.append({"name": cname})
			else:
				# 玩家 spawner/initial/ability 单位 → player_main.banished
				var player_main = _main_slot_for_faction(BoardSlot.FACTION_PLAYER)
				if player_main != null and is_instance_valid(player_main):
					if cdata != null:
						player_main.banished.append(cdata)
					else:
						player_main.banished.append({"name": cname})

	# 2. 发信号刷新 UI（统一在数据写入后发）
	if has_game():
		var enemy_main = _main_slot_for_faction(BoardSlot.FACTION_ENEMY)
		if enemy_main != null and is_instance_valid(enemy_main):
			enemy_main.pile_changed.emit("banished")
		var player_main = _main_slot_for_faction(BoardSlot.FACTION_PLAYER)
		if player_main != null and is_instance_valid(player_main):
			player_main.pile_changed.emit("banished")
		if Game.deck != null:
			Game.deck.pile_changed.emit("banish")

	# 3. 清空 slot 自身数据
	if is_instance_valid(slot):
		slot.graveyard.clear()
		slot.banished.clear()

	# 4. 断开 pile_changed 所有外部连接
	if is_instance_valid(slot):
		var connections: Array = slot.pile_changed.get_connections()
		for conn in connections:
			slot.pile_changed.disconnect(conn["callable"])

	# 5. 注销 + 释放
	if has_game() and Game.registry != null:
		Game.registry.remove(slot.id)
	if is_instance_valid(slot.board):
		slot.board.queue_free()
	if is_instance_valid(slot.spawners):
		slot.spawners.queue_free()
	if is_instance_valid(slot.spell_casters):
		slot.spell_casters.queue_free()
	if is_instance_valid(slot.hero):
		slot.hero.queue_free()
	if is_instance_valid(slot):
		slot.queue_free()

# 按阵营找到对应主盘（玩家→player_main，敌方→enemy_main）
static func _main_slot_for_faction(faction: int) -> BoardSlot:
	if not has_game() or Game.registry == null:
		return null
	if faction == BoardSlot.FACTION_PLAYER:
		return Game.registry.main_player()
	for s in Game.registry.by_role(BoardSlot.ROLE_MAIN_ENEMY):
		return s
	return null
