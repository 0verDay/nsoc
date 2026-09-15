extends Node

## 规则层单元测试（重构文档.md §7 阶段 2「测试网」）。
##
## 运行：
##   godot --headless --path dev_gd/nsoc res://tests/RulesTest.tscn
##
## 输出：
##   RULES_CASE [PASS|FAIL] <用例名> <说明>
##   RULES_RESULT PASS|FAIL passed=N failed=M
##
## 覆盖的都是**无需场景树即可实例化**的纯逻辑模块：
##   Orientation（阵营↔绝对方向映射、血量视角转换）
##   ManaSystem（费用增长、封顶、花费）
##   DeckManager（牌堆展开、抽牌、墓地回收、种子确定性）
##   MarkupParser（自定义标记 → BBCode）
##
## 注意：GDScript 的运行时错误不会终止 _ready()，出错函数会静默提前返回，
## 因此末尾必须校验用例总数（EXPECTED_CASES），否则会"假通过"。

const EXPECTED_CASES: int = 48

var _passed: int = 0
var _failed: int = 0


class FakeCard:
	var name: String = ""
	var count: int = 1

	func _init(p_name: String = "", p_count: int = 1) -> void:
		name = p_name
		count = p_count


func _ready() -> void:
	_test_orientation()
	_test_mana()
	_test_deck()
	_test_markup()
	_test_battle_mode()
	_test_slot_order()
	_test_battle_rng()
	_test_combat_resolve()
	_test_pvp_settlement()

	var total: int = _passed + _failed
	if total != EXPECTED_CASES:
		_failed += 1
		print("RULES_CASE FAIL 用例数量异常：期望 %d，实际 %d（有测试函数被运行时错误静默中断）"
			% [EXPECTED_CASES, total])

	print("RULES_RESULT %s passed=%d failed=%d" % [
		"PASS" if _failed == 0 else "FAIL", _passed, _failed,
	])
	get_tree().quit(0 if _failed == 0 else 1)


# ══ Orientation ══════════════════════════════════════════════════════════

func _test_orientation() -> void:
	_check("方向: SIDES 为四面",
		Orientation.SIDES == ["front", "back", "left", "right"], str(Orientation.SIDES))
	_check("方向: ABS_DIRS 为四个屏幕方向",
		Orientation.ABS_DIRS == ["top", "bottom", "left", "right"], str(Orientation.ABS_DIRS))

	# 往返一致性：side → abs → side 必须回到原值（玩家侧与敌方侧都要成立）
	var round_trip_ok := true
	var bad := ""
	for side in Orientation.SIDES:
		for is_enemy in [false, true]:
			var abs_dir: String = Orientation.side_to_abs(side, is_enemy)
			var back: String = Orientation.abs_to_side(abs_dir, is_enemy)
			if back != side:
				round_trip_ok = false
				bad = "%s(enemy=%s) -> %s -> %s" % [side, str(is_enemy), abs_dir, back]
	_check("方向: side→abs→side 往返一致", round_trip_ok, bad)

	_check("方向: 敌方视角左右镜像",
		Orientation.side_to_abs("front", true) == "bottom"
		and Orientation.side_to_abs("left", true) == "right"
		and Orientation.side_to_abs("front", false) == "top"
		and Orientation.side_to_abs("left", false) == "left",
		"enemy front=%s left=%s / player front=%s left=%s" % [
			Orientation.side_to_abs("front", true), Orientation.side_to_abs("left", true),
			Orientation.side_to_abs("front", false), Orientation.side_to_abs("left", false)])

	var side_hp: Dictionary = Orientation.health_player_abs_to_side(
		{"top": 1, "bottom": 2, "left": 3, "right": 4})
	_check("方向: 玩家视角血量按 front/back 映射",
		int(side_hp["front"]) == 1 and int(side_hp["back"]) == 2
		and int(side_hp["left"]) == 3 and int(side_hp["right"]) == 4, str(side_hp))

	var original: Dictionary = {"front": 5, "back": 5, "left": 5, "right": 5}
	var copy: Dictionary = Orientation.clone_side_health(original)
	copy["front"] = 99
	_check("方向: clone_side_health 不共享引用", int(original["front"]) == 5, str(original))

	_check("方向: 未知方向原样返回",
		Orientation.abs_to_side("nonsense", false) == "nonsense",
		Orientation.abs_to_side("nonsense", false))


# ══ ManaSystem ═══════════════════════════════════════════════════════════

