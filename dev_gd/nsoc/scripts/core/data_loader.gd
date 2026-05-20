class_name DataLoader
extends RefCounted

# 静态方法集合：负责把 JSON 解析为 CardBase 子类/关卡配置。
# 不依赖任何节点；输入路径，输出纯数据。

const HERO_JSON := "res://data/test_hero.json"
const CARD_JSON := "res://data/test_card.json"
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

static func load_hero_info(default_player_hp: int = 30, default_enemy_hp: int = 30) -> Dictionary:
	var out := {
		"player": {"name": "Player", "health": default_player_hp, "abilities": []},
		"enemy":  {"name": "Enemy",  "health": default_enemy_hp, "abilities": []},
	}
	var j = _read_json(HERO_JSON)
	if typeof(j) == TYPE_DICTIONARY:
		if j.has("player"):
			var p: Dictionary = j["player"]
			out.player.health = int(p.get("health", default_player_hp))
			out.player.name = String(p.get("name", out.player.name))
			out.player.abilities = _parse_string_array(p.get("abilities", []))
		if j.has("enemy"):
			var e: Dictionary = j["enemy"]
			out.enemy.health = int(e.get("health", default_enemy_hp))
			out.enemy.name = String(e.get("name", out.enemy.name))
			out.enemy.abilities = _parse_string_array(e.get("abilities", []))
	return out

static func _parse_string_array(raw) -> Array:
	if typeof(raw) != TYPE_ARRAY:
		return []
	var out: Array = []
	for item in raw:
		out.append(String(item))
	return out

static func load_cards() -> Array:
	var j = _read_json(CARD_JSON)
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
