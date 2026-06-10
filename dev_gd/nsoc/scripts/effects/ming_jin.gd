extends Effect

# 鸣金：选择一个友方单位，替代本回合抽牌动作，将该单位放回手牌。
# target = "friendly_unit"（PlayController 过滤）
# 替代抽牌：设置 Game.counters["ming_jin_used"] = true，
# TurnSystem.run() 开头抽牌处检查此 flag 并跳过一次抽牌。

func id() -> String:
	return "ming_jin"

func display_name() -> String:
	return "鸣金"

func description() -> String:
	return "鸣金：选择一个友方单位放回手牌，本回合不抽牌"

func target() -> String:
	return "friendly_unit"

func on_play(card_data, ctx) -> bool:
	var cell = ctx.target_cell
	var local_team: String = ctx.game.team_of_player(ctx.game.local_player_id) \
		if ctx.game != null else ""
	if cell == null or not cell.has_card or cell.is_hostile_to(local_team):
		return true

	# 查找对应卡牌原型
	var cdata = ctx.game.get_card(cell.card_name)
	if cdata == null:
		return true

	# 将单位放回牌库顶（PVP 中 friendly_unit 可能是队友单位 → 必须回到该单位
	# 拥有者的 deck 而非 caster 本地 deck，否则锁步双端 deck 状态发散）。
	var owner_pid: String = ""
	if cell.owner_slot_id != "" and ctx.game != null and ctx.game.registry != null:
		var owner_slot: BoardSlot = ctx.game.registry.get_by_id(cell.owner_slot_id)
		if owner_slot != null:
			owner_pid = owner_slot.owner_player_id
	var d: DeckManager = null
	if owner_pid != "" and ctx.game != null:
		d = ctx.game.get_deck(owner_pid)
	if d == null and ctx.game != null:
		d = ctx.game.deck
	if d != null:
		d.add_to_draw_pile(cdata)
	# 清除格子（不走死亡/墓地流程）
	cell.clear_card()

	# 标记本回合跳过下一次抽牌（TurnSystem 检查此 flag）
	ctx.set_counter("ming_jin_used", ctx.get_counter("ming_jin_used", 0) + 1)
	return true