func _test_mana() -> void:
	var m := ManaSystem.new()
	m.setup(5, 10)
	_check("费用: setup 后 current == maximum == start",
		m.current == 5 and m.maximum == 5, "current=%d maximum=%d" % [m.current, m.maximum])

	var m2 := ManaSystem.new()
	m2.setup(1, 99)
	_check("费用: cap 被夹到 MAX_MANA_CAP",
		m2.cap == ManaSystem.MAX_MANA_CAP, str(m2.cap))

	m2.start_new_turn()
	_check("费用: 新回合上限 +1 且补满",
		m2.maximum == 2 and m2.current == 2, "current=%d maximum=%d" % [m2.current, m2.maximum])

	var m3 := ManaSystem.new()
	m3.setup(1, 3)
	for _i in range(6):
		m3.start_new_turn()
	_check("费用: 达到 cap 后不再增长",
		m3.maximum == 3 and m3.current == 3, "current=%d maximum=%d cap=%d" % [m3.current, m3.maximum, m3.cap])

	var m4 := ManaSystem.new()
	m4.setup(3, 10)
	var before: int = m4.current
	var refused: bool = m4.spend(999)
	_check("费用: 不足时拒绝且不扣费",
		refused == false and m4.current == before, "spend(999)=%s current=%d" % [str(refused), m4.current])
	_check("费用: 足额花费成功",
		m4.spend(3) and m4.current == 0, "current=%d" % m4.current)


# ══ DeckManager ══════════════════════════════════════════════════════════

func _test_deck() -> void:
	var dm := DeckManager.new()
	dm.setup([FakeCard.new("A", 2), FakeCard.new("B", 3)])
	_check("牌堆: setup 按 count 展开", dm.draw_pile.size() == 5, str(dm.draw_pile.size()))
	var counts: Dictionary = dm.get_deck_counts()
	_check("牌堆: get_deck_counts 按名统计",
		int(counts.get("A", 0)) == 2 and int(counts.get("B", 0)) == 3, str(counts))

	for _i in range(5):
		dm.draw_card()
	_check("牌堆: 抽空后返回 null", dm.draw_card() == null, str(dm.draw_pile.size()))

	# 墓地回收：把牌送入墓地后，空堆再抽会触发 reshuffle(false)
	var dm2 := DeckManager.new()
	dm2.setup([FakeCard.new("C", 1)])
	var card = dm2.draw_card()
	dm2.send_to_graveyard(card)
	var recycled = dm2.draw_card()
	_check("牌堆: 空堆自动回收墓地", recycled != null and String(recycled.name) == "C",
		"recycled=%s" % str(recycled))
	_check("牌堆: 回收后墓地清空", dm2.graveyard.is_empty(), str(dm2.graveyard.size()))

	# 种子确定性：PVP 同步依赖它
	var a := DeckManager.new()
	a.setup_seeded([FakeCard.new("X", 4), FakeCard.new("Y", 4), FakeCard.new("Z", 4)], 20260101)
	var b := DeckManager.new()
	b.setup_seeded([FakeCard.new("X", 4), FakeCard.new("Y", 4), FakeCard.new("Z", 4)], 20260101)
	var c := DeckManager.new()
	c.setup_seeded([FakeCard.new("X", 4), FakeCard.new("Y", 4), FakeCard.new("Z", 4)], 777)
	var names_a: Array = a.draw_pile.map(func(x): return String(x.name))
	var names_b: Array = b.draw_pile.map(func(x): return String(x.name))
	var names_c: Array = c.draw_pile.map(func(x): return String(x.name))
	_check("牌堆: 同种子顺序完全一致", names_a == names_b, "%s vs %s" % [str(names_a), str(names_b)])
	_check("牌堆: 不同种子顺序不同", names_a != names_c, "%s vs %s" % [str(names_a), str(names_c)])

	var dm3 := DeckManager.new()
	dm3.setup([FakeCard.new("D", 1)])
	var d = dm3.draw_card()
	dm3.banish(d)
	_check("牌堆: banish 进入除外区", dm3.banished.size() == 1, str(dm3.banished.size()))


# ══ MarkupParser ═════════════════════════════════════════════════════════

