class_name DataLoader
extends RefCounted

# 静态方法集合：负责把 JSON 解析为 CardBase 子类/关卡配置。
# 不依赖任何节点；输入路径，输出纯数据。
#
# 文件分工：
#   res://data/all_cards.json     - 卡片原型库（图鉴），战斗的真相之源
#   res://data/review_cards.json  - 备战界面专用（可含占位卡）
#   res://data/hero.json          - 英雄数据：display_name / max_health / abilities / skill_text
#   user://battle_cards.json      - main.gd 启动时按当前牌组生成的本局牌池
#   res://data/test_level.json    - 关卡配置（保留）

const ALL_CARDS_JSON := "res://data/all_cards.json"
const REVIEW_CARDS_JSON := "res://data/review_cards.json"
const HERO_JSON := "res://data/hero.json"
const BATTLE_CARDS_JSON := "user://battle_cards.json"
const LEVEL_JSON := "res://data/test_level.json"

# 读取并 parse 一个 JSON 文件。失败返回 null（带 push_error）。
static func _read_json(path: String):
	if not FileAccess.file_exists(path):
		push_warning("DataLoader: file not found: " + path)
		return null
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		push_error("DataLoader: cannot open " + path)
		return null
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if parsed == null:
		push_error("DataLoader: malformed JSON: " + path)
	return parsed

static func _parse_string_array(raw) -> Array:
	if typeof(raw) != TYPE_ARRAY:
		return []
	var out: Array = []
	for item in raw:
		out.append(String(item))
	return out

# 卡牌读取。path 必传，调用方按用途选择 ALL/REVIEW/BATTLE 路径。
static func load_cards(path: String) -> Array:
	var j = _read_json(path)
	if typeof(j) != TYPE_ARRAY or (j as Array).size() == 0:
		return _fallback_cards()
	var out: Array = []
	for card in j:
		if typeof(card) != TYPE_DICTIONARY:
			push_warning("DataLoader: skipping non-dict card entry")
			continue
		out.append(_parse_card(card))
	return out

static func _parse_card(card: Dictionary):
	var c_name: String = card.get("name", "Unknown")
	var c_type: String = card.get("type", "单位")
	var c_cost: int = int(card.get("cost", 0))
	var c_effects: Array = card.get("effects", [])
	var c_count: int = int(card.get("count", 1))
	var new_card
	if c_type == "单位":
		var c_atk: int = int(card.get("attack", 0))
		var hp := {"top": 1, "bottom": 1, "left": 1, "right": 1}
		if card.has("health"):
			if typeof(card["health"]) == TYPE_DICTIONARY:
				hp = {
					"top": int(card["health"].get("top", 1)),
					"bottom": int(card["health"].get("bottom", 1)),
					"left": int(card["health"].get("left", 1)),
					"right": int(card["health"].get("right", 1)),
				}
			else:
				var hv: int = int(card["health"])
				hp = {"top": hv, "bottom": hv, "left": hv, "right": hv}
		new_card = CardUnit.new(c_name, c_cost, c_atk, hp, c_effects)
	else:
		var c_target: String = card.get("target", "")
		new_card = CardSpell.new(c_name, c_cost, c_effects, c_target)
	new_card.count = c_count
	return new_card

static func load_level() -> Dictionary:
	var out := {"initial_units": [], "spawners": []}
	var j = _read_json(LEVEL_JSON)
	if typeof(j) != TYPE_DICTIONARY:
		return out
	if j.has("initial_units") and typeof(j["initial_units"]) == TYPE_ARRAY:
		for cfg in j["initial_units"]:
			var positions: Array = []
			for pos in cfg["positions"]:
				positions.append(Vector2(int(pos["row"]), int(pos["col"])))
			out.initial_units.append({
				"name": cfg["name"],
				"faction": int(cfg["faction"]),
				"positions": positions,
			})
	if j.has("spawners") and typeof(j["spawners"]) == TYPE_ARRAY:
		for sp in j["spawners"]:
			# 兼容两种写法：单数 position 字段 / 复数 positions 数组。
			# 统一规整为 positions: Array[Vector2]。
			var positions: Array = []
			if sp.has("positions") and typeof(sp["positions"]) == TYPE_ARRAY:
				for pos in sp["positions"]:
					positions.append(Vector2(int(pos["row"]), int(pos["col"])))
			elif sp.has("position"):
				var p = sp["position"]
				positions.append(Vector2(int(p["row"]), int(p["col"])))
			out.spawners.append({
				"name": sp["name"],
				"faction": int(sp["faction"]),
				"positions": positions,
				"interval": int(sp["interval"]),
			})
	return out

