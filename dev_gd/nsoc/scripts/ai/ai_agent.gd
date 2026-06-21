class_name AiAgent
extends Node

var slot_id: String = ""
var deck: DeckManager = null
var mana: ManaSystem = null
var strategy: AiStrategy = null
var sink: AiActionSink = null
var view: AiGameView = null

const DRAW_PER_TURN: int = 1
const STEP_DELAY: float = 0.3
const MAX_HAND_SIZE: int = 5

var _hand_buf: Array = []

func setup(p_slot_id: String, p_deck: DeckManager, p_mana: ManaSystem,
		p_strategy: AiStrategy, p_sink: AiActionSink) -> void:
	slot_id = p_slot_id
	deck = p_deck
	mana = p_mana
	strategy = p_strategy
	sink = p_sink
	view = AiGameView.new()
	view.setup(slot_id, deck, mana)

# 一个 AI 回合：摸牌 → 决策 → 顺序执行。由 turn_system 在 ENEMY 阶段前调用。
func take_turn() -> void:
	_draw(DRAW_PER_TURN)
	view.set_hand(_current_hand())
	var actions: Array = strategy.decide(view)
	for action in actions:
		if not is_inside_tree():
			break
		if action.kind == AiAction.Kind.END_TURN:
			break
		var cost: int = 0
		if action.card_name != "":
			cost = _cost_of(action.card_name)
			if not mana.can_spend(cost):
				continue
			mana.spend(cost)
			_remove_from_hand(action.card_name)
		var ok = await sink.apply(action)
		# 节点在动画期间被销毁则提前退出
		if not is_inside_tree():
			break
		if not ok and action.card_name != "":
			# apply 失败（格子已满等），回滚费用与手牌
			mana.gain(cost)
			var refund_card = Game.get_card(action.card_name)
			if refund_card != null:
				_hand_buf.append(refund_card)
		else:
			await get_tree().create_timer(STEP_DELAY).timeout
			if not is_inside_tree():
				break

# 跨盘即时回调：turn_system 走到本 AI 单位 front_row 时调用
func on_cross_requested(cell) -> String:
	return strategy.choose_cross_target(view, cell)

# ── 手牌缓冲 ─────────────────────────────────────────────────────────────────

func _draw(n: int) -> void:
	for _i in range(n):
		if _hand_buf.size() >= MAX_HAND_SIZE:
			break
		var c = deck.draw_card()
		if c != null:
			_hand_buf.append(c)

func _current_hand() -> Array:
	return _hand_buf.duplicate()

func _remove_from_hand(p_name: String) -> void:
	for i in range(_hand_buf.size()):
		if _hand_buf[i].name == p_name:
			_hand_buf.remove_at(i)
			return

func _cost_of(p_name: String) -> int:
	var c = Game.get_card(p_name)
	return int(c.cost) if c != null else 0
