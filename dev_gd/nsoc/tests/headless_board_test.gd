extends Node

## 无头棋盘测试（重构文档.md §3.4-6 / 阶段 3「数据与表现分离」）。
##
## 运行：
##   godot --headless --path dev_gd/nsoc res://tests/HeadlessBoardTest.tscn
##
## 输出：
##   BOARD_CASE [PASS|FAIL] <用例名> <说明>
##   BOARD_RESULT PASS|FAIL passed=N failed=M
##
## 目的：证明**棋盘状态可以完全不依赖 UI 节点**。本文件只创建 `BoardModel`(Node)
## 与 `CellData`(RefCounted)，**不加载任何 .tscn、不入场景树、不创建 Control**；
## 规则函数（`CombatSystem` / `BoardModel` 邻接查询 / 序列化）在纯数据上跑通。
##
## 这是服务器权威化的前置条件：权威端要在无头环境里复用同一套棋盘规则。
##
## 注意：GDScript 运行时错误不会终止 _ready()，出错函数会静默提前返回，
## 因此末尾必须校验用例总数（EXPECTED_CASES），否则会"假通过"。

const EXPECTED_CASES: int = 21

var _passed: int = 0
var _failed: int = 0


func _ready() -> void:
	_test_pure_data_board()
	_test_adjacency()
	_test_combat_on_data()
	_test_serialization_round_trip()
	_test_team_semantics()

	var total: int = _passed + _failed
	if total != EXPECTED_CASES:
		_failed += 1
		print("BOARD_CASE FAIL 用例数量异常：期望 %d，实际 %d（有测试函数被运行时错误静默中断）"
			% [EXPECTED_CASES, total])

	print("BOARD_RESULT %s passed=%d failed=%d" % [
		"PASS" if _failed == 0 else "FAIL", _passed, _failed,
	])
	get_tree().quit(0 if _failed == 0 else 1)


# ── 工具 ─────────────────────────────────────────────────────────────

## 建一张 3×3 的纯数据棋盘：grid_cells 里全是 CellData，不含任何 Control。
func _make_board(slot_id: String) -> BoardModel:
	var board := BoardModel.new()
	for r in range(BoardModel.ROWS):
		for c in range(BoardModel.COLS):
			var cell := CellData.new()
			cell.row = r
			cell.col = c
			cell.slot_id = slot_id
			board.register_cell(cell)
	return board


func _cell(board: BoardModel, r: int, c: int) -> CellData:
	return board.get_cell(Vector2(r, c))


func _test_pure_data_board() -> void:
	var board := _make_board("board_a")
	_check("装配: 3×3 = 9 个纯数据格", board.grid_cells.size() == 9, str(board.grid_cells.size()))

	var all_data := true
	for v in board.grid_cells.values():
		if not (v is CellData):
			all_data = false
	_check("装配: 全部格子都是 CellData（无 Control/Panel 依赖）", all_data)

	var cell := _cell(board, 1, 1)
	cell.set_card("qingzhou", 3, {"front": 4, "back": 4, "left": 4, "right": 4}, false,
		["charge"], "", "initial", "team_a")
	_check("装配: set_card 写入牌面与四维",
		cell.has_card and cell.card_name == "qingzhou" and cell.attack == 3
		and int(cell.health["front"]) == 4, "%s %s" % [cell.card_name, str(cell.health)])
	_check("装配: max_health 记录初始四维", int(cell.max_health["front"]) == 4, str(cell.max_health))
	_check("装配: 归属盘与队伍显式注入（不依赖 Game.registry）",
		cell.owner_slot_id == "board_a" and cell.team_id == "team_a",
		"%s / %s" % [cell.owner_slot_id, cell.team_id])

	cell.clear_card()
	_check("装配: clear_card 清空牌面并复位归属",
		not cell.has_card and cell.card_name == "" and cell.team_id == ""
		and cell.owner_slot_id == "", "%s %s" % [cell.card_name, cell.team_id])


func _test_adjacency() -> void:
	var board := _make_board("board_a")
	var a := _cell(board, 1, 1)
	a.set_card("a", 2, {"front": 5, "back": 5, "left": 5, "right": 5}, false, [], "", "initial", "team_a")
	# 同队邻格：不算敌人
	var ally := _cell(board, 0, 1)
	ally.set_card("ally", 2, {"front": 5, "back": 5, "left": 5, "right": 5}, false, [], "", "initial", "team_a")
	# 敌队邻格：算敌人
	var foe := _cell(board, 1, 2)
	foe.set_card("foe", 2, {"front": 5, "back": 5, "left": 5, "right": 5}, false, [], "", "initial", "team_b")

	var found: Array = board.find_adjacent_enemies(a, false)
	_check("邻接: 只返回敌对邻格（同队不算）", found.size() == 1, str(found.size()))
	if found.size() == 1:
		_check("邻接: 方向与对位面正确（right ↔ left）",
			found[0]["dir"] == "right" and found[0]["opp_dir"] == "left" and found[0]["cell"] == foe,
			str(found[0]))

	# PVE 路径：无 team_id 时按 is_enemy 二分
	var board2 := _make_board("board_pve")
	var p := _cell(board2, 1, 1)
	p.set_card("p", 2, {"front": 5, "back": 5, "left": 5, "right": 5}, false)
	var e := _cell(board2, 2, 1)
	e.set_card("e", 2, {"front": 5, "back": 5, "left": 5, "right": 5}, true)
	var found2: Array = board2.find_adjacent_enemies(p, false)
	_check("邻接: PVE（无 team_id）回退 is_enemy 判定",
		found2.size() == 1 and found2[0]["cell"] == e, str(found2.size()))

	# 攻击标记复位
	a.has_attacked = true
	a.has_charged = true
	board.reset_attack_flags()
	_check("邻接: reset_attack_flags 清空全盘攻击标记",
		not a.has_attacked and not a.has_charged)


