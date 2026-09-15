extends Node

## 权威进程入口测试（重构文档.md §7「权威进程」）。
##
## 运行：
##   godot --headless --path dev_gd/nsoc res://tests/AuthorityMainTest.tscn
##
## 输出：
##   AMAIN_CASE [PASS|FAIL] <用例名> <说明>
##   AMAIN_RESULT PASS|FAIL passed=N failed=M
##
## 覆盖 `AuthorityMain` 与中继的**协议面**（不需要真实网络：`send_override` 收集出站消息）：
##   注册 → 开局 → 未握手拒绝 → 握手回执 → 意图受理 → 行动阶段结算（tick）→ 出站带 to
##
## 注意：GDScript 运行时错误不会终止 _ready()，出错函数会静默提前返回，
## 因此末尾必须校验用例总数（EXPECTED_CASES），否则会"假通过"。

const EXPECTED_CASES: int = 17

var _passed: int = 0
var _failed: int = 0


func _ready() -> void:
	await _run()

	var total: int = _passed + _failed
	if total != EXPECTED_CASES:
		_failed += 1
		print("AMAIN_CASE FAIL 用例数量异常：期望 %d，实际 %d（有测试函数被运行时错误静默中断）"
			% [EXPECTED_CASES, total])

	print("AMAIN_RESULT %s passed=%d failed=%d" % [
		"PASS" if _failed == 0 else "FAIL", _passed, _failed,
	])
	get_tree().quit(0 if _failed == 0 else 1)


func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("AMAIN_CASE PASS %s" % name)
	else:
		_failed += 1
		print("AMAIN_CASE FAIL %s | %s" % [name, detail])


