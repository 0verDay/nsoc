extends Effect

# 弃手牌：选择一张手牌弃置（fade 淡出 → 入墓 → 补牌）。
# 玩家取消时返回 false，装备耐久不扣。

func id() -> String:
	return "discard_hand_card"

func display_name() -> String:
	return "弃手牌"

func description() -> String:
	return "弃手牌：选择一张手牌弃置，然后补 1 张。"

func on_play(_card_data, ctx) -> bool:
	# 弹出手牌选择器，等待玩家点击
	var chosen = await ctx.pick_hand_card_async()
	if chosen == null:
		return false   # 玩家取消，装备耐久不扣

	# 交给 HandView 处理弃牌动画 + 入墓 + 补位
	var hand_view = Game.play.get("hand_view") if Game.play != null else null
	if hand_view == null or not hand_view.has_method("discard_card"):
		# 兜底：直接入墓（无动画）
		var data = chosen.card_data if "card_data" in chosen else null
		if data != null and data is CardBase:
			Game.deck.send_to_graveyard(data)
		return true

	await hand_view.discard_card(chosen)
	return true
