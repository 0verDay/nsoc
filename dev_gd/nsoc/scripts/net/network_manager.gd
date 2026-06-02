extends Node

# NetworkManager —— WebSocket 客户端网络层。autoload "Net"。
#
# 职责：
#   1. 管理与服务器的 WebSocket 连接（连接 / 断开 / 重连）
#   2. 把收到的 JSON 文本反序列化为 Dictionary 并分发信号
#   3. 提供 send / send_to_room 便捷发送 API
#   4. 持有本地玩家 uuid + nickname（来自 ProfileManager）
#
# 使用方式：
#   Net.connect_to_server()                    # 读 user://server.json 自动连接
#   Net.connect_to_server("192.168.1.1", 8080) # 指定地址
#   Net.send_to_room("game/start", room_id)    # 发消息
#   Net.message_received.connect(_on_msg)      # 监听所有入站消息
#
# 连接参数通过 URL query 传给服务器：
#   ws://host:port/ws?uuid=<uuid>&nickname=<encoded_nick>

signal connected
signal connection_failed(reason: String)
signal disconnected
signal message_received(msg: Dictionary)

# 连接状态
const STATE_DISCONNECTED: int = 0
const STATE_CONNECTING:   int = 1
const STATE_CONNECTED:    int = 2

var _peer: WebSocketPeer = null
var _state: int = STATE_DISCONNECTED

var _uuid: String = ""
# session_id = uuid + 随机 4 位后缀，每次启动重新生成。
# 同一台机跑两个实例时两端 uuid 相同，但 session_id 不同，
# 保证服务器 / 消息路由能区分两个玩家。
var _session_id: String = ""
var _nickname: String = ""

func _ready() -> void:
	_uuid     = ProfileManager.get_or_create_uuid()
	_nickname = ProfileManager.get_nickname()
	var rng := RandomNumberGenerator.new()
	rng.randomize()
	_session_id = _uuid + "_" + str(rng.randi_range(1000, 9999))

# ── 连接 / 断开 ──────────────────────────────────────────────────────
func connect_to_server(host: String = "", port: int = 0) -> void:
	if _state != STATE_DISCONNECTED:
		disconnect_from_server()
	if host == "":
		var cfg := ProfileManager.get_server_config()
		host = cfg.host
		port = int(cfg.port)
	# 用 session_id 作为 uuid 参数，保证同机两实例被服务器视为不同玩家
	var url: String = "ws://%s:%d/ws?uuid=%s&nickname=%s" % [
		host, port, _session_id, _nickname.uri_encode(),
	]
	_peer = WebSocketPeer.new()
	var err := _peer.connect_to_url(url)
	if err != OK:
		_peer = null
		connection_failed.emit("connect_to_url error %d" % err)
		return
	_state = STATE_CONNECTING

func disconnect_from_server() -> void:
	if _peer != null:
		_peer.close()
		_peer = null
	if _state != STATE_DISCONNECTED:
		_state = STATE_DISCONNECTED
		disconnected.emit()

# ── _process：轮询 WebSocketPeer ─────────────────────────────────────
func _process(_delta: float) -> void:
	if _peer == null:
		return
	_peer.poll()
	var ws_state := _peer.get_ready_state()
	match ws_state:
		WebSocketPeer.STATE_OPEN:
			if _state != STATE_CONNECTED:
				_state = STATE_CONNECTED
				connected.emit()
			_drain_packets()
		WebSocketPeer.STATE_CONNECTING:
			pass  # 等待
		WebSocketPeer.STATE_CLOSING, WebSocketPeer.STATE_CLOSED:
			if _state != STATE_DISCONNECTED:
				_state = STATE_DISCONNECTED
				_peer = null
				disconnected.emit()

func _drain_packets() -> void:
	while _peer != null and _peer.get_available_packet_count() > 0:
		var raw: PackedByteArray = _peer.get_packet()
		var text: String = raw.get_string_from_utf8()
		var d = JSON.parse_string(text)
		if typeof(d) == TYPE_DICTIONARY:
			message_received.emit(d)
		else:
			push_warning("Net: invalid JSON: %s" % text.left(120))

# ── 发送 API ─────────────────────────────────────────────────────────
func send(msg: Dictionary) -> void:
	if _peer == null or _peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		push_warning("Net: not connected, drop %s" % msg.get("type", "?"))
		return
	_peer.send_text(JSON.stringify(msg))

# 便捷包装：自动填 room_id 与 to 字段。
func send_to_room(type: String, room_id: String,
		payload: Dictionary = {}, to: String = "all") -> void:
	send({
		"type":    type,
		"to":      to,
		"room_id": room_id,
		"payload": payload,
	})

# 发给房主（to = "host"）。
func send_to_host(type: String, room_id: String, payload: Dictionary = {}) -> void:
	send_to_room(type, room_id, payload, "host")

# 发给指定 uuid。
func send_to(type: String, room_id: String, target_uuid: String,
		payload: Dictionary = {}) -> void:
	send_to_room(type, room_id, payload, target_uuid)

# ── 便捷查询 ─────────────────────────────────────────────────────────
func is_connected_to_server() -> bool:
	return _state == STATE_CONNECTED

# 当前所在房间号（由 pvp_lobby 在切场景前注入）。
# 战斗场景通过此字段发 action/* 消息。
var _current_room_id: String = ""

func set_current_room_id(rid: String) -> void:
	_current_room_id = rid

func get_current_room_id() -> String:
	return _current_room_id

func get_uuid() -> String:
	return _uuid

# 本次会话唯一标识（含随机后缀），用于玩家身份识别。
func get_session_id() -> String:
	return _session_id

func get_nickname() -> String:
	return _nickname

# 同步更新昵称（同时持久化到 profile.json）。
func set_nickname(nick: String) -> void:
	_nickname = nick
	ProfileManager.set_nickname(nick)
