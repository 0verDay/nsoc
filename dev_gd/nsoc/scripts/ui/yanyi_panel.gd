class_name YanyiPanel
extends SecondaryPanel

# 演义二级界面（res://scenes/YanyiPanel.tscn）。
# 继承 SecondaryPanel 复用 BackBtn 风格 + 转场淡入淡出。
#
# 布局：
#   BackBtn          : 右上 160×80
#   RightActionPnl   : BackBtn 下方，同宽，含「帝国」「游历」两个模式按钮
#   LeftContentPnl   : 左侧主内容区（施工中占位）
#
# 手动布局：完全绕开 anchor 系统，在 NOTIFICATION_RESIZED 里计算
# position / size，与 SparringPanel 保持相同范式。

const MODE_NAMES: Array = [
	"帝国",
	"游历",
]

const DEFAULT_MODE: int = 0

# ── 布局参数（与 SparringPanel 保持一致） ───────────────────────────────────
const RIGHT_MARGIN: float = 20.0
const RIGHT_WIDTH:  float = 160.0
const BACKBTN_H:    float = 80.0
const GAP:          float = 20.0
const LEFT_GAP:     float = 20.0
const LR_GAP:       float = 20.0

# ── 颜色 / 尺寸 ──────────────────────────────────────────────────────────────
const ACCENT: Color     = Color(0.109804, 0.494118, 0.839216, 1)
const TEXT_MUTED: Color = Color("#868e96")

const FONT_SIZE_BODY: int  = 28
const BTN_HEIGHT: float    = 72.0
const ACTION_BTN_W: float  = 160.0   # 右下角操作按钮宽度（与 RightActionPnl 同宽）

# ── 节点引用 ─────────────────────────────────────────────────────────────────
@onready var right_action_pnl: Panel = $RightActionPnl
@onready var left_content_pnl: Panel = $LeftContentPnl
@onready var _btn0: Button = $RightActionPnl/Margin/VBox/ModeBtn0
@onready var _btn1: Button = $RightActionPnl/Margin/VBox/ModeBtn1

var _mode_btns: Array[Button] = []
var _selected_idx: int = DEFAULT_MODE

# 剧本视图状态
const SCENARIO_VIEW_SCENE := preload("res://scenes/EmpireScenarioView.tscn")
const SCENARIO_FADE: float = 0.3
const EmpireSaveStorageClass = preload("res://scripts/core/empire_save_storage.gd")
var _in_scenario_view: bool = false
var _scenario_view: EmpireScenarioView = null

# 载入面板状态
var _in_load_view: bool = false
var _load_view: Control = null

# ── 样式 ─────────────────────────────────────────────────────────────────────
static func _selected_style() -> Dictionary:
	var normal := ThemeFactory.panel(Color("#1c7ed6"), Color.WHITE, 3, 12, true)
	var hover  := ThemeFactory.panel(Color("#1971c2"), Color.WHITE, 3, 12, true)
	return {"normal": normal, "hover": hover, "pressed": normal, "disabled": normal}

static func _unselected_style() -> Dictionary:
	return {
		"normal":   ThemeFactory.panel(Color("#adb5bd"), Color.TRANSPARENT, 0, 12),
		"hover":    ThemeFactory.panel(Color("#868e96"), Color.TRANSPARENT, 0, 12),
		"pressed":  ThemeFactory.panel(Color("#868e96"), Color.TRANSPARENT, 0, 12),
		"disabled": ThemeFactory.panel(Color("#ced4da"), Color.TRANSPARENT, 0, 12),
	}

# ── 初始化 ───────────────────────────────────────────────────────────────────
func _apply_styles() -> void:
	var pnl_style := ThemeFactory.panel(Color.WHITE, Color(1, 1, 1, 0.6), 1, 20, true)
	right_action_pnl.add_theme_stylebox_override("panel", pnl_style)
	left_content_pnl.add_theme_stylebox_override("panel", pnl_style)

	# 重接 BackBtn：递层返回
	if back_btn:
		for c in back_btn.pressed.get_connections():
			back_btn.pressed.disconnect(c["callable"])
		back_btn.pressed.connect(_on_back_btn_pressed)

	_mode_btns = [_btn0, _btn1]
	for i in _mode_btns.size():
		var btn := _mode_btns[i]
		btn.add_theme_color_override("font_color",         Color.WHITE)
		btn.add_theme_color_override("font_hover_color",   Color.WHITE)
		btn.add_theme_color_override("font_pressed_color", Color.WHITE)
		btn.pressed.connect(_on_mode_btn_pressed.bind(i))
	_apply_selection(DEFAULT_MODE)
	_do_layout()
	_refresh_left_content()


