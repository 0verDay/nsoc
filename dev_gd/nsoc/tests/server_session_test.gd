extends Node

## 服务器会话层测试（重构文档.md §4 / §7 阶段 1 验收）。
##
## 运行：
##   godot --headless --path dev_gd/nsoc res://tests/ServerSessionTest.tscn
##
## 输出：
##   SERVER_CASE [PASS|FAIL] <用例名> <说明>
##   SERVER_RESULT PASS|FAIL passed=N failed=M
##
## 重点验证"服务器权威"的边界：
##   伪造服务器专属消息被丢弃 / 身份取连接绑定 / 握手与版本校验 /
##   私有事件只发本人 / 按玩家过滤的视图。

const EXPECTED_CASES: int = 32

var _passed: int = 0
var _failed: int = 0


func _ready() -> void:
	_test_hello_required()
	_test_protocol_mismatch()
	_test_hello_ok()
	_test_content_mismatch_warning()
	_test_forged_server_messages()
	_test_identity_binding()
	_test_turn_ownership_after_handshake()
	_test_unknown_player_and_type()
	_test_state_filtering()
	_test_private_event_routing()
	_test_drain_clears()

	var total: int = _passed + _failed
	if total != EXPECTED_CASES:
		_failed += 1
		print("SERVER_CASE FAIL 用例数量异常：期望 %d，实际 %d（有测试函数被运行时错误静默中断）"
			% [EXPECTED_CASES, total])

	print("SERVER_RESULT %s passed=%d failed=%d" % [
		"PASS" if _failed == 0 else "FAIL", _passed, _failed,
	])
	get_tree().quit(0 if _failed == 0 else 1)


# ══ 握手 ══════════════════════════════════════════════════════════════════

func _test_hello_required() -> void:
	var s := _make_session()
	_drain_all(s)
	var r := s.handle_client_message("p0", {"type": NetProtocol.INTENT_END_TURN, "payload": {"seq": 0}})
	_check("握手: 未握手不得发意图",
		r["reason"] == NetProtocol.REJECT_NOT_HANDSHAKEN, str(r))


func _test_protocol_mismatch() -> void:
	var s := _make_session()
	_drain_all(s)
	var r := s.handle_client_message("p0", {"type": NetProtocol.CLIENT_HELLO,
		"payload": {"protocol": NetProtocol.VERSION + 1, "content_hash": "abc"}})
	_check("握手: 协议版本不匹配被拒",
		r["reason"] == NetProtocol.REJECT_PROTOCOL_MISMATCH, str(r))
	_check("握手: 版本不匹配写入审计日志", _audit_has(s, "protocol_mismatch"), str(s.audit_log()))
	_check("握手: 版本不匹配后仍未握手", not s.is_handshaken("p0"))


func _test_hello_ok() -> void:
	var s := _make_session()
	_drain_all(s)
	var r := s.handle_client_message("p0", {"type": NetProtocol.CLIENT_HELLO,
		"payload": {"protocol": NetProtocol.VERSION, "content_hash": "abc"}})
	_check("握手: 正确版本被接受", bool(r["accepted"]), str(r))
	var msgs := s.drain_outbound("p0")
	var hello := _find(msgs, NetProtocol.AUTH_HELLO)
	_check("握手: 回执 auth/hello 且 you 正确",
		not hello.is_empty() and String(hello["payload"].get("you", "")) == "p0", str(hello))
	_check("握手: 回执带协议版本", not hello.is_empty()
		and int(hello["payload"].get("protocol", -1)) == NetProtocol.VERSION, str(hello))
	_check("握手: 回执后立即拿到自己的视图",
		not _find(msgs, NetProtocol.AUTH_STATE).is_empty(), str(msgs.size()))


func _test_content_mismatch_warning() -> void:
	var s := _make_session()
	_drain_all(s)
	var r := s.handle_client_message("p0", {"type": NetProtocol.CLIENT_HELLO,
		"payload": {"protocol": NetProtocol.VERSION, "content_hash": "不同的哈希"}})
	_check("握手: 内容不一致仍接受（不炸局）", bool(r["accepted"]), str(r))
	_check("握手: 内容不一致给出告警",
		String(r.get("warning", "")) == BattleServerSession.WARN_CONTENT_MISMATCH, str(r))


# ══ 伪造服务器消息（审计里的灾难级漏洞）══════════════════════════════════

