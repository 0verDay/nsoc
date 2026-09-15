extends Node

## 无视图装配测试（重构文档.md §3.4-6 / 阶段 3）。
##
## 运行：
##   godot --headless --path dev_gd/nsoc res://tests/HeadlessSetupTest.tscn
##
## 输出：
##   HSETUP_CASE [PASS|FAIL] <用例名> <说明>
##   HSETUP_RESULT PASS|FAIL passed=N failed=M
##
## 目的：证明**整块棋盘可以在零视图环境里装配出来**（`BoardSlotFactory.create_headless`）：
##   BoardModel + CellData + HeroState + SpawnerSystem + SpellCasterSystem + BoardSlot + Registry
## 全部就位，而 `grid_node` / `bg_panel` / `hero_panel` 全为空 —— 服务器权威端要跑的就是这条
## 装配路径（客户端那条走 `create_main`，两条共用 `create_slot` 这一份数据层装配）。
##
## 同时锁定一处本轮修掉的真问题：`CombatSystem.move_card` 的瞬时（服务器）路径原来不透传
## `team_id`，`CellData` 又没有 `Game.registry` 可反查，导致 PVP 单位一跨盘就掉队伍归属。
##
## 注意：GDScript 运行时错误不会终止 _ready()，出错函数会静默提前返回，
## 因此末尾必须校验用例总数（EXPECTED_CASES），否则会"假通过"。

const EXPECTED_CASES: int = 20

var _passed: int = 0
var _failed: int = 0


## 替身卡牌原型：`populate_initial_units` 只读 name/attack/health/effects 四个字段，
## 必须是对象（不能是 Dictionary），所以这里给一个最小类。
class FakeCard:
	var name: String = "fake_unit"
	var attack: int = 3
	var health: Dictionary = {"front": 4, "back": 4, "left": 4, "right": 4}
	var effects: Array = []

	func _init(p_name: String = "fake_unit", p_atk: int = 3, p_hp: int = 4) -> void:
		name = p_name
		attack = p_atk
		health = {"front": p_hp, "back": p_hp, "left": p_hp, "right": p_hp}


func _ready() -> void:
	_test_headless_assembly()
	_test_initial_units_and_registry()
	_test_data_board_combat()

	var total: int = _passed + _failed
	if total != EXPECTED_CASES:
		_failed += 1
		print("HSETUP_CASE FAIL 用例数量异常：期望 %d，实际 %d（有测试函数被运行时错误静默中断）"
			% [EXPECTED_CASES, total])

	print("HSETUP_RESULT %s passed=%d failed=%d" % [
		"PASS" if _failed == 0 else "FAIL", _passed, _failed,
	])
	get_tree().quit(0 if _failed == 0 else 1)


func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("HSETUP_CASE PASS %s" % name)
	else:
		_failed += 1
		print("HSETUP_CASE FAIL %s | %s" % [name, detail])


func _fake_resolver(a_name: String, a_atk: int = 3, a_hp: int = 4) -> Callable:
	var card := FakeCard.new(a_name, a_atk, a_hp)
	return func(_n: String): return card


func _test_headless_assembly() -> void:
	var slot: BoardSlot = BoardSlotFactory.create_headless(
		"hb_player", BoardSlot.FACTION_PLAYER, BoardSlot.ROLE_MAIN_PLAYER,
		{"hp": 25, "name_short": "关", "name_full": "关羽", "abilities": []})
	_check("装配: create_headless 返回有效 slot", slot != null and slot.id == "hb_player")

	var all_data := true
	var pos_ok := true
	for key in slot.board.grid_cells.keys():
		var cell = slot.board.grid_cells[key]
		if not (cell is CellData):
			all_data = false
		if cell.row != int(key.x) or cell.col != int(key.y) or cell.slot_id != "hb_player":
			pos_ok = false
	_check("装配: 3×3 = 9 格且全部是 CellData（无 Control）",
		slot.board.grid_cells.size() == 9 and all_data, str(slot.board.grid_cells.size()))
	_check("装配: 每格 row/col/slot_id 正确", pos_ok)

	_check("装配: 零视图（grid_node / bg_panel / hero_panel 均为空）",
		slot.grid_node == null and slot.bg_panel == null and slot.hero_panel == null)
	_check("装配: 英雄按 hero_spec 建立", slot.hero != null and slot.hero.health == 25
		and slot.hero.name_short == "关", "%s %s" % [str(slot.hero.health), slot.hero.name_short])
	_check("装配: spawner 与法术施放器已就位",
		slot.spawners != null and slot.spell_casters != null)
	_check("装配: 已注册进 registry（get_by_id / main_player）",
		Game.registry.get_by_id("hb_player") == slot and Game.registry.main_player() == slot)


