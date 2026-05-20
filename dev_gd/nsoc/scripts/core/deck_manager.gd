class_name DeckManager
extends Node

# 管理 draw_pile / graveyard / banished （玩家），以及 enemy_graveyard / enemy_banished （敌方）。
# 信号驱动；不直接操作 UI。
# 敌方区域当前仅累积显示，不参与抽牌/复用。

signal pile_changed(pile_name: String)   # "draw" / "graveyard" / "banish" / "enemy_graveyard" / "enemy_banish"

var draw_pile: Array = []
var graveyard: Array = []
var banished: Array = []
var enemy_graveyard: Array = []
var enemy_banished: Array = []
var _all_cards: Array = []               # 初始牌库快照，洗牌还原用

func setup(cards: Array) -> void:
	_all_cards = cards
	reshuffle(true)

func reshuffle(initial: bool = false) -> void:
	draw_pile.clear()
	if initial:
		for card in _all_cards:
			for i in range(card.count):
				draw_pile.append(card)
	else:
		draw_pile.append_array(graveyard)
		graveyard.clear()
		pile_changed.emit("graveyard")
	draw_pile.shuffle()
	pile_changed.emit("draw")

# 抽牌，空堆自动回收墓地，仍空则返回 null（由调用方决定补什么）。
func draw_card():
	if draw_pile.size() == 0:
		reshuffle(false)
	if draw_pile.size() == 0:
		return null
	var c = draw_pile.pop_back()
	pile_changed.emit("draw")
	return c

func add_to_draw_pile(card) -> void:
	draw_pile.append(card)
	pile_changed.emit("draw")

func send_to_graveyard(card) -> void:
	graveyard.append(card)
	pile_changed.emit("graveyard")

func banish(card) -> void:
	banished.append(card)
	pile_changed.emit("banish")

func enemy_send_to_graveyard(card) -> void:
	enemy_graveyard.append(card)
	pile_changed.emit("enemy_graveyard")

func enemy_banish(card) -> void:
	enemy_banished.append(card)
	pile_changed.emit("enemy_banish")

func get_deck_counts() -> Dictionary:
	var counts: Dictionary = {}
	for card in draw_pile:
		counts[card.name] = counts.get(card.name, 0) + 1
	return counts
