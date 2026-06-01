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
	if cell == null or not cell.has_card or cell.is_enemy:
		return true

	# 查找对应卡牌原型
	var cdata = ctx.game.get_card(cell.card_name)
	if cdata == null:
		return true

	# 将单位放回牌库顶（玩家下次会抽到它）
	# 使用 add_to_draw_pile 追加到抽牌堆末尾（pop_back 抽的是末尾，等价于放在最顶端）
	if ctx.game.deck != null:
		ctx.game.deck.add_to_draw_pile(cdata)
	# 清除格子（不走死亡/墓地流程）
	cell.clear_card()

	# 标记本回合跳过下一次抽牌（TurnSystem 检查此 flag）
	ctx.set_counter("ming_jin_used", ctx.get_counter("ming_jin_used", 0) + 1)
	return true
