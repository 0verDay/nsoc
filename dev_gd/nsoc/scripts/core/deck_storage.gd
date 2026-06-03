class_name DeckStorage
extends RefCounted

# 卡组持久化（user://decks.json）。
# 文件结构：
# {
#   "version": 2,
#   "selected_hero": "A",   # 玩家上次在备战界面确认携带的英雄 key
#   "decks": {
#     "<hero_key>": {
#       "cards": { "<card_name>": <count>, ... },
#       "order": [ "<card_name>", ... ],   # 显式条目顺序，反序列化稳定可靠
#       "sort_mode": "no_sort" | "cost_asc" | "cost_desc"
#     },
#     ...
#   }
# }
# 设计要点：
#   - 每英雄一套卡组，key 与 HeroCarousel.HERO_NAMES 元素一致（"A"/"B"/"C"...）。
#   - selected_hero：玩家退出备战界面时保存的英雄 key，作为 Test 场景和多人游戏
#     使用的英雄/卡组来源。初次启动无记录时默认 "A"。
#   - cards 用 name→count 字典；order 显式存条目顺序，避免依赖 JSON 字典保序假设。
#   - sort_mode 记录玩家上次离开时的排序模式，下次进入界面恢复同一视图。
#   - 静态方法 + 全量读写（卡组数据量小，避免持有状态导致一致性 bug）。
#   - 任何 IO 失败都 push_warning 静默退化，不让玩家因存档异常无法进入界面。
#   - v1 旧存档（仅 cards）兼容读取：order 缺失 → 用 cards.keys()，sort_mode 缺失 → "no_sort"。

const PATH: String = "user://decks.json"
const SCHEMA_VERSION: int = 2
const DEFAULT_HERO: String = "A"


# 读取整个存档；文件不存在 / 损坏 → 返回空骨架。
static func load_all() -> Dictionary:
	var empty := {"version": SCHEMA_VERSION, "selected_hero": DEFAULT_HERO, "decks": {}}
	if not FileAccess.file_exists(PATH):
		return empty
	var f := FileAccess.open(PATH, FileAccess.READ)
	if f == null:
		push_warning("DeckStorage: cannot open " + PATH)
		return empty
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("DeckStorage: malformed json, reset to empty")
		return empty
	if not parsed.has("decks") or typeof(parsed["decks"]) != TYPE_DICTIONARY:
		parsed["decks"] = {}
	if not parsed.has("selected_hero"):
		parsed["selected_hero"] = DEFAULT_HERO
	return parsed


# 写回整个存档（覆盖）。失败仅记日志。
static func save_all(data: Dictionary) -> void:
	data["version"] = SCHEMA_VERSION
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f == null:
		push_warning("DeckStorage: cannot write " + PATH)
		return
	f.store_string(JSON.stringify(data, "\t"))
	f.close()


# 读取指定英雄的卡组。返回 {cards: name→count, order: [name...], sort_mode: String}。
# v1 旧存档（无 order / sort_mode）自动补：order 取 cards.keys()，sort_mode 取 "no_sort"。
# 不存在 / 损坏 → 返回空骨架 {cards={}, order=[], sort_mode="no_sort"}。
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
	# int 化 count，防 JSON 解析出 float。
	var cards: Dictionary = {}
	for k in raw_cards.keys():
		cards[String(k)] = int(raw_cards[k])

	# 显式 order：若缺失或与 cards 不一致，取 cards.keys() 作回退；
	# 顺序里多余的项跳过，缺失的项追加到末尾。
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


# 写回指定英雄的卡组卡表 + 顺序 + 排序模式。空表写入 → 保留条目以记录"该英雄已清空"状态。
# order 必须由调用方按视图当前顺序提供；sort_mode 透传字符串（"no_sort"/"cost_asc"/"cost_desc"）。
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


# ── 选中英雄 ──────────────────────────────────────────────────────────────────
# 读取玩家上次在备战界面退出时携带的英雄 key。不存在 → 返回 DEFAULT_HERO。
static func get_selected_hero() -> String:
	return String(load_all().get("selected_hero", DEFAULT_HERO))


# 保存当前选中的英雄 key（退出备战界面时调用）。
static func save_selected_hero(hero_key: String) -> void:
	var data := load_all()
	data["selected_hero"] = hero_key
	save_all(data)
