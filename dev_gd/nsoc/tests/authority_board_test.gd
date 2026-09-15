extends Node

## 权威端棋盘结算测试（重构文档.md §4：把棋盘交给服务器裁决）。
##
## 运行：
##   godot --headless --path dev_gd/nsoc res://tests/AuthorityBoardTest.tscn
##
## 输出：
##   ABOARD_CASE [PASS|FAIL] <用例名> <说明>
##   ABOARD_RESULT PASS|FAIL passed=N failed=M
##
## 覆盖 `BattleAuthority` + `AuthorityBoard` 的接合：
##   ✅ 服务器建盘（同一套规则引擎 + CellData 纯数据）
##   ✅ intent/play_card 在权威盘面上校验并落子（用真实卡库的 CardUnit 属性）
##   ✅ 落点非法 / 打到对手盘 / 非单位卡 / 越界 → 拒绝，且**不消耗手牌与费用**（原子性）
##   ✅ 盘面进 auth/state 视图（公开信息），手牌仍只暴露数量（暗牌）
##   ✅ 权威事件流（card_played / unit_deployed）
##
## 注意：GDScript 运行时错误不会终止 _ready()，出错函数会静默提前返回，
## 因此末尾必须校验用例总数（EXPECTED_CASES），否则会"假通过"。

const EXPECTED_CASES: int = 85

var _passed: int = 0
var _failed: int = 0

var _auth: BattleAuthority = null
var _board: AuthorityBoard = null
var _unit: String = ""
var _spell: String = ""


func _ready() -> void:
	Game._load_card_db()
	Game.registry.clear()
	_unit = _find_card(true)
	_spell = _find_card(false)

	_board = AuthorityBoard.new()
	var started: Dictionary = _board.start({
		"players": ["p1", "p2"],
		"teams": {"p1": "defender", "p2": "attacker"},
		"hero_hp": {"p1": 30, "p2": 30},
	})

	_auth = BattleAuthority.new()
	_auth.start({
		"match_id": "m_board",
		"seed": 20260101,
		"players": ["p1", "p2"],
		# 3 张牌 = 开局手牌，洗牌顺序无关，手牌内容确定（2 单位 + 1 非单位）
		"card_costs": {_unit: 1, _spell: 1},
		"decks": {"p1": [_unit, _unit, _spell], "p2": [_unit, _unit, _spell]},
		"hero_hp": {"p1": 30, "p2": 30},
	})
	_auth.attach_board(_board)
	_auth.drain_all_events()   # 清掉开局事件，便于后面断言

	_test_setup(started)
	_test_rejects_are_free()
	_test_deploy_and_view()
	_test_insufficient_mana()
	_test_session_wiring()
	await _test_turn_phase()
	await _test_board_hero_sync()
	await _test_spell_play()
	await _test_hero_ability()
	await _test_equipment()

	var total: int = _passed + _failed
	if total != EXPECTED_CASES:
		_failed += 1
		print("ABOARD_CASE FAIL 用例数量异常：期望 %d，实际 %d（有测试函数被运行时错误静默中断）"
			% [EXPECTED_CASES, total])

	print("ABOARD_RESULT %s passed=%d failed=%d" % [
		"PASS" if _failed == 0 else "FAIL", _passed, _failed,
	])
	get_tree().quit(0 if _failed == 0 else 1)


