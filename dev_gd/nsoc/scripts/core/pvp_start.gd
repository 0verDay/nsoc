class_name PvpStart
extends RefCounted

## `game/start` 载荷 → `bootstrap_pvp` 入参的**唯一解析入口**（重构文档.md §7 阶段 3）。
##
## 为什么单独成类：大厅（SparringPanel._handle_game_start）与 headless PVP 冒烟
## （tests/HeadlessPvp）必须走**同一份**解析逻辑 —— 否则"冒烟通过"证明不了真实入口。
##
## 纯数据、无场景树依赖（分层规则：core 层），可在无头环境直接调用。

## 解析结果：
##   order                  Array[String]             行动顺序
##   per_player_deck_cards  Dictionary{pid: Array}    每位玩家牌组（卡牌原型对象）
##   per_player_heroes      Dictionary{pid: hero_key}
##   rng_seed               int
##   match_type             String  ("1v1" / "1v3" / "3v3")
##   slot_layout            Array[Dictionary]
##   local_deck_fallback    bool    本地玩家牌组是否走了本地兜底
##   shared_deck_fallback   bool    是否用了旧协议的"全员共用牌组"
static func resolve(payload: Dictionary, local_pid: String,
		fallback_deck_names: Array = [], fallback_hero_key: String = "",
		card_db: Dictionary = {}, fallback_order: Array = []) -> Dictionary:
	var order: Array = _string_array(payload.get("action_order", []))
	if order.is_empty():
		order = _string_array(fallback_order)
	var rng_seed: int = int(payload.get("rng_seed", 0))

	# 牌组：新协议 per_player_decks（{ pid: [卡名] }），旧协议 deck_names（全员共用）
	var deck_names_by_pid: Dictionary = {}
	var shared_deck_fallback: bool = false
	var raw_ppd = payload.get("per_player_decks", {})
	if typeof(raw_ppd) == TYPE_DICTIONARY and not (raw_ppd as Dictionary).is_empty():
		for pid_raw in (raw_ppd as Dictionary).keys():
			deck_names_by_pid[String(pid_raw)] = _string_array((raw_ppd as Dictionary)[pid_raw])
	else:
		shared_deck_fallback = true
		var shared: Array = _string_array(payload.get("deck_names", []))
		for pid_raw in order:
			deck_names_by_pid[String(pid_raw)] = shared.duplicate()

	# 本地玩家牌组缺失 → 用本地存档兜底（离线 / 旧服务端）
	var local_deck_fallback: bool = false
	if not deck_names_by_pid.has(local_pid) or (deck_names_by_pid[local_pid] as Array).is_empty():
		local_deck_fallback = true
		deck_names_by_pid[local_pid] = _string_array(fallback_deck_names)

	var per_player_deck_cards: Dictionary = {}
	for pid_raw in deck_names_by_pid.keys():
		per_player_deck_cards[String(pid_raw)] = _cards_of(deck_names_by_pid[pid_raw], card_db)

	# 英雄：{ pid: hero_key }；本地玩家缺失 → 本地选中英雄
	var per_player_heroes: Dictionary = {}
	var raw_pph = payload.get("per_player_heroes", {})
	if typeof(raw_pph) == TYPE_DICTIONARY:
		for pid_raw in (raw_pph as Dictionary).keys():
			var hkey: String = String((raw_pph as Dictionary)[pid_raw])
			if hkey != "":
				per_player_heroes[String(pid_raw)] = hkey
	if not per_player_heroes.has(local_pid) or String(per_player_heroes[local_pid]) == "":
		per_player_heroes[local_pid] = fallback_hero_key

	# 对阵类型 + 槽位布局
	var match_type: String = String(payload.get("match_type", "1v1"))
	var slot_layout: Array = []
	var raw_sl = payload.get("slot_layout", [])
	if typeof(raw_sl) == TYPE_ARRAY:
		for entry in raw_sl:
			if typeof(entry) == TYPE_DICTIONARY:
				slot_layout.append(entry)

	return {
		"order":                 order,
		"per_player_deck_cards": per_player_deck_cards,
		"per_player_heroes":     per_player_heroes,
		"rng_seed":              rng_seed,
		"match_type":            match_type,
		"slot_layout":           slot_layout,
		"local_deck_fallback":   local_deck_fallback,
		"shared_deck_fallback":  shared_deck_fallback,
	}


# ── 内部 ──────────────────────────────────────────────────────────────────

## 卡名列表 → 卡牌原型列表（未知卡名跳过，与大厅原行为一致）。
static func _cards_of(names: Array, card_db: Dictionary) -> Array:
	var cards: Array = []
	for n in names:
		var c = card_db.get(String(n))
		if c != null:
			cards.append(c)
	return cards


static func _string_array(raw) -> Array:
	var out: Array = []
	if typeof(raw) != TYPE_ARRAY:
		return out
	for v in raw:
		out.append(String(v))
	return out