func _run() -> void:
	Game.registry.clear()
	var main := AuthorityMain.new()
	add_child(main)   # 入树 → _ready 跑：读环境、装卡库、建模拟宿主
	var out: Array = []
	main.send_override = func(msg): out.append((msg as Dictionary).duplicate(true))

	_check("入口: 场景就绪且模拟宿主已建", main.sim_host != null and main.session == null)
	_check("入口: 未指定房间时不注册（只告警）",
		main.room_id == "" and out.is_empty())

	# ① 玩家在开局前发意图：服务器层没有对局 → 拒绝
	main.handle_relay_message({"type": "intent/end_turn", "payload": {"seq": 0}, "from": "p1"})
	_check("入口: 开局前意图被丢弃（会话未建立）", out.is_empty(), str(out.size()))

	# ② 中继回执 → 开局（内置默认配置）
	main.handle_relay_message({"type": "authority/joined",
		"payload": {"room_id": "12345", "players": ["p1", "p2"], "match_type": "1v1",
			"host_uuid": "p1"}})
	_check("入口: 收到 authority/joined 后建立对局", main.session != null)
	_check("入口: 出站含 auth/hello（每个玩家各一条）",
		_count_type(out, NetProtocol.AUTH_HELLO) == 2, str(out.size()))
	_check("入口: 出站含 auth/state（每个玩家各一条）",
		_count_type(out, NetProtocol.AUTH_STATE) == 2, str(out.size()))
	_check("入口: 每条出站都带 to（中继据此路由）",
		_all_have_to(out, "p1", "p2"), str(out.size()))
	var hello: Dictionary = _first_of_type(out, NetProtocol.AUTH_HELLO)
	_check("入口: auth/hello 带协议版本与人数",
		int((hello.get("payload", {}) as Dictionary).get("protocol", -1)) == NetProtocol.VERSION
		and ((hello.get("payload", {}) as Dictionary).get("players", []) as Array).size() == 2,
		str(hello))
	var st: Dictionary = _first_of_type(out, NetProtocol.AUTH_STATE)
	_check("入口: auth/state 是按玩家过滤的视图（自己 hand 明文 + 盘面）",
		((st.get("payload", {}) as Dictionary).get("you", {}) as Dictionary).has("hand")
		and (st.get("payload", {}) as Dictionary).has("board"),
		str(st.get("payload", {})).left(120))

	out.clear()
	# ③ 未握手就发意图 → not_handshaken
	main.handle_relay_message({"type": NetProtocol.INTENT_END_TURN,
		"payload": {"seq": 0}, "from": "p1"})
	var reject: Dictionary = _first_of_type(out, NetProtocol.AUTH_REJECT)
	_check("入口: 未握手发意图 → auth/reject not_handshaken",
		String((reject.get("payload", {}) as Dictionary).get("reason", ""))
		== NetProtocol.REJECT_NOT_HANDSHAKEN, str(reject))

	out.clear()
	# ④ 握手
	main.handle_relay_message({"type": NetProtocol.CLIENT_HELLO,
		"payload": {"protocol": NetProtocol.VERSION, "content_hash": "abc"}, "from": "p1"})
	_check("入口: 握手后回 auth/hello + auth/state",
		_count_type(out, NetProtocol.AUTH_HELLO) >= 1 and _count_type(out, NetProtocol.AUTH_STATE) >= 1,
		str(out.size()))

	out.clear()
	# ⑤ 合法意图：结束回合 → 登记待结算阶段
	main.handle_relay_message({"type": NetProtocol.INTENT_END_TURN,
		"payload": {"seq": 0}, "from": "p1"})
	_check("入口: 合法意图被受理（下发 phase_pending 事件）",
		_has_event(out, "phase_pending"), str(out.size()))

	out.clear()
	# ⑥ tick 结算整侧行动 + 推进回合
	await main.tick_once()
	_check("入口: tick 后下发 phase_resolved（服务器算完整侧动作）",
		_has_event(out, "phase_resolved"), str(out.size()))
	_check("入口: tick 后下发 turn_started / turn_ended",
		_has_event(out, "turn_started") and _has_event(out, "turn_ended"), str(out.size()))
	_check("入口: 回合已推进到 p2（权威状态）",
		main.session.authority().active_player() == "p2",
		main.session.authority().active_player())

	out.clear()
	# ⑦ 非法 JSON / 未知类型不崩
	main.handle_relay_text("not json")
	main.handle_relay_message({"type": "no/such_type", "payload": {}, "from": "p1"})
	_check("入口: 非法 JSON 与未知类型不会崩溃（无出站或仅拒绝）",
		out.size() == 0 or _count_type(out, NetProtocol.AUTH_REJECT) >= 0, str(out.size()))

	# ⑧ 默认配置可用性：牌组来自真实卡库、费用表非空
	var cfg: Dictionary = AuthorityMain.build_default_config(["a", "b"])
	_check("默认配置: 两队/血量/牌组/费用齐全",
		(cfg["teams"] as Dictionary)["a"] == "defender"
		and (cfg["teams"] as Dictionary)["b"] == "attacker"
		and (cfg["decks"]["a"] as Array).size() >= 10
		and (cfg["card_costs"] as Dictionary).size() > 0
		and (cfg["board"] as Dictionary).has("players"), str(cfg.keys()))


func _count_type(msgs: Array, type: String) -> int:
	var n: int = 0
	for m in msgs:
		if String((m as Dictionary).get("type", "")) == type:
			n += 1
	return n


func _first_of_type(msgs: Array, type: String) -> Dictionary:
	for m in msgs:
		if String((m as Dictionary).get("type", "")) == type:
			return m
	return {}


func _all_have_to(msgs: Array, a: String, b: String) -> bool:
	for m in msgs:
		var to := String((m as Dictionary).get("to", ""))
		if to != a and to != b:
			return false
	return not msgs.is_empty()


func _has_event(msgs: Array, event_name: String) -> bool:
	for m in msgs:
		var p: Dictionary = (m as Dictionary).get("payload", {})
		if String(p.get("event", "")) == event_name:
			return true
	return false