## 装备接入权威端：打出（手牌→实例、扣费）/ 激活（耐久 -1、每回合一次）/ 破损入墓 / 回合重置。
func _test_equipment() -> void:
	var equip_name := ""
	for key in Game.card_db.keys():
		var card = Game.card_db[key]
		if card is CardEquipment and (card.effects as Array).has("gain_mana_1"):
			equip_name = String(key)
			break
	_check("装备: 找到 gain_mana_1 装备卡", equip_name != "", equip_name)
	if equip_name == "":
		for _i in range(14):
			_check("装备: 跳过（卡库缺该装备）", false, "no equipment")
		return

	Game.registry.clear()
	var host := BattleSimHost.new()
	add_child(host)
	var s := BattleServerSession.new()
	s.configure(NetProtocol.VERSION, "abc")
	s.create_match({
		"match_id": "m_equip", "seed": 23, "players": ["p1", "p2"],
		"decks": {"p1": [equip_name, equip_name, equip_name],
			"p2": [equip_name, equip_name, equip_name]},
		"card_costs": {equip_name: 1}, "hero_hp": {"p1": 30, "p2": 30},
		"rate_limit_per_sec": -1,
		"board": {"players": ["p1", "p2"], "teams": {"p1": "defender", "p2": "attacker"}},
		"sim_host": host,
	})
	var hello := {"type": NetProtocol.CLIENT_HELLO,
		"payload": {"protocol": NetProtocol.VERSION, "content_hash": "abc"}}
	s.handle_client_message("p1", hello)
	s.handle_client_message("p2", hello)
	s.drain_outbound("p1")
	s.drain_outbound("p2")

	# ① 无效装备名（手牌里没有）
	var r0: Dictionary = s.handle_client_message("p1", {"type": NetProtocol.INTENT_PLAY_EQUIP,
		"payload": {"card_name": "no_such_equip", "seq": 0}})
	_check("装备: 手牌里没有 → card_not_in_hand",
		String(r0.get("reason", "")) == NetProtocol.REJECT_CARD_NOT_IN_HAND, str(r0))

	# ② 打出装备
	var r1: Dictionary = s.handle_client_message("p1", {"type": NetProtocol.INTENT_PLAY_EQUIP,
		"payload": {"card_name": equip_name, "seq": 1}})
	_check("装备: 打出被受理", bool(r1.get("accepted", false)), str(r1))
	var you: Dictionary = s.authority().view_for("p1")["you"]
	_check("装备: 手牌 -1、费用 1 → 0",
		(you["hand"] as Array).size() == 2 and int((you["mana"] as Dictionary)["current"]) == 0,
		"%d / %d" % [(you["hand"] as Array).size(), int((you["mana"] as Dictionary)["current"])])
	_check("装备: 权威视图出现该装备实例（耐久 = 卡面）",
		(you["equipments"] as Array).size() == 1
		and int((you["equipments"][0] as Dictionary)["durability_left"]) == 2,
		str(you["equipments"]))
	_check("装备: 对手也能看到（装备是公开信息）",
		((s.authority().view_for("p2")["others"][0] as Dictionary)["equipments"] as Array).size() == 1)

	# ③ 激活（once_per_turn）
	var r2: Dictionary = s.handle_client_message("p1", {"type": NetProtocol.INTENT_ACTIVATE_EQUIP,
		"payload": {"equip_name": equip_name, "seq": 2}})
	_check("装备: 激活被受理并排队", bool(r2.get("accepted", false)) and s.authority().has_pending_work(),
		str(r2))
	await s.tick()
	_check("装备: 激活后耐久 2 → 1",
		int(((s.authority().view_for("p1")["you"] as Dictionary)["equipments"][0] as Dictionary)["durability_left"]) == 1)
	var r3: Dictionary = s.handle_client_message("p1", {"type": NetProtocol.INTENT_ACTIVATE_EQUIP,
		"payload": {"equip_name": equip_name, "seq": 3}})
	_check("装备: 同回合第二次 → not_allowed（once_per_turn）",
		String(r3.get("reason", "")) == NetProtocol.REJECT_NOT_ALLOWED, str(r3))
	var r4: Dictionary = s.handle_client_message("p1", {"type": NetProtocol.INTENT_ACTIVATE_EQUIP,
		"payload": {"equip_name": "no_such_equip", "seq": 4}})
	_check("装备: 激活未持有的装备 → not_allowed",
		String(r4.get("reason", "")) == NetProtocol.REJECT_NOT_ALLOWED, str(r4))

	# ④ 走完 p2 的回合再回到 p1：每回合一次的限制应被重置
	s.handle_client_message("p1", {"type": NetProtocol.INTENT_END_TURN, "payload": {"seq": 5}})
	await s.tick()
	_check("装备: 回合推进到 p2", s.authority().active_player() == "p2", s.authority().active_player())
	s.handle_client_message("p2", {"type": NetProtocol.INTENT_END_TURN, "payload": {"seq": 0}})
	await s.tick()
	_check("装备: 再次回到 p1", s.authority().active_player() == "p1", s.authority().active_player())

	# ⑤ 新回合再激活一次 → 耐久归零 → 破损入墓
	var r5: Dictionary = s.handle_client_message("p1", {"type": NetProtocol.INTENT_ACTIVATE_EQUIP,
		"payload": {"equip_name": equip_name, "seq": 6}})
	_check("装备: 新回合可再次激活（限制已重置）", bool(r5.get("accepted", false)), str(r5))
	await s.tick()
	you = s.authority().view_for("p1")["you"]
	_check("装备: 耐久归零后从装备列表移除", (you["equipments"] as Array).is_empty(), str(you["equipments"]))
	_check("装备: 破损后计入墓地", (you["graveyard"] as Array).has(equip_name), str(you["graveyard"]))
	var r6: Dictionary = s.handle_client_message("p1", {"type": NetProtocol.INTENT_ACTIVATE_EQUIP,
		"payload": {"equip_name": equip_name, "seq": 7}})
	_check("装备: 破损后再激活 → not_allowed",
		String(r6.get("reason", "")) == NetProtocol.REJECT_NOT_ALLOWED, str(r6))

	var events: Array = []
	for m in s.drain_outbound("p2"):
		events.append(String(((m as Dictionary).get("payload", {}) as Dictionary).get("event", "")))
	_check("装备: 事件齐全（equip_played / equip_activated / equip_broken）",
		events.has("equip_played") and events.has("equip_activated") and events.has("equip_broken"),
		str(events))


