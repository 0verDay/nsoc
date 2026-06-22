class_name EmpireDeckStorage
extends RefCounted

# 帝国模式卡组的会话内存缓存。
#
# 行为变化（v2）：
#   - 不再读写 user://empire_decks.json（弃用）
#   - 所有 API 操作进程内的静态 Dictionary 缓存
#   - 新游戏开局通过 reset_session() 清空，存档载入通过 inject_from_save() 注入
#   - 旧文件 user://empire_decks.json 会在首次访问时被主动删除（一次性，幂等）
#
# 缓存结构（与原 JSON 一致，方便保留现有接口）：
#   {
#     "version": SCHEMA_VERSION,
#     "selected_hero": "A",
#     "decks": {
#       <hero_key>: {"cards": {<card_name>: int}, "order": [...], "sort_mode": "..."}
#     }
#   }

const LEGACY_PATH: String = "user://empire_decks.json"
const SCHEMA_VERSION: int = 2
const DEFAULT_HERO: String = "A"

# 进程内缓存（所有 API 实际数据源）
static var _cache: Dictionary = {
	"version": SCHEMA_VERSION,
	"selected_hero": DEFAULT_HERO,
	"decks": {},
}

# 旧文件清理标志（首次任意 API 调用时执行，仅一次）
static var _legacy_purged: bool = false


# 清理旧的 user://empire_decks.json 文件（仅执行一次）。
static func _purge_legacy_file() -> void:
	if _legacy_purged:
		return
	_legacy_purged = true
	if FileAccess.file_exists(LEGACY_PATH):
		var dir := DirAccess.open("user://")
		if dir != null:
			var err := dir.remove("empire_decks.json")
			if err != OK:
				push_warning("EmpireDeckStorage: failed to remove legacy file, err=" + str(err))


# 重置会话缓存（新游戏开局调用）。
static func reset_session() -> void:
	_purge_legacy_file()
	_cache = {
		"version": SCHEMA_VERSION,
		"selected_hero": DEFAULT_HERO,
		"decks": {},
	}


# 从存档数据注入缓存（载入存档时调用）。
# snap_data 接受 {"decks": {...}, "selected_hero": "..."} 或同时含整个 cache 结构。
static func inject_from_save(snap_data: Dictionary) -> void:
	_purge_legacy_file()
	var decks: Dictionary = snap_data.get("decks", {})
	var sel: String = String(snap_data.get("selected_hero", DEFAULT_HERO))
	_cache = {
		"version": SCHEMA_VERSION,
		"selected_hero": sel,
		"decks": decks.duplicate(true),
	}


# 序列化缓存供存档保存。
static func dump_for_save() -> Dictionary:
	_purge_legacy_file()
	return {
		"selected_hero": String(_cache.get("selected_hero", DEFAULT_HERO)),
		"decks":         (_cache.get("decks", {}) as Dictionary).duplicate(true),
	}


# ── 保留原 API（内部改为访问 _cache）────────────────────────────────────────

static func load_all() -> Dictionary:
	_purge_legacy_file()
	# 返回缓存拷贝，避免外部修改污染
	return _cache.duplicate(true)


static func save_all(data: Dictionary) -> void:
	_purge_legacy_file()
	# 写回缓存：仅同步 selected_hero 与 decks 字段
	if data.has("selected_hero"):
		_cache["selected_hero"] = String(data["selected_hero"])
	if data.has("decks") and typeof(data["decks"]) == TYPE_DICTIONARY:
		_cache["decks"] = (data["decks"] as Dictionary).duplicate(true)
	_cache["version"] = SCHEMA_VERSION


static func load_deck(hero_key: String) -> Dictionary:
	_purge_legacy_file()
	var empty := {"cards": {}, "order": [], "sort_mode": "no_sort"}
	var decks: Dictionary = _cache.get("decks", {})
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
	_purge_legacy_file()
	if not _cache.has("decks") or typeof(_cache["decks"]) != TYPE_DICTIONARY:
		_cache["decks"] = {}
	_cache["decks"][hero_key] = {
		"cards":     cards.duplicate(true),
		"order":     order.duplicate(),
		"sort_mode": sort_mode,
	}


static func get_selected_hero() -> String:
	_purge_legacy_file()
	return String(_cache.get("selected_hero", DEFAULT_HERO))


static func save_selected_hero(hero_key: String) -> void:
	_purge_legacy_file()
	_cache["selected_hero"] = hero_key
