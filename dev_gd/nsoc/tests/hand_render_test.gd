extends Node

## 权威手牌渲染测试（重构文档.md §4.2：手牌也按 auth/state 渲染）。
##
## 运行：
##   godot --headless --path dev_gd/nsoc res://tests/HandRenderTest.tscn
##
## 输出：
##   HR_CASE [PASS|FAIL] <用例名> <说明>
##   HR_RESULT PASS|FAIL passed=N failed=M
##
## 用真实 `scenes/HandCard.tscn` + 一个容器，验证 `HandView.replace_hand_with()`：
## 按给定的卡名列表**重建**手牌区（清空 + 逐张建卡），卡面取自卡库原型。
## 这是 v2 权威模式下"手牌由服务器说了算"的渲染入口。

const EXPECTED_CASES: int = 9

var _passed: int = 0
var _failed: int = 0


func _ready() -> void:
	Game._load_card_db()
	_test_replace_hand()

	var total: int = _passed + _failed
	if total != EXPECTED_CASES:
		_failed += 1
		print("HR_CASE FAIL 用例数量异常：期望 %d，实际 %d（有测试函数被运行时错误静默中断）"
			% [EXPECTED_CASES, total])

	print("HR_RESULT %s passed=%d failed=%d" % [
		"PASS" if _failed == 0 else "FAIL", _passed, _failed,
	])
	get_tree().quit(0 if _failed == 0 else 1)


func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("HR_CASE PASS %s" % name)
	else:
		_failed += 1
		print("HR_CASE FAIL %s | %s" % [name, detail])


func _unit_card_name() -> String:
	for key in Game.card_db.keys():
		if Game.card_db[key] is CardUnit:
			return String(key)
	return ""


func _equip_card_name() -> String:
	for key in Game.card_db.keys():
		if Game.card_db[key] is CardEquipment:
			return String(key)
	return ""


func _test_replace_hand() -> void:
	var container := HBoxContainer.new()
	add_child(container)
	# 飞入动画的挂载点（本测试用不到动画，但 setup 要求是 Control）
	var anim_root := Control.new()
	add_child(anim_root)
	var view := HandView.new()
	view.name = "HandView"
	add_child(view)
	view.setup(container, load("res://scenes/HandCard.tscn"), anim_root)

	var unit_name := _unit_card_name()
	var equip_name := _equip_card_name()
	_check("准备: 卡库里有单位卡与装备卡", unit_name != "" and equip_name != "", unit_name)

	# ① 空手牌
	view.replace_hand_with([])
	_check("渲染: 空列表 → 手牌区为空", container.get_child_count() == 0,
		str(container.get_child_count()))

	# ② 两张（顺序保持）
	view.replace_hand_with([unit_name, equip_name])
	_check("渲染: 两张手牌被建出", container.get_child_count() == 2,
		str(container.get_child_count()))
	var first = container.get_child(0)
	var second = container.get_child(1)
	_check("渲染: 第一张牌面来自卡库（不是虚空兜底）",
		String(first.card_data.name) == unit_name, String(first.card_data.name))
	_check("渲染: 第二张牌面来自卡库（装备）",
		String(second.card_data.name) == equip_name, String(second.card_data.name))
	_check("渲染: 手牌卡片的牌面对象就是卡库原型",
		first.card_data == Game.get_card(unit_name))

	# ③ 重建而非追加（服务器说只剩一张 → 就只剩一张）
	view.replace_hand_with([equip_name])
	_check("渲染: 重建语义（旧的清掉、只留新的一张）",
		container.get_child_count() == 1
		and String(container.get_child(0).card_data.name) == equip_name,
		str(container.get_child_count()))

	# ④ 未知卡名被跳过，不影响其他卡
	view.replace_hand_with([unit_name, "no_such_card"])
	_check("渲染: 未知卡名跳过（只建出真实存在的那张）",
		container.get_child_count() == 1
		and String(container.get_child(0).card_data.name) == unit_name,
		str(container.get_child_count()))

	# ⑤ 单测再次清空（回到空手牌：被服务器拿光）
	view.replace_hand_with([])
	_check("渲染: 再次清空可用（幂等）", container.get_child_count() == 0)
