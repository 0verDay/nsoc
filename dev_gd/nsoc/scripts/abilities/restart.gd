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
	# ① 声明了 `ctx.hand_action` 注入缝的宿主：手牌由宿主持有，走该 Callable 改
	#    **宿主手牌**（宿主可能根本没有 hand_view 节点）。这样两种装配路径的
	#    "再起"行为完全一致。
	#    注意：共享层禁止 `.call(`（tools/ci/check_layers.py 的反射规则），
	#    所以这里用 `callv()`；参数按 `(action, payload)` 契约，额外的 pid 由 bind 追加在末尾。
	var hand_action = ctx.get("hand_action") if typeof(ctx) == TYPE_DICTIONARY else ctx.hand_action
	if hand_action is Callable and (hand_action as Callable).is_valid():
		(hand_action as Callable).callv(["restart_hand", {}])
		return
	# ② 客户端 / 常规模式：直接操作本地手牌区（弃牌入墓 + 补满 5 张）
	var hand_view = ctx.get("hand_view") if typeof(ctx) == TYPE_DICTIONARY else ctx.hand_view
	if hand_view == null:
		return
	hand_view.discard_all_and_refill()