# ── 手动布局 ─────────────────────────────────────────────────────────────────
func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_do_layout()


func _do_layout() -> void:
	var W: float = size.x
	var H: float = size.y
	if W <= 0.0 or H <= 0.0:
		return

	if back_btn:
		back_btn.position = Vector2(W - RIGHT_MARGIN - RIGHT_WIDTH, RIGHT_MARGIN)
		back_btn.size     = Vector2(RIGHT_WIDTH, BACKBTN_H)

	var rap_top: float = RIGHT_MARGIN + BACKBTN_H + GAP
	if right_action_pnl:
		right_action_pnl.position = Vector2(W - RIGHT_MARGIN - RIGHT_WIDTH, rap_top)
		right_action_pnl.size     = Vector2(RIGHT_WIDTH, H - rap_top - RIGHT_MARGIN)

	var lcp_right: float = W - RIGHT_MARGIN - RIGHT_WIDTH - LR_GAP
	if left_content_pnl:
		left_content_pnl.position = Vector2(LEFT_GAP, RIGHT_MARGIN)
		left_content_pnl.size     = Vector2(lcp_right - LEFT_GAP, H - RIGHT_MARGIN * 2.0)


# ── 模式切换 ─────────────────────────────────────────────────────────────────
func _on_mode_btn_pressed(idx: int) -> void:
	if idx == _selected_idx:
		return
	_selected_idx = idx
	_apply_selection(idx)
	_refresh_left_content()


func _apply_selection(idx: int) -> void:
	var sel   := _selected_style()
	var unsel := _unselected_style()
	for i in _mode_btns.size():
		ThemeFactory.apply_button_styles(_mode_btns[i], sel if i == idx else unsel)


# ── 内容区渲染 ────────────────────────────────────────────────────────────────
func _refresh_left_content() -> void:
	if left_content_pnl == null:
		return
	for child in left_content_pnl.get_children():
		child.queue_free()

	var holder := MarginContainer.new()
	holder.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	holder.add_theme_constant_override("margin_left",   24)
	holder.add_theme_constant_override("margin_right",  24)
	holder.add_theme_constant_override("margin_top",    24)
	holder.add_theme_constant_override("margin_bottom", 24)
	left_content_pnl.add_child(holder)

	_build_empire(holder, MODE_NAMES[_selected_idx])


const EMPIRE_TEST_SCENE := "res://scenes/EmpireTest.tscn"

func _build_empire(holder: Control, mode_title: String) -> void:
	var hbox := HBoxContainer.new()
	hbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hbox.add_theme_constant_override("separation", 16)
	holder.add_child(hbox)

	var main_area := Control.new()
	main_area.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	main_area.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	hbox.add_child(main_area)

	var title_lbl := Label.new()
	title_lbl.text = mode_title + "模式"
	title_lbl.add_theme_color_override("font_color", ACCENT)
	title_lbl.add_theme_font_size_override("font_size", 64)
	title_lbl.position = Vector2(0, 0)
	title_lbl.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	title_lbl.size_flags_vertical   = Control.SIZE_SHRINK_BEGIN
	main_area.add_child(title_lbl)

	var btn_col := VBoxContainer.new()
	btn_col.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	btn_col.size_flags_horizontal = Control.SIZE_SHRINK_END
	btn_col.add_theme_constant_override("separation", 12)
	hbox.add_child(btn_col)

	for label in ["载\n入", "开\n始", "继\n续"]:
		var btn := _make_action_btn(label)
		btn_col.add_child(btn)
		match label:
			"开\n始":
				btn.pressed.connect(_on_empire_start_pressed)
			"继\n续":
				var has_auto: bool = EmpireSaveStorageClass.has_auto_save()
				btn.disabled = not has_auto
				if has_auto:
					btn.pressed.connect(_on_empire_continue_pressed)
			"载\n入":
				btn.pressed.connect(_on_empire_load_pressed)

	if _selected_idx == 0:
		var center := CenterContainer.new()
		center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		main_area.add_child(center)
		var test_btn := Button.new()
		test_btn.text = "test"
		test_btn.custom_minimum_size = Vector2(320, 120)
		test_btn.pressed.connect(func(): get_tree().change_scene_to_file(EMPIRE_TEST_SCENE))
		center.add_child(test_btn)