## 桩技能：只为验证权威端的技能执行链路（不进入正式内容，测试内注入注册表）。
class StubAbility extends HeroAbility:
	func id() -> String:
		return "test_authority_stub"
	func display_name() -> String:
		return "stub"
	func cost() -> int:
		return 1
	func once_per_turn() -> bool:
		return true
	func on_activate(ctx) -> void:
		var cell = ctx.target_cell
		if cell != null and cell.has_card and not (cell.effects as Array).has("charge"):
			cell.effects.append("charge")


## 英雄技能接入权威端：归属校验（英雄必须真的带这个技能）/ 每回合一次 / 费用，效果排队到 tick。
## 注：正式内容里当前**没有"可主动激活且无头安全"的技能**（restart / yi_yong_jun 需要 hand_view
## 等 UI），因此执行链路用测试内注入的桩技能验证；真实技能待其去掉 UI 依赖后即可直接复用。
func _test_hero_ability() -> void:
	HeroAbilities._instances["test_authority_stub"] = StubAbility.new()
	Game.registry.clear()
	var host := BattleSimHost.new()
	add_child(host)
	var s := BattleServerSession.new()
	s.configure(NetProtocol.VERSION, "abc")
	s.create_match({
		"match_id": "m_ability", "seed": 19, "players": ["p1", "p2"],
		"decks": {"p1": [_unit], "p2": [_unit]}, "card_costs": {_unit: 1},
		"hero_hp": {"p1": 30, "p2": 30}, "rate_limit_per_sec": -1,
		"board": {"players": ["p1", "p2"], "teams": {"p1": "defender", "p2": "attacker"},
			"abilities": {"p1": ["test_authority_stub", "weishan_ability"], "p2": []}},
		"sim_host": host,
	})
	var hello := {"type": NetProtocol.CLIENT_HELLO,
		"payload": {"protocol": NetProtocol.VERSION, "content_hash": "abc"}}
	s.handle_client_message("p1", hello)
	s.handle_client_message("p2", hello)
	s.drain_outbound("p1")
	s.drain_outbound("p2")

	var b = s.board()
	var ally: CellData = b.cell_at("main_p1", 2, 1)
	ally.set_card(_unit, 2, {"front": 4, "back": 4, "left": 4, "right": 4}, false,
		[], "main_p1", "initial", "defender")

	# ① 未注册的技能
	var r1: Dictionary = s.handle_client_message("p1", {"type": NetProtocol.INTENT_ACTIVATE_HERO,
		"payload": {"ability_id": "no_such_ability", "seq": 0}})
	_check("技能: 未注册技能 → bad_payload",
		String(r1.get("reason", "")) == NetProtocol.REJECT_BAD_PAYLOAD, str(r1))

	# ② 已注册但不属于该英雄 → not_allowed（防"用一个别人的技能"）
	var r2: Dictionary = s.handle_client_message("p1", {"type": NetProtocol.INTENT_ACTIVATE_HERO,
		"payload": {"ability_id": "first_arrow_ability", "seq": 1}})
	_check("技能: 不属于本英雄 → not_allowed",
		String(r2.get("reason", "")) == NetProtocol.REJECT_NOT_ALLOWED, str(r2))

	# ③ 纯被动（can_activate=false）不可激活
	var r3: Dictionary = s.handle_client_message("p1", {"type": NetProtocol.INTENT_ACTIVATE_HERO,
		"payload": {"ability_id": "weishan_ability", "seq": 2}})
	_check("技能: 纯被动 → not_allowed",
		String(r3.get("reason", "")) == NetProtocol.REJECT_NOT_ALLOWED, str(r3))
	_check("技能: 三次拒绝后费用未变",
		int(((s.authority().view_for("p1")["you"] as Dictionary)["mana"] as Dictionary)["current"]) == 1)

	# ④ 合法激活：受理 + 扣费 + 效果排队
	var r4: Dictionary = s.handle_client_message("p1", {"type": NetProtocol.INTENT_ACTIVATE_HERO,
		"payload": {"ability_id": "test_authority_stub", "seq": 3,
			"target_slot_id": "main_p1", "row": 2, "col": 1}})
	_check("技能: 合法激活被受理", bool(r4.get("accepted", false)), str(r4))
	_check("技能: 费用已扣（1 → 0）",
		int(((s.authority().view_for("p1")["you"] as Dictionary)["mana"] as Dictionary)["current"]) == 0)
	_check("技能: 效果排在待结算队列（尚未执行）",
		s.authority().has_pending_work() and not (ally.effects as Array).has("charge"),
		"%s / %s" % [str(s.authority().has_pending_work()), str(ally.effects)])

	# ⑤ 每回合一次：同回合再次激活被拒
	var r5: Dictionary = s.handle_client_message("p1", {"type": NetProtocol.INTENT_ACTIVATE_HERO,
		"payload": {"ability_id": "test_authority_stub", "seq": 4}})
	_check("技能: 同回合第二次 → not_allowed（once_per_turn）",
		String(r5.get("reason", "")) == NetProtocol.REJECT_NOT_ALLOWED, str(r5))

	# ⑥ tick 执行
	await s.tick()
	_check("技能: tick 后效果生效（目标获得 charge）", (ally.effects as Array).has("charge"),
		str(ally.effects))
	_check("技能: 待结算队列已清空", not s.authority().has_pending_work())

	var events: Array = []
	for m in s.drain_outbound("p2"):
		events.append(String(((m as Dictionary).get("payload", {}) as Dictionary).get("event", "")))
	_check("技能: 下发 hero_ability_queued / hero_ability_used",
		events.has("hero_ability_queued") and events.has("hero_ability_used"), str(events))


