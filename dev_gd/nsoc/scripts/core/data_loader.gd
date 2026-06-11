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
const CAMPAIGNS_JSON := "res://data/campaigns.json"
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

static func _parse_int_array(raw) -> Array:
	if typeof(raw) != TYPE_ARRAY:
		return []
	var out: Array = []
	for item in raw:
		out.append(int(item))
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
		# JSON 仍以玩家视角 top/bottom/left/right 书写，转换为单位视角 side。
		var hp := {"front": 1, "back": 1, "left": 1, "right": 1}
		if card.has("health"):
			if typeof(card["health"]) == TYPE_DICTIONARY:
				var raw_hp: Dictionary = card["health"]
				# 兼容两种写法：玩家视角 abs(top/bottom) 或已是 side(front/back)
				if raw_hp.has("front") or raw_hp.has("back"):
					hp = {
						"front": int(raw_hp.get("front", 1)),
						"back":  int(raw_hp.get("back", 1)),
						"left":  int(raw_hp.get("left", 1)),
						"right": int(raw_hp.get("right", 1)),
					}
				else:
					hp = Orientation.health_player_abs_to_side(raw_hp)
			else:
				var hv: int = int(card["health"])
				hp = {"front": hv, "back": hv, "left": hv, "right": hv}
		new_card = CardUnit.new(c_name, c_cost, c_atk, hp, c_effects)
	elif c_type == "装备":
		var c_dura: int = int(card.get("durability", 1))
		var c_opt: bool = bool(card.get("once_per_turn", false))
		new_card = CardEquipment.new(c_name, c_cost, c_dura, c_effects, c_opt)
	else:
		var c_target: String = card.get("target", "")
		new_card = CardSpell.new(c_name, c_cost, c_effects, c_target)
	new_card.count = c_count
	return new_card

static func load_level() -> Dictionary:
	var out := _empty_level()
	var j = _read_json(LEVEL_JSON)
	if typeof(j) != TYPE_DICTIONARY:
		return out
	return _parse_level(j)

# 从任意路径加载关卡（供 Game.pending_level_path 使用）。
static func load_level_from_path(path: String) -> Dictionary:
	var out := _empty_level()
	var j = _read_json(path)
	if typeof(j) != TYPE_DICTIONARY:
		return out
	return _parse_level(j)

# 从章节 JSON 中读取关卡结构。
# 章节无关卡字段时返回空骨架，调用方走默认。
static func load_level_from_chapter(chapter_json_path: String) -> Dictionary:
	var out := _empty_level()
	var j = _read_json(chapter_json_path)
	if typeof(j) != TYPE_DICTIONARY:
		return out
	return _parse_level(j)

# 输出结构（多棋盘模型）：
# {
#   "boards": {
#     "player_main": {"initial_units": [...], "spawners": [...]},
#     "enemy_main":  {"initial_units": [...], "spawners": [...]},
#   },
#   # 兼容旧调用：聚合视图（去重后的全部条目）
#   "initial_units": [...],
#   "spawners": [...],
# }
#
# 旧 JSON 兼容规则：
#   - cfg.faction == 0 → 路由到 player_main，row 经 (ROWS_OLD-1) - row 翻转，
#     映射 6×3 时代的玩家半场 row 3..5 到 3×3 player_main 的 row 2..0。
#   - cfg.faction == 1 → 路由到 enemy_main，row 0..2 不变。
#   - 新 JSON 可直接以顶层 "boards" 字段写明每盘各自的 initial_units / spawners。
static func _empty_level() -> Dictionary:
	return {
		"boards": {
			"player_main": _default_board_meta("player_main"),
			"enemy_main":  _default_board_meta("enemy_main"),
		},
		# 旧聚合视图（向后兼容）
		"initial_units": [],
		"spawners": [],
		# 局内棋盘事件：[{"turn":N, "add":[slot_idx,...], "remove":[slot_idx,...], "actions":[...]}]
		"board_events": [],
		# 剧情触发器：[{"id","when","once","cooldown","actions",[...]}]
		"triggers": [],
		# 战役章节专属字段：
		# hero_key —— 章节为玩家指定的英雄（hero.json key）。空时回退 BATTLE_HERO_KEY。
		# initial_mana —— 章节首回合起始费（max=current=N）。0/缺失时按默认 1 走。
		# mana_max_cap —— 章节费用上限硬封顶（如协防 cap=5 永久不再 +1）。0/缺失时按默认 10。
		# objective —— 章节胜利目标 {"type":..., 其它参数}。无 type 时不启用目标。
		"hero_key": "",
		"initial_mana": 0,
		"mana_max_cap": 0,
		"objective": {},
		# 章节名称（用于战斗内 ObjectiveDrawer 标题显示）
		"name": "",
	}

