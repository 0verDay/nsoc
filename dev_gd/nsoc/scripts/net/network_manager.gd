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

# ── v2 权威协议下行信号（客户端接入权威路径用）──────────────────────────
# 默认 use_v2 = false：老路径（action/* + message_received）行为逐字不变。
# 打开后连接建立即自动发 client/hello，并按 auth/* 类型分发到下面的信号。
signal auth_hello(payload: Dictionary)
signal auth_state(payload: Dictionary)
signal auth_event(payload: Dictionary)
signal auth_reject(payload: Dictionary)
signal auth_verdict(payload: Dictionary)
signal auth_request_choice(payload: Dictionary)

## 是否使用 v2 权威协议（意图上行 + 权威结果下行）。
var use_v2: bool = false
## 连接建立后是否自动发 client/hello（v2 下必须握手才能发意图）。
var auto_hello: bool = true
var _hello_sent: bool = false

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
				if use_v2 and auto_hello and not _hello_sent:
					_hello_sent = true
					send_client_hello()
			_drain_packets()
		WebSocketPeer.STATE_CONNECTING:
			pass  # 等待
		WebSocketPeer.STATE_CLOSING, WebSocketPeer.STATE_CLOSED:
			if _state != STATE_DISCONNECTED:
				_state = STATE_DISCONNECTED
				_peer = null
				_hello_sent = false
				disconnected.emit()

func _drain_packets() -> void:
	while _peer != null and _peer.get_available_packet_count() > 0:
		var raw: PackedByteArray = _peer.get_packet()
		handle_inbound_text(raw.get_string_from_utf8())

## 处理一条入站文本。**公开**以便无网络环境下测试分发逻辑（_drain_packets 也走这里）。
func handle_inbound_text(text: String) -> void:
	var d = JSON.parse_string(text)
	if typeof(d) != TYPE_DICTIONARY:
		push_warning("Net: invalid JSON: %s" % text.left(120))
		return
	message_received.emit(d)
	if use_v2:
		_dispatch_auth(d)

## 按 v2 协议把 auth/* 分发到各自的信号（客户端只渲染权威结果，不做本地裁决）。
func _dispatch_auth(d: Dictionary) -> void:
	var payload: Dictionary = d.get("payload", {}) if typeof(d.get("payload", {})) == TYPE_DICTIONARY else {}
	match String(d.get("type", "")):
		NetProtocol.AUTH_HELLO:
			auth_hello.emit(payload)
		NetProtocol.AUTH_STATE:
			auth_state.emit(payload)
		NetProtocol.AUTH_EVENT:
			auth_event.emit(payload)
		NetProtocol.AUTH_REJECT:
			auth_reject.emit(payload)
		NetProtocol.AUTH_VERDICT:
			auth_verdict.emit(payload)
		NetProtocol.AUTH_REQUEST_CHOICE:
			auth_request_choice.emit(payload)
		_:
			pass   # room/* 等非权威消息仍由 message_received 处理

# ── 发送 API ─────────────────────────────────────────────────────────
func send(msg: Dictionary) -> void:
	if _peer == null or _peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		push_warning("Net: not connected, drop %s" % msg.get("type", "?"))
		return
	_peer.send_text(JSON.stringify(msg))

# 便捷包装：自动填 room_id 与 to 字段。
func send_to_room(type: String, room_id: String,
		payload: Dictionary = {}, to: String = "all") -> void:
	send(build_message(type, payload, to, room_id))


## 构造一条 v1 业务消息（纯函数，便于无网络测试）。
func build_message(type: String, payload: Dictionary = {},
		to: String = "all", room_id: String = "") -> Dictionary:
	return {
		"type":    type,
		"to":      to,
		"room_id": room_id,
		"payload": payload,
	}


## 构造一条 v2 意图消息（纯函数）。意图没有 `to` 字段：服务器按连接身份路由，
# 客户端不上报身份，也不上报结果。
func build_intent(type: String, payload: Dictionary = {}) -> Dictionary:
	return {
		"type":    type,
		"room_id": _current_room_id,
		"payload": payload,
	}


## 发一条 v2 意图（intent/*）。服务器结算后通过 auth/* 回话。
func send_intent(type: String, payload: Dictionary = {}) -> void:
	send(build_intent(type, payload))


## 发握手（v2 必需）：上报协议版本与内容哈希，服务器据此拒绝不兼容客户端。
func send_client_hello(content_hash: String = "") -> void:
	send({
		"type": NetProtocol.CLIENT_HELLO,
		"payload": {"protocol": NetProtocol.VERSION, "content_hash": content_hash},
	})


## 发 heartbeat（v2）。
func send_client_ping() -> void:
	send({"type": NetProtocol.CLIENT_PING, "payload": {}})


## 给某张卡的意图补上 `seq`（服务器要求序号单调递增；由调用方持有计数器）。
func next_intent(type: String, payload: Dictionary, seq: int) -> Dictionary:
	var out: Dictionary = payload.duplicate()
	out["seq"] = seq
	return build_intent(type, out)


# 发给指定 uuid。
func send_to(type: String, room_id: String, target_uuid: String,
		payload: Dictionary = {}) -> void:
	send_to_room(type, room_id, payload, target_uuid)

# ── 便捷查询 ─────────────────────────────────────────────────────────
func is_connected_to_server() -> bool:
	return _state == STATE_CONNECTED

# 当前所在房间号（由大厅面板 SparringPanel 在切场景前注入）。
# 战斗场景通过此字段发 action/* 消息。
var _current_room_id: String = ""

func set_current_room_id(rid: String) -> void:
	_current_room_id = rid

func get_current_room_id() -> String:
	return _current_room_id


# 本次会话唯一标识（含随机后缀），用于玩家身份识别。
func get_session_id() -> String:
	return _session_id

func get_nickname() -> String:
	return _nickname

# 同步更新昵称（同时持久化到 profile.json）。
func set_nickname(nick: String) -> void:
	_nickname = nick
	ProfileManager.set_nickname(nick)
