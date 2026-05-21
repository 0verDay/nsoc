class_name DeckStorage
extends RefCounted

# 卡组持久化（user://decks.json）。
# 文件结构：
# {
#   "version": 1,
#   "decks": { "<hero_key>": { "cards": { "<card_name>": <count>, ... } }, ... }
# }
# 设计要点：
#   - 每英雄一套卡组，key 与 HeroCarousel.HERO_NAMES 元素一致（"A"/"B"/"C"...）。
#   - cards 用 name→count 字典，运行时按需 DataLoader 还原 CardBase。
#   - 静态方法 + 全量读写（卡组数据量小，避免持有状态导致一致性 bug）。
#   - 任何 IO 失败都 push_warning 静默退化，不让玩家因存档异常无法进入界面。

const PATH: String = "user://decks.json"
const SCHEMA_VERSION: int = 1


# 读取整个存档；文件不存在 / 损坏 → 返回空骨架。
static func load_all() -> Dictionary:
	var empty := {"version": SCHEMA_VERSION, "decks": {}}
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


# 读取指定英雄的卡组卡表（name→count）。无则返回空字典。
static func load_deck(hero_key: String) -> Dictionary:
	var data := load_all()
	var decks: Dictionary = data.get("decks", {})
	var deck = decks.get(hero_key, null)
	if typeof(deck) != TYPE_DICTIONARY:
		return {}
	var cards = deck.get("cards", {})
	if typeof(cards) != TYPE_DICTIONARY:
		return {}
	# int 化 count，防 JSON 解析出 float。
	var out: Dictionary = {}
	for k in cards.keys():
		out[String(k)] = int(cards[k])
	return out


# 写回指定英雄的卡组卡表。空表写入 → 保留条目以记录"该英雄已清空"状态。
static func save_deck(hero_key: String, cards: Dictionary) -> void:
	var data := load_all()
	if not data.has("decks") or typeof(data["decks"]) != TYPE_DICTIONARY:
		data["decks"] = {}
	data["decks"][hero_key] = {"cards": cards}
	save_all(data)