func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("ABOARD_CASE PASS %s" % name)
	else:
		_failed += 1
		print("ABOARD_CASE FAIL %s | %s" % [name, detail])


func _find_card(want_unit: bool) -> String:
	for key in Game.card_db.keys():
		var card = Game.card_db[key]
		if card == null:
			continue
		var is_unit: bool = card is CardUnit
		if not want_unit and is_unit:
			continue
		if want_unit and (not is_unit or not (card.health is Dictionary)):
			continue
		return String(key)
	return ""


func _mana_of(pid: String) -> int:
	return int((_auth.view_for(pid)["you"] as Dictionary)["mana"]["current"])


func _hand_of(pid: String) -> Array:
	return (_auth.view_for(pid)["you"] as Dictionary)["hand"]


func _cell_dict(slot_id: String, row: int, col: int) -> Dictionary:
	var st: Dictionary = _board.state()
	var slot: Dictionary = st.get(slot_id, {})
	var cells: Dictionary = slot.get("cells", {})
	return cells.get("%d,%d" % [row, col], {})


func _test_setup(started: Dictionary) -> void:
	_check("准备: 真实卡库已装载", Game.card_db.size() > 0, str(Game.card_db.size()))
	_check("准备: 找到单位卡（CardUnit）", _unit != "", _unit)
	_check("准备: 找到非单位卡（法术/装备）", _spell != "", _spell)
	_check("建盘: AuthorityBoard.start 成功", bool(started.get("ok", false)), str(started))
	_check("建盘: 两名玩家各一块盘、各 9 个纯数据格",
		_board.slots_of("p1").size() == 1 and _board.slots_of("p2").size() == 1
		and _board.slot_at("main_p1").board.grid_cells.size() == 9
		and (_board.cell_at("main_p1", 0, 0) is CellData),
		str(_board.state().keys()))
	_check("建盘: 盘归属与队伍已注入",
		_board.slot_at("main_p1").owner_player_id == "p1"
		and _board.slot_at("main_p1").team_id == "defender"
		and _board.slot_at("main_p2").team_id == "attacker",
		"%s %s" % [_board.slot_at("main_p1").team_id, _board.slot_at("main_p2").team_id])
	_check("开局: p1 手牌 = 3 张、费用 1", _hand_of("p1").size() == 3 and _mana_of("p1") == 1,
		"%d / %d" % [_hand_of("p1").size(), _mana_of("p1")])


func _test_rejects_are_free() -> void:
	# ① 打到对手盘：一律非法（防"把单位放到对手盘上"）
	var r1: Dictionary = _auth.submit_intent("p1", "intent/play_card", {
		"card_name": _unit, "seq": 0, "target_slot_id": "main_p2", "row": 2, "col": 1})
	_check("拒绝: 打到对手盘 → illegal_target",
		not bool(r1.get("ok", true)) and String(r1.get("reason", "")) == NetProtocol.REJECT_ILLEGAL_TARGET,
		str(r1))
	_check("拒绝: 被拒后不消耗手牌与费用（原子性）",
		_hand_of("p1").size() == 3 and _mana_of("p1") == 1,
		"%d / %d" % [_hand_of("p1").size(), _mana_of("p1")])
	_check("拒绝: 对手盘仍为空",
		not bool(_cell_dict("main_p2", 2, 1).get("has_card", false)),
		str(_cell_dict("main_p2", 2, 1)))

	# ② 缺落点坐标
	var r2: Dictionary = _auth.submit_intent("p1", "intent/play_card", {
		"card_name": _unit, "seq": 1, "target_slot_id": "main_p1"})
	_check("拒绝: 缺 row/col → bad_payload",
		String(r2.get("reason", "")) == NetProtocol.REJECT_BAD_PAYLOAD, str(r2))

	# ③ 越界格
	var r3: Dictionary = _auth.submit_intent("p1", "intent/play_card", {
		"card_name": _unit, "seq": 2, "target_slot_id": "main_p1", "row": 9, "col": 1})
	_check("拒绝: 越界格 → illegal_target",
		String(r3.get("reason", "")) == NetProtocol.REJECT_ILLEGAL_TARGET, str(r3))

	# ④ 非单位卡（法术）暂不权威结算：明确拒绝而不是静默放行
	var r4: Dictionary = _auth.submit_intent("p1", "intent/play_card", {
		"card_name": _spell, "seq": 3, "target_slot_id": "main_p1", "row": 2, "col": 1})
	_check("拒绝: 非单位卡 → not_allowed（不静默放行）",
		String(r4.get("reason", "")) == NetProtocol.REJECT_NOT_ALLOWED, str(r4))
	_check("拒绝: 三次拒绝后手牌与费用仍未变",
		_hand_of("p1").size() == 3 and _mana_of("p1") == 1,
		"%d / %d" % [_hand_of("p1").size(), _mana_of("p1")])


