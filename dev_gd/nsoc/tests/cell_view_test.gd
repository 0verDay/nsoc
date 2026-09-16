extends Node

## Cell 视图 ↔ CellData 数据 等价测试（重构文档.md §3.4-6）。
##
## 运行：
##   godot --headless --path dev_gd/nsoc res://tests/CellViewTest.tscn
##
## 输出：
##   CELLVIEW_CASE [PASS|FAIL] <用例名> <说明>
##   CELLVIEW_RESULT PASS|FAIL passed=N failed=M
##
## 背景：`Cell` 的状态字段已改为**转发属性**，真正存放状态的是 `CellData`（纯数据）。
## 本测试锁定三件事：
##   1. 转发是双向且无损的（读写都落到 CellData；原地改 health 等子字典照旧生效）；
##   2. 视图刷新不改变状态语义（set_card / clear_card / from_dict 落状态一致）；
##   3. 规则层（CombatSystem）作用在 Cell 上时，改的是 CellData 里的状态。
##
## 注意：GDScript 运行时错误不会终止 _ready()，出错函数会静默提前返回，
## 因此末尾必须校验用例总数（EXPECTED_CASES），否则会"假通过"。

const EXPECTED_CASES: int = 19
const CELL_SCENE := "res://scenes/Cell.tscn"

var _passed: int = 0
var _failed: int = 0


func _ready() -> void:
	_test_state_lives_in_data()
	_test_clear_and_phantom()
	_test_from_dict_and_combat()

	var total: int = _passed + _failed
	if total != EXPECTED_CASES:
		_failed += 1
		print("CELLVIEW_CASE FAIL 用例数量异常：期望 %d，实际 %d（有测试函数被运行时错误静默中断）"
			% [EXPECTED_CASES, total])

	print("CELLVIEW_RESULT %s passed=%d failed=%d" % [
		"PASS" if _failed == 0 else "FAIL", _passed, _failed,
	])
	get_tree().quit(0 if _failed == 0 else 1)


# ── 工具 ─────────────────────────────────────────────────────────────

## 实例化一个真正的 Cell 节点并入树（_ready 里会建 hp_labels_abs，必须入树）。
func _make_cell() -> Panel:
	var scene: PackedScene = load(CELL_SCENE)
	var cell = scene.instantiate()
	add_child(cell)
	return cell


func _ref_data() -> CellData:
	var d := CellData.new()
	d.set_card("guanyu", 4, {"front": 3, "back": 4, "left": 5, "right": 6}, true,
		["charge"], "", "initial", "")
	return d


func _test_state_lives_in_data() -> void:
	var cell = _make_cell()
	_check("数据: Cell 持有 CellData", cell.data is CellData, str(typeof(cell.data)))

	var fresh := CellData.new()
	_check("数据: 新格子的转发属性等于 CellData 默认值",
		cell.has_card == fresh.has_card and cell.health == fresh.health and cell.row == fresh.row,
		"has_card=%s row=%d" % [str(cell.has_card), cell.row])

	var cell2 = _make_cell()
	cell2.set_card("guanyu", 4, {"front": 3, "back": 4, "left": 5, "right": 6}, true,
		["charge"], "", "initial")
	_check("数据: set_card 后状态与同参数的 CellData 逐键相等",
		cell2.to_dict() == _ref_data().to_dict(),
		"%s vs %s" % [str(cell2.to_dict()), str(_ref_data().to_dict())])
	_check("数据: 视图已刷新（可见 + 卡名标签）",
		cell2.inner_panel.visible and cell2.name_lbl.text == "guanyu",
		"%s / %s" % [str(cell2.inner_panel.visible), cell2.name_lbl.text])
	# is_enemy=true：abs "bottom" ↔ side "front"（见 Orientation.side_to_abs("front", true)）
	_check("数据: 四维标签按单位视角映射到正确绝对方向",
		cell2.hp_labels_abs["bottom"].text == "3" and cell2.hp_labels_abs["top"].text == "4",
		"bottom=%s top=%s" % [cell2.hp_labels_abs["bottom"].text, cell2.hp_labels_abs["top"].text])

	# 转发：写 cell → 落到 data
	cell2.team_id = "team_a"
	_check("转发: 写 cell 属性落到 CellData", cell2.data.team_id == "team_a", cell2.data.team_id)
	# 转发：改子字典（规则层最常见的写法）必须影响 CellData 里的同一个字典
	cell2.health["front"] -= 2
	_check("转发: 原地改 health 子字典等于改 CellData",
		int(cell2.data.health["front"]) == 1, str(cell2.data.health))
	# 转发：写 data → 读 cell
	cell2.data.card_name = "zhangfei"
	_check("转发: 写 CellData 反映到 cell 属性", cell2.card_name == "zhangfei", cell2.card_name)
	_check("转发: to_dict 直接转发 CellData", cell2.to_dict() == cell2.data.to_dict())


