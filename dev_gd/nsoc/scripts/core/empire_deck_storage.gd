class_name EmpireDeckStorage
extends RefCounted

# 帝国模式专属卡组持久化（user://empire_decks.json）。
# 与主菜单备战面板的 DeckStorage 完全隔离，结构相同。
# 文件结构同 DeckStorage（version / selected_hero / decks）。

const PATH: String = "user://empire_decks.json"
const SCHEMA_VERSION: int = 1
const DEFAULT_HERO: String = "A"


static func load_all() -> Dictionary:
	var empty := {"version": SCHEMA_VERSION, "selected_hero": DEFAULT_HERO, "decks": {}}
	if not FileAccess.file_exists(PATH):
		return empty
	var f := FileAccess.open(PATH, FileAccess.READ)
	if f == null:
		push_warning("EmpireDeckStorage: cannot open " + PATH)
		return empty
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("EmpireDeckStorage: malformed json, reset to empty")
		return empty
	if not parsed.has("decks") or typeof(parsed["decks"]) != TYPE_DICTIONARY:
		parsed["decks"] = {}
	if not parsed.has("selected_hero"):
		parsed["selected_hero"] = DEFAULT_HERO
	return parsed


static func save_all(data: Dictionary) -> void:
	data["version"] = SCHEMA_VERSION
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f == null:
		push_warning("EmpireDeckStorage: cannot write " + PATH)
		return
	f.store_string(JSON.stringify(data, "\t"))
	f.close()


static func load_deck(hero_key: String) -> Dictionary:
	var empty := {"cards": {}, "order": [], "sort_mode": "no_sort"}
	var data := load_all()
	var decks: Dictionary = data.get("decks", {})
	var deck = decks.get(hero_key, null)
	if typeof(deck) != TYPE_DICTIONARY:
		return empty
	var raw_cards = deck.get("cards", {})
	if typeof(raw_cards) != TYPE_DICTIONARY:
		return empty
	var cards: Dictionary = {}
	for k in raw_cards.keys():
		cards[String(k)] = int(raw_cards[k])

	var order: Array = []
	var raw_order = deck.get("order", null)
	if typeof(raw_order) == TYPE_ARRAY:
		for item in raw_order:
			var name_str := String(item)
			if cards.has(name_str) and not order.has(name_str):
				order.append(name_str)
	for k in cards.keys():
		if not order.has(k):
			order.append(k)

	var sort_mode := String(deck.get("sort_mode", "no_sort"))
	return {"cards": cards, "order": order, "sort_mode": sort_mode}


static func save_deck(hero_key: String, cards: Dictionary, order: Array = [], sort_mode: String = "no_sort") -> void:
	var data := load_all()
	if not data.has("decks") or typeof(data["decks"]) != TYPE_DICTIONARY:
		data["decks"] = {}
	data["decks"][hero_key] = {
		"cards": cards,
		"order": order,
		"sort_mode": sort_mode,
	}
	save_all(data)


static func get_selected_hero() -> String:
	return String(load_all().get("selected_hero", DEFAULT_HERO))


static func save_selected_hero(hero_key: String) -> void:
	var data := load_all()
	data["selected_hero"] = hero_key
	save_all(data)