func _test_deploy_and_view() -> void:
	var r: Dictionary = _auth.submit_intent("p1", "intent/play_card", {
		"card_name": _unit, "seq": 4, "target_slot_id": "main_p1", "row": 2, "col": 1})
	_check("落子: 合法落点被接受", bool(r.get("ok", false)), str(r))
	_check("落子: 手牌 -1", _hand_of("p1").size() == 2, str(_hand_of("p1").size()))
	_check("落子: 费用按 cost 扣除（1 → 0）", _mana_of("p1") == 0, str(_mana_of("p1")))

	var cell: Dictionary = _cell_dict("main_p1", 2, 1)
	_check("落子: 权威盘面格子上确有该单位（牌面来自卡库而非客户端）",
		bool(cell.get("has_card", false)) and String(cell.get("card_name", "")) == _unit,
		str(cell))
	_check("落子: 单位归属与队伍正确（跨盘/友敌判定依据）",
		String(cell.get("owner_slot_id", "")) == "main_p1"
		and String(cell.get("team_id", "")) == "defender"
		and String(cell.get("origin", "")) == "hand",
		"%s %s %s" % [cell.get("owner_slot_id"), cell.get("team_id"), cell.get("origin")])

	# 视图：盘面公开（对手也看得到单位），手牌仍然只有数量
	var v2: Dictionary = _auth.view_for("p2")
	var others: Array = v2.get("others", [])
	var p1_entry: Dictionary = others[0] if others.size() > 0 else {}
	_check("视图: auth/state 带盘面（对手可见单位位置）",
		(v2.get("board", {}) as Dictionary).has("main_p1")
		and bool(((v2["board"]["main_p1"]["cells"] as Dictionary).get("2,1", {})).get("has_card", false)))
	_check("视图: 对手手牌只暴露数量（暗牌未被盘面泄漏）",
		not p1_entry.has("hand") and int(p1_entry.get("hand_count", -1)) == 2,
		str(p1_entry.keys()))

	var events: Array = _auth.drain_all_events()
	var types: Array = []
	for e in events:
		types.append(String((e.get("payload", {}) as Dictionary).get("event", "")))
	_check("事件: 下发 card_played", types.has("card_played"), str(types))
	_check("事件: 下发 unit_deployed（带落点）", types.has("unit_deployed"), str(types))
	var deployed: Dictionary = {}
	for e in events:
		var p: Dictionary = e.get("payload", {})
		if String(p.get("event", "")) == "unit_deployed":
			deployed = p
			break
	_check("事件: unit_deployed 带 slot/row/col/team",
		String(deployed.get("slot_id", "")) == "main_p1" and int(deployed.get("row", -1)) == 2
		and int(deployed.get("col", -1)) == 1 and String(deployed.get("team_id", "")) == "defender",
		str(deployed))


func _test_insufficient_mana() -> void:
	var r: Dictionary = _auth.submit_intent("p1", "intent/play_card", {
		"card_name": _unit, "seq": 5, "target_slot_id": "main_p1", "row": 1, "col": 1})
	_check("费用: 费用不足时拒绝且不落子",
		String(r.get("reason", "")) == NetProtocol.REJECT_NOT_ENOUGH_MANA
		and not bool(_cell_dict("main_p1", 1, 1).get("has_card", false)), str(r))


