extends Node

# NetworkManager —— **空壳**（autoload "Net"）。
#
# ⚠️  本项目已转为**纯本地**（单机战役 + 自由对战 + 演义模式）。
#     联机层、中继服务端与权威裁判进程已整体删除，详见
#     `docs/archive/multiplayer-removal.md`。
#
# 为什么还留着这个 autoload：
#   PVP 回合 / 队伍内核（`Game.bootstrap_pvp`、`Game.pvp_*`、`run_pvp_phase*`、
#   `test_main` 的 PVP 装配等）按决策**保留为死代码**，将来要恢复联机时照着归档清单
#   接回来即可。那些内核里有 `Net.send_to_room(...)` / `Net.get_current_room_id()`
#   这类调用 —— 本文件保留它们的**同名同签名空实现**，内核才能通过脚本解析检查。
#
# 行为约定（务必与调用方预期一致）：
#   * 一行网络都不发：没有 WebSocketPeer，没有 socket，没有连接。
#   * `is_connected_to_server()` 恒为 false → 所有"连上才做事"的分支永不进入。
#   * `send()` / `send_to_room()` / `send_intent()` 全部静默丢弃（只打一条 warning）。
#   * `current_room_id` 永远是空串 → 内核里 `pvp_room_id != ""` 的判断恒为 false。
#
# 因此：联机内核作为死代码可以安全存在，但**不可能**真的连上任何东西。

# ── 连接状态信号（保留签名，永远不发）─────────────────────────────────
signal connected
signal connection_failed(reason: String)
signal disconnected
signal message_received(msg: Dictionary)

# ── 权威协议下行信号（保留签名，永远不发）─────────────────────────────
signal auth_hello(payload: Dictionary)
signal auth_state(payload: Dictionary)
signal auth_event(payload: Dictionary)
signal auth_reject(payload: Dictionary)
signal auth_verdict(payload: Dictionary)
signal auth_request_choice(payload: Dictionary)

# ── 状态常量（保留，供 /root/Net 的调用方比较）─────────────────────────
const STATE_DISCONNECTED: int = 0
const STATE_CONNECTING:   int = 1
const STATE_CONNECTED:    int = 2

# ── 兼容字段（写入无副作用，读取无害）─────────────────────────────────
## 是否使用 v2 权威协议。空壳下无意义，保留以免死代码引用报错。
var use_v2: bool = false
## 建房时是否请求服务器权威。空壳下无意义。
var want_authoritative: bool = false
## 连接后是否自动握手。空壳下无意义。
var auto_hello: bool = true

# 当前房间号：**永远为空**。大厅已不可用，没有东西会写它。
var _current_room_id: String = ""

# 本次会话唯一标识。只用于本地显示/日志，不再参与任何路由。
var _session_id: String = "local"
var _nickname: String = "玩家"

func _ready() -> void:
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	_session_id = "local_%d" % rng.randi_range(1000, 9999)


# ── 连接 / 断开：全部为空操作 ─────────────────────────────────────────
## 空壳：不再建立任何连接。参数保留以便死代码与将来恢复联机时同名调用。
func connect_to_server(_host: String = "", _port: int = 0) -> void:
	pass


func disconnect_from_server() -> void:
	pass


# ── 发送 API：全部静默丢弃 ────────────────────────────────────────────
func send(msg: Dictionary) -> void:
	push_warning("Net（空壳）: 联机已移除，丢弃消息 %s" % msg.get("type", "?"))


## 便捷包装：自动填 room_id 与 to 字段。
func send_to_room(type: String, room_id: String,
		payload: Dictionary = {}, to: String = "all") -> void:
	send(build_message(type, payload, to, room_id))


## 构造一条 v1 业务消息（纯函数；不发包，便于死代码与测试复用）。
func build_message(type: String, payload: Dictionary = {},
		to: String = "all", room_id: String = "") -> Dictionary:
	return {
		"type":    type,
		"to":      to,
		"room_id": room_id,
		"payload": payload,
	}


## 构造一条 v2 意图消息（纯函数）。
func build_intent(type: String, payload: Dictionary = {}) -> Dictionary:
	return {
		"type":    type,
		"room_id": _current_room_id,
		"payload": payload,
	}


## 发一条 v2 意图（空壳：丢弃）。
func send_intent(type: String, payload: Dictionary = {}) -> void:
	send(build_intent(type, payload))


## 发握手（空壳：丢弃）。
func send_client_hello(_content_hash: String = "") -> void:
	pass


## 最近发出的 v2 消息：空壳永远为空。
func sent_log() -> Array:
	return []


func clear_sent_log() -> void:
	pass


## 发 heartbeat（空壳：丢弃）。
func send_client_ping() -> void:
	pass


## 给意图补 `seq`（纯函数）。
func next_intent(type: String, payload: Dictionary, seq: int) -> Dictionary:
	var out: Dictionary = payload.duplicate()
	out["seq"] = seq
	return build_intent(type, out)


# 发给指定 uuid（空壳：丢弃）。
func send_to(type: String, room_id: String, target_uuid: String,
		payload: Dictionary = {}) -> void:
	send_to_room(type, room_id, payload, target_uuid)


# ── 便捷查询 ─────────────────────────────────────────────────────────
## 恒为 false：联机层已删除，本项目不再有任何服务器连接。
func is_connected_to_server() -> bool:
	return false


func set_current_room_id(rid: String) -> void:
	_current_room_id = rid


func get_current_room_id() -> String:
	return _current_room_id


## 本次会话唯一标识（仅本地用途）。
func get_session_id() -> String:
	return _session_id


func get_nickname() -> String:
	return _nickname


## 同步更新昵称（仅内存；本地身份不再持久化到 user://profile.json）。
func set_nickname(nick: String) -> void:
	_nickname = nick
