class_name BattleServerSession
extends RefCounted

## 服务器侧对局会话（重构文档.md §4「确保无法作弊」的入口层）。
##
## 分层：
##     BattleAuthority        纯状态与规则结算，完全不知道"消息"的存在
##          ↑
##     BattleServerSession    本类：消息信封、协议校验、握手、按玩家路由
##          ↑
##     传输层（Go 网关 / WebSocket）——本类不依赖传输，便于无头测试
##
## 四个关键反作弊点（逐一对应审计里的灾难级漏洞）：
##   1. **服务器专属消息一律丢弃**：客户端发来 `game/end` / `disconnect/notify` /
##      `game/start` / `auth/*` 时，服务器不转发、不执行，只记审计日志。
##      （原架构下任意房内成员都能靠伪造这两条秒杀对手 / 直接判胜。）
##   2. **身份取连接绑定**：一律使用 sender_pid，忽略 payload 里的任何身份字段。
##   3. **协议版本**不匹配 → 拒绝；**内容哈希**不匹配 → 接受但在握手回执里告警。
##   4. **未握手不得发意图**；每个意图书由 BattleAuthority 做序号单调与限速校验。

const WARN_CONTENT_MISMATCH := "content_mismatch"

var match_id: String = ""

var _authority: BattleAuthority = null
var _players: Array = []
var _outbound: Dictionary = {}       # pid -> Array[消息]
var _handshaken: Dictionary = {}     # pid -> bool
var _protocol_version: int = NetProtocol.VERSION
var _content_hash: String = ""
var _audit: Array = []               # [{"event", "pid", "type", "detail"}]
var _forged_dropped: int = 0
var _inbound_handled: int = 0
var _verdict_sent: bool = false


## 配置服务器侧协议参数（由部署环境注入）。
func configure(protocol_version: int, content_hash: String = "") -> void:
	_protocol_version = protocol_version
	_content_hash = content_hash


## 开局：创建权威核心并给每人排队 auth/hello + 各自的过滤视图。
## config 与 BattleAuthority.start 相同（players / decks / card_costs / hero_hp / seed ...）。
func create_match(config: Dictionary) -> void:
	match_id = String(config.get("match_id", ""))
	_players = (config.get("players", []) as Array).duplicate()
	_outbound.clear()
	_handshaken.clear()
	_audit.clear()
	_forged_dropped = 0
	_inbound_handled = 0
	_verdict_sent = false

	_authority = BattleAuthority.new()
	_authority.start(config)

	for pid_raw in _players:
		var pid := String(pid_raw)
		_outbound[pid] = []
		_handshaken[pid] = false
		_queue(pid, {
			"type": NetProtocol.AUTH_HELLO,
			"payload": {
				"protocol": _protocol_version,
				"match_id": match_id,
				"you": pid,
				"players": _players.duplicate(),
				"content_hash": _content_hash,
				"warning": "",
			},
		})
		_queue(pid, {"type": NetProtocol.AUTH_STATE, "payload": _authority.view_for(pid)})

	# 开局事件（match_started / turn_started / 初始发牌）必须立即路由，
	# 否则会积压在权威核心的事件队列里，直到第一条意图才下发。
	_route_authority_events()


# ══ 入站 ══════════════════════════════════════════════════════════════════

## 处理一条来自某个连接的消息信封。
## 返回 {"accepted": bool, "reason": String, "forged": bool}（下行消息请用 drain_outbound 取）。
func handle_client_message(sender_pid: String, msg: Dictionary) -> Dictionary:
	_inbound_handled += 1
	var type := String(msg.get("type", ""))
	var payload = msg.get("payload", {})
	if typeof(payload) != TYPE_DICTIONARY:
		payload = {}

	if _authority == null:
		return _reject(sender_pid, NetProtocol.REJECT_UNKNOWN_TYPE, type, "no_match")
	if not _players.has(sender_pid):
		return _reject(sender_pid, NetProtocol.REJECT_UNKNOWN_PLAYER, type)

	# ① 服务器专属消息：伪造一律丢弃（不转发、不执行），并记审计
	if NetProtocol.is_server_only(type):
		_forged_dropped += 1
		_audit.append({"event": "forged_server_message", "pid": sender_pid, "type": type})
		return {"accepted": false, "reason": NetProtocol.REJECT_NOT_ALLOWED, "forged": true}

	# ② 握手 / 心跳
	if type == NetProtocol.CLIENT_HELLO:
		return _handle_hello(sender_pid, payload)
	if type == NetProtocol.CLIENT_PING:
		return {"accepted": true, "reason": "", "forged": false}

	# ③ 未握手不得发意图
	if not bool(_handshaken.get(sender_pid, false)):
		return _reject(sender_pid, NetProtocol.REJECT_NOT_HANDSHAKEN, type)

	# ④ 只接受意图；身份永远是 sender_pid（payload 中的身份字段被忽略）
	if not NetProtocol.is_intent(type):
		return _reject(sender_pid, NetProtocol.REJECT_UNKNOWN_TYPE, type)

	var result: Dictionary = _authority.submit_intent(sender_pid, type, payload)
	_route_authority_events()
	_push_state_to_all()
	return {
		"accepted": bool(result.get("ok", false)),
		"reason": String(result.get("reason", "")),
		"forged": false,
	}