static func _fallback_cards() -> Array:
	var a = CardUnit.new("填线宝宝", 1, 1, {"top": 1, "bottom": 1, "left": 1, "right": 1}, [])
	a.count = 5
	var b = CardUnit.new("灰烬填线宝宝", 2, 2, {"top": 2, "bottom": 2, "left": 2, "right": 2}, ["ash"])
	b.count = 3
	return [a, b]


# ============================================================================
# 英雄数据（res://data/hero.json）
# ============================================================================

# 读取整个 hero.json。返回 {"heroes": {key: {...}}, "enemy_default": {...}}。
# 文件缺失/损坏时返回空骨架，调用方按需走默认。
static func load_hero_db() -> Dictionary:
	var empty := {"heroes": {}, "enemy_default": {}}
	var j = _read_json(HERO_JSON)
	if typeof(j) != TYPE_DICTIONARY:
		return empty
	if not j.has("heroes") or typeof(j["heroes"]) != TYPE_DICTIONARY:
		j["heroes"] = {}
	if not j.has("enemy_default") or typeof(j["enemy_default"]) != TYPE_DICTIONARY:
		j["enemy_default"] = {}
	return j


# 取指定英雄数据（按 key，如 "A"）。键缺失时返回空字典；调用方再走默认。
static func get_hero(hero_key: String) -> Dictionary:
	var db := load_hero_db()
	var h = db["heroes"].get(hero_key, null)
	if typeof(h) != TYPE_DICTIONARY:
		return {}
	return h


# 取敌方默认配置。
static func get_enemy_default() -> Dictionary:
	var db := load_hero_db()
	return db["enemy_default"]


# ============================================================================
# user://battle_cards.json 生成与读取
# ============================================================================

# 从 all_cards.json 中筛选玩家牌组卡 + 写入 count 字段，输出为
# user://battle_cards.json，供本局战斗读取。
#   hero_key: HeroCarousel 中的英雄 key（如 "A"）→ 决定从 decks.json 拿哪份卡组
#   失败兜底：玩家卡组为空时，写入空数组（战斗 _fallback_cards 接管）。
static func generate_battle_cards(hero_key: String) -> void:
	var deck: Dictionary = DeckStorage.load_deck(hero_key)
	var raw = _read_json(ALL_CARDS_JSON)
	var prototypes: Array = []
	if typeof(raw) == TYPE_ARRAY:
		prototypes = raw
	# 建 name → 原型 dict 索引。
	var index: Dictionary = {}
	for p in prototypes:
		if typeof(p) == TYPE_DICTIONARY and p.has("name"):
			index[String(p["name"])] = p
	# 按玩家牌组卡名聚合，count 来自 decks.json[hero].cards 的值。
	var out: Array = []
	for cname in deck.keys():
		var cnt: int = int(deck[cname])
		if cnt <= 0:
			continue
		var proto = index.get(String(cname), null)
		if proto == null:
			push_warning("DataLoader.generate_battle_cards: card not found in all_cards.json: " + String(cname))
			continue
		# 复制一份原型并覆盖 count（不污染 all_cards 的内存解析）。
		var copy: Dictionary = proto.duplicate(true)
		copy["count"] = cnt
		out.append(copy)
	# 写盘 user://battle_cards.json。
	var f := FileAccess.open(BATTLE_CARDS_JSON, FileAccess.WRITE)
	if f == null:
		push_error("DataLoader.generate_battle_cards: cannot write " + BATTLE_CARDS_JSON)
		return
	f.store_string(JSON.stringify(out, "\t"))
	f.close()