# 默认 board meta：保证主棋盘永远在 boards 段中存在，且默认 enabled=true。
# 附盘（ally_left / ally_right / enemy_left / enemy_right）默认不存在，
# 由关卡 JSON 显式声明才会被 Orchestrator 创建。
static func _default_board_meta(id: String) -> Dictionary:
	var meta := {
		"id": id,
		"faction": 1,             # 默认 ENEMY，下方按 id 修正
		"role": "enemy",
		"slot_index": -1,
		"enabled": false,         # 未知盘默认不自动创建，须 JSON 显式 enabled:true 或有内容
		"hero": {},               # 由 hero.json 提供 fallback
		"initial_units": [],
		"spawners": [],
		"spell_casters": [],      # SpellCasterSystem 配置
	}
	match id:
		"player_main":
			meta["faction"] = 0
			meta["role"] = "main_player"
			meta["slot_index"] = 4
			meta["enabled"] = true   # 主棋盘始终创建
		"enemy_main":
			meta["faction"] = 1
			meta["role"] = "main_enemy"
			meta["slot_index"] = 1
			meta["enabled"] = true   # 主棋盘始终创建
		"ally_left":
			meta["faction"] = 0
			meta["role"] = "ally"
			meta["slot_index"] = 3
		"ally_right":
			meta["faction"] = 0
			meta["role"] = "ally"
			meta["slot_index"] = 5
		"enemy_left":
			meta["faction"] = 1
			meta["role"] = "enemy"
			meta["slot_index"] = 0
		"enemy_right":
			meta["faction"] = 1
			meta["role"] = "enemy"
			meta["slot_index"] = 2
	return meta

const _OLD_ROWS: int = 6  # 旧 6×3 主棋盘行数，仅用于兼容映射

static func _route_pos(faction: int, raw_pos: Dictionary) -> Vector2:
	var r := int(raw_pos["row"])
	var c := int(raw_pos["col"])
	if faction == 0:
		# 玩家半场旧 row 3..5 → 新 player_main row 2..0
		return Vector2(_OLD_ROWS - 1 - r, c)
	# 敌方旧 row 0..2 → 新 enemy_main row 0..2
	return Vector2(r, c)

static func _route_board(faction: int) -> String:
	return "player_main" if faction == 0 else "enemy_main"