func _handle_hello(sender_pid: String, payload: Dictionary) -> Dictionary:
	var ver: int = int(payload.get("protocol", -1))
	if ver != _protocol_version:
		_audit.append({"event": "protocol_mismatch", "pid": sender_pid,
			"type": NetProtocol.CLIENT_HELLO, "detail": str(ver)})
		return _reject(sender_pid, NetProtocol.REJECT_PROTOCOL_MISMATCH, NetProtocol.CLIENT_HELLO)

	var hash := String(payload.get("content_hash", ""))
	var warning := ""
	if hash != "" and hash != _content_hash:
		warning = WARN_CONTENT_MISMATCH
		_audit.append({"event": "content_mismatch", "pid": sender_pid,
			"type": NetProtocol.CLIENT_HELLO, "detail": hash})

	_handshaken[sender_pid] = true
	_queue(sender_pid, {
		"type": NetProtocol.AUTH_HELLO,
		"payload": {
			"protocol": _protocol_version,
			"match_id": match_id,
			"you": sender_pid,
			"players": _players.duplicate(),
			"content_hash": _content_hash,
			"warning": warning,
		},
	})
	_queue(sender_pid, {"type": NetProtocol.AUTH_STATE, "payload": _authority.view_for(sender_pid)})
	return {"accepted": true, "reason": "", "warning": warning, "forged": false}


# ══ 出站 ══════════════════════════════════════════════════════════════════

## 取出并清空发给某玩家的下行消息。
func drain_outbound(pid: String) -> Array:
	var out: Array = _outbound.get(pid, [])
	_outbound[pid] = []
	return out


func audit_log() -> Array:
	return _audit.duplicate()


func forged_dropped() -> int:
	return _forged_dropped


func inbound_handled() -> int:
	return _inbound_handled


func authority() -> BattleAuthority:
	return _authority


func players() -> Array:
	return _players.duplicate()


func is_handshaken(pid: String) -> bool:
	return bool(_handshaken.get(pid, false))


# ══ 内部 ══════════════════════════════════════════════════════════════════

## 把权威核心产生的事件按 to 路由："" = 广播给所有人，否则只发给该玩家。
func _route_authority_events() -> void:
	for entry in _authority.drain_all_events():
		var to := String((entry as Dictionary).get("to", ""))
		var payload = (entry as Dictionary).get("payload", {})
		if to == "":
			for pid_raw in _players:
				_queue(String(pid_raw), {"type": NetProtocol.AUTH_EVENT, "payload": payload})
		else:
			_queue(to, {"type": NetProtocol.AUTH_EVENT, "payload": payload})

	if _authority.is_finished() and not _verdict_sent:
		_verdict_sent = true
		for pid_raw in _players:
			_queue(String(pid_raw), {"type": NetProtocol.AUTH_VERDICT, "payload": _authority.verdict()})


## 每个玩家拿到的是**自己的**过滤视图（对手手牌只有数量）。
func _push_state_to_all() -> void:
	for pid_raw in _players:
		var pid := String(pid_raw)
		_queue(pid, {"type": NetProtocol.AUTH_STATE, "payload": _authority.view_for(pid)})


func _queue(pid: String, msg: Dictionary) -> void:
	if not _outbound.has(pid):
		_outbound[pid] = []
	(_outbound[pid] as Array).append(msg)


func _reject(pid: String, reason: String, type: String, detail: String = "") -> Dictionary:
	_audit.append({"event": "reject", "pid": pid, "type": type, "detail": reason})
	_queue(pid, {"type": NetProtocol.AUTH_REJECT, "payload": {"reason": reason, "intent": type, "detail": detail}})
	return {"accepted": false, "reason": reason, "forged": false}
