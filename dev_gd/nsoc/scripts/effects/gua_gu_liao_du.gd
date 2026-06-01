extends Effect

# 刮骨疗毒：
# 若除外区存在"樊城·关羽"卡 → 将其从除外区移到牌库顶。
# 否则无效果，不退费（10 费点错是玩家责任）。

const TARGET_CARD_NAME: String = "樊城·关羽"

func id() -> String:
	return "gua_gu_liao_du"

func display_name() -> String:
	return "刮骨疗毒"

func description() -> String:
	return "若「樊城·关羽」在除外区，将其放回牌库顶；否则无效"

func on_play(card_data, ctx) -> bool:
	if ctx == null or ctx.game == null:
		return true
	var deck = ctx.game.deck
	if deck == null:
		return true

	# 在除外区查找"樊城·关羽"
	var found_index: int = -1
	for i in range(deck.banished.size()):
		var c = deck.banished[i]
		if c != null and String(c.name) == TARGET_CARD_NAME:
			found_index = i
			break

	if found_index < 0:
		# 没找到 → 无效果，入墓
		return true

	# 移出除外区，放到牌库顶
	var recovered = deck.banished[found_index]
	deck.banished.remove_at(found_index)
	deck.pile_changed.emit("banish")
	deck.add_to_draw_pile(recovered)
	return true
