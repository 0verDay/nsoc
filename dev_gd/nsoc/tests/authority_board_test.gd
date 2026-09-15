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

const EXPECTED_CASES: int = 25

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

	var total: int = _passed + _failed
	if total != EXPECTED_CASES:
		_failed += 1
		print("ABOARD_CASE FAIL 用例数量异常：期望 %d，实际 %d（有测试函数被运行时错误静默中断）"
			% [EXPECTED_CASES, total])

	print("ABOARD_RESULT %s passed=%d failed=%d" % [
		"PASS" if _failed == 0 else "FAIL", _passed, _failed,
	])
	get_tree().quit(0 if _failed == 0 else 1)


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