func _test_clear_and_phantom() -> void:
	var cell = _make_cell()
	var cleared_count: Array = [0]
	cell.cleared.connect(func(_c): cleared_count[0] += 1)
	cell.set_card("guanyu", 4, {"front": 3, "back": 3, "left": 3, "right": 3}, true, [], "", "initial")
	cell.clear_card()
	_check("清空: clear_card 清掉 CellData 状态",
		not cell.has_card and cell.card_name == "" and cell.team_id == ""
		and cell.owner_slot_id == "" and cell.origin == "",
		"%s %s" % [str(cell.has_card), cell.card_name])
	_check("清空: 视图复位（InnerPanel 隐藏）", not cell.inner_panel.visible)
	_check("清空: cleared 信号只发一次", cleared_count[0] == 1, str(cleared_count[0]))

	var phantom = _make_cell()
	phantom.set_phantom("scout", 1, {"front": 2, "back": 2, "left": 2, "right": 2})
	_check("幻影: has_card=false 但 is_phantom=true（数据层）",
		not phantom.has_card and phantom.is_phantom and phantom.data.is_phantom,
		"has_card=%s phantom=%s" % [str(phantom.has_card), str(phantom.is_phantom)])
	_check("幻影: 视图半透明且可见",
		is_equal_approx(phantom.inner_panel.modulate.a, 0.4) and phantom.inner_panel.visible,
		str(phantom.inner_panel.modulate.a))


func _test_from_dict_and_combat() -> void:
	# from_dict 往返：CellData → dict → Cell，再取 dict 应逐键相等
	var cell = _make_cell()
	var ref: CellData = _ref_data()
	ref.has_attacked = true
	ref.max_health = {"front": 9, "back": 9, "left": 9, "right": 9}
	var payload: Dictionary = JSON.parse_string(JSON.stringify(ref.to_dict()))
	cell.from_dict(payload)
	_check("还原: from_dict 后 to_dict 与源数据逐键相等",
		cell.to_dict() == ref.to_dict(), str(cell.to_dict()))
	_check("还原: 视图已刷新且四维标签正确",
		cell.inner_panel.visible and cell.hp_labels_abs["bottom"].text == "3",
		cell.hp_labels_abs["bottom"].text)

	# 空格 payload → 还原为空
	var empty_cell = _make_cell()
	empty_cell.set_card("x", 1, {"front": 1, "back": 1, "left": 1, "right": 1})
	empty_cell.from_dict({"has_card": false, "is_phantom": false, "slot_id": "board_a"})
	_check("还原: 空格 payload 清空状态且视图隐藏",
		not empty_cell.has_card and not empty_cell.inner_panel.visible
		and empty_cell.slot_id == "board_a", str(empty_cell.to_dict()))

	# 规则层作用在 Cell 上时，改的是 CellData 里的状态
	var atk = _make_cell()
	atk.set_card("atk", 3, {"front": 5, "back": 5, "left": 5, "right": 5}, false, [], "", "initial")
	var dfd = _make_cell()
	dfd.set_card("dfd", 0, {"front": 2, "back": 2, "left": 2, "right": 2}, false, [], "", "initial")
	CombatSystem.resolve_attack(atk, [{"cell": dfd, "opp_dir": "top"}])
	_check("规则: 结算改的是 CellData 里的四维（abs top → side front）",
		int(dfd.data.health["front"]) == -1 and int(dfd.data.health["left"]) == 2, str(dfd.data.health))
	_check("规则: 阵亡判定与数据层一致",
		CombatSystem.is_cell_dead(dfd) and int(dfd.data.health["front"]) <= 0)


func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("CELLVIEW_CASE PASS %s" % name)
	else:
		_failed += 1
		print("CELLVIEW_CASE FAIL %s | %s" % [name, detail])
