extends Node

## 无头战斗结算测试（重构文档.md §3.4-6 / 阶段 3）。
##
## 运行：
##   godot --headless --path dev_gd/nsoc res://tests/HeadlessCombatTest.tscn
##
## 输出：
##   HCOMBAT_CASE [PASS|FAIL] <用例名> <说明>
##   HCOMBAT_RESULT PASS|FAIL passed=N failed=M
##
## 目的：证明**一次完整攻击（含阵亡清算与入墓路由）能在零视图环境里跑完**。
##   装配：BoardSlotFactory.create_headless（CellData 盘面）
##   结算：CombatSystem.presentation_enabled = false（不碰视图、不建 tween、不等待）
##   清算：PlayController.handle_unit_death（本身已是纯规则；只有出牌动画路径依赖 UI）
## 这条链路就是服务器权威端要跑的"棋盘结算"。
##
## 用真实卡库（`Game._load_card_db()`）：死亡清算要 `Game.get_card(cell.card_name)` 反查
## 卡牌原型，查不到会**直接丢弃而不入墓**（既有语义），所以替身卡名测不出入墓路由。
## 选一张"无效果"的真实卡，避免 death trigger 引入不确定行为。
##
## 注意：GDScript 运行时错误不会终止 _ready()，出错函数会静默提前返回，
## 因此末尾必须校验用例总数（EXPECTED_CASES），否则会"假通过"。

const EXPECTED_CASES: int = 16

var _passed: int = 0
var _failed: int = 0

var _combat: CombatSystem = null
var _pc: PlayController = null
var _player: BoardSlot = null
var _enemy: BoardSlot = null
var _card: String = ""


func _ready() -> void:
	Game._load_card_db()
	Game.registry.clear()
	_card = _plain_card_name()

	_player = BoardSlotFactory.create_headless("hc_p", BoardSlot.FACTION_PLAYER,
		BoardSlot.ROLE_MAIN_PLAYER, {"hp": 30, "name_short": "P"}, {}, "team_a", "uuid_a")
	_enemy = BoardSlotFactory.create_headless("hc_e", BoardSlot.FACTION_ENEMY,
		BoardSlot.ROLE_MAIN_ENEMY, {"hp": 30, "name_short": "E"}, {}, "team_b", "uuid_e")

	# 无表现的 CombatSystem + 未 setup 的 PlayController（死亡清算不需要 UI 容器）
	_combat = CombatSystem.new()
	add_child(_combat)
	_combat.presentation_enabled = false
	_pc = PlayController.new()
	add_child(_pc)
	_combat.setup(null, null, _pc)

	await _test_no_presentation_kill()
	await _test_death_routing()
	_test_instant_move()

	var total: int = _passed + _failed
	if total != EXPECTED_CASES:
		_failed += 1
		print("HCOMBAT_CASE FAIL 用例数量异常：期望 %d，实际 %d（有测试函数被运行时错误静默中断）"
			% [EXPECTED_CASES, total])

	print("HCOMBAT_RESULT %s passed=%d failed=%d" % [
		"PASS" if _failed == 0 else "FAIL", _passed, _failed,
	])
	get_tree().quit(0 if _failed == 0 else 1)


func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("HCOMBAT_CASE PASS %s" % name)
	else:
		_failed += 1
		print("HCOMBAT_CASE FAIL %s | %s" % [name, detail])


## 取一张"无死trigger 效果"的真实卡名，保证测试确定性。
func _plain_card_name() -> String:
	for key in Game.card_db.keys():
		var card = Game.card_db[key]
		var effs = card.effects if card != null else []
		if typeof(effs) == TYPE_ARRAY and effs.is_empty():
			return String(key)
	return ""


func _test_no_presentation_kill() -> void:
	_check("准备: 真实卡库已装载", Game.card_db.size() > 0, str(Game.card_db.size()))
	_check("准备: 找到无效果的普通单位卡", _card != "", _card)

	var atk: CellData = _player.board.get_cell(Vector2(2, 1))
	atk.set_card(_card, 5, {"front": 5, "back": 5, "left": 5, "right": 5}, false,
		[], "", "initial", "team_a")
	var dfd: CellData = _enemy.board.get_cell(Vector2(0, 1))
	dfd.set_card(_card, 0, {"front": 2, "back": 2, "left": 2, "right": 2}, false,
		[], "", "initial", "team_b")

	var nodes_before: int = _combat.get_child_count()
	# 细粒度动作信号（服务器转成 auth/event 下发用）
	var dmg_events: Array = []
	var death_events: Array = []
	_combat.damage_dealt.connect(func(p): dmg_events.append(p))
	_combat.units_died.connect(func(p): death_events.append(p))
	await _combat.attack_cells(atk, [{"cell": dfd, "opp_dir": "top"}])

	_check("无表现: 结算已生效（防守方对位面变负）",
		int(dfd.health["front"]) == -3, str(dfd.health))
	_check("事件: damage_dealt 带攻守双方血量快照",
		dmg_events.size() == 1
		and int(((dmg_events[0] as Dictionary)["defenders"][0] as Dictionary)["health"]["front"]) == -3
		and String(((dmg_events[0] as Dictionary)["defenders"][0] as Dictionary)["slot_id"]) == "hc_e",
		str(dmg_events))
	_check("事件: units_died 带阵亡名单（清空前的快照）",
		death_events.size() == 1
		and String(((death_events[0] as Dictionary)["deaths"][0] as Dictionary)["card_name"]) == _card
		and int(((death_events[0] as Dictionary)["deaths"][0] as Dictionary)["row"]) == 0,
		str(death_events))
	_check("无表现: 阵亡单位已从盘面清空", not dfd.has_card and dfd.card_name == "")
	_check("无表现: 攻击方存活", atk.has_card)
	_check("无表现: 全程不产生任何表现节点（CombatSystem 未挂 visual）",
		_combat.get_child_count() == nodes_before, str(_combat.get_child_count()))
	_check("无表现: 阵亡已完成入墓清算（入原属盘墓地）",
		_enemy.graveyard.size() == 1, str(_enemy.graveyard.size()))


