extends Node

## 服务器权威核心的 headless 测试（重构文档.md §7 阶段 1 验收）。
##
## 运行：
##   godot --headless --path dev_gd/nsoc res://tests/AuthorityTest.tscn
##
## 输出：
##   AUTHORITY_CASE [PASS|FAIL] <用例名>
##   AUTHORITY_RESULT PASS|FAIL passed=N failed=M
##
## 覆盖：身份 / 回合归属 / 序号单调 / 限速 / 结构校验 / 手牌与费用 / 私有视图 /
##       事件私有性 / 回合推进 / 投降与终局 / 服务器专属消息不可伪造 / 服务器 RNG 确定性。

const CARD_FILLER := "填线宝宝"
const COST_MAP := {CARD_FILLER: 1, "放箭": 1, "鼓舞": 2, "贵卡": 99}

var _passed: int = 0
var _failed: int = 0

## 预期用例数。用于捕获"某个测试函数因运行时错误被静默中断"的情况：
## GDScript 的运行时错误不会终止 _ready()，只是让出错函数提前返回，
## 若不校验总数，测试会在没跑完的情况下打印 PASS（本项目已踩过一次）。
const EXPECTED_CASES: int = 46


func _ready() -> void:
	_test_protocol_gate()
	_test_start_state()
	_test_unknown_player()
	_test_turn_ownership()
	_test_stale_seq()
	_test_struct_validation()
	_test_card_not_in_hand()
	_test_not_enough_mana()
	_test_play_card_ok()
	_test_rate_limit()
	_test_private_view()
	_test_event_privacy()
	_test_turn_advance()
	_test_surrender_and_finish()
	_test_server_rng_determinism()
	_test_registries()

	var total: int = _passed + _failed
	if total != EXPECTED_CASES:
		_failed += 1
		print("AUTHORITY_CASE FAIL 用例数量异常：期望 %d，实际 %d（有测试函数被运行时错误静默中断）"
			% [EXPECTED_CASES, total])

	print("AUTHORITY_RESULT %s passed=%d failed=%d" % [
		"PASS" if _failed == 0 else "FAIL", _passed, _failed,
	])
	get_tree().quit(0 if _failed == 0 else 1)


# ── 用例 ──────────────────────────────────────────────────────────────────

func _test_protocol_gate() -> void:
	_check("协议: 意图可上行", NetProtocol.server_may_accept(NetProtocol.INTENT_PLAY_CARD))
	_check("协议: 客户端不得发送服务器专属消息",
		not NetProtocol.client_may_send("game/end") and not NetProtocol.client_may_send("disconnect/notify"))
	_check("协议: 服务器不得接受 game/start",
		not NetProtocol.server_may_accept("game/start"))
	_check("协议: 服务器专属分类正确",
		NetProtocol.is_server_only(NetProtocol.AUTH_VERDICT) and NetProtocol.is_server_only("disconnect/notify"))


func _test_start_state() -> void:
	var auth := _make()
	_check("开局: 活跃玩家为 p0", auth.active_player() == "p0", auth.active_player())
	var v0 := auth.view_for("p0")
	_check("开局: 手牌 3 张", (v0["you"]["hand"] as Array).size() == 3,
		str((v0["you"]["hand"] as Array).size()))
	_check("开局: 先手首回合费用 1/1（开局不额外加费）",
		int(v0["you"]["mana"]["current"]) == 1 and int(v0["you"]["mana"]["maximum"]) == 1,
		str(v0["you"]["mana"]))


func _test_unknown_player() -> void:
	var auth := _make()
	var r := auth.submit_intent("attacker", NetProtocol.INTENT_END_TURN, {"seq": 0})
	_check("身份: 未知玩家被拒", r["reason"] == NetProtocol.REJECT_UNKNOWN_PLAYER, str(r))


func _test_turn_ownership() -> void:
	var auth := _make()
	var r := auth.submit_intent("p1", NetProtocol.INTENT_END_TURN, {"seq": 0})
	_check("回合归属: 非当前玩家不能结束回合",
		r["reason"] == NetProtocol.REJECT_NOT_YOUR_TURN, str(r))
	var r2 := auth.submit_intent("p1", NetProtocol.INTENT_PLAY_CARD,
		{"card_name": CARD_FILLER, "seq": 1})
	_check("回合归属: 非当前玩家不能出牌",
		r2["reason"] == NetProtocol.REJECT_NOT_YOUR_TURN, str(r2))


func _test_stale_seq() -> void:
	var auth := _make()
	var r1 := auth.submit_intent("p0", NetProtocol.INTENT_END_TURN, {"seq": 5})
	_check("序号: 首次接受", bool(r1["ok"]), str(r1))
	# 结束回合后活跃玩家变成 p1；用 p0 重放同一 seq —— 序号检查先于回合归属检查
	var r2 := auth.submit_intent("p0", NetProtocol.INTENT_END_TURN, {"seq": 5})
	_check("序号: 重放被拒", r2["reason"] == NetProtocol.REJECT_STALE_SEQ, str(r2))


