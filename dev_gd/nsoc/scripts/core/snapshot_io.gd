class_name SnapshotIO
extends RefCounted

# 战斗状态快照 IO（PVP 联机基础设施）。
# Step 1：先做单玩家本地存读档原型，验证序列化边界。
# Step 5+：扩展为多玩家 + 私密性过滤（按 player_id 拆 deck/hand/equipments）。
#
# 顶层包装规则：
#   - 调 Game.deck / Game.mana / Game.registry / Equipments 各自的 to_dict()
#   - 卡牌按 name string 序列化；反序通过 Game.get_card(name) 还原
#   - 视觉节点不序列化；BoardSlot 视觉容器（bg_panel / grid_node / hero_panel）
#     由场景树持有，反序时只更新数据层
#
# 不序列化的部分（PVP 阶段会另行处理或跳过）：
#   - SpawnerSystem._spawners 配置（PVP 关闭 spawner）
#   - SpellCasterSystem._casters 配置（PVP 关闭 spell caster）
#   - HeroAbilityRegistry 内的 once_per_turn 状态（待加）
#   - Game.level_data（关卡静态配置，PVP 由服务器下发）
#   - DialogueManager / ScriptedEvents 状态（PVP 禁用）

const VERSION: int = 1

# 序列化整局战斗到 Dictionary。
# 1v1 阶段先做"完整可见"版本（无私密性过滤）。
# 多玩家阶段在此调用 to_dict_public 与 player_id 比对决定取哪个版本。
static func serialize_battle() -> Dictionary:
	var snap: Dictionary = {
		"version": VERSION,
		"turn_number": 0,
	}
	if Engine.get_main_loop() == null:
		return snap
	var root: Node = Engine.get_main_loop().root
	if not root.has_node("/root/Game"):
		return snap

	if Game.turn != null:
		snap["turn_number"] = Game.turn.turn_number
	if Game.deck != null:
		snap["deck"] = Game.deck.to_dict()
	if Game.mana != null:
		snap["mana"] = Game.mana.to_dict()
	snap["counters"] = Game.counters.duplicate() if Game.counters != null else {}

	# 多盘快照
	var slots_arr: Array = []
	if Game.registry != null:
		for slot in Game.registry.slots:
			if slot == null:
				continue
			slots_arr.append(slot.to_dict())
	snap["slots"] = slots_arr

	# 装备
	if root.has_node("/root/Equipments"):
		snap["equipments"] = Equipments.to_dict()

	return snap

# 从 Dictionary 还原整局战斗状态。
# 前提：Game.bootstrap() 已跑过（卡牌库 / BoardSlot / 空 Cell 已建好）。
# 反序后视觉自动通过各 from_dict 内部的信号刷新。
static func restore_battle(snap: Dictionary) -> void:
	if typeof(snap) != TYPE_DICTIONARY:
		push_warning("SnapshotIO.restore_battle: snap 非字典")
		return
	if int(snap.get("version", 0)) != VERSION:
		push_warning("SnapshotIO.restore_battle: 版本不匹配，期望 %d 收到 %s" % [VERSION, snap.get("version")])
		# 版本不一致仍尝试恢复（原型期）
	if Engine.get_main_loop() == null:
		return
	var root: Node = Engine.get_main_loop().root
	if not root.has_node("/root/Game"):
		return

	if Game.turn != null:
		Game.turn.turn_number = int(snap.get("turn_number", 0))
	if Game.deck != null and snap.has("deck"):
		Game.deck.from_dict(snap["deck"])
	if Game.mana != null and snap.has("mana"):
		Game.mana.from_dict(snap["mana"])
	var raw_counters = snap.get("counters", {})
	if Game.counters != null and typeof(raw_counters) == TYPE_DICTIONARY:
		Game.counters.clear()
		for k in raw_counters.keys():
			Game.counters[k] = raw_counters[k]

	# 多盘
	if Game.registry != null and snap.has("slots"):
		var raw_slots = snap["slots"]
		if typeof(raw_slots) == TYPE_ARRAY:
			# 按 id 匹配（顺序无关）；缺失盘静默跳过
			var by_id: Dictionary = {}
			for slot in Game.registry.slots:
				if slot != null:
					by_id[slot.id] = slot
			for entry in raw_slots:
				if typeof(entry) != TYPE_DICTIONARY:
					continue
				var sid: String = String(entry.get("id", ""))
				var slot = by_id.get(sid)
				if slot != null:
					slot.from_dict(entry)

	if root.has_node("/root/Equipments") and snap.has("equipments"):
		Equipments.from_dict(snap["equipments"])

# ── 本地存读档（开发期调试用）────────────────────────────────────────
const SAVE_PATH: String = "user://battle_snapshot.json"

static func save_to_file(path: String = SAVE_PATH) -> bool:
	var snap := serialize_battle()
	var f := FileAccess.open(path, FileAccess.WRITE)
	if f == null:
		push_warning("SnapshotIO: 无法写入 %s" % path)
		return false
	f.store_string(JSON.stringify(snap, "  "))
	f.close()
	return true

static func load_from_file(path: String = SAVE_PATH) -> bool:
	if not FileAccess.file_exists(path):
		return false
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return false
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("SnapshotIO: 读取的 JSON 不是字典")
		return false
	restore_battle(parsed)
	return true