func _test_initial_units_and_registry() -> void:
	var player_slot: BoardSlot = BoardSlotFactory.create_headless(
		"hb_p2", BoardSlot.FACTION_PLAYER, BoardSlot.ROLE_MAIN_PLAYER,
		{"hp": 30, "name_short": "P"})
	# 初始铺盘走 populate_initial_units（与客户端同一条函数），只是格子是数据对象
	player_slot.board.populate_initial_units(
		[{"name": "fake_unit", "positions": [Vector2(2, 1)]}],
		_fake_resolver("fake_unit", 5, 6), false)
	var p_cell: CellData = player_slot.board.get_cell(Vector2(2, 1))
	_check("铺盘: 数据格上落子成功（牌面/四维/出处）",
		p_cell.has_card and p_cell.card_name == "fake_unit" and p_cell.attack == 5
		and int(p_cell.health["front"]) == 6 and p_cell.origin == "initial",
		"%s %s" % [p_cell.card_name, str(p_cell.health)])
	_check("铺盘: 归属盘取所在盘（owner_slot_id = slot_id）",
		p_cell.owner_slot_id == "hb_p2", p_cell.owner_slot_id)

	# 敌方盘 + 显式注入队伍（PVP 语义）：连初始铺下的单位也要带队伍
	var enemy_slot: BoardSlot = BoardSlotFactory.create_headless(
		"hb_e2", BoardSlot.FACTION_ENEMY, BoardSlot.ROLE_MAIN_ENEMY,
		{"hp": 30, "name_short": "E"}, {}, "team_b", "uuid_e2")
	enemy_slot.board.populate_initial_units(
		[{"name": "fake_unit", "positions": [Vector2(0, 0)]}],
		_fake_resolver("fake_unit", 2, 3), true)
	var e_cell: CellData = enemy_slot.board.get_cell(Vector2(0, 0))
	var all_team := true
	for cell in enemy_slot.board.grid_cells.values():
		if cell.team_id != "team_b":
			all_team = false
	_check("铺盘: 队伍显式注入覆盖全部格子", all_team)
	_check("铺盘: 已落子单位也带队伍（CellData 不查 registry）",
		e_cell.team_id == "team_b", e_cell.team_id)
	_check("铺盘: 敌方单位按盘默认 faction 判为敌", e_cell.is_enemy)
	_check("铺盘: slot 记录 owner_player_id", enemy_slot.owner_player_id == "uuid_e2")

	_check("注册表: by_faction / by_role / sorted_by_order 在无头 slot 上可用",
		Game.registry.by_faction(BoardSlot.FACTION_ENEMY).has(enemy_slot)
		and Game.registry.by_role(BoardSlot.ROLE_MAIN_ENEMY).has(enemy_slot)
		and Game.registry.sorted_by_order().has(player_slot))


func _test_data_board_combat() -> void:
	var saved_instant: bool = Game.instant_battle
	Game.instant_battle = true   # 服务器/无头模式

	var a: BoardSlot = BoardSlotFactory.create_headless(
		"hb_a3", BoardSlot.FACTION_PLAYER, BoardSlot.ROLE_MAIN_PLAYER,
		{"hp": 30, "name_short": "A"}, {}, "team_a")
	var b: BoardSlot = BoardSlotFactory.create_headless(
		"hb_b3", BoardSlot.FACTION_ENEMY, BoardSlot.ROLE_MAIN_ENEMY,
		{"hp": 30, "name_short": "B"}, {}, "team_b")

	var src: CellData = a.board.get_cell(Vector2(2, 0))
	src.set_card("mover", 4, {"front": 5, "back": 5, "left": 5, "right": 5}, false,
		["charge"], "", "hand", "team_a")
	src.has_charged = true
	var dst: CellData = b.board.get_cell(Vector2(0, 2))

	var combat := CombatSystem.new()
	add_child(combat)
	combat.move_card(src, dst)   # 瞬时路径无 await，同步完成

	_check("移动: 源格已清空", not src.has_card and src.card_name == "")
	_check("移动: 目标格获得全部字段（牌面/四维/效果/冲锋标记）",
		dst.has_card and dst.card_name == "mover" and dst.attack == 4
		and int(dst.health["front"]) == 5 and dst.effects.has("charge") and dst.has_charged,
		"%s %s" % [dst.card_name, str(dst.health)])
	_check("移动: 保留原属盘与出处（死亡入原属盘墓地）",
		dst.owner_slot_id == "hb_a3" and dst.origin == "hand",
		"%s %s" % [dst.owner_slot_id, dst.origin])
	_check("移动: 跨盘后队伍归属不变（本轮修复：CellData 需显式透传 team_id）",
		dst.team_id == "team_a", dst.team_id)

	# 跨盘攻击结算：攻击方在 A 盘，防守方在 B 盘（数据对象，无任何节点）
	var attacker: CellData = a.board.get_cell(Vector2(2, 2))
	attacker.set_card("atk", 3, {"front": 5, "back": 5, "left": 5, "right": 5}, false,
		[], "", "initial", "team_a")
	var victim: CellData = b.board.get_cell(Vector2(0, 0))
	victim.set_card("victim", 0, {"front": 2, "back": 2, "left": 2, "right": 2}, false,
		[], "", "initial", "team_b")

	var dead: Array = CombatSystem.resolve_attack(attacker, [{"cell": victim, "opp_dir": "top"}])
	_check("结算: 跨盘攻击扣血（abs top → side front）",
		int(victim.health["front"]) == -1 and int(victim.health["left"]) == 2, str(victim.health))
	_check("结算: 阵亡判定与名单一致（数据对象）",
		CombatSystem.is_cell_dead(victim) and dead.has(victim), str(dead.size()))

	Game.instant_battle = saved_instant