func _test_combat_on_data() -> void:
	var board := _make_board("board_a")
	var atk := _cell(board, 1, 1)
	atk.set_card("atk", 3, {"front": 5, "back": 5, "left": 5, "right": 5}, false, [], "", "initial", "team_a")
	var dfd := _cell(board, 1, 2)
	dfd.set_card("dfd", 0, {"front": 2, "back": 2, "left": 2, "right": 2}, false, [], "", "initial", "team_b")

	# 纯数据上的结算：CombatSystem 只读字段，不碰场景树
	# opp_dir 是屏幕绝对方向，按 defender.is_enemy 转成单位视角 side（top → front）。
	# 注意：伤害不做 0 夹紧（现状为 2 - 3 = -1），阵亡由 is_cell_dead 的 <= 0 判定。
	var dead: Array = CombatSystem.resolve_attack(atk, [{"cell": dfd, "opp_dir": "top"}])
	_check("结算: 对位面扣血（abs top → side front，未夹紧到 0）",
		int(dfd.health["front"]) == -1 and int(dfd.health["left"]) == 2, str(dfd.health))
	_check("结算: 阵亡判定与阵亡名单一致",
		CombatSystem.is_cell_dead(dfd) and dead.has(dfd), str(dead.size()))

	# 虚弱：四面同扣
	var atk2 := _cell(board, 2, 1)
	atk2.set_card("atk2", 1, {"front": 5, "back": 5, "left": 5, "right": 5}, false, [], "", "initial", "team_a")
	var dfd2 := _cell(board, 2, 2)
	dfd2.set_card("dfd2", 0, {"front": 3, "back": 3, "left": 3, "right": 3}, false, ["frail"], "", "initial", "team_b")
	CombatSystem.resolve_attack(atk2, [{"cell": dfd2, "opp_dir": "left"}])
	_check("结算: 虚弱（frail）四面同扣并进入阵亡名单",
		int(dfd2.health["front"]) == 2 and int(dfd2.health["back"]) == 2
		and CombatSystem.is_cell_dead(dfd2) == false, str(dfd2.health))


func _test_serialization_round_trip() -> void:
	var board := _make_board("board_a")
	var cell := _cell(board, 0, 0)
	cell.set_card("guanyu", 4, {"front": 3, "back": 3, "left": 3, "right": 3}, true,
		["charge", "frail"], "board_owner", "initial", "team_b")
	cell.has_attacked = true
	var d: Dictionary = board.to_dict()

	# JSON 往返（联机路径真的会过一遍 JSON：数值变 float）
	var json_text: String = JSON.stringify(d)
	var parsed = JSON.parse_string(json_text)
	_check("序列化: to_dict → JSON → parse 成功", typeof(parsed) == TYPE_DICTIONARY, json_text)

	var board2 := _make_board("board_a")
	board2.from_dict(parsed)
	var cell2 := _cell(board2, 0, 0)
	_check("序列化: 还原后牌面一致",
		cell2.has_card and cell2.card_name == "guanyu" and cell2.attack == 4
		and cell2.effects == ["charge", "frail"], "%s %s" % [cell2.card_name, str(cell2.effects)])
	_check("序列化: 还原后四维为 int（不出现 3.0）",
		int(cell2.health["front"]) == 3 and typeof(cell2.health["front"]) == TYPE_INT,
		"%s %s" % [str(cell2.health["front"]), typeof(cell2.health["front"])])
	_check("序列化: 还原后归属/队伍/攻击标记一致",
		cell2.owner_slot_id == "board_owner" and cell2.team_id == "team_b" and cell2.has_attacked)
	_check("序列化: 二次 to_dict 与首次逐键相等",
		board2.to_dict() == d, str(board2.to_dict()))

	# 空格的序列化：has_card=false 且非 phantom → 还原为空
	var board3 := _make_board("board_a")
	board3.from_dict(parsed)
	_check("序列化: 未写入的格子仍为空",
		not _cell(board3, 2, 2).has_card and _cell(board3, 2, 2).card_name == "")


func _test_team_semantics() -> void:
	var cell := CellData.new()
	cell.set_card("x", 1, {"front": 5, "back": 5, "left": 5, "right": 5}, false, [], "", "initial", "team_a")
	_check("队伍: 跨队敌对 / 同队友好",
		cell.is_hostile_to("team_b") and not cell.is_hostile_to("team_a")
		and cell.is_friendly_to("team_a") and not cell.is_friendly_to("team_b"))

	var pve := CellData.new()
	pve.set_card("y", 1, {"front": 5, "back": 5, "left": 5, "right": 5}, true)
	_check("队伍: PVE（team_id 为空）回退 is_enemy 二分",
		pve.is_hostile_to("") and not pve.is_friendly_to(""))


func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("BOARD_CASE PASS %s" % name)
	else:
		_failed += 1
		print("BOARD_CASE FAIL %s | %s" % [name, detail])