func _test_forged_server_messages() -> void:
	var s := _make_session()
	_hello_both(s)
	_drain_all(s)

	var forged_types: Array = [
		"game/end", "disconnect/notify", "game/start",
		NetProtocol.AUTH_VERDICT, NetProtocol.AUTH_STATE,
	]
	var all_forged := true
	var detail := ""
	for t in forged_types:
		var r := s.handle_client_message("p1", {"type": t, "payload": {"winning_team": "team_b",
			"dead_player_id": "p0", "player_id": "p0"}})
		if not bool(r.get("forged", false)):
			all_forged = false
			detail = "%s -> %s" % [t, str(r)]
	_check("伪造: 服务器专属消息全部被识别为伪造", all_forged, detail)
	_check("伪造: 计数正确", s.forged_dropped() == forged_types.size(), str(s.forged_dropped()))
	_check("伪造 game/end 未改变对局状态（未判胜/未结束）",
		not s.authority().is_finished() and String(s.authority().verdict()["winner"]) == "",
		str(s.authority().verdict()))
	_check("伪造: 未向其他玩家下发任何事件",
		_find(s.drain_outbound("p0"), NetProtocol.AUTH_EVENT).is_empty(), "p0 收到了事件")
	_check("伪造: 审计日志含 forged_server_message", _audit_has(s, "forged_server_message"),
		str(s.audit_log()))


# ══ 身份与回合归属 ═══════════════════════════════════════════════════════

func _test_identity_binding() -> void:
	var s := _make_session()
	_hello_both(s)
	_drain_all(s)
	# p0 冒充 p1 结束回合：payload 里的身份字段必须被忽略，实际按 sender_pid=p0 结算
	var r := s.handle_client_message("p0", {"type": NetProtocol.INTENT_END_TURN,
		"payload": {"seq": 0, "player_id": "p1", "from": "p1", "uuid": "p1"}})
	_check("身份: 意图被接受（按发送连接结算）", bool(r["accepted"]), str(r))
	_check("身份: 结算归属是发送者（活跃玩家由 p0 交到 p1）",
		s.authority().active_player() == "p1", s.authority().active_player())


func _test_turn_ownership_after_handshake() -> void:
	var s := _make_session()
	_hello_both(s)
	_drain_all(s)
	# 当前活跃是 p0；p1 抢先结束回合应被拒
	var r := s.handle_client_message("p1", {"type": NetProtocol.INTENT_END_TURN, "payload": {"seq": 0}})
	_check("回合: 非当前玩家意图被拒",
		r["reason"] == NetProtocol.REJECT_NOT_YOUR_TURN, str(r))


func _test_unknown_player_and_type() -> void:
	var s := _make_session()
	_drain_all(s)
	var r1 := s.handle_client_message("outsider", {"type": NetProtocol.INTENT_END_TURN, "payload": {"seq": 0}})
	_check("边界: 未注册玩家被拒",
		r1["reason"] == NetProtocol.REJECT_UNKNOWN_PLAYER, str(r1))
	_hello_both(s)
	var r2 := s.handle_client_message("p0", {"type": "action/play_card", "payload": {"seq": 0}})
	_check("边界: 旧协议 type 不被接受",
		r2["reason"] == NetProtocol.REJECT_UNKNOWN_TYPE, str(r2))


# ══ 私有视图与事件路由 ═══════════════════════════════════════════════════

func _test_state_filtering() -> void:
	var s := _make_session()
	_hello_both(s)
	_drain_all(s)
	# p0 出一张牌 → 服务器结算并给双方各发一份过滤视图
	var r := s.handle_client_message("p0", {"type": NetProtocol.INTENT_PLAY_CARD,
		"payload": {"card_name": "A1", "seq": 0}})
	_check("视图: 合法出牌被接受", bool(r["accepted"]), str(r))

	var st0 := _find(s.drain_outbound("p0"), NetProtocol.AUTH_STATE)
	var st1 := _find(s.drain_outbound("p1"), NetProtocol.AUTH_STATE)
	_check("视图: 双方都收到 auth/state", not st0.is_empty() and not st1.is_empty(), "缺视图")
	var blob0 := JSON.stringify(st0)
	var blob1 := JSON.stringify(st1)
	_check("视图: p0 视图含自己手牌明文", blob0.contains("A"), blob0.substr(0, 120))
	_check("视图: p0 视图不含对手手牌内容",
		not blob0.contains("\"B1\"") and not blob0.contains("\"B2\""), blob0.substr(0, 200))
	_check("视图: p1 视图不含对手手牌内容",
		not blob1.contains("\"A2\"") and not blob1.contains("\"A3\""), blob1.substr(0, 200))


