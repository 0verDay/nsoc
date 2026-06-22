class_name EmpireSaveStorage
extends RefCounted

# 帝国模式存读档（user://empire_saves.json）。
# 槽位：
#   "auto"   — 自动档（回合结束时写入）
#   "slot_1" / "slot_2" / "slot_3" — 手动档（玩家主动存档）
#
# 文件结构：
#   {
#     "version": int,
#     "slots": {
#       "<slot_id>": {
#         "meta":  {timestamp, scenario_id, scenario_name, map_path,
#                   turn_number, gold, food, hero_count},
#         "state": { ...完整快照（含 decks 子字段）... }
#       }
#     }
#   }

const PATH: String = "user://empire_saves.json"
const SCHEMA_VERSION: int = 1

const SLOT_AUTO: String   = "auto"
const SLOT_1: String      = "slot_1"
const SLOT_2: String      = "slot_2"
const SLOT_3: String      = "slot_3"

const MANUAL_SLOTS: Array = ["slot_1", "slot_2", "slot_3"]
const ALL_SLOTS: Array    = ["auto", "slot_1", "slot_2", "slot_3"]


static func load_all() -> Dictionary:
	var empty := {"version": SCHEMA_VERSION, "slots": {}}
	if not FileAccess.file_exists(PATH):
		return empty
	var f := FileAccess.open(PATH, FileAccess.READ)
	if f == null:
		push_warning("EmpireSaveStorage: cannot open " + PATH)
		return empty
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		push_warning("EmpireSaveStorage: malformed json, reset to empty")
		return empty
	if not parsed.has("slots") or typeof(parsed["slots"]) != TYPE_DICTIONARY:
		parsed["slots"] = {}
	return parsed


static func _save_all(data: Dictionary) -> void:
	data["version"] = SCHEMA_VERSION
	var f := FileAccess.open(PATH, FileAccess.WRITE)
	if f == null:
		push_warning("EmpireSaveStorage: cannot write " + PATH)
		return
	f.store_string(JSON.stringify(data, "\t"))
	f.close()


# 存入指定槽位。meta / state 均为调用方构建的 Dictionary。
static func save_slot(slot_id: String, meta: Dictionary, state: Dictionary) -> void:
	var data := load_all()
	data["slots"][slot_id] = {"meta": meta, "state": state}
	_save_all(data)


# 读取指定槽位；不存在则返回空 Dictionary。
# 返回结构：{"meta": {...}, "state": {...}}
static func load_slot(slot_id: String) -> Dictionary:
	var data := load_all()
	var slots: Dictionary = data.get("slots", {})
	var entry = slots.get(slot_id, null)
	if typeof(entry) != TYPE_DICTIONARY:
		return {}
	return entry


# 删除指定槽位。
static func delete_slot(slot_id: String) -> void:
	var data := load_all()
	data["slots"].erase(slot_id)
	_save_all(data)


# 返回所有已存在槽位的摘要，格式：
#   [ {"slot_id": String, "meta": {...}}, ... ]
# 顺序：auto 优先，其次 slot_1/2/3；空槽不包含。
static func list_slots() -> Array:
	var data := load_all()
	var slots: Dictionary = data.get("slots", {})
	var out: Array = []
	for sid in ALL_SLOTS:
		if slots.has(sid) and typeof(slots[sid]) == TYPE_DICTIONARY:
			out.append({"slot_id": sid, "meta": slots[sid].get("meta", {})})
	return out


# 自动档是否存在。
static func has_auto_save() -> bool:
	return not load_slot(SLOT_AUTO).is_empty()