## 服务器会话入口（BattleServerSession）与权威盘面的接合：
## 真实部署里棋盘是由会话层按 config.board 建起来的，这条链路必须可达。
func _test_session_wiring() -> void:
	Game.registry.clear()
	var s := BattleServerSession.new()
	s.configure(NetProtocol.VERSION, "abc")
	s.create_match({
		"match_id": "m_wired",
		"seed": 7,
		"players": ["p1", "p2"],
		"decks": {"p1": [_unit, _unit, _unit], "p2": [_unit, _unit, _unit]},
		"card_costs": {_unit: 1},
		"hero_hp": {"p1": 30, "p2": 30},
		"rate_limit_per_sec": -1,
		"board": {"players": ["p1", "p2"], "teams": {"p1": "defender", "p2": "attacker"}},
	})
	_check("会话: config.board 存在时建出权威盘面", s.board() != null and s.authority().has_board())

	var hello := {"type": NetProtocol.CLIENT_HELLO,
		"payload": {"protocol": NetProtocol.VERSION, "content_hash": "abc"}}
	s.handle_client_message("p1", hello)
	s.handle_client_message("p2", hello)
	s.drain_outbound("p1")
	s.drain_outbound("p2")

	var r: Dictionary = s.handle_client_message("p1", {"type": NetProtocol.INTENT_PLAY_CARD,
		"payload": {"card_name": _unit, "seq": 0, "target_slot_id": "main_p1", "row": 2, "col": 0}})
	_check("会话: 意图经会话层落到权威盘面", bool(r.get("accepted", false)), str(r))
	_check("会话: 盘面格子上确有该单位",
		bool((s.board().state()["main_p1"]["cells"] as Dictionary).get("2,0", {}).get("has_card", false)),
		str(s.board().state()["main_p1"]["cells"].get("2,0", {})))

	var peer_events: Array = []
	for m in s.drain_outbound("p2"):
		var p: Dictionary = (m as Dictionary).get("payload", {})
		peer_events.append(String(p.get("event", "")))
	_check("会话: 对手收到 unit_deployed 权威事件", peer_events.has("unit_deployed"),
		str(peer_events))

	# 建盘失败（没有玩家）必须被审计，且不接盘面、不炸
	var s2 := BattleServerSession.new()
	s2.configure(NetProtocol.VERSION, "abc")
	s2.create_match({
		"match_id": "m_bad", "seed": 1, "players": ["p1", "p2"],
		"decks": {"p1": [_unit], "p2": [_unit]}, "card_costs": {_unit: 1},
		"hero_hp": {"p1": 30, "p2": 30}, "rate_limit_per_sec": -1,
		"board": {"players": []},
	})
	var audited := false
	for entry in s2.audit_log():
		if String((entry as Dictionary).get("event", "")) == "board_setup_failed":
			audited = true
	_check("会话: 建盘失败写审计且不接盘面（骨架模式继续可用）",
		s2.board() == null and audited and not s2.authority().has_board(),
		str(s2.audit_log()))


## 权威端**回合推进**：end_turn → 服务器用 TurnSystem 结算本单位行动 → 推进回合。
## 这条链路是"服务器能自己算完一整局"的核心。
func _test_turn_phase() -> void:
	Game.registry.clear()
	# 运行时宿主（建节点、入树）由部署入口/测试负责；服务器层只接收注入。
	var host := BattleSimHost.new()
	add_child(host)
	var s := BattleServerSession.new()
	s.configure(NetProtocol.VERSION, "abc")
	s.create_match({
		"match_id": "m_phase", "seed": 11, "players": ["p1", "p2"],
		"decks": {"p1": [_unit, _unit, _unit], "p2": [_unit, _unit, _unit]},
		"card_costs": {_unit: 1}, "hero_hp": {"p1": 30, "p2": 30},
		"rate_limit_per_sec": -1,
		"board": {"players": ["p1", "p2"], "teams": {"p1": "defender", "p2": "attacker"}},
		"sim_host": host,
	})
	_check("回合: 模拟宿主已注入权威盘面", s.board() != null and s.board().has_sim())
	var b = s.board()
	# 服务器会话要求先握手（与真实客户端一致）
	var hello := {"type": NetProtocol.CLIENT_HELLO,
		"payload": {"protocol": NetProtocol.VERSION, "content_hash": "abc"}}
	s.handle_client_message("p1", hello)
	s.handle_client_message("p2", hello)
	s.drain_outbound("p1")
	s.drain_outbound("p2")
	# p1 盘上：p1 单位（owner=main_p1）与 p2 单位（owner=main_p2）相邻 → 应发生攻击
	var atk: CellData = b.cell_at("main_p1", 2, 1)
	atk.set_card(_unit, 5, {"front": 5, "back": 5, "left": 5, "right": 5}, false,
		[], "main_p1", "initial", "defender")
	var dfd: CellData = b.cell_at("main_p1", 2, 2)
	dfd.set_card(_unit, 0, {"front": 1, "back": 1, "left": 1, "right": 1}, false,
		[], "main_p2", "initial", "attacker")

	var r: Dictionary = s.handle_client_message("p1", {"type": NetProtocol.INTENT_END_TURN,
		"payload": {"seq": 0}})
	_check("回合: end_turn 被接受并登记待结算阶段",
		bool(r.get("accepted", false)) and s.authority().has_pending_work(), str(r))
	await s.tick()
	_check("回合: 结算后待处理阶段清空", not s.authority().has_pending_work())
	_check("回合: 服务器结算了攻击（相邻敌方单位阵亡）",
		not dfd.has_card and dfd.card_name == "", str(dfd.to_dict()))
	_check("回合: 阵亡按归属入墓（owner_slot_id 路由）",
		b.slot_at("main_p2").graveyard.size() == 1, str(b.slot_at("main_p2").graveyard.size()))
	_check("回合: 攻击方仍在原位", atk.has_card and atk.card_name == _unit)

	var events: Array = []
	for m in s.drain_outbound("p2"):
		events.append(String(((m as Dictionary).get("payload", {}) as Dictionary).get("event", "")))
	_check("回合: 下发 phase_resolved 权威事件", events.has("phase_resolved"), str(events))
	_check("回合: 回合已推进到 p2", s.authority().active_player() == "p2",
		s.authority().active_player())
	_check("回合: 无棋盘时不登记待结算阶段（骨架模式语义不变）",
		not _make_skeleton_session().authority().has_pending_work())