func _test_private_event_routing() -> void:
	var s := _make_session()
	# 开局发牌事件应在 create_match 时立即路由（不能积压到第一条意图）
	var ev0 := _find_event(s.drain_outbound("p0"), "card_drawn")
	var ev1 := _find_event(s.drain_outbound("p1"), "card_drawn")
	_check("路由: 开局发牌事件发给本人", not ev0.is_empty() and not ev1.is_empty(),
		"p0=%s p1=%s" % [str(ev0), str(ev1)])
	_check("路由: 发牌事件携带的是本人的 pid",
		not ev0.is_empty() and not ev1.is_empty()
		and String(ev0["payload"].get("pid", "")) == "p0"
		and String(ev1["payload"].get("pid", "")) == "p1",
		"p0=%s p1=%s" % [str(ev0), str(ev1)])

	_hello_both(s)
	_drain_all(s)
	var _r := s.handle_client_message("p0", {"type": NetProtocol.INTENT_PLAY_CARD,
		"payload": {"card_name": "A1", "seq": 0}})
	# 私有事件（行动确认 / 抽牌）只发给本人；公共事件（card_played 等）双方都要收到
	var p1_msgs := s.drain_outbound("p1")
	var p0_msgs := s.drain_outbound("p0")
	_check("路由: p1 不会收到 p0 的行动确认（私有）",
		not _has_event(p1_msgs, "intent_accepted"), str(p1_msgs))
	_check("路由: p1 不会收到属于 p0 的抽牌事件",
		_events_named_with_pid(p1_msgs, "card_drawn", "p0").is_empty(), str(p1_msgs))
	_check("路由: 本人能收到自己的行动确认",
		_has_event(p0_msgs, "intent_accepted"), str(p0_msgs))


func _test_drain_clears() -> void:
	var s := _make_session()
	_hello_both(s)
	_drain_all(s)
	var _r := s.handle_client_message("p0", {"type": NetProtocol.INTENT_END_TURN, "payload": {"seq": 0}})
	var first: Array = s.drain_outbound("p0")
	var second: Array = s.drain_outbound("p0")
	_check("队列: drain 取出后有内容", not first.is_empty(), str(first.size()))
	_check("队列: drain 后再取为空", second.is_empty(), str(second.size()))


# ══ 工具 ═════════════════════════════════════════════════════════════════

const COST_MAP: Dictionary = {
	"A1": 1, "A2": 1, "A3": 2, "A4": 2,
	"B1": 1, "B2": 1, "B3": 2, "B4": 2,
}


func _make_session() -> BattleServerSession:
	var s := BattleServerSession.new()
	s.configure(NetProtocol.VERSION, "abc")
	s.create_match({
		"match_id": "test",
		"seed": 20260101,
		"players": ["p0", "p1"],
		"decks": {
			"p0": ["A1", "A2", "A3", "A4"],
			"p1": ["B1", "B2", "B3", "B4"],
		},
		"card_costs": COST_MAP,
		"hero_hp": {"p0": 30, "p1": 30},
		"hand_size": 3,
		"rate_limit_per_sec": -1,
	})
	return s


func _hello(s: BattleServerSession, pid: String) -> void:
	s.handle_client_message(pid, {"type": NetProtocol.CLIENT_HELLO,
		"payload": {"protocol": NetProtocol.VERSION, "content_hash": "abc"}})


func _hello_both(s: BattleServerSession) -> void:
	_hello(s, "p0")
	_hello(s, "p1")


func _drain_all(s: BattleServerSession) -> void:
	for pid in s.players():
		s.drain_outbound(String(pid))


func _find(msgs: Array, type: String) -> Dictionary:
	for m in msgs:
		if String((m as Dictionary).get("type", "")) == type:
			return m
	return {}


func _find_event(msgs: Array, event_name: String) -> Dictionary:
	for m in msgs:
		var d := m as Dictionary
		if String(d.get("type", "")) != NetProtocol.AUTH_EVENT:
			continue
		var p = d.get("payload", {})
		if typeof(p) == TYPE_DICTIONARY and String(p.get("event", "")) == event_name:
			return d
	return {}


## 收件箱里是否有指定事件名的权威事件。
func _has_event(msgs: Array, event_name: String) -> bool:
	return not _find_event(msgs, event_name).is_empty()


## 收件箱里所有 payload.pid == owner 的指定事件（用于检测私有事件外流）。
## 注意：像 intent_accepted 这类事件的归属只在路由层（payload 里没有 pid），
## 因此只能用"该事件是否出现在不该出现的人那里"来判定。
func _events_named_with_pid(msgs: Array, event_name: String, owner: String) -> Array:
	var out: Array = []
	for m in msgs:
		var d := m as Dictionary
		if String(d.get("type", "")) != NetProtocol.AUTH_EVENT:
			continue
		var p = d.get("payload", {})
		if typeof(p) != TYPE_DICTIONARY:
			continue
		if String(p.get("event", "")) == event_name and String(p.get("pid", "")) == owner:
			out.append(d)
	return out


func _audit_has(s: BattleServerSession, event: String) -> bool:
	for e in s.audit_log():
		if String((e as Dictionary).get("event", "")) == event:
			return true
	return false


func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("SERVER_CASE PASS %s" % name)
	else:
		_failed += 1
		print("SERVER_CASE FAIL %s | %s" % [name, detail])
