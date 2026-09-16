extends Node

## 演武切磋入口冒烟（**联机移除后的验收**）：
##   玩家能进入该界面、四个模式按钮可切换，
##   但「我的房间」「加入房间」**只显示"联机功能暂未开放"**，
##   界面上**不存在任何创建 / 加入房间的入口**，且不会建立任何网络连接。
##
## 运行：
##   godot --headless --path dev_gd/nsoc res://tests/SparringPanelTest.tscn

const EXPECTED_CASES: int = 16

var _passed: int = 0
var _failed: int = 0
var _texts: Array = []
var _buttons: Array = []


func _ready() -> void:
	var packed: PackedScene = load("res://scenes/SparringPanel.tscn")
	_check("入口: SparringPanel.tscn 可加载", packed != null)
	if packed == null:
		_finish()
		return
	var panel: Control = packed.instantiate()
	add_child(panel)
	# _apply_styles 是 call_deferred，等两帧让它与 _refresh_left_content 跑完
	await get_tree().process_frame
	await get_tree().process_frame

	_check("入口: 场景已入树（玩家能进入界面）", is_instance_valid(panel))

	# 默认模式页：四个模式按钮都在，能切换
	var mode_btns: Array = []
	for i in range(4):
		var b: Button = panel.get_node_or_null("RightActionPnl/Margin/VBox/ModeBtn%d" % i)
		mode_btns.append(b)
	_check("入口: 四个模式按钮齐全",
		mode_btns.all(func(b): return b != null))

	# 默认页（我的房间）
	_collect(panel)
	_check("默认页: 左侧有内容", _texts.size() > 0, str(_texts.size()))
	_check("默认页: 标题为「我的房间」", _has_text("我的房间"), str(_texts))
	_check("默认页: 显示「联机功能暂未开放」", _has_text("联机功能暂未开放"), str(_texts))
	_check("默认页: 说明提到无法创建房间", _has_fragment("创建房间"), str(_texts))
	_check("默认页: 不存在开始/创建之类按钮",
		not _has_button_text(["开始", "创建房间", "创建", "进入房间"]), str(_buttons))

	# 切到「加入房间」
	mode_btns[1].emit_signal("pressed")
	await get_tree().process_frame
	_collect(panel)
	_check("切页: 标题为「加入房间」", _has_text("加入房间"), str(_texts))
	_check("切页: 显示「联机功能暂未开放」", _has_text("联机功能暂未开放"), str(_texts))
	_check("切页: 说明提到无法加入房间", _has_fragment("加入房间均不可用"), str(_texts))
	_check("切页: 没有房间列表 / 刷新按钮",
		not _has_button_text(["刷新列表", "刷新", "加入", "准备"]), str(_buttons))

	# 切到占位页
	mode_btns[2].emit_signal("pressed")
	await get_tree().process_frame
	_collect(panel)
	_check("切页: 「随机匹配」显示（施工中）", _has_text("随机匹配") and _has_text("（施工中）"), str(_texts))

	mode_btns[3].emit_signal("pressed")
	await get_tree().process_frame
	_collect(panel)
	_check("切页: 「随机排位」显示（施工中）", _has_text("随机排位") and _has_text("（施工中）"), str(_texts))

	# 全程不得建立网络连接（Net 是空壳）
	_check("网络: 未连接任何服务器", not Net.is_connected_to_server())
	_check("网络: 大厅没有留下房间号", Net.get_current_room_id() == "", Net.get_current_room_id())

	panel.free()
	_finish()


# ── 内部 ──────────────────────────────────────────────────────────────────
func _collect(node: Node) -> void:
	_texts = []
	_buttons = []
	_walk(node)


func _walk(node: Node) -> void:
	for child in node.get_children():
		if child is Label:
			_texts.append(String((child as Label).text))
		elif child is Button:
			_buttons.append(String((child as Button).text))
		_walk(child)


func _has_text(t: String) -> bool:
	return _texts.has(t)


func _has_fragment(frag: String) -> bool:
	for t in _texts:
		if String(t).contains(frag):
			return true
	return false


func _has_button_text(cands: Array) -> bool:
	for b in _buttons:
		for c in cands:
			if String(b).replace("\n", "") == String(c):
				return true
	return false


func _check(name: String, ok: bool, detail: String = "") -> void:
	if ok:
		_passed += 1
		print("SPARRING_CASE PASS %s" % name)
	else:
		_failed += 1
		print("SPARRING_CASE FAIL %s | %s" % [name, detail])


func _finish() -> void:
	var total: int = _passed + _failed
	if total != EXPECTED_CASES:
		_failed += 1
		print("SPARRING_CASE FAIL 用例数 | 跑了 %d 条，期望 %d 条" % [total, EXPECTED_CASES])
	print("SPARRING_RESULT %s passed=%d failed=%d" % [
		"PASS" if _failed == 0 else "FAIL", _passed, _failed])
	get_tree().quit(0 if _failed == 0 else 1)
