extends Node

## 本地端到端联调探针（中继 + 权威进程 + 客户端三件套）。
##
## 一个进程里开两条中继连接：p1 建房、p2 加入；等权威进程注册并开局后，
## p1 发一条 `intent/end_turn`，断言双方都能收到权威结果（`auth/*`）。
##
## 由 `tools/ci/run_e2e_local.ps1` 编排（先起中继，再起本探针，拿到房号后起权威进程）。
## 手跑：
##   godot --headless --path dev_gd/nsoc res://tests/E2ERelayProbe.tscn -- \
##     --host=127.0.0.1 --port=8080 --roomfile=C:\Temp\room.txt --timeout=60
##
## 输出：E2E_RESULT PASS|FAIL <说明>（供编排脚本 grep）

var host: String = "127.0.0.1"
var port: int = 8080
var room_file: String = ""
var timeout_sec: float = 60.0

var _p1: WebSocketPeer = null
var _p2: WebSocketPeer = null
var _p1_id: String = "e2e-p1"
var _p2_id: String = "e2e-p2"
var _room_id: String = ""
var _phase: String = "connect"
var _deadline: float = 0.0
var _seq: int = 0
var _sent_intent: bool = false
var _rehello_done: bool = false
var _result_at: float = -1.0
var _authoritative: bool = false
var _create_ok_payload: Dictionary = {}
var _p1_auth: Array = []
var _p2_auth: Array = []
var _p1_events: Array = []
var _p2_events: Array = []
var _p1_state: int = 0
var _trace: Array = []


func _ready() -> void:
	_parse_args()
	_deadline = Time.get_ticks_msec() / 1000.0 + timeout_sec
	_p1 = WebSocketPeer.new()
	_p2 = WebSocketPeer.new()
	var u1 := "ws://%s:%d/ws?uuid=%s&nickname=%s" % [host, port, _p1_id, "p1"]
	var u2 := "ws://%s:%d/ws?uuid=%s&nickname=%s" % [host, port, _p2_id, "p2"]
	if _p1.connect_to_url(u1) != OK or _p2.connect_to_url(u2) != OK:
		_finish(false, "connect_to_url failed")
		return
	_trace.append("connecting %s" % host)


func _parse_args() -> void:
	for arg in OS.get_cmdline_user_args():
		var a := String(arg)
		if a.begins_with("--host="):
			host = a.substr(7)
		elif a.begins_with("--port="):
			port = int(a.substr(7))
		elif a.begins_with("--roomfile="):
			room_file = a.substr(11)
		elif a.begins_with("--timeout="):
			timeout_sec = float(a.substr(10))


func _process(_delta: float) -> void:
	if _p1 == null or _p2 == null:
		return
	var now := Time.get_ticks_msec() / 1000.0
	if now > _deadline:
		_finish(false, "timeout in phase=%s p1_events=%s p2_events=%s trace=%s" % [
			_phase, str(_p1_events), str(_p2_events), str(_trace)])
		return

	_poll(_p1, true)
	_poll(_p2, false)

	match _phase:
		"connect":
			if _p1.get_ready_state() == WebSocketPeer.STATE_OPEN \
					and _p2.get_ready_state() == WebSocketPeer.STATE_OPEN:
				# 权威模式建房：中继会把房间派给一个"待命权威"（没有则回 authoritative=false）
				_send(_p1, {"type": "room/create",
					"payload": {"match_type": "1v1", "authoritative": true}})
				_phase = "creating"
				_trace.append("room/create sent (authoritative)")
		"joining":
			pass   # 等 room/joined 回执（在 _on_msg 里推进）
		"waiting_auth":
			pass   # 等 auth/hello（在 _on_msg 里推进）
		"waiting_result":
			if _result_at > 0.0 and now >= _result_at:
				_check_result()


func _poll(peer: WebSocketPeer, is_p1: bool) -> void:
	peer.poll()
	while peer.get_available_packet_count() > 0:
		var text: String = peer.get_packet().get_string_from_utf8()
		var d = JSON.parse_string(text)
		if typeof(d) == TYPE_DICTIONARY:
			_on_msg(d, is_p1)


func _send(peer: WebSocketPeer, msg: Dictionary) -> void:
	peer.send_text(JSON.stringify(msg))