func _test_death_routing() -> void:
	# 每个子用例先清墓，断言本次击杀的入墓结果（避免与上一段用例累计）
	_enemy.graveyard.clear()
	# origin="initial" → 入"原属盘"墓地（跨盘后仍按 owner_slot_id 定向）
	var atk: CellData = _player.board.get_cell(Vector2(2, 0))
	atk.set_card(_card, 5, {"front": 5, "back": 5, "left": 5, "right": 5}, false,
		[], "", "initial", "team_a")
	var dfd: CellData = _enemy.board.get_cell(Vector2(0, 2))
	dfd.set_card(_card, 0, {"front": 1, "back": 1, "left": 1, "right": 1}, false,
		[], "", "initial", "team_b")
	await _combat.attack_cells(atk, [{"cell": dfd, "opp_dir": "top"}])
	_check("入墓: origin=initial → 入原属盘（敌方盘）墓地",
		_enemy.graveyard.size() == 1, str(_enemy.graveyard.size()))
	_check("入墓: 墓地里是那张卡的原型对象",
		_enemy.graveyard.size() == 1 and String(_enemy.graveyard[0].name) == _card,
		str(_enemy.graveyard[0]) if _enemy.graveyard.size() > 0 else "<empty>")

	# origin="hand" → 入单位归属玩家的 deck.graveyard（PVP 路径；本测试无 decks[uid] → 兜底 Game.deck）
	if Game.deck == null:
		Game.deck = DeckManager.new()
	Game.deck.graveyard.clear()
	var atk2: CellData = _player.board.get_cell(Vector2(2, 2))
	atk2.set_card(_card, 5, {"front": 5, "back": 5, "left": 5, "right": 5}, false,
		[], "", "initial", "team_a")
	var dfd2: CellData = _enemy.board.get_cell(Vector2(1, 0))
	dfd2.set_card(_card, 0, {"front": 1, "back": 1, "left": 1, "right": 1}, false,
		[], "", "hand", "team_a")
	await _combat.attack_cells(atk2, [{"cell": dfd2, "opp_dir": "top"}])
	_check("入墓: origin=hand 且无归属玩家牌库 → 兜底入 Game.deck.graveyard",
		Game.deck.graveyard.size() == 1, str(Game.deck.graveyard.size()))
	_check("入墓: 每次阵亡只入一处（不会重复入墓）",
		_enemy.graveyard.size() == 1 and Game.deck.graveyard.size() == 1,
		"%d / %d" % [_enemy.graveyard.size(), Game.deck.graveyard.size()])


func _test_instant_move() -> void:
	# 表现开关关闭时，即使 instant_battle 为 false 也必须走瞬时数据转移
	var saved_instant: bool = Game.instant_battle
	Game.instant_battle = false
	var src: CellData = _player.board.get_cell(Vector2(1, 1))
	src.set_card(_card, 3, {"front": 4, "back": 4, "left": 4, "right": 4}, false,
		["charge"], "", "hand", "team_a")
	var dst: CellData = _enemy.board.get_cell(Vector2(2, 2))
	var move_events: Array = []
	_combat.move_resolved.connect(func(p): move_events.append(p))
	_combat.move_card(src, dst)
	_check("移动: 表现开关关闭时 move_card 仍走瞬时路径（不建 visual）",
		not src.has_card and dst.has_card and dst.card_name == _card)
	_check("事件: move_resolved 带起点（已空）与终点快照",
		move_events.size() == 1
		and String((move_events[0] as Dictionary)["card"]) == _card
		and String(((move_events[0] as Dictionary)["to"] as Dictionary)["slot_id"]) == "hc_e"
		and int(((move_events[0] as Dictionary)["to"] as Dictionary)["row"]) == 2,
		str(move_events))
	_check("移动: owner_slot_id / origin / team_id 全保留",
		dst.owner_slot_id == "hc_p" and dst.origin == "hand" and dst.team_id == "team_a",
		"%s %s %s" % [dst.owner_slot_id, dst.origin, dst.team_id])
	Game.instant_battle = saved_instant