## 棋盘英雄血量 ↔ 权威终局判定：棋盘是真相来源，英雄阵亡必须产生 auth/verdict。
func _test_board_hero_sync() -> void:
	Game.registry.clear()
	var host := BattleSimHost.new()
	add_child(host)
	var s := BattleServerSession.new()
	s.configure(NetProtocol.VERSION, "abc")
	s.create_match({
		"match_id": "m_hero", "seed": 13, "players": ["p1", "p2"],
		"decks": {"p1": [_unit], "p2": [_unit]}, "card_costs": {_unit: 1},
		"hero_hp": {"p1": 30, "p2": 30}, "rate_limit_per_sec": -1,
		"board": {"players": ["p1", "p2"], "teams": {"p1": "defender", "p2": "attacker"}},
		"sim_host": host,
	})
	var hello := {"type": NetProtocol.CLIENT_HELLO,
		"payload": {"protocol": NetProtocol.VERSION, "content_hash": "abc"}}
	s.handle_client_message("p1", hello)
	s.handle_client_message("p2", hello)
	s.drain_outbound("p1")
	s.drain_outbound("p2")

	_check("英雄: 权威视图的血量取自棋盘",
		int(((s.authority().view_for("p2")["you"] as Dictionary)["hero"] as Dictionary)["hp"]) == 30,
		str(s.authority().view_for("p2")["you"]["hero"]))

	# 棋盘上英雄受到致命伤（能力/冲锋都会走这条路径）
	s.board().slot_at("main_p2").damage_hero(100, "triggered")
	_check("英雄: 棋盘英雄血量已归零（伤害不夹紧，<=0 即阵亡）",
		s.board().hero_hp("p2") <= 0, str(s.board().hero_hp("p2")))
	_check("英雄: 同步前权威尚未判终局", not s.authority().is_finished())

	await s.tick()
	_check("英雄: tick 同步后判定终局", s.authority().is_finished())
	_check("英雄: 获胜者是 p1", String(s.authority().verdict()["winner"]) == "p1",
		str(s.authority().verdict()))

	var p2_types: Array = []
	for m in s.drain_outbound("p2"):
		p2_types.append(String((m as Dictionary).get("type", "")))
	_check("英雄: 向双方下发 auth/verdict", p2_types.has(NetProtocol.AUTH_VERDICT), str(p2_types))