# ── 递层返回 ─────────────────────────────────────────────────────────────────
func _on_back_btn_pressed() -> void:
	if _in_scenario_view:
		_exit_scenario_view()
	elif _in_load_view:
		_exit_load_view()
	else:
		back_pressed.emit()


# ── 进入剧本选择视图 ─────────────────────────────────────────────────────────
func _on_empire_start_pressed() -> void:
	if _in_scenario_view:
		return
	_in_scenario_view = true

	# 淡出 right_action_pnl + left_content_pnl
	var tw := create_tween()
	tw.set_parallel(true)
	tw.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(right_action_pnl, "modulate:a", 0.0, SCENARIO_FADE)
	tw.tween_property(left_content_pnl, "modulate:a", 0.0, SCENARIO_FADE)
	await tw.finished
	# 隐藏：防止透明面板的子节点继续拦截鼠标事件
	left_content_pnl.hide()
	right_action_pnl.hide()

	# 在 YanyiPanel 自身上添加剧本视图（填满全区域），move_child 到底层使 BackBtn 保持最前
	_scenario_view = SCENARIO_VIEW_SCENE.instantiate() as EmpireScenarioView
	_scenario_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_scenario_view.modulate.a = 0.0
	add_child(_scenario_view)
	move_child(_scenario_view, 0)  # index 0 = 最底层，BackBtn 保持可见

	var tw2 := create_tween()
	tw2.tween_property(_scenario_view, "modulate:a", 1.0, SCENARIO_FADE) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


# ── 退出剧本选择视图 ─────────────────────────────────────────────────────────
func _exit_scenario_view() -> void:
	var tw := create_tween()
	tw.tween_property(_scenario_view, "modulate:a", 0.0, SCENARIO_FADE) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)
	await tw.finished

	_scenario_view.queue_free()
	_scenario_view = null
	_refresh_left_content()

	# show() 恢复可见，然后淡入
	right_action_pnl.show()
	left_content_pnl.show()
	right_action_pnl.modulate.a = 0.0
	left_content_pnl.modulate.a = 0.0
	var tw2 := create_tween()
	tw2.set_parallel(true)
	tw2.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw2.tween_property(right_action_pnl, "modulate:a", 1.0, SCENARIO_FADE)
	tw2.tween_property(left_content_pnl, "modulate:a", 1.0, SCENARIO_FADE)
	await tw2.finished

	_in_scenario_view = false


func _make_action_btn(label: String) -> Button:
	var btn := Button.new()
	btn.text = label
	btn.custom_minimum_size = Vector2(ACTION_BTN_W, BTN_HEIGHT)
	btn.size_flags_horizontal = Control.SIZE_SHRINK_END
	btn.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	btn.add_theme_font_size_override("font_size", FONT_SIZE_BODY)
	ThemeFactory.apply_button_styles(btn, ThemeFactory.primary_button_styles())
	btn.add_theme_color_override("font_color",         Color.WHITE)
	btn.add_theme_color_override("font_hover_color",   Color.WHITE)
	btn.add_theme_color_override("font_pressed_color", Color.WHITE)
	return btn


func _build_placeholder(holder: Control, title: String) -> void:
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	holder.add_child(center)

	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 20)
	center.add_child(vbox)

	var title_lbl := Label.new()
	title_lbl.text = title
	title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title_lbl.add_theme_color_override("font_color", ACCENT)
	title_lbl.add_theme_font_size_override("font_size", 48)
	vbox.add_child(title_lbl)

	var hint_lbl := Label.new()
	hint_lbl.text = "（施工中）"
	hint_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hint_lbl.add_theme_color_override("font_color", TEXT_MUTED)
	hint_lbl.add_theme_font_size_override("font_size", 24)
	vbox.add_child(hint_lbl)


# ── 帝国模式：继续 / 载入 ────────────────────────────────────────────────────

func _on_empire_continue_pressed() -> void:
	EmpireTest.pending_load_slot = EmpireSaveStorageClass.SLOT_AUTO
	var entry: Dictionary = EmpireSaveStorageClass.load_slot(EmpireSaveStorageClass.SLOT_AUTO)
	if not entry.is_empty():
		var map_path: String = String(entry.get("meta", {}).get("map_path", ""))
		if map_path != "":
			EmpireTest.pending_map_path = map_path
	get_tree().change_scene_to_file(EMPIRE_TEST_SCENE)


