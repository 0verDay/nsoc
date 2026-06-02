class_name DeckManager
extends Node

# 玩家个人牌堆管理：draw_pile / graveyard / banished。
# 阶段 5 起：敌方阵亡单位由各 BoardSlot 自己的 graveyard / banished 持有，
# 不再走本类的 enemy_* 字段（已删除）。

signal pile_changed(pile_name: String)   # "draw" / "graveyard" / "banish"

var draw_pile: Array = []
var graveyard: Array = []
var banished: Array = []
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

func get_deck_counts() -> Dictionary:
	var counts: Dictionary = {}
	for card in draw_pile:
		counts[card.name] = counts.get(card.name, 0) + 1
	return counts

# ── 序列化（PVP 联机用）────────────────────────────────────────────
# 卡牌按 name 序列化，反序时通过 Game.get_card(name) 还原 CardBase 对象。
# 私密性：draw_pile / graveyard / banished 内容仅发给本人；
# 其他玩家收到的快照应只含 *_count 字段（由 snapshot_io 顶层过滤后再调 to_dict_public）。
func to_dict() -> Dictionary:
	return {
		"draw_pile":  _names_of(draw_pile),
		"graveyard":  _names_of(graveyard),
		"banished":   _names_of(banished),
		"all_cards":  _names_of(_all_cards),
	}

# 公开版本：仅暴露牌堆 / 墓地 / 除外的数量与名字（敌方墓地/除外名字仍可见）。
# 抽牌堆只发数量，避免泄漏顺序。
func to_dict_public() -> Dictionary:
	return {
		"draw_count": draw_pile.size(),
		"graveyard":  _names_of(graveyard),
		"banished":   _names_of(banished),
	}

func from_dict(d: Dictionary) -> void:
	draw_pile = _resolve_cards(d.get("draw_pile", []))
	graveyard = _resolve_cards(d.get("graveyard", []))
	banished  = _resolve_cards(d.get("banished",  []))
	if d.has("all_cards"):
		_all_cards = _resolve_cards(d.get("all_cards", []))
	pile_changed.emit("draw")
	pile_changed.emit("graveyard")
	pile_changed.emit("banish")

static func _names_of(arr: Array) -> Array:
	var out: Array = []
	for c in arr:
		if c == null:
			continue
		out.append(String(c.name))
	return out

static func _resolve_cards(names) -> Array:
	var out: Array = []
	if typeof(names) != TYPE_ARRAY:
		return out
	if Engine.get_main_loop() == null:
		return out
	var root: Node = Engine.get_main_loop().root
	if not root.has_node("/root/Game"):
		return out
	for n in names:
		var c = Game.get_card(String(n))
		if c != null:
			out.append(c)
	return out