## 法术接入权威端：目标校验同步、效果在 tick 中执行（协程），并下发 spell_cast。
func _test_spell_play() -> void:
	# 取一张"无 await 效果"的真实法术（empower：对友方单位四维各 +1）
	var spell_name := ""
	for key in Game.card_db.keys():
		var card = Game.card_db[key]
		if card is CardSpell and (card.effects as Array).has("empower"):
			spell_name = String(key)
			break
	_check("法术: 找到 empower 法术卡", spell_name != "", spell_name)
	if spell_name == "":
		# 补齐断言数量，避免"用例数异常"掩盖真实失败
		for _i in range(10):
			_check("法术: 跳过（卡库缺 empower）", false, "no empower spell")
		return

	Game.registry.clear()
	var host := BattleSimHost.new()
	add_child(host)
	var s := BattleServerSession.new()
	s.configure(NetProtocol.VERSION, "abc")
	s.create_match({
		"match_id": "m_spell", "seed": 17, "players": ["p1", "p2"],
		# 牌库 3 张 = 开局手牌，保证手上有法术
		"decks": {"p1": [spell_name, spell_name, spell_name],
			"p2": [spell_name, spell_name, spell_name]},
		"card_costs": {spell_name: 1}, "hero_hp": {"p1": 30, "p2": 30},
		"rate_limit_per_sec": -1,
		"board": {"players": ["p1", "p2"], "teams": {"p1": "defender", "p2": "attacker"}},
		"sim_host": host,
	})
	var hello := {"type": NetProtocol.CLIENT_HELLO,
		"payload": {"protocol": NetProtocol.VERSION, "content_hash": "abc"}}
	s.handle_client_message("p1", hello)
	s.handle_client_message("p2", hello)
	s.drain_outbound("p1")
	s.drain_outbound("p2")

	var b = s.board()
	var ally: CellData = b.cell_at("main_p1", 2, 1)
	ally.set_card(_unit, 2, {"front": 4, "back": 4, "left": 4, "right": 4}, false,
		[], "main_p1", "initial", "defender")

	# ① 目标格没有单位 → 非法目标（效果没机会跑，也就不会白扣费用）
	var r1: Dictionary = s.handle_client_message("p1", {"type": NetProtocol.INTENT_PLAY_CARD,
		"payload": {"card_name": spell_name, "seq": 0,
			"target_slot_id": "main_p1", "row": 0, "col": 0}})
	_check("法术: 指向空格 → illegal_target",
		String(r1.get("reason", "")) == NetProtocol.REJECT_ILLEGAL_TARGET, str(r1))

	# ② 有目标策略的法术缺 row/col → illegal_target
	var r2: Dictionary = s.handle_client_message("p1", {"type": NetProtocol.INTENT_PLAY_CARD,
		"payload": {"card_name": spell_name, "seq": 1, "target_slot_id": "main_p1"}})
	_check("法术: 缺落点 → illegal_target",
		String(r2.get("reason", "")) == NetProtocol.REJECT_ILLEGAL_TARGET, str(r2))
	_check("法术: 两次拒绝后未消耗手牌与费用",
		(s.authority().view_for("p1")["you"] as Dictionary)["hand"].size() == 3
		and int(((s.authority().view_for("p1")["you"] as Dictionary)["mana"] as Dictionary)["current"]) == 1)

	# ③ 合法目标 → 接受（效果排队）
	var r3: Dictionary = s.handle_client_message("p1", {"type": NetProtocol.INTENT_PLAY_CARD,
		"payload": {"card_name": spell_name, "seq": 2,
			"target_slot_id": "main_p1", "row": 2, "col": 1}})
	_check("法术: 合法目标被接受", bool(r3.get("accepted", false)), str(r3))
	_check("法术: 接受后排入待结算队列（效果还没跑）",
		s.authority().has_pending_work() and int(ally.health["front"]) == 4,
		"%s / %s" % [str(s.authority().has_pending_work()), str(ally.health)])
	_check("法术: 手牌 -1、费用 -1",
		(s.authority().view_for("p1")["you"] as Dictionary)["hand"].size() == 2
		and int(((s.authority().view_for("p1")["you"] as Dictionary)["mana"] as Dictionary)["current"]) == 0)

	# ④ tick 执行效果
	await s.tick()
	_check("法术: tick 后效果已生效（四维各 +1）",
		int(ally.health["front"]) == 5 and int(ally.health["back"]) == 5
		and int(ally.health["left"]) == 5 and int(ally.health["right"]) == 5,
		str(ally.health))
	_check("法术: 待结算队列已清空", not s.authority().has_pending_work())

	var events: Array = []
	for m in s.drain_outbound("p2"):
		events.append(String(((m as Dictionary).get("payload", {}) as Dictionary).get("event", "")))
	_check("法术: 下发 card_played / spell_queued", events.has("card_played") and events.has("spell_queued"),
		str(events))
	_check("法术: 效果执行后下发 spell_cast（对手可见）", events.has("spell_cast"), str(events))

	# ⑤ 用过的法术牌进权威墓地（与骨架模式语义一致：已打出的牌不再回手）
	var grave: Array = (s.authority().view_for("p1")["you"] as Dictionary)["graveyard"]
	_check("法术: 已打出的法术计入墓地", grave.has(spell_name), str(grave))


func _make_skeleton_session() -> BattleServerSession:
	var s := BattleServerSession.new()
	s.configure(NetProtocol.VERSION, "abc")
	s.create_match({
		"match_id": "m_skel", "seed": 3, "players": ["p1", "p2"],
		"decks": {"p1": [_unit], "p2": [_unit]}, "card_costs": {_unit: 1},
		"hero_hp": {"p1": 30, "p2": 30}, "rate_limit_per_sec": -1,
	})
	s.handle_client_message("p1", {"type": NetProtocol.INTENT_END_TURN, "payload": {"seq": 0}})
	return s
