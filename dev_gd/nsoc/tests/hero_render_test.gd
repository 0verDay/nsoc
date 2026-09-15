extends Node

## 权威装备渲染测试：`auth/state.you.equipments` → 本端 `Equipments` 单例
## （重构文档.md §7 阶段 3「手牌/装备按 auth/state 渲染」的装备那一半）。
##
## 用真实卡库装备原型 + 真实 `Equipments` autoload，不建场景树即可跑。
##
## 运行：
##   godot --headless --path dev_gd/nsoc res://tests/HeroRenderTest.tscn
##
## 输出：
##   HRENDER_CASE [PASS|FAIL] <说明>
##   HRENDER_RESULT PASS|FAIL passed=N failed=M

const CUP := "圣杯"        # cost 1 / 耐久 2 / effect gain_mana_1
const SWORD := "仁之剑"    # cost 5 / 耐久 5 / effect destroy_unit
const EXPECTED_CASES := 20

var _passed: int = 0
var _failed: int = 0
var _added: int = 0
var _removed: int = 0
var _changed: int = 0


func _ready() -> void:
	_ensure_card_db()
	Equipments.equipment_added.connect(func(_i): _added += 1)
	Equipments.equipment_removed.connect(func(_i): _removed += 1)
	Equipments.equipment_changed.connect(func(_i): _changed += 1)

	_test_empty_is_noop()
	_test_apply_creates()
	_test_idempotent()
	_test_json_float_roundtrip()
	_test_durability_change()
	_test_used_flag_change()
	_test_second_equipment()
	_test_unknown_skipped()
	_test_removal()
	_test_bad_input_untouched()
	_test_signals_drive_ui()

	var total: int = _passed + _failed
	if total != EXPECTED_CASES:
		_fail("用例数", "跑了 %d 条，期望 %d 条（有测试函数被静默跳过？）" % [total, EXPECTED_CASES])
	print("HRENDER_RESULT %s passed=%d failed=%d" % [
		"PASS" if _failed == 0 else "FAIL", _passed, _failed])
	get_tree().quit(0 if _failed == 0 else 1)


# ── 用例 ──────────────────────────────────────────────────────────────────

func _test_empty_is_noop() -> void:
	_reset()
	_check("空列表 + 本地已空 → 返回 false（无变化不写入）",
		AuthEquipRenderer.apply([]) == false)
	_check("本地仍为空", Equipments.all().size() == 0)


func _test_apply_creates() -> void:
	_reset()
	var applied: bool = AuthEquipRenderer.apply([_entry(CUP, 2, false)])
	_check("权威给了装备 → 返回 true", applied)
	_check("本地建出 1 件装备", Equipments.all().size() == 1)
	var inst: EquipmentInstance = Equipments.all()[0] if Equipments.all().size() > 0 else null
	_check("装备牌面来自卡库（不是虚空）",
		inst != null and inst.card_data != null and inst.card_data.name == CUP)
	_check("耐久按权威写入（2）", inst != null and inst.durability_left == 2)


func _test_idempotent() -> void:
	_reset()
	AuthEquipRenderer.apply([_entry(CUP, 2, false)])
	var before_added: int = _added
	var before_removed: int = _removed
	var again: bool = AuthEquipRenderer.apply([_entry(CUP, 2, false)])
	_check("同一份权威列表重复应用 → 返回 false", again == false)
	_check("重复应用不重建设备（无 added/removed，按钮不重播动画）",
		_added == before_added and _removed == before_removed)


func _test_json_float_roundtrip() -> void:
	_reset()
	AuthEquipRenderer.apply([_entry(CUP, 2, false)])
	# 网络回来的 JSON 没有整数类型：耐久是 2.0，used 可能是 0/1
	var from_wire: Array = [{"card_name": CUP, "durability_left": 2.0, "used_this_turn": 0}]
	_check("JSON 浮点/int 差异不算变化（返回 false）",
		AuthEquipRenderer.apply(from_wire) == false)


func _test_durability_change() -> void:
	_reset()
	AuthEquipRenderer.apply([_entry(CUP, 2, false)])
	_check("耐久 2 → 1 算变化（返回 true）",
		AuthEquipRenderer.apply([_entry(CUP, 1, false)]))
	_check("本地耐久跟上权威（1）", Equipments.all()[0].durability_left == 1)


func _test_used_flag_change() -> void:
	_reset()
	AuthEquipRenderer.apply([_entry(CUP, 2, false)])
	_check("used_this_turn 翻转算变化（返回 true）",
		AuthEquipRenderer.apply([_entry(CUP, 2, true)]))
	_check("本地 used_this_turn 跟上权威", Equipments.all()[0].used_this_turn == true)


func _test_second_equipment() -> void:
	_reset()
	var applied: bool = AuthEquipRenderer.apply([
		_entry(CUP, 2, false), _entry(SWORD, 5, false),
	])
	_check("两件装备按权威建出", applied and Equipments.all().size() == 2)


func _test_unknown_skipped() -> void:
	_reset()
	AuthEquipRenderer.apply([_entry("不存在的装备", 3, false)])
	_check("未知装备名被跳过且不崩（本地保持为空）", Equipments.all().size() == 0)


func _test_removal() -> void:
	_reset()
	AuthEquipRenderer.apply([_entry(CUP, 2, false)])
	_check("权威列表清空 → 返回 true 且本地清空",
		AuthEquipRenderer.apply([]) and Equipments.all().size() == 0)


func _test_bad_input_untouched() -> void:
	_reset()
	AuthEquipRenderer.apply([_entry(CUP, 2, false)])
	var not_array: bool = AuthEquipRenderer.apply(null)
	_check("字段缺失（null）→ 返回 false", not_array == false)
	_check("字段缺失时不动本地状态（仍有 1 件）", Equipments.all().size() == 1)


func _test_signals_drive_ui() -> void:
	_reset()
	var before_added: int = _added
	var before_removed: int = _removed
	AuthEquipRenderer.apply([_entry(CUP, 2, false)])
	_check("写入时发 equipment_added（HeroActionBar 据此建按钮）", _added == before_added + 1)
	AuthEquipRenderer.apply([])
	_check("清空时发 equipment_removed（按钮随之移除）", _removed == before_removed + 1)


# ── 内部 ──────────────────────────────────────────────────────────────────

func _entry(card_name: String, durability_left: int, used_this_turn: bool) -> Dictionary:
	return {
		"card_name": card_name,
		"durability_left": durability_left,
		"used_this_turn": used_this_turn,
	}


func _reset() -> void:
	Equipments.clear_all()
	_added = 0
	_removed = 0
	_changed = 0


func _ensure_card_db() -> void:
	if not Game.card_db.is_empty():
		return
	for card in DataLoader.load_cards(DataLoader.ALL_CARDS_JSON):
		Game.card_db[card.name] = card


func _check(what: String, ok: bool) -> void:
	if ok:
		_passed += 1
		print("HRENDER_CASE PASS %s" % what)
	else:
		_failed += 1
		print("HRENDER_CASE FAIL %s" % what)


func _fail(where: String, detail: String) -> void:
	_failed += 1
	print("HRENDER_CASE FAIL %s | %s" % [where, detail])