func _on_empire_load_pressed() -> void:
	if _in_scenario_view or _in_load_view:
		return
	_in_load_view = true

	# 淡出 right_action_pnl + left_content_pnl
	var tw := create_tween()
	tw.set_parallel(true)
	tw.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(right_action_pnl, "modulate:a", 0.0, SCENARIO_FADE)
	tw.tween_property(left_content_pnl, "modulate:a", 0.0, SCENARIO_FADE)
	await tw.finished
	left_content_pnl.hide()
	right_action_pnl.hide()

	# 在 YanyiPanel 自身上添加载入视图（填满全区域），move_child 到底层使 BackBtn 保持最前
	_load_view = _LoadEmbeddedView.new()
	_load_view.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_load_view.modulate.a = 0.0
	(_load_view as _LoadEmbeddedView).setup(_get_load_slot_entries())
	(_load_view as _LoadEmbeddedView).slot_selected.connect(_on_load_slot_selected)
	add_child(_load_view)
	move_child(_load_view, 0)

	var tw2 := create_tween()
	tw2.tween_property(_load_view, "modulate:a", 1.0, SCENARIO_FADE) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


# ── 退出载入视图 ─────────────────────────────────────────────────────────────
func _exit_load_view() -> void:
	if _load_view == null:
		return
	var tw := create_tween()
	tw.tween_property(_load_view, "modulate:a", 0.0, SCENARIO_FADE) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)
	await tw.finished

	_load_view.queue_free()
	_load_view = null
	_refresh_left_content()

	right_action_pnl.show()
	left_content_pnl.show()
	right_action_pnl.modulate.a = 0.0
	left_content_pnl.modulate.a = 0.0
	var tw2 := create_tween()
	tw2.set_parallel(true)
	tw2.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw2.tween_property(right_action_pnl, "modulate:a", 1.0, SCENARIO_FADE)
	tw2.tween_property(left_content_pnl, "modulate:a", 1.0, SCENARIO_FADE)
	await tw2.finished

	_in_load_view = false


func _get_load_slot_entries() -> Array:
	var all_slots: Array = EmpireSaveStorageClass.list_slots()
	var slot_meta: Dictionary = {}
	for item in all_slots:
		slot_meta[String(item["slot_id"])] = item.get("meta", {})

	var out: Array = []
	var auto_meta: Dictionary = slot_meta.get(EmpireSaveStorageClass.SLOT_AUTO, {})
	out.append(_build_entry(EmpireSaveStorageClass.SLOT_AUTO, "自动存档", auto_meta))
	var manual_ids: Array = [EmpireSaveStorageClass.SLOT_1, EmpireSaveStorageClass.SLOT_2, EmpireSaveStorageClass.SLOT_3]
	for i in manual_ids.size():
		var sid: String = manual_ids[i]
		out.append(_build_entry(sid, "存档 " + str(i + 1), slot_meta.get(sid, {})))
	return out


func _build_entry(slot_id: String, label: String, meta: Dictionary) -> Dictionary:
	var exists: bool = not meta.is_empty()
	var date_str: String = ""
	var scenario_name: String = ""
	var turn: int = 0
	var gold: int = 0
	var food: int = 0
	if exists:
		var ts: float = float(meta.get("timestamp", 0.0))
		var dt := Time.get_datetime_dict_from_unix_time(int(ts))
		date_str     = "%04d-%02d-%02d %02d:%02d" % [int(dt.get("year",0)),int(dt.get("month",0)),
			int(dt.get("day",0)),int(dt.get("hour",0)),int(dt.get("minute",0))]
		scenario_name = str(meta.get("scenario_name", ""))
		turn  = int(meta.get("turn_number", 0))
		gold  = int(meta.get("gold", 0))
		food  = int(meta.get("food", 0))
	return {
		"slot_id":       slot_id,
		"label":         label,
		"is_auto":       slot_id == EmpireSaveStorageClass.SLOT_AUTO,
		"exists":        exists,
		"date_str":      date_str,
		"scenario_name": scenario_name,
		"turn":          turn,
		"gold":          gold,
		"food":          food,
		# 保留单行格式供 _format_save_meta 兼容调用
		"meta_text":     _format_save_meta(meta) if exists else "（空）",
	}