func _test_markup() -> void:
	_check("标记: 空串原样返回", MarkupParser.parse("") == "", MarkupParser.parse(""))
	_check("标记: {break} 转空行",
		MarkupParser.parse("a{break}b") == "a\n\nb", MarkupParser.parse("a{break}b"))
	_check("标记: {place:..} 转 BBCode 颜色",
		MarkupParser.parse("{place:长坂坡}") == "[color=#ffd43b]长坂坡[/color]",
		MarkupParser.parse("{place:长坂坡}"))
	_check("标记: 多个标记与正文混排",
		MarkupParser.parse("见{ally:赵云}与{enemy:曹操}") \
			== "见[color=#74c0fc]赵云[/color]与[color=#ff6b6b]曹操[/color]",
		MarkupParser.parse("见{ally:赵云}与{enemy:曹操}"))


# ══ BattleMode ═══════════════════════════════════════════════════════════

func _test_battle_mode() -> void:
	_check("模式: 名称映射正确",
		BattleMode.name_of(BattleMode.Kind.CAMPAIGN) == "campaign"
		and BattleMode.name_of(BattleMode.Kind.SKIRMISH) == "skirmish"
		and BattleMode.name_of(BattleMode.Kind.EMPIRE) == "empire"
		and BattleMode.name_of(BattleMode.Kind.PVP) == "pvp"
		and BattleMode.name_of(99) == "unknown",
		BattleMode.name_of(99))
	_check("模式: 合法性校验",
		BattleMode.is_valid(BattleMode.Kind.PVP) and not BattleMode.is_valid(-1)
		and not BattleMode.is_valid(4), str(BattleMode.is_valid(4)))
	_check("模式: 默认 AI 判定",
		BattleMode.default_uses_ai(BattleMode.Kind.SKIRMISH)
		and BattleMode.default_uses_ai(BattleMode.Kind.EMPIRE)
		and not BattleMode.default_uses_ai(BattleMode.Kind.CAMPAIGN)
		and not BattleMode.default_uses_ai(BattleMode.Kind.PVP), "AI 判定不符")
	_check("模式: 由 pending 派生",
		BattleMode.from_pending("res://data/chapters/x.json", "", false) == BattleMode.Kind.CAMPAIGN
		and BattleMode.from_pending("", "res://data/test_level.json", false) == BattleMode.Kind.CAMPAIGN
		and BattleMode.from_pending("", "", false) == BattleMode.Kind.SKIRMISH
		and BattleMode.from_pending("", "", true) == BattleMode.Kind.EMPIRE,
		"派生结果不符")


# ══ 行动定序（§3.4-7）═════════════════════════════════════════════════════

## 定序必须与屏幕像素无关：本测试刻意不创建任何 bg_panel / cell，
## 因此旧的 visual_x() 实现只能返回 INF（顺序随机），新实现应给出确定顺序。
func _test_slot_order() -> void:
	var reg := BoardRegistry.new()
	var right := BoardSlot.new(); right.id = "ally_right";   right.slot_index = 5
	var left  := BoardSlot.new(); left.id  = "ally_left";    left.slot_index = 3
	var main  := BoardSlot.new(); main.id  = "player_main";  main.slot_index = 4
	reg.slots = [right, main, left]   # 故意打乱加入顺序
	var ordered: Array = reg.sorted_by_order()
	_check("定序: 按 slot_index 升序且与加入顺序无关",
		ordered.size() == 3 and String(ordered[0].id) == "ally_left"
		and String(ordered[1].id) == "player_main"
		and String(ordered[2].id) == "ally_right",
		str(ordered.map(func(s): return s.id)))

	var dup_b := BoardSlot.new(); dup_b.id = "b_slot"; dup_b.slot_index = 1
	var dup_a := BoardSlot.new(); dup_a.id = "a_slot"; dup_a.slot_index = 1
	reg.slots = [dup_b, dup_a]
	var ordered2: Array = reg.sorted_by_order()
	_check("定序: 相同 slot_index 时按 id 兜底（完全确定）",
		String(ordered2[0].id) == "a_slot" and String(ordered2[1].id) == "b_slot",
		str(ordered2.map(func(s): return s.id)))

	for s in [right, left, main, dup_a, dup_b]:
		s.free()


# ══ 规则随机源（§3.4-7）═════════════════════════════════════════════════

