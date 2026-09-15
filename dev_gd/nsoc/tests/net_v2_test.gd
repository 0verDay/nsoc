extends Node

## v2 权威协议客户端传输层测试（重构文档.md §4.2 / 阶段 3「客户端接入权威路径」第一步）。
##
## 运行：
##   godot --headless --path dev_gd/nsoc res://tests/NetV2Test.tscn
##
## 输出：
##   NETV2_CASE [PASS|FAIL] <用例名> <说明>
##   NETV2_RESULT PASS|FAIL passed=N failed=M
##
## 覆盖 `NetworkManager`（autoload "Net"）新增的 v2 原语，**不需要真实网络**：
##   - 消息构造是纯函数（意图没有 to/身份字段，v1 消息保持原样）
##   - 入站文本分发：auth/* 各类型落到对应信号，v1 监听者仍收到 message_received
##   - use_v2=false（默认）时行为与以前完全一致（老路径不受影响）
##
## 注意：GDScript 运行时错误不会终止 _ready()，出错函数会静默提前返回，
## 因此末尾必须校验用例总数（EXPECTED_CASES），否则会"假通过"。

const EXPECTED_CASES: int = 17

var _passed: int = 0
var _failed: int = 0


func _ready() -> void:
	_test_message_building()
	_test_auth_dispatch()
	_test_v2_off_keeps_v1()

	var total: int = _passed + _failed
	if total != EXPECTED_CASES:
		_failed += 1
		print("NETV2_CASE FAIL 用例数量异常：期望 %d，实际 %d（有测试函数被运行时错误静默中断）"
			% [EXPECTED_CASES, total])

	print("NETV2_RESULT %s passed=%d failed=%d" % [
		"PASS" if _failed == 0 else "FAIL", _passed, _failed,
	])
	get_tree().quit(0 if _failed == 0 else 1)


func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("NETV2_CASE PASS %s" % name)
	else:
		_failed += 1
		print("NETV2_CASE FAIL %s | %s" % [name, detail])


## 新的 NetworkManager 实例（不入树：_ready 里的 ProfileManager 调用不影响构造；
## 但入树才能走 _process；本测试只测纯函数与分发，因此手动 add_child 一次）。
func _make_net():
	var script := load("res://scripts/net/network_manager.gd")
	var net = script.new()
	add_child(net)
	return net


func _test_message_building() -> void:
	var net = _make_net()
	net.set_current_room_id("12345")

	var intent: Dictionary = net.build_intent(NetProtocol.INTENT_END_TURN, {"seq": 3})
	_check("构造: 意图带 type/room_id/payload", intent.get("type") == NetProtocol.INTENT_END_TURN
		and String(intent.get("room_id", "")) == "12345"
		and int((intent.get("payload", {}) as Dictionary).get("seq", -1)) == 3, str(intent))
	_check("构造: 意图**不带** to 字段（服务器按连接身份路由）", not intent.has("to"), str(intent.keys()))
	_check("构造: 意图不带任何身份字段（player_id/uuid）",
		not (intent.get("payload", {}) as Dictionary).has("player_id")
		and not (intent.get("payload", {}) as Dictionary).has("uuid"))

	var v1: Dictionary = net.build_message("room/ready_update", {"ready": true}, "all", "12345")
	_check("构造: v1 消息保持 type/to/room_id/payload 四字段",
		v1.has("to") and String(v1.get("to", "")) == "all"
		and String(v1.get("room_id", "")) == "12345", str(v1))

	var seq_intent: Dictionary = net.next_intent(NetProtocol.INTENT_PLAY_CARD,
		{"card_name": "x"}, 7)
	_check("构造: next_intent 注入 seq 且不改原 payload",
		int((seq_intent.get("payload", {}) as Dictionary).get("seq", -1)) == 7
		and String((seq_intent.get("payload", {}) as Dictionary).get("card_name", "")) == "x",
		str(seq_intent))

	_check("构造: 默认 use_v2 = false（老路径不受影响）", not net.use_v2 and not net.is_connected_to_server())
	net.use_v2 = true
	_check("构造: 可显式打开 v2", net.use_v2)


func _test_auth_dispatch() -> void:
	var net = _make_net()
	net.use_v2 = true

	var got: Dictionary = {}
	net.auth_hello.connect(func(p): got["hello"] = p)
	net.auth_state.connect(func(p): got["state"] = p)
	net.auth_event.connect(func(p): got["event"] = p)
	net.auth_reject.connect(func(p): got["reject"] = p)
	net.auth_verdict.connect(func(p): got["verdict"] = p)
	net.auth_request_choice.connect(func(p): got["choice"] = p)
	var v1_hits: Array = []
	net.message_received.connect(func(m): v1_hits.append(String(m.get("type", ""))))

	net.handle_inbound_text('{"type":"auth/hello","payload":{"protocol":2,"you":"p1"}}')
	net.handle_inbound_text('{"type":"auth/state","payload":{"turn":1,"board":{"main_p1":{}}}}')
	net.handle_inbound_text('{"type":"auth/event","payload":{"event":"unit_deployed","row":2}}')
	net.handle_inbound_text('{"type":"auth/reject","payload":{"reason":"illegal_target"}}')
	net.handle_inbound_text('{"type":"auth/verdict","payload":{"winner":"p1"}}')
	net.handle_inbound_text('{"type":"auth/request_choice","payload":{"request_id":"r1"}}')

	_check("分发: auth/hello → auth_hello", String((got.get("hello", {}) as Dictionary).get("you", "")) == "p1")
	_check("分发: auth/state → auth_state", int((got.get("state", {}) as Dictionary).get("turn", -1)) == 1)
	_check("分发: auth/event → auth_event",
		String((got.get("event", {}) as Dictionary).get("event", "")) == "unit_deployed")
	_check("分发: auth/reject → auth_reject（客户端据此回滚预览）",
		String((got.get("reject", {}) as Dictionary).get("reason", "")) == "illegal_target")
	_check("分发: auth/verdict → auth_verdict",
		String((got.get("verdict", {}) as Dictionary).get("winner", "")) == "p1")
	_check("分发: auth/request_choice → auth_request_choice",
		String((got.get("choice", {}) as Dictionary).get("request_id", "")) == "r1")
	_check("分发: v2 打开时 v1 监听者仍收到全部 6 条（互不干扰）", v1_hits.size() == 6, str(v1_hits))
	net.handle_inbound_text("not json")
	_check("分发: 非法 JSON 不崩且不触发信号", v1_hits.size() == 6, str(v1_hits.size()))


func _test_v2_off_keeps_v1() -> void:
	var net = _make_net()
	_check("默认: use_v2 关闭时不自动握手（auto_hello 逻辑不参与）",
		not net.use_v2 and net.auto_hello)
	var hits: Array = []
	net.auth_state.connect(func(p): hits.append(p))
	net.handle_inbound_text('{"type":"auth/state","payload":{"turn":9}}')
	_check("默认: v2 关闭时 auth/* 不分发到权威信号（维持老行为）", hits.is_empty(), str(hits))