func _format_save_meta(meta: Dictionary) -> String:
	if meta.is_empty():
		return "（空）"
	var ts: float = float(meta.get("timestamp", 0.0))
	var dt := Time.get_datetime_dict_from_unix_time(int(ts))
	var date_str: String = "%04d-%02d-%02d %02d:%02d" % [
		int(dt.get("year", 0)), int(dt.get("month", 0)), int(dt.get("day", 0)),
		int(dt.get("hour", 0)), int(dt.get("minute", 0)),
	]
	var scenario: String = str(meta.get("scenario_name", ""))
	var turn: int = int(meta.get("turn_number", 0))
	var gold: int = int(meta.get("gold", 0))
	var food: int = int(meta.get("food", 0))
	return "%s  %s  第%d回合  金:%d 粮:%d" % [date_str, scenario, turn, gold, food]


func _on_load_slot_selected(slot_id: String) -> void:
	# 点击有效槽后立刻切场景。_load_view 不必清理（场景切换会卸载整个树）。
	var entry: Dictionary = EmpireSaveStorageClass.load_slot(slot_id)
	if entry.is_empty():
		return
	var map_path: String = String(entry.get("meta", {}).get("map_path", ""))
	if map_path != "":
		EmpireTest.pending_map_path = map_path
	EmpireTest.pending_load_slot = slot_id
	get_tree().change_scene_to_file(EMPIRE_TEST_SCENE)


