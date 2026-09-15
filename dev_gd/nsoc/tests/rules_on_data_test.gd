extends Node

## 规则层在**纯数据格**上运行测试（重构文档.md §3.4-6「规则层直面 CellData」）。
##
## 运行：
##   godot --headless --path dev_gd/nsoc res://tests/RulesOnDataTest.tscn
##
## 输出：
##   ROD_CASE [PASS|FAIL] <用例名> <说明>
##   ROD_RESULT PASS|FAIL passed=N failed=M
##
## 为什么需要它：规则层里有若干处会顺手调"表现"（`effects_changed.emit` /
## `play_damage_effect` / `play_death_effect` / `_update_hp_labels`）。这些调用在客户端
## `Cell` 上有真实视图，在**无头/服务器**的 `CellData` 上却是致命的 —— 之前会在
## 法术施放器、疑兵自爆、`straight_in_ability` 等路径直接抛
## "Invalid access ... on a base object of type 'CellData'"。
##
## 本测试用**纯数据盘**跑这些路径：既验证"不再崩"，也验证"该发生的状态变化照样发生"。

const EXPECTED_CASES: int = 16

var _passed: int = 0
var _failed: int = 0


func _ready() -> void:
	Game._load_card_db()
	Game.registry.clear()
	_test_presentation_surface()
	_test_ability_paths()
	await _test_effect_paths()

	var total: int = _passed + _failed
	if total != EXPECTED_CASES:
		_failed += 1
		print("ROD_CASE FAIL 用例数量异常：期望 %d，实际 %d（有测试函数被运行时错误静默中断）"
			% [EXPECTED_CASES, total])

	print("ROD_RESULT %s passed=%d failed=%d" % [
		"PASS" if _failed == 0 else "FAIL", _passed, _failed,
	])
	get_tree().quit(0 if _failed == 0 else 1)


func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("ROD_CASE PASS %s" % name)
	else:
		_failed += 1
		print("ROD_CASE FAIL %s | %s" % [name, detail])


## 建一块纯数据盘（含一个可选单位）。
func _board(slot_id: String, faction: int, with_unit: bool = true,
		enemy: bool = false, card: String = "") -> BoardSlot:
	var slot: BoardSlot = BoardSlotFactory.create_headless(slot_id, faction,
		BoardSlot.ROLE_MAIN_PLAYER if faction == BoardSlot.FACTION_PLAYER else BoardSlot.ROLE_MAIN_ENEMY,
		{"hp": 30, "name_short": slot_id}, {}, "team_a", "uuid_" + slot_id)
	if with_unit:
		var cell = slot.board.get_cell(Vector2(2, 1))
		var cname: String = card if card != "" else _any_unit_card()
		var cdata = Game.get_card(cname)
		cell.set_card(String(cdata.name), int(cdata.attack), cdata.health, enemy,
			(cdata.effects as Array).duplicate(), slot_id, "initial", "team_a")
	return slot


func _any_unit_card() -> String:
	for key in Game.card_db.keys():
		if Game.card_db[key] is CardUnit:
			return String(key)
	return ""


## 表现面空实现：这些调用在数据格上必须安全（no-op）。
func _test_presentation_surface() -> void:
	var cell := CellData.new()
	cell.set_card("x", 1, {"front": 1, "back": 1, "left": 1, "right": 1})
	var ok := true
	var detail := ""
	for call_name in ["_update_hp_labels", "play_damage_effect", "play_attack_effect",
			"play_death_effect"]:
		if not cell.has_method(call_name):
			ok = false
			detail = call_name
	_check("表现面: CellData 具备与 Cell 同名的表现方法（鸭子类型）", ok, detail)
	cell.effects_changed.emit({"name": "x"})
	_check("表现面: effects_changed 信号可 emit（无监听者为 no-op）", true)
	_check("表现面: 空实现不改变状态",
		int(cell.health["front"]) == 1 and cell.has_card)