## 服务器权威要求"随机由服务端掌握"：同一种子必须给出同一序列，
## 客户端无法通过重开来挑选有利随机。
func _test_battle_rng() -> void:
	Game.seed_battle_rng(20260101)
	var seq_a: Array = [Game.rand_index(100), Game.rand_index(100), Game.rand_index(100)]
	Game.seed_battle_rng(20260101)
	var seq_b: Array = [Game.rand_index(100), Game.rand_index(100), Game.rand_index(100)]
	_check("随机源: 同种子下标序列一致", seq_a == seq_b, "%s vs %s" % [str(seq_a), str(seq_b)])

	Game.seed_battle_rng(777)
	var arr_a: Array = [1, 2, 3, 4, 5, 6, 7, 8]
	Game.shuffle_in_place(arr_a)
	Game.seed_battle_rng(777)
	var arr_b: Array = [1, 2, 3, 4, 5, 6, 7, 8]
	Game.shuffle_in_place(arr_b)
	_check("随机源: 同种子洗牌结果一致", arr_a == arr_b, "%s vs %s" % [str(arr_a), str(arr_b)])


# ══ 战斗结算（§3.4-6：规则与表现分离）═══════════════════════════════════

## 最小替身：只为 CombatSystem.resolve_attack 提供数据字段，
## 不含任何表现方法 —— 若结算函数偷偷调用 UI，本测试会立刻报错。
class FakeCell:
	extends Node

	var card_name: String = "fake"
	var health: Dictionary = {"front": 5, "back": 5, "left": 5, "right": 5}
	var effects: Array = []
	var is_enemy: bool = false
	var has_card: bool = true
	var attack: int = 2
	var owner_slot_id: String = ""
	var slot_id: String = ""
	var origin: String = ""

	func _init(p_hp: int = 5, p_effects: Array = [], p_is_enemy: bool = false, p_atk: int = 2) -> void:
		health = {"front": p_hp, "back": p_hp, "left": p_hp, "right": p_hp}
		effects = p_effects
		is_enemy = p_is_enemy
		attack = p_atk


func _test_combat_resolve() -> void:
	# 普通攻击：只扣对位面（玩家视角 opp_dir=top → side=front）
	var atk := FakeCell.new(5, [], false, 2)
	var dfd := FakeCell.new(5, [], false, 0)
	var dead: Array = CombatSystem.resolve_attack(atk, [{"cell": dfd, "opp_dir": "top"}])
	_check("结算: 普通攻击只扣对位面（top → front）",
		int(dfd.health["front"]) == 3 and int(dfd.health["back"]) == 5
		and int(dfd.health["left"]) == 5 and int(dfd.health["right"]) == 5, str(dfd.health))
	_check("结算: 未阵亡时阵亡名单为空", dead.is_empty(), str(dead.size()))
	atk.free(); dfd.free()

	# 虚弱：受到任意方向伤害时四面同扣
	var atk2 := FakeCell.new(5, [], false, 2)
	var dfd2 := FakeCell.new(5, ["frail"], false, 0)
	CombatSystem.resolve_attack(atk2, [{"cell": dfd2, "opp_dir": "top"}])
	_check("结算: 虚弱（frail）四面同扣",
		int(dfd2.health["front"]) == 3 and int(dfd2.health["back"]) == 3
		and int(dfd2.health["left"]) == 3 and int(dfd2.health["right"]) == 3, str(dfd2.health))
	atk2.free(); dfd2.free()

	# 浸水：受任何伤害后四面归零，并移除标记（一次性）
	var atk3 := FakeCell.new(5, [], false, 1)
	var dfd3 := FakeCell.new(9, ["soaked"], false, 0)
	CombatSystem.resolve_attack(atk3, [{"cell": dfd3, "opp_dir": "top"}])
	_check("结算: 浸水（soaked）四面归零且标记被移除",
		int(dfd3.health["front"]) == 0 and int(dfd3.health["back"]) == 0
		and not dfd3.effects.has("soaked"), "%s %s" % [str(dfd3.health), str(dfd3.effects)])
	atk3.free(); dfd3.free()

	# 疑兵：被攻击即自爆，并使攻击者四面各 -2
	var atk4 := FakeCell.new(5, [], false, 3)
	var dfd4 := FakeCell.new(5, ["yi_bing"], false, 0)
	var dead4: Array = CombatSystem.resolve_attack(atk4, [{"cell": dfd4, "opp_dir": "top"}])
	_check("结算: 疑兵（yi_bing）自爆且攻击者四面 -2",
		int(dfd4.health["front"]) == 0 and int(atk4.health["front"]) == 3
		and int(atk4.health["right"]) == 3, "%s %s" % [str(dfd4.health), str(atk4.health)])
	_check("结算: 阵亡名单含自爆的防御者、不含仍存活（3 血）的攻击者",
		dead4.has(dfd4) and not dead4.has(atk4), "size=%d atk=%s" % [dead4.size(), str(atk4.health)])
	atk4.free(); dfd4.free()

	# 攻击者被反伤致死：必须进入阵亡名单（原实现在延迟分支里补判）
	var atk5 := FakeCell.new(2, [], false, 1)
	var dfd5 := FakeCell.new(5, ["yi_bing"], false, 0)
	var dead5: Array = CombatSystem.resolve_attack(atk5, [{"cell": dfd5, "opp_dir": "top"}])
	_check("结算: 攻击者被反伤致死后进入阵亡名单",
		CombatSystem.is_cell_dead(atk5) and dead5.has(atk5), str(atk5.health))
	atk5.free(); dfd5.free()

	# is_cell_dead：任一面 <= 0 即为真
	var alive := FakeCell.new(1, [], false, 0)
	var gone := FakeCell.new(1, [], false, 0)
	gone.health["left"] = 0
	_check("结算: is_cell_dead 判定任一面 <=0",
		not CombatSystem.is_cell_dead(alive) and CombatSystem.is_cell_dead(gone),
		"%s %s" % [str(alive.health), str(gone.health)])
	alive.free(); gone.free()