# ── 载入视图（内嵌进 YanyiPanel 底板，与 EmpireScenarioView 转场范式一致）──────
# 布局：
#   ┌─ Auto Slot (BackBtn 左侧，同高 80) ─┐  [BackBtn]
#   ├─ Manual Slot 1 ────────────────────────────────┤
#   ├─ Manual Slot 2 ────────────────────────────────┤
#   ├─ Manual Slot 3 ────────────────────────────────┤
#   └────────────────────────────────────────────────┘
class _LoadEmbeddedView extends Control:
	signal slot_selected(slot_id: String)

	# 与 YanyiPanel 对齐的布局常量
	const LEFT_GAP:      float = 20.0
	const RIGHT_MARGIN:  float = 20.0
	const TOP_MARGIN:    float = 20.0
	const BOTTOM_MARGIN: float = 20.0
	const RIGHT_WIDTH:   float = 160.0
	const BACKBTN_H:     float = 80.0
	const GAP:           float = 20.0

	# 字号
	const LABEL_FS:    int = 26
	const META_FS:     int = 20
	const META_SM_FS:  int = 18

	# 颜色
	const C_TEXT:      Color = Color("#1f2937")
	const C_MUTED:     Color = Color("#868e96")
	const C_DISABLED:  Color = Color("#adb5bd")
	const C_ACCENT:    Color = Color("#1c7ed6")
	const C_ACCENT_BG: Color = Color("#e7f5ff")
	const C_ACCENT_BD: Color = Color("#74c0fc")

	var _auto_slot: Control = null
	var _manual_slots: Array = []

	func setup(entries: Array) -> void:
		mouse_filter = Control.MOUSE_FILTER_PASS
		if entries.size() >= 1:
			_auto_slot = _make_auto_slot(entries[0])
			add_child(_auto_slot)
		for i in range(1, entries.size()):
			var s := _make_manual_slot(entries[i])
			_manual_slots.append(s)
			add_child(s)
		resized.connect(_do_layout)
		call_deferred("_do_layout")

	func _do_layout() -> void:
		var W: float = size.x
		var H: float = size.y
		if W <= 0.0 or H <= 0.0:
			return
		if _auto_slot:
			var auto_w: float = W - LEFT_GAP - GAP - RIGHT_WIDTH - RIGHT_MARGIN
			_auto_slot.position = Vector2(LEFT_GAP, TOP_MARGIN)
			_auto_slot.size     = Vector2(max(auto_w, 0.0), BACKBTN_H)
		var mx: float     = LEFT_GAP
		var my_start: float = TOP_MARGIN + BACKBTN_H + GAP
		var mw: float     = W - LEFT_GAP - RIGHT_MARGIN
		var total_h: float = H - my_start - BOTTOM_MARGIN
		var n: int = _manual_slots.size()
		if n <= 0 or total_h <= 0.0:
			return
		var slot_h: float = (total_h - GAP * float(n - 1)) / float(n)
		for i in n:
			var s: Control = _manual_slots[i]
			s.position = Vector2(mx, my_start + i * (slot_h + GAP))
			s.size     = Vector2(max(mw, 0.0), max(slot_h, 0.0))

	# ── 自动存档槽：单行左右布局 ─────────────────────────────────────────────
	func _make_auto_slot(entry: Dictionary) -> Control:
		var exists: bool = bool(entry.get("exists", false))
		var btn := Button.new()
		btn.flat = false; btn.focus_mode = Control.FOCUS_NONE
		btn.disabled = not exists
		btn.mouse_filter = Control.MOUSE_FILTER_STOP

		var styles: Dictionary
		if exists:
			styles = {
				"normal":   ThemeFactory.panel(C_ACCENT_BG,         C_ACCENT_BD,        1, 16, true),
				"hover":    ThemeFactory.panel(Color("#d0ebff"),     Color("#4dabf7"),    1, 16, true),
				"pressed":  ThemeFactory.panel(Color("#a5d8ff"),     Color("#1c7ed6"),    1, 16, true),
				"disabled": ThemeFactory.panel(Color("#e9ecef"),     Color("#dee2e6"),    1, 16, false),
			}
		else:
			styles = {
				"normal":   ThemeFactory.panel(Color("#f8f9fa"),     Color("#dee2e6"),    1, 16, false),
				"hover":    ThemeFactory.panel(Color("#f8f9fa"),     Color("#dee2e6"),    1, 16, false),
				"pressed":  ThemeFactory.panel(Color("#f8f9fa"),     Color("#dee2e6"),    1, 16, false),
				"disabled": ThemeFactory.panel(Color("#f8f9fa"),     Color("#dee2e6"),    1, 16, false),
			}
		ThemeFactory.apply_button_styles(btn, styles)

		# 单行 HBox：[标签] [弹性间隔] [摘要]
		var hb := HBoxContainer.new()
		hb.set_anchors_preset(Control.PRESET_FULL_RECT)
		hb.offset_left = 20; hb.offset_right = -20
		hb.offset_top  = 0;  hb.offset_bottom = 0
		hb.add_theme_constant_override("separation", 12)
		hb.alignment = BoxContainer.ALIGNMENT_CENTER
		hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		btn.add_child(hb)

		var lbl_name := Label.new()
		lbl_name.text = "自动存档"
		lbl_name.add_theme_font_size_override("font_size", LABEL_FS)
		lbl_name.add_theme_color_override("font_color", C_ACCENT if exists else C_DISABLED)
		lbl_name.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
		lbl_name.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hb.add_child(lbl_name)

		var spacer := Control.new()
		spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hb.add_child(spacer)

		var lbl_meta := Label.new()
		lbl_meta.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if exists:
			var meta_parts: Array = []
			var date_str: String = str(entry.get("date_str", ""))
			var scenario: String = str(entry.get("scenario_name", ""))
			var turn: int    = int(entry.get("turn", 0))
			var gold: int    = int(entry.get("gold", 0))
			var food: int    = int(entry.get("food", 0))
			if scenario != "":
				meta_parts.append(scenario)
			if turn > 0:
				meta_parts.append("第%d回合" % turn)
			if gold > 0 or food > 0:
				meta_parts.append("金%d 粮%d" % [gold, food])
			if date_str != "":
				meta_parts.append(date_str)
			lbl_meta.text = "  ·  ".join(meta_parts)
			lbl_meta.add_theme_color_override("font_color", C_MUTED)
		else:
			lbl_meta.text = "（无存档）"
			lbl_meta.add_theme_color_override("font_color", C_DISABLED)
		lbl_meta.add_theme_font_size_override("font_size", META_FS)
		lbl_meta.size_flags_horizontal = Control.SIZE_SHRINK_END
		hb.add_child(lbl_meta)

		if exists:
			var sid: String = str(entry.get("slot_id", ""))
			btn.pressed.connect(func(): slot_selected.emit(sid))
		return btn

	# ── 手动存档槽：双行分栏布局 ─────────────────────────────────────────────
	func _make_manual_slot(entry: Dictionary) -> Control:
		var exists: bool = bool(entry.get("exists", false))
		var btn := Button.new()
		btn.flat = false; btn.focus_mode = Control.FOCUS_NONE
		btn.disabled = not exists
		btn.mouse_filter = Control.MOUSE_FILTER_STOP

		var styles: Dictionary
		if exists:
			styles = {
				"normal":   ThemeFactory.panel(Color.WHITE,        Color("#ced4da"),   1, 16, true),
				"hover":    ThemeFactory.panel(Color("#f0f9ff"),   Color("#74c0fc"),   1, 16, true),
				"pressed":  ThemeFactory.panel(Color("#dbeafe"),   Color("#4dabf7"),   1, 16, true),
				"disabled": ThemeFactory.panel(Color("#e9ecef"),   Color("#dee2e6"),   1, 16, false),
			}
		else:
			styles = {
				"normal":   ThemeFactory.panel(Color("#f8f9fa"),   Color("#e9ecef"),   1, 16, false),
				"hover":    ThemeFactory.panel(Color("#f8f9fa"),   Color("#e9ecef"),   1, 16, false),
				"pressed":  ThemeFactory.panel(Color("#f8f9fa"),   Color("#e9ecef"),   1, 16, false),
				"disabled": ThemeFactory.panel(Color("#f8f9fa"),   Color("#e9ecef"),   1, 16, false),
			}
		ThemeFactory.apply_button_styles(btn, styles)

		# 整体 HBox：左区（名称+剧本） | 右区（日期+回合资源）
		var hb := HBoxContainer.new()
		hb.set_anchors_preset(Control.PRESET_FULL_RECT)
		hb.offset_left = 24; hb.offset_right = -24
		hb.offset_top  = 0;  hb.offset_bottom = 0
		hb.add_theme_constant_override("separation", 16)
		hb.alignment = BoxContainer.ALIGNMENT_CENTER
		hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		btn.add_child(hb)

		# 左区
		var left_vb := VBoxContainer.new()
		left_vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		left_vb.alignment = BoxContainer.ALIGNMENT_CENTER
		left_vb.add_theme_constant_override("separation", 4)
		left_vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hb.add_child(left_vb)

		var lbl_name := Label.new()
		lbl_name.text = str(entry.get("label", ""))
		lbl_name.add_theme_font_size_override("font_size", LABEL_FS)
		lbl_name.add_theme_color_override("font_color", C_TEXT if exists else C_DISABLED)
		lbl_name.mouse_filter = Control.MOUSE_FILTER_IGNORE
		left_vb.add_child(lbl_name)

		var lbl_scenario := Label.new()
		lbl_scenario.mouse_filter = Control.MOUSE_FILTER_IGNORE
		if exists:
			var scenario: String = str(entry.get("scenario_name", ""))
			lbl_scenario.text = scenario if scenario != "" else "—"
			lbl_scenario.add_theme_color_override("font_color", C_MUTED)
		else:
			lbl_scenario.text = "（空）"
			lbl_scenario.add_theme_color_override("font_color", C_DISABLED)
		lbl_scenario.add_theme_font_size_override("font_size", META_FS)
		left_vb.add_child(lbl_scenario)

		# 右区（仅有存档时显示）
		if exists:
			var right_vb := VBoxContainer.new()
			right_vb.size_flags_horizontal = Control.SIZE_SHRINK_END
			right_vb.alignment = BoxContainer.ALIGNMENT_CENTER
			right_vb.add_theme_constant_override("separation", 4)
			right_vb.mouse_filter = Control.MOUSE_FILTER_IGNORE
			hb.add_child(right_vb)

			var lbl_date := Label.new()
			lbl_date.text = str(entry.get("date_str", ""))
			lbl_date.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			lbl_date.add_theme_font_size_override("font_size", META_SM_FS)
			lbl_date.add_theme_color_override("font_color", C_MUTED)
			lbl_date.mouse_filter = Control.MOUSE_FILTER_IGNORE
			right_vb.add_child(lbl_date)

			var turn: int = int(entry.get("turn", 0))
			var gold: int = int(entry.get("gold", 0))
			var food: int = int(entry.get("food", 0))
			var lbl_stat := Label.new()
			lbl_stat.text = "第%d回合  金%d  粮%d" % [turn, gold, food]
			lbl_stat.horizontal_alignment = HORIZONTAL_ALIGNMENT_RIGHT
			lbl_stat.add_theme_font_size_override("font_size", META_SM_FS)
			lbl_stat.add_theme_color_override("font_color", C_MUTED)
			lbl_stat.mouse_filter = Control.MOUSE_FILTER_IGNORE
			right_vb.add_child(lbl_stat)

			var sid: String = str(entry.get("slot_id", ""))
			btn.pressed.connect(func(): slot_selected.emit(sid))
		return btn
