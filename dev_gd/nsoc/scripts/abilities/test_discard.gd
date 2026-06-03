extends HeroAbility

# "测试技能" —— 消耗 1 费用，选择一张手牌弃置，并自动补 1 张。
# ctx 字段约定：
#   ctx.hand_view  : HandView
#   ctx._hand_picker : HandPickerController（由 EffectContext / Game.make_effect_context 注入）

func id() -> String:
	return "test_discard"

func display_name() -> String:
	return "测试技能"

func description() -> String:
	return "消耗 1 费用，选择一张手牌弃置，并补一张。"

func cost() -> int:
	return 1

func once_per_turn() -> bool:
	return true

# 需要至少有 1 张手牌（不含虚空占位）才可激活。
func can_activate(ctx) -> bool:
	if not super.can_activate(ctx):
		return false
	var hand_view = _get_hand_view(ctx)
	if hand_view == null:
		return false
	var container = hand_view.get_hand_container() if hand_view.has_method("get_hand_container") else null
	if container == null:
		return false
	for child in container.get_children():
		if child.get_meta("consumed", false):
			continue
		var data = child.card_data if "card_data" in child else null
		if data != null and data is CardBase and String(data.name) != "虚空":
			return true
	return false

func on_activate(ctx) -> void:
	if ctx == null:
		return
	var hand_view = _get_hand_view(ctx)
	if hand_view == null:
		return
	# 锁回合（防出牌/结束回合干扰选牌）
	if Game.turn != null:
		Game.turn.is_running = true
	# 等玩家点击一张手牌
	var hand_picker = _get_hand_picker(ctx)
	var chosen = null
	if hand_picker != null and hand_picker.has_method("pick_async"):
		chosen = await hand_picker.pick_async()
	# 解锁（无论是否取消）
	if Game.turn != null:
		Game.turn.is_running = false
	if chosen == null:
		# 玩家取消：退还费用
		# HeroAbilityRegistry.activate 已在调用 on_activate 前扣费，此处退还
		if Game.mana != null:
			Game.mana.gain(cost())
		# 同时清除"本回合已用"标记，让玩家可重试
		var root: Node = Engine.get_main_loop().root if Engine.get_main_loop() != null else null
		if root != null and root.has_node("/root/HeroAbilities"):
			HeroAbilities.clear_turn_usage(id())
		return
	# 弃置选中手牌并自动补位（discard_card 内部：入墓 + 飞入补牌）
	await hand_view.discard_card(chosen)

# ── 内部辅助 ────────────────────────────────────────────────────────────────
static func _get_hand_view(ctx):
	if typeof(ctx) == TYPE_DICTIONARY:
		return ctx.get("hand_view")
	if "hand_view" in ctx:
		return ctx.hand_view
	return null

static func _get_hand_picker(ctx):
	if typeof(ctx) == TYPE_DICTIONARY:
		return ctx.get("_hand_picker")
	if "_hand_picker" in ctx:
		return ctx._hand_picker
	return null
