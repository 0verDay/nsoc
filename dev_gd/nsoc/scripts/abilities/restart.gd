extends HeroAbility

# "再起" —— 消耗 1 费用，弃置所有手牌进墓地，再补齐至 MIN_HAND_SIZE。
# ctx 字段约定：
#   ctx.hand_view : HandView
#   ctx.hero      : HeroState

func id() -> String:
	return "restart"

func display_name() -> String:
	return "再起"

func description() -> String:
	return "消耗 1 费用，弃置所有手牌，然后重新补满 5 张。"

func cost() -> int:
	return 1

func once_per_turn() -> bool:
	return true

func on_activate(ctx) -> void:
	if ctx == null:
		return
	var hand_view = ctx.get("hand_view") if typeof(ctx) == TYPE_DICTIONARY else ctx.hand_view
	if hand_view == null:
		return
	hand_view.discard_all_and_refill()
