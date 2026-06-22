class_name EmpireStateIO
extends RefCounted

# 帝国模式快照序列化 / 反序列化。
# 与 EmpireTest 解耦：所有状态通过参数传入，不持有对 EmpireTest 的引用。
#
# 职责：
#   build_snapshot()       — 把运行时状态打包为可序列化字典
#   write_save_slot()      — 附加 meta，调用 EmpireSaveStorage 写盘
#   apply_snapshot()       — 把快照字典反序列化回运行时状态
#   read_scenario_meta()   — 从 map JSON 读剧本 id/name
#
# 调用方（EmpireTest）负责把 _shape_nodes / _id_to_node 等传入，
# 并在 apply_snapshot 后自行刷新 UI。


# ── 构建快照 ─────────────────────────────────────────────────────────────────
# deployed_heroes: hero_key → EmpireMapShapeNode
# exiled_heroes:   hero_key → true
# pending_campaigns: target_id(int) → Array[hero_key]
# pending_campaign_sources: hero_key → source_node_id(int)
# pending_moves:   hero_key → EmpireMapShapeNode
# shape_nodes:     Array[EmpireMapShapeNode]
static func build_snapshot(
		deployed_heroes: Dictionary,
		exiled_heroes: Dictionary,
		pending_campaigns: Dictionary,
		pending_campaign_sources: Dictionary,
		pending_moves: Dictionary,
		shape_nodes: Array,
		battle_select_mode: bool,
		player_gold: int,
		player_food: int,
		turn_number: int,
		talent_last_hero: String,
		map_path: String
) -> Dictionary:
	var deployed: Dictionary = {}
	for k in deployed_heroes.keys():
		var n = deployed_heroes[k]
		if is_instance_valid(n) and "_id" in n:
			deployed[String(k)] = int(n._id)

	var faction_snap: Dictionary = {}
	for n in shape_nodes:
		if is_instance_valid(n) and "_id" in n and "_faction_id" in n:
			faction_snap[int(n._id)] = int(n._faction_id)

	var camps_dump: Dictionary = {}
	for tid in pending_campaigns.keys():
		camps_dump[str(int(tid))] = (pending_campaigns[tid] as Array).duplicate()

	var moves_dump: Dictionary = {}
	for hk in pending_moves.keys():
		var mn = pending_moves[hk]
		if is_instance_valid(mn) and "_id" in mn:
			moves_dump[String(hk)] = int(mn._id)

	var decks_snap: Dictionary = EmpireDeckStorage.dump_for_save()

	return {
		"deployed":                 deployed,
		"exiled":                   exiled_heroes.duplicate(),
		"pending_campaigns":        camps_dump,
		"pending_campaign_sources": pending_campaign_sources.duplicate(),
		"pending_moves":            moves_dump,
		"battle_select_mode":       battle_select_mode,
		"faction_overrides":        faction_snap,
		"gold":                     player_gold,
		"food":                     player_food,
		"turn_number":              turn_number,
		"talent_last_hero":         talent_last_hero,
		"map_path":                 map_path,
		"decks":                    decks_snap,
	}


# ── 写槽位 ───────────────────────────────────────────────────────────────────
# 附加 meta 摘要后调用 EmpireSaveStorage.save_slot。
# alive_hero_count: 未流放人才数量（由调用方传入，避免重算）
static func write_save_slot(
		slot_id: String,
		snap: Dictionary,
		map_path: String,
		turn_number: int,
		player_gold: int,
		player_food: int,
		alive_hero_count: int
) -> void:
	var scenario_id: String = ""
	var scenario_name: String = ""
	var file := FileAccess.open(map_path, FileAccess.READ)
	if file != null:
		var j := JSON.new()
		if j.parse(file.get_as_text()) == OK:
			var sc: Dictionary = (j.get_data() as Dictionary).get("scenario", {})
			scenario_id   = str(sc.get("id",   ""))
			scenario_name = str(sc.get("name", ""))
		file.close()
	var meta: Dictionary = {
		"timestamp":     Time.get_unix_time_from_system(),
		"scenario_id":   scenario_id,
		"scenario_name": scenario_name,
		"map_path":      map_path,
		"turn_number":   turn_number,
		"gold":          player_gold,
		"food":          player_food,
		"hero_count":    alive_hero_count,
	}
	EmpireSaveStorage.save_slot(slot_id, meta, snap)


# ── 反序列化快照 ─────────────────────────────────────────────────────────────
# 把 snap 写回运行时状态。
# id_to_node: node_id(int) → EmpireMapShapeNode
# faction_color_fn / faction_name_fn: Callable(faction_id:int) → Color/String
#
# 返回一个 Dictionary，包含恢复后的各项状态，由调用方写回自身成员：
#   {
#     "deployed_heroes": Dictionary,
#     "exiled_heroes": Dictionary,
#     "pending_campaigns": Dictionary,
#     "pending_campaign_sources": Dictionary,
#     "pending_moves": Dictionary,
#     "player_gold": int,
#     "player_food": int,
#     "turn_number": int,
#     "talent_last_hero": String,
#     "battle_select_mode": bool,
#   }
static func apply_snapshot(
		snap: Dictionary,
		id_to_node: Dictionary,
		faction_color_fn: Callable,
		faction_name_fn: Callable
) -> Dictionary:
	# --- 卡组 ---
	EmpireDeckStorage.inject_from_save(snap.get("decks", {}))

	# --- 节点势力 ---
	var fmap: Dictionary = snap.get("faction_overrides", {})
	for nid in fmap.keys():
		var node = id_to_node.get(int(nid), null)
		if node and is_instance_valid(node):
			var fid: int = int(fmap[nid])
			node._faction_id   = fid
			node._fill         = faction_color_fn.call(fid)
			node._faction_name = faction_name_fn.call(fid)
			node.queue_redraw()

	# --- 部署 ---
	var deployed: Dictionary = {}
	var dep: Dictionary = snap.get("deployed", {})
	for hk in dep.keys():
		var n = id_to_node.get(int(dep[hk]), null)
		if n and is_instance_valid(n):
			deployed[String(hk)] = n

	# --- 流放 ---
	var exiled: Dictionary = (snap.get("exiled", {}) as Dictionary).duplicate()

	# --- 出征 ---
	var campaigns: Dictionary = {}
	var camps_dump: Dictionary = snap.get("pending_campaigns", {})
	for sid in camps_dump.keys():
		campaigns[int(sid)] = (camps_dump[sid] as Array).duplicate()
	var campaign_sources: Dictionary = (snap.get("pending_campaign_sources", {}) as Dictionary).duplicate()

	# --- 行棋 ---
	var moves: Dictionary = {}
	var moves_dump: Dictionary = snap.get("pending_moves", {})
	for hk in moves_dump.keys():
		var n = id_to_node.get(int(moves_dump[hk]), null)
		if n and is_instance_valid(n):
			moves[String(hk)] = n

	return {
		"deployed_heroes":            deployed,
		"exiled_heroes":              exiled,
		"pending_campaigns":          campaigns,
		"pending_campaign_sources":   campaign_sources,
		"pending_moves":              moves,
		"player_gold":                int(snap.get("gold", 0)),
		"player_food":                int(snap.get("food", 0)),
		"turn_number":                int(snap.get("turn_number", 0)),
		"talent_last_hero":           String(snap.get("talent_last_hero", "")),
		"battle_select_mode":         bool(snap.get("battle_select_mode", false)),
	}
