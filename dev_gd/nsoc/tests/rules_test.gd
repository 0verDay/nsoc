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

const EXPECTED_CASES: int = 29

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


# ══ 工具 ═════════════════════════════════════════════════════════════════

func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("RULES_CASE PASS %s" % name)
	else:
		_failed += 1
		print("RULES_CASE FAIL %s | %s" % [name, detail])