# ══ 多队伍 PVP 结算（§4.1：结算由本端确定性推导，不依赖对端 game/end）══════

## 服务器已把 game/end 列为服务器专属消息（客户端发来被丢弃），因此结算画面
## 必须由本端自行推导。本测试锁定两件事：
##   1. winning_team_for 的胜负映射（3v3 / 1v3 / 边界）
##   2. pvp_end_game 会在本端 emit match_result_decided（广播只是对端兜底）
func _test_pvp_settlement() -> void:
	var saved_teams: Dictionary = Game.pvp_teams
	var saved_is_pvp: bool = Game.is_pvp
	var saved_room: String = Game.pvp_room_id

	# ── 胜负映射 ─────────────────────────────────────────────────────
	Game.pvp_teams = {"team_a": ["p1", "p2", "p3"], "team_b": ["p4", "p5", "p6"]}
	_check("结算: 3v3 落败 team_a → 获胜 team_b",
		Game.winning_team_for("team_a") == "team_b", Game.winning_team_for("team_a"))
	_check("结算: 3v3 落败 team_b → 获胜 team_a",
		Game.winning_team_for("team_b") == "team_a", Game.winning_team_for("team_b"))

	Game.pvp_teams = {"defender": ["p1"], "attacker": ["p2", "p3", "p4"]}
	_check("结算: 1v3 落败 defender → 获胜 attacker",
		Game.winning_team_for("defender") == "attacker", Game.winning_team_for("defender"))

	_check("结算: 落败队伍为空串时返回空串（不误判）",
		Game.winning_team_for("") == "", Game.winning_team_for(""))
	Game.pvp_teams = {"team_a": ["p1"]}
	_check("结算: 只有一支队伍时返回空串",
		Game.winning_team_for("team_a") == "", Game.winning_team_for("team_a"))

	# ── 本端信号（不依赖网络回声）────────────────────────────────────
	Game.pvp_teams = {"team_a": ["p1", "p2", "p3"], "team_b": ["p4", "p5", "p6"]}
	Game.pvp_room_id = "12345"
	Game.is_pvp = true
	var got: Array = []
	var cb := func(wt: String, lp: String) -> void: got.append([wt, lp])
	Game.match_result_decided.connect(cb)
	# 未连接服务器：Net.send_to_room 会走 "not connected, drop" 分支（不影响本端结算）
	Game.pvp_end_game("team_b", "p1")
	Game.match_result_decided.disconnect(cb)
	_check("结算: pvp_end_game 在本端 emit match_result_decided（含胜负与阵亡者）",
		got.size() == 1 and got[0][0] == "team_b" and got[0][1] == "p1", str(got))

	# 非 PVP 模式不得触发结算信号
	Game.is_pvp = false
	var got2: Array = []
	var cb2 := func(wt: String, lp: String) -> void: got2.append([wt, lp])
	Game.match_result_decided.connect(cb2)
	Game.pvp_end_game("team_b", "p1")
	Game.match_result_decided.disconnect(cb2)
	_check("结算: 非 PVP 模式不触发结算信号", got2.is_empty(), str(got2))

	Game.pvp_teams = saved_teams
	Game.is_pvp = saved_is_pvp
	Game.pvp_room_id = saved_room


# ══ 工具 ═════════════════════════════════════════════════════════════════

func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("RULES_CASE PASS %s" % name)
	else:
		_failed += 1
		print("RULES_CASE FAIL %s | %s" % [name, detail])