func _test_struct_validation() -> void:
	var auth := _make()
	var r := auth.submit_intent("p0", NetProtocol.INTENT_PLAY_CARD, {})
	_check("结构: 缺字段被拒", r["reason"] == NetProtocol.REJECT_BAD_PAYLOAD, str(r))
	var r2 := auth.submit_intent("p0", "action/play_card", {"seq": 0})
	_check("结构: 旧协议 type 不被接受", r2["reason"] == NetProtocol.REJECT_UNKNOWN_TYPE, str(r2))


func _test_card_not_in_hand() -> void:
	var auth := _make()
	var r := auth.submit_intent("p0", NetProtocol.INTENT_PLAY_CARD,
		{"card_name": "不在手里的卡", "seq": 0})
	_check("出牌: 手牌外的卡被拒",
		r["reason"] == NetProtocol.REJECT_CARD_NOT_IN_HAND, str(r))


func _test_not_enough_mana() -> void:
	var auth := _make()
	# 直接把贵卡塞进服务器手牌，模拟"客户端谎称有牌"之外的费用校验
	auth._hand["p0"] = ["贵卡"]
	var r := auth.submit_intent("p0", NetProtocol.INTENT_PLAY_CARD,
		{"card_name": "贵卡", "seq": 0})
	_check("出牌: 费用不足被拒",
		r["reason"] == NetProtocol.REJECT_NOT_ENOUGH_MANA, str(r))


func _test_play_card_ok() -> void:
	var auth := _make()
	auth._hand["p0"] = [CARD_FILLER, "放箭"]
	var mana_before: int = int(auth.view_for("p0")["you"]["mana"]["current"])
	var r := auth.submit_intent("p0", NetProtocol.INTENT_PLAY_CARD,
		{"card_name": CARD_FILLER, "seq": 0})
	_check("出牌: 合法出牌被接受", bool(r["ok"]), str(r))
	var v := auth.view_for("p0")
	_check("出牌: 手牌减少", (v["you"]["hand"] as Array).size() == 1,
		str((v["you"]["hand"] as Array).size()))
	var cost: int = int(COST_MAP[CARD_FILLER])
	_check("出牌: 费用按服务器结算扣除",
		int(v["you"]["mana"]["current"]) == mana_before - cost,
		"%d - %d -> %s" % [mana_before, cost, str(v["you"]["mana"])])
	_check("出牌: 卡进入服务器墓地", (v["you"]["graveyard"] as Array).has(CARD_FILLER),
		str(v["you"]["graveyard"]))


func _test_rate_limit() -> void:
	var auth := _make(3)
	var reasons: Array = []
	for i in range(4):
		var r := auth.submit_intent("p0", NetProtocol.INTENT_PLAY_CARD,
			{"card_name": "不在手里的卡", "seq": i})
		reasons.append(String(r["reason"]))
	_check("限速: 超过阈值被拒", reasons[3] == NetProtocol.REJECT_RATE_LIMITED, str(reasons))


func _test_private_view() -> void:
	var auth := _make()
	auth._hand["p1"] = ["秘密卡A", "秘密卡B"]
	var v0 := auth.view_for("p0")
	var opponents: Array = v0["others"]
	_check("私密: 视图包含对手条目", opponents.size() == 1, str(opponents.size()))
	var blob := JSON.stringify(v0)
	_check("私密: 对手手牌内容不出现在视图里",
		not blob.contains("秘密卡A") and not blob.contains("秘密卡B"))
	_check("私密: 对手手牌数量可见",
		int((opponents[0] as Dictionary)["hand_count"]) == 2, blob)
	_check("私密: 自己手牌明文可见",
		(v0["you"]["hand"] as Array).size() == 3, str(v0["you"]["hand"]))


func _test_event_privacy() -> void:
	var auth := _make()
	auth.drain_events_for("p0")
	auth.drain_events_for("p1")
	# 让 p1 抽一张（服务器内部路径）
	auth._draw_one("p1")
	var to_p0: Array = auth.drain_events_for("p0")
	var leaked := false
	for ev in to_p0:
		if String((ev as Dictionary).get("event", "")) == "card_drawn":
			leaked = true
	_check("事件: 对手抽牌事件不下发给本人", not leaked, JSON.stringify(to_p0))