static func _parse_level(j: Dictionary) -> Dictionary:
	var out := _empty_level()
	# 优先解析新格式 boards 字段（多棋盘原生）
	if j.has("boards") and typeof(j["boards"]) == TYPE_DICTIONARY:
		for board_id in j["boards"].keys():
			var sub: Dictionary = j["boards"][board_id]
			var entry: Dictionary = out["boards"].get(board_id,
				_default_board_meta(board_id))
			_parse_board_section(sub, entry, false)
			# 元字段覆盖：faction / role / slot_index / enabled / hero
			if sub.has("faction"): entry["faction"] = int(sub["faction"])
			if sub.has("role"):    entry["role"]    = String(sub["role"])
			if sub.has("slot_index"): entry["slot_index"] = int(sub["slot_index"])
			if sub.has("enabled"): entry["enabled"] = bool(sub["enabled"])
			if sub.has("hero") and typeof(sub["hero"]) == TYPE_DICTIONARY:
				entry["hero"] = sub["hero"]
			out["boards"][board_id] = entry
	# 兼容旧格式：顶层 initial_units / spawners + faction 字段
	if j.has("initial_units") and typeof(j["initial_units"]) == TYPE_ARRAY:
		for cfg in j["initial_units"]:
			var faction: int = int(cfg.get("faction", 1))
			var board_id: String = _route_board(faction)
			var positions: Array = []
			for pos in cfg["positions"]:
				positions.append(_route_pos(faction, pos))
			out["boards"][board_id]["initial_units"].append({
				"name": cfg["name"],
				"faction": faction,
				"positions": positions,
			})
	if j.has("spawners") and typeof(j["spawners"]) == TYPE_ARRAY:
		for sp in j["spawners"]:
			var faction: int = int(sp.get("faction", 1))
			var board_id: String = _route_board(faction)
			var positions: Array = []
			if sp.has("positions") and typeof(sp["positions"]) == TYPE_ARRAY:
				for pos in sp["positions"]:
					positions.append(_route_pos(faction, pos))
			elif sp.has("position"):
				positions.append(_route_pos(faction, sp["position"]))
			out["boards"][board_id]["spawners"].append({
				"name": sp["name"],
				"faction": faction,
				"positions": positions,
				"interval": int(sp["interval"]),
			})
	# 聚合视图（旧调用方仍可读 out.initial_units / out.spawners）
	for board_id in out["boards"].keys():
		out["initial_units"].append_array(out["boards"][board_id]["initial_units"])
		out["spawners"].append_array(out["boards"][board_id]["spawners"])
	# 解析 board_events
	if j.has("board_events") and typeof(j["board_events"]) == TYPE_ARRAY:
		for ev in j["board_events"] as Array:
			if typeof(ev) != TYPE_DICTIONARY:
				continue
			var parsed_ev: Dictionary = {
				"turn":    int(ev.get("turn", -1)),
				"add":     _parse_int_array(ev.get("add", [])),
				"remove":  _parse_int_array(ev.get("remove", [])),
				# actions 数组原样保留（Events 自行解析）
				"actions": (ev.get("actions", []) as Array).duplicate(true),
			}
			if parsed_ev["turn"] >= 1:
				out["board_events"].append(parsed_ev)
	# 解析 triggers（顶层）
	if j.has("triggers") and typeof(j["triggers"]) == TYPE_ARRAY:
		for trig in j["triggers"] as Array:
			if typeof(trig) == TYPE_DICTIONARY:
				out["triggers"].append((trig as Dictionary).duplicate(true))
	# 战役章节专属字段（顶层）
	if j.has("hero_key") and typeof(j["hero_key"]) == TYPE_STRING:
		out["hero_key"] = String(j["hero_key"])
	if j.has("initial_mana"):
		out["initial_mana"] = int(j["initial_mana"])
	if j.has("mana_max_cap"):
		out["mana_max_cap"] = int(j["mana_max_cap"])
	if j.has("objective") and typeof(j["objective"]) == TYPE_DICTIONARY:
		out["objective"] = (j["objective"] as Dictionary).duplicate()
	# 章节名称（ObjectiveDrawer 顶部标题）
	if j.has("name") and typeof(j["name"]) == TYPE_STRING:
		out["name"] = String(j["name"])
	return out

# 解析 boards.<id> 子段。新格式 row/col 不做映射，按盘内 0..ROWS-1 读取。
static func _parse_board_section(sub: Dictionary, entry: Dictionary,
		_legacy_remap: bool) -> void:
	if sub.has("initial_units") and typeof(sub["initial_units"]) == TYPE_ARRAY:
		for cfg in sub["initial_units"]:
			var positions: Array = []
			for pos in cfg["positions"]:
				positions.append(Vector2(int(pos["row"]), int(pos["col"])))
			entry["initial_units"].append({
				"name": cfg["name"],
				"faction": int(cfg.get("faction", 1)),
				"positions": positions,
			})
	if sub.has("spawners") and typeof(sub["spawners"]) == TYPE_ARRAY:
		for sp in sub["spawners"]:
			var positions: Array = []
			if sp.has("positions") and typeof(sp["positions"]) == TYPE_ARRAY:
				for pos in sp["positions"]:
					positions.append(Vector2(int(pos["row"]), int(pos["col"])))
			elif sp.has("position"):
				positions.append(Vector2(int(sp["position"]["row"]), int(sp["position"]["col"])))
			entry["spawners"].append({
				"name": sp["name"],
				"faction": int(sp.get("faction", 1)),
				"positions": positions,
				"interval": int(sp["interval"]),
			})
	# spell_casters：原样保留，由 SpellCasterSystem.setup 解析
	if sub.has("spell_casters") and typeof(sub["spell_casters"]) == TYPE_ARRAY:
		entry["spell_casters"] = (sub["spell_casters"] as Array).duplicate(true)

