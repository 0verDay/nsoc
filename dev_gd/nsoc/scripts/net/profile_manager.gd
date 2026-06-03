class_name ProfileManager
extends RefCounted

# 本地玩家身份持久化。保存于 user://profile.json。
# 不需要 autoload，所有方法为 static，可在任何地方直接调用。
#
# user://profile.json 结构：
#   { "uuid": "...", "nickname": "玩家甲" }
#
# user://server.json 结构：
#   { "host": "159.75.154.122", "port": 8080 }

const PROFILE_PATH: String = "user://profile.json"
const SERVER_PATH:  String = "user://server.json"

# ── UUID ─────────────────────────────────────────────────────────────
# 首次调用时生成并持久化 UUID v4（简化实现，随机 128 位）。
static func get_or_create_uuid() -> String:
	var p := _load_profile()
	var uid: String = String(p.get("uuid", ""))
	if uid != "":
		return uid
	uid = _gen_uuid()
	p["uuid"] = uid
	_save_profile(p)
	return uid

# ── 昵称 ─────────────────────────────────────────────────────────────
static func get_nickname() -> String:
	return String(_load_profile().get("nickname", "玩家"))

static func set_nickname(nick: String) -> void:
	var p := _load_profile()
	p["nickname"] = nick
	_save_profile(p)

# ── 服务器配置 ────────────────────────────────────────────────────────
static func get_server_config() -> Dictionary:
	if not FileAccess.file_exists(SERVER_PATH):
		return _default_server()
	var f := FileAccess.open(SERVER_PATH, FileAccess.READ)
	if f == null:
		return _default_server()
	var d = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(d) != TYPE_DICTIONARY:
		return _default_server()
	return {
		"host": String(d.get("host", "159.75.154.122")),
		"port": int(d.get("port", 8080)),
	}

static func save_server_config(host: String, port: int) -> void:
	var f := FileAccess.open(SERVER_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify({"host": host, "port": port}, "  "))
	f.close()

# ── 内部 ─────────────────────────────────────────────────────────────
static func _default_server() -> Dictionary:
	return {"host": "159.75.154.122", "port": 8080}

static func _load_profile() -> Dictionary:
	if not FileAccess.file_exists(PROFILE_PATH):
		return {}
	var f := FileAccess.open(PROFILE_PATH, FileAccess.READ)
	if f == null:
		return {}
	var d = JSON.parse_string(f.get_as_text())
	f.close()
	return d if typeof(d) == TYPE_DICTIONARY else {}

static func _save_profile(d: Dictionary) -> void:
	var f := FileAccess.open(PROFILE_PATH, FileAccess.WRITE)
	if f == null:
		return
	f.store_string(JSON.stringify(d, "  "))
	f.close()

# 简化 UUID v4：32 位随机十六进制 + 标准分隔符。
static func _gen_uuid() -> String:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	const HEX: String = "0123456789abcdef"
	var out: String = ""
	for i in range(32):
		if i == 8 or i == 12 or i == 16 or i == 20:
			out += "-"
		if i == 12:
			out += "4"
		elif i == 16:
			out += HEX[rng.randi_range(8, 11)]
		else:
			out += HEX[rng.randi_range(0, 15)]
	return out
