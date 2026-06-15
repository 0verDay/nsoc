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


func _build_empire(holder: Control, mode_title: String) -> void:
	# 整体 HBox：主内容区（占满） + 右侧操作按钮列
	var hbox := HBoxContainer.new()
	hbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	hbox.add_theme_constant_override("separation", 16)
	holder.add_child(hbox)

	# 左侧主内容（左上角模式标题占位）
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

	# 右侧操作按钮列（竖向填满）
	var btn_col := VBoxContainer.new()
	btn_col.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	btn_col.size_flags_horizontal = Control.SIZE_SHRINK_END
	btn_col.add_theme_constant_override("separation", 12)
	hbox.add_child(btn_col)

	for label in ["载\n入", "开\n始", "继\n续"]:
		btn_col.add_child(_make_action_btn(label))


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