static func _fallback_cards() -> Array:
	var a = CardUnit.new("填线宝宝", 1, 1, {"front": 1, "back": 1, "left": 1, "right": 1}, [])
	a.count = 5
	var b = CardUnit.new("灰烬填线宝宝", 2, 2, {"front": 2, "back": 2, "left": 2, "right": 2}, ["ash"])
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
# 战役数据（res://data/campaigns.json）
# ============================================================================

# 读取整个 campaigns.json。返回 {"campaigns": {key: {display_name, description, ...}}}。
# 文件缺失/损坏时返回空骨架；CampaignCarousel 自带占位文案兜底。
static func load_campaign_db() -> Dictionary:
	var empty := {"campaigns": {}}
	var j = _read_json(CAMPAIGNS_JSON)
	if typeof(j) != TYPE_DICTIONARY:
		return empty
	if not j.has("campaigns") or typeof(j["campaigns"]) != TYPE_DICTIONARY:
		j["campaigns"] = {}
	return j


# ============================================================================
# user://battle_cards.json 生成与读取
# ============================================================================

# 从 all_cards.json 中筛选玩家牌组卡 + 写入 count 字段，输出为
# user://battle_cards.json，供本局战斗读取。
#   hero_key: HeroCarousel 中的英雄 key（如 "A"）→ 决定从 decks.json 拿哪份卡组
#   失败兜底：玩家卡组为空时，写入空数组（战斗 _fallback_cards 接管）。
static func generate_battle_cards(hero_key: String) -> void:
	var deck_meta: Dictionary = DeckStorage.load_deck(hero_key)
	var deck: Dictionary = deck_meta.get("cards", {})
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


# 战役章节版：从章节 json 的 cards: [{name, count}] 取卡名 + 数量，
# 反查 all_cards.json 拼出本局牌堆，写入 user://battle_cards.json。
# 与 generate_battle_cards(hero_key) 平行：旧路径绑玩家备战卡组，本路径绑章节固定牌堆。
# Game.bootstrap 根据 pending_chapter_config 是否为空决定走哪一条。
static func generate_battle_cards_from_chapter(chapter_json_path: String) -> void:
	var raw_cfg = _read_json(chapter_json_path)
	if typeof(raw_cfg) != TYPE_DICTIONARY:
		push_warning("DataLoader.generate_battle_cards_from_chapter: bad chapter json " + chapter_json_path)
		_write_battle_cards([])
		return
	var cards = raw_cfg.get("cards", [])
	if typeof(cards) != TYPE_ARRAY:
		_write_battle_cards([])
		return

	var raw = _read_json(ALL_CARDS_JSON)
	var index: Dictionary = {}
	if typeof(raw) == TYPE_ARRAY:
		for p in raw:
			if typeof(p) == TYPE_DICTIONARY and p.has("name"):
				index[String(p["name"])] = p

	var out: Array = []
	for entry in cards:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var cname := String(entry.get("name", ""))
		var cnt: int = int(entry.get("count", 1))
		if cname == "" or cnt <= 0:
			continue
		var proto = index.get(cname, null)
		if proto == null:
			push_warning("generate_battle_cards_from_chapter: card not in all_cards: " + cname)
			continue
		var copy: Dictionary = proto.duplicate(true)
		copy["count"] = cnt
		out.append(copy)
	_write_battle_cards(out)


# 提取的写盘工具（两版 generate 共用），减重复。
static func _write_battle_cards(arr: Array) -> void:
	var f := FileAccess.open(BATTLE_CARDS_JSON, FileAccess.WRITE)
	if f == null:
		push_error("DataLoader: cannot write " + BATTLE_CARDS_JSON)
		return
	f.store_string(JSON.stringify(arr, "\t"))
	f.close()