func _test_turn_advance() -> void:
	var auth := _make()
	var r := auth.submit_intent("p0", NetProtocol.INTENT_END_TURN, {"seq": 0})
	_check("回合: 结束回合被接受", bool(r["ok"]), str(r))
	_check("回合: 活跃玩家切换为 p1", auth.active_player() == "p1", auth.active_player())
	var v1 := auth.view_for("p1")
	_check("回合: 新回合玩家费用提升为 2/2",
		int(v1["you"]["mana"]["current"]) == 2 and int(v1["you"]["mana"]["maximum"]) == 2,
		str(v1["you"]["mana"]))
	_check("回合: 新回合玩家摸一张（开局 3 + 1）",
		(v1["you"]["hand"] as Array).size() == 4, str((v1["you"]["hand"] as Array).size()))
	_check("回合: 未走完一轮时回合数仍为 1", int(v1["turn"]) == 1, str(v1["turn"]))

	var r2 := auth.submit_intent("p1", NetProtocol.INTENT_END_TURN, {"seq": 0})
	_check("回合: p1 结束回合被接受", bool(r2["ok"]), str(r2))
	var v0b := auth.view_for("p0")
	_check("回合: 走完一轮后回合数递增为 2", int(v0b["turn"]) == 2, str(v0b["turn"]))
	_check("回合: 回到 p0 且费用提升为 2/2",
		auth.active_player() == "p0" and int(v0b["you"]["mana"]["current"]) == 2,
		"%s %s" % [auth.active_player(), str(v0b["you"]["mana"])])


func _test_surrender_and_finish() -> void:
	var auth := _make()
	var r := auth.submit_intent("p1", NetProtocol.INTENT_SURRENDER, {"seq": 0})
	_check("终局: 非活跃玩家也可投降", bool(r["ok"]), str(r))
	_check("终局: 对局标记结束", auth.is_finished())
	_check("终局: 胜者为对手", String(auth.verdict()["winner"]) == "p0", str(auth.verdict()))
	var r2 := auth.submit_intent("p0", NetProtocol.INTENT_END_TURN, {"seq": 0})
	_check("终局: 结束后拒绝新意图",
		r2["reason"] == NetProtocol.REJECT_MATCH_FINISHED, str(r2))


func _test_server_rng_determinism() -> void:
	var a := _make(-1, 4242)
	var b := _make(-1, 4242)
	var c := _make(-1, 9999)
	var ha: Array = (a.view_for("p0")["you"]["hand"] as Array)
	var hb: Array = (b.view_for("p0")["you"]["hand"] as Array)
	var hc: Array = (c.view_for("p0")["you"]["hand"] as Array)
	_check("确定性: 同种子发牌一致", ha == hb, "%s vs %s" % [str(ha), str(hb)])
	_check("确定性: 不同种子发牌不同", ha != hc, "%s vs %s" % [str(ha), str(hc)])


## 显式注册表完整性（重构文档.md §3.4-3）：
## 注册表由"扫目录"改为显式路径表后，路径写错会导致某个效果/技能静默缺失。
## 数量断言 + 关键 id 抽查可以在无头环境立刻发现这类错误。
func _test_registries() -> void:
	var eff: Array = Effects.ids()
	var abi: Array = HeroAbilities.ids()
	var act: Array = Actions.ids()
	var obj: Array = Objectives.ids()
	_check("注册表: 效果数量为 32", eff.size() == 32, str(eff.size()))
	_check("注册表: 技能数量为 15", abi.size() == 15, str(abi.size()))
	_check("注册表: 关卡动作数量为 10", act.size() == 10, str(act.size()))
	_check("注册表: 关卡目标数量为 1", obj.size() == 1, str(obj))
	var need_eff: Array = ["weaken", "inspire", "vigilance", "charge", "ash", "die_hard", "empower"]
	var miss_eff: Array = []
	for e in need_eff:
		if not eff.has(e):
			miss_eff.append(e)
	_check("注册表: 卡牌引用的效果均已注册", miss_eff.is_empty(), str(miss_eff))
	var need_abi: Array = ["restart", "yi_yong_jun", "flood_strategy_hero", "weishan_ability"]
	var miss_abi: Array = []
	for a in need_abi:
		if not abi.has(a):
			miss_abi.append(a)
	_check("注册表: 英雄引用的技能均已注册", miss_abi.is_empty(), str(miss_abi))


# ── 工具 ──────────────────────────────────────────────────────────────────

func _make(rate: int = -1, seed_v: int = 12345) -> BattleAuthority:
	var auth := BattleAuthority.new()
	auth.start({
		"match_id": "test",
		"seed": seed_v,
		"players": ["p0", "p1"],
		"decks": {
			"p0": ["填线宝宝", "放箭", "鼓舞", "填线宝宝", "放箭", "鼓舞"],
			"p1": ["填线宝宝", "放箭", "鼓舞", "填线宝宝", "放箭", "鼓舞"],
		},
		"card_costs": COST_MAP,
		"hero_hp": {"p0": 30, "p1": 30},
		"hand_size": 3,
		"rate_limit_per_sec": rate,
	})
	return auth


func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("AUTHORITY_CASE PASS %s" % name)
	else:
		_failed += 1
		print("AUTHORITY_CASE FAIL %s | %s" % [name, detail])