func _on_msg(d: Dictionary, is_p1: bool) -> void:
	var type := String(d.get("type", ""))
	var payload: Dictionary = d.get("payload", {}) \
		if typeof(d.get("payload", {})) == TYPE_DICTIONARY else {}
	_trace.append("%s %s" % ["p1" if is_p1 else "p2", type])

	match type:
		"room/create_ok":
			if is_p1:
				_create_ok_payload = payload
				# 房号在**信封层**（msg.room_id），不在 payload 里
				_room_id = String(d.get("room_id", ""))
				if _room_id == "":
					_room_id = String(payload.get("room_id", ""))
				if _room_id == "":
					_finish(false, "room/create_ok 没有 room_id: %s" % str(d))
					return
				_write_room_file(_room_id)
				_send(_p2, {"type": "room/join",
					"payload": {"room_id": _room_id, "match_type": "1v1"}})
				_phase = "joining"
				_trace.append("room_id=%s, p2 joining" % _room_id)
		"room/joined":
			if not is_p1:
				_authoritative = bool(_create_ok_payload.get("authoritative", false))
				_trace.append("authoritative=%s" % str(_authoritative))
				# 双方先握手（可能发生在权威开局之前，因此收到 auth/hello 后会再握一次）
				_send(_p1, {"type": "client/hello",
					"payload": {"protocol": 2, "content_hash": ""}})
				_send(_p2, {"type": "client/hello",
					"payload": {"protocol": 2, "content_hash": ""}})
				# 房主把开局配置交给权威（真实大厅走同一条消息）
				_send(_p1, {"type": "authority/start_match", "payload": {
					"match_id": "e2e", "seed": 20260101,
					"players": [_p1_id, _p2_id],
					"teams": {_p1_id: "defender", _p2_id: "attacker"},
					"hero_hp": {_p1_id: 30, _p2_id: 30},
					"decks": {_p1_id: [], _p2_id: []},
					"board": {"players": [_p1_id, _p2_id],
						"teams": {_p1_id: "defender", _p2_id: "attacker"}},
					"rate_limit_per_sec": -1,
				}})
				_phase = "waiting_auth"
				_trace.append("hello + authority/start_match sent")
		"auth/hello":
			if is_p1 and not _rehello_done:
				# 权威进程已开局：**重新握手**（早先那次握手发生在权威注册之前，会话层没收到）
				_rehello_done = true
				_send(_p1, {"type": "client/hello",
					"payload": {"protocol": 2, "content_hash": ""}})
				_send(_p2, {"type": "client/hello",
					"payload": {"protocol": 2, "content_hash": ""}})
				_phase = "waiting_state"
				_trace.append("re-hello after match_created")
		"auth/state":
			if is_p1 and not _sent_intent and _rehello_done:
				_sent_intent = true
				_send(_p1, {"type": "intent/end_turn", "payload": {"seq": _seq}})
				_seq += 1
				_phase = "waiting_result"
				_trace.append("intent/end_turn sent")
		"auth/event":
			var ev := String(payload.get("event", ""))
			if is_p1:
				_p1_events.append(ev)
			else:
				_p2_events.append(ev)
			if ev == "phase_resolved" and _result_at < 0.0:
				# 广播给对手会晚一点（各一条 WS 往返），留个短宽限期再判定
				_result_at = Time.get_ticks_msec() / 1000.0 + 1.5

	if type.begins_with("auth/"):
		if is_p1:
			_p1_auth.append(type)
		else:
			_p2_auth.append(type)


func _check_result() -> void:
	var ok := _authoritative and _p1_auth.has("auth/hello") and _p1_auth.has("auth/state") \
		and _p1_auth.has("auth/event") \
		and _p1_events.has("phase_resolved") and _p1_events.has("turn_started") \
		and _p2_events.has("phase_resolved")
	_finish(ok, "authoritative=%s p1_auth=%s p1_events=%s p2_events=%s" % [
		str(_authoritative), str(_p1_auth), str(_p1_events), str(_p2_events)])


func _write_room_file(rid: String) -> void:
	if room_file == "":
		return
	var f := FileAccess.open(room_file, FileAccess.WRITE)
	if f != null:
		f.store_string(rid)
		f.close()


func _finish(ok: bool, detail: String) -> void:
	if _p1 != null:
		_p1.close()
	if _p2 != null:
		_p2.close()
	print("E2E_TRACE %s" % " | ".join(_trace))
	print("E2E_RESULT %s %s" % ["PASS" if ok else "FAIL", detail])
	get_tree().quit(0 if ok else 1)