## 英雄技能里会顺手调表现的两条路径。
func _test_ability_paths() -> void:
	Game.registry.clear()
	# straight_in_ability.trigger_start：给"敌方单位"加 charge，并 emit effects_changed
	var xuhuang: BoardSlot = _board("enemy_xuhuang", BoardSlot.FACTION_ENEMY, false)
	var enemy_slot: BoardSlot = _board("enemy_main", BoardSlot.FACTION_ENEMY, true, false)
	# is_hostile_to(local_team)：local_team 为空 → 回退 is_enemy，因此把单位设为敌方
	var target: CellData = enemy_slot.board.get_cell(Vector2(2, 1))
	target.is_enemy = true
	straight_in_ability_trigger()
	_check("技能: straight_in_ability 在纯数据盘上跑通（不崩）", true)
	_check("技能: 敌方单位获得 charge（状态变化照样发生）",
		(target.effects as Array).has("charge"), str(target.effects))
	_check("技能: 技能锚点盘存在则其单位也处理（同一路径）",
		not (xuhuang.board.get_cell(Vector2(2, 1)) as CellData).has_card)

	# surrender_ability.trigger：给玩家盘单位恢复初始四维 + 英雄满血
	Game.registry.clear()
	var player_slot: BoardSlot = _board("player_main", BoardSlot.FACTION_PLAYER, true, false)
	var unit: CellData = player_slot.board.get_cell(Vector2(2, 1))
	unit.health["front"] = 1
	surrender_ability_trigger()
	_check("技能: surrender_ability 在纯数据盘上跑通（不崩）", true)
	_check("技能: 单位四维恢复至初始值（max_health）",
		int(unit.health["front"]) == int(unit.max_health["front"]), str(unit.health))
	_check("技能: 英雄满血", player_slot.hero != null and player_slot.hero.health == player_slot.hero.max_health,
		str(player_slot.hero.health) if player_slot.hero != null else "no hero")


## 效果里会顺手调表现的几条路径（走 Effects.trigger_play，与权威端同一条路）。
func _test_effect_paths() -> void:
	Game.registry.clear()
	var slot: BoardSlot = _board("main_p1", BoardSlot.FACTION_PLAYER, true, false)
	var cell: CellData = slot.board.get_cell(Vector2(2, 1))
	var fake_card = Game.get_card(_any_unit_card())

	for eff_id in ["empower", "weaken", "jue_di", "destroy_unit"]:
		var ctx := Game.make_effect_context()
		ctx.target_cell = cell
		var ok: bool = await Effects.trigger_play(eff_id, fake_card, ctx)
		_check("效果: %s 在纯数据格上跑通（不崩）" % eff_id, ok, str(ok))

	_check("效果: 目标格仍可被查询（未被误清理）",
		cell != null and slot.board.get_cell(Vector2(2, 1)) == cell)
	# destroy_unit 走的是标准死亡流程：需要 Game.play（权威进程里指向自己的 PlayController），
	# 否则会"清空格子但不入墓"（静默漏结算）。这里用一块干净盘验证死亡清算确实发生。
	# 死亡清算走 Game.play（权威进程里由 BattleSimHost 指向自己的 PlayController）。
	# 本测试同样需要一个 PlayController 才能验证"入墓"这一步确实发生。
	if Game.play == null:
		var pc := PlayController.new()
		pc.name = "TestPlayController"
		add_child(pc)
		Game.play = pc
	Game.registry.clear()
	var s2: BoardSlot = _board("main_p2", BoardSlot.FACTION_PLAYER, true, false)
	var victim: CellData = s2.board.get_cell(Vector2(2, 1))
	var ctx2 := Game.make_effect_context()
	ctx2.target_cell = victim
	await Effects.trigger_play("destroy_unit", fake_card, ctx2)
	_check("效果: destroy_unit 后目标被清空", not victim.has_card, str(victim.has_card))
	_check("效果: destroy_unit 走了标准死亡流程（牌入原属盘墓地，未静默漏结算）",
		s2.graveyard.size() == 1, str(s2.graveyard.size()))


## 直接以静态方式调用技能（技能本身是 static func trigger*(game_node)）。
func straight_in_ability_trigger() -> void:
	var script = load("res://scripts/abilities/straight_in_ability.gd")
	var inst = script.new()
	inst.trigger_start(Game)


func surrender_ability_trigger() -> void:
	var script = load("res://scripts/abilities/surrender_ability.gd")
	var inst = script.new()
	inst.trigger(Game)
