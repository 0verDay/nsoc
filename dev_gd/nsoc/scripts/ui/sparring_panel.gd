class_name SparringPanel
extends SecondaryPanel

# 演武切磋二级界面（res://scenes/SparringPanel.tscn）。
# 继承 SecondaryPanel 复用 BackBtn 风格 + 转场淡入淡出。
#
# ⚠️  **联机功能暂未开放**（本项目已转为纯本地：战役 + 自由对战 + 演义模式）。
#     页面本身完整保留 —— 玩家点「演武切磋」能正常进入、能切换四个模式页、
#     能看到模式说明 —— 但**无法创建房间、无法加入房间、无法开始任何联机对局**。
#     所有联网逻辑（WebSocket / 房间列表 / 准备与开局 / 权威裁决接线）已整体删除，
#     详见 `docs/archive/multiplayer-removal.md`。
#
# 布局（.tscn 中静态节点）：
#   BackBtn                  : 右上 160×80
#   RightActionPnl/...       : 右侧 4 个模式按钮（ModeBtn0~3）
#   LeftContentPnl           : 左侧主内容区（脚本动态填充）
#
# 模式分工（点击右侧按钮切换，全部为只读占位页）：
#   ModeBtn0「我的房间」: 原"创建房间"入口 → 提示暂未开放
#   ModeBtn1「加入房间」: 原"加入房间"入口 → 提示暂未开放
#   ModeBtn2「随机匹配」: 占位（施工中）
#   ModeBtn3「随机排位」: 占位（施工中）
#
# ⚠️  父节点（RightSidePnl）由 MainMenu 以绝对 Tween size/position 控制，
#     不走 Container 路径，anchor 布局时序不可靠。
#     因此本脚本在 _notification(NOTIFICATION_RESIZED) 里手动计算并设置
#     RightActionPnl / LeftContentPnl 的 position + size，
#     完全绕开 anchor 系统，确保在任何 size 下都能正确布局。

const DEFAULT_MODE: int = 0  # 默认落在「我的房间」，让玩家第一眼就看到状态提示

const MODE_NAMES: Array = [
	"我的房间",
	"加入房间",
	"随机匹配",
	"随机排位",
]

# ── 字号 / 颜色 ─────────────────────────────────────────────────────────
const FONT_SIZE_TITLE: int   = 48
const FONT_SIZE_BODY: int    = 28
const FONT_SIZE_SMALL: int   = 22
const BTN_HEIGHT: float      = 72.0
const TEXT_DARK: Color       = Color("#212529")
const TEXT_MUTED: Color      = Color("#868e96")
const ACCENT: Color          = Color(0.109804, 0.494118, 0.839216, 1)

# ── 布局参数（与 BackBtn 保持对齐） ───────────────────────────────────────
const RIGHT_MARGIN:   float = 20.0   # 距屏幕右边 / 上边 / 下边的留白
const RIGHT_WIDTH:    float = 160.0  # BackBtn 及 RightActionPnl 宽度
const BACKBTN_H:      float = 80.0   # BackBtn 高度
const GAP:            float = 20.0   # BackBtn 与 RightActionPnl 的间距
const LEFT_GAP:       float = 20.0   # LeftContentPnl 左边留白
const LR_GAP:         float = 20.0   # LeftContentPnl 与 RightActionPnl 之间的间距

# ── 文案 ─────────────────────────────────────────────────────────────────
## 联机模式（我的房间 / 加入房间）的统一提示。
const UNAVAILABLE_TITLE: String = "联机功能暂未开放"
const UNAVAILABLE_HINT_0: String = "本版本已转为本地单机：战役 / 自由对战 / 演义模式。\n创建房间与加入房间均不可用。"
const UNAVAILABLE_HINT_1: String = "本版本已转为本地单机：战役 / 自由对战 / 演义模式。\n房间列表与加入房间均不可用。"

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

# ── 节点引用 ─────────────────────────────────────────────────────────────────
@onready var right_action_pnl: Panel = $RightActionPnl
@onready var left_content_pnl: Panel = $LeftContentPnl
@onready var _btn0: Button = $RightActionPnl/Margin/VBox/ModeBtn0
@onready var _btn1: Button = $RightActionPnl/Margin/VBox/ModeBtn1
@onready var _btn2: Button = $RightActionPnl/Margin/VBox/ModeBtn2
@onready var _btn3: Button = $RightActionPnl/Margin/VBox/ModeBtn3

var _mode_btns: Array[Button] = []
var _selected_idx: int = DEFAULT_MODE

# ── 初始化 ───────────────────────────────────────────────────────────────────
func _apply_styles() -> void:
	var pnl_style := ThemeFactory.panel(Color.WHITE, Color(1, 1, 1, 0.6), 1, 20, true)
	right_action_pnl.add_theme_stylebox_override("panel", pnl_style)
	left_content_pnl.add_theme_stylebox_override("panel", pnl_style)

	_mode_btns = [_btn0, _btn1, _btn2, _btn3]
	for i in _mode_btns.size():
		var btn := _mode_btns[i]
		btn.add_theme_color_override("font_color",         Color.WHITE)
		btn.add_theme_color_override("font_hover_color",   Color.WHITE)
		btn.add_theme_color_override("font_pressed_color", Color.WHITE)
		btn.pressed.connect(_on_mode_btn_pressed.bind(i))
	_apply_selection(_selected_idx)

	_do_layout()
	_refresh_left_content()


# ── 手动布局：完全绕开 anchor 系统 ───────────────────────────────────────────
func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_do_layout()


func _do_layout() -> void:
	var W: float = size.x
	var H: float = size.y
	if W <= 0.0 or H <= 0.0:
		return

	# BackBtn
	if back_btn:
		back_btn.position = Vector2(W - RIGHT_MARGIN - RIGHT_WIDTH, RIGHT_MARGIN)
		back_btn.size     = Vector2(RIGHT_WIDTH, BACKBTN_H)

	# RightActionPnl：BackBtn 正下方，同宽，撑到底部留白
	var rap_top: float = RIGHT_MARGIN + BACKBTN_H + GAP
	if right_action_pnl:
		right_action_pnl.position = Vector2(W - RIGHT_MARGIN - RIGHT_WIDTH, rap_top)
		right_action_pnl.size     = Vector2(RIGHT_WIDTH, H - rap_top - RIGHT_MARGIN)

	# LeftContentPnl：左留白 ~ RightActionPnl 左边沿再留 LR_GAP
	var lcp_right: float = W - RIGHT_MARGIN - RIGHT_WIDTH - LR_GAP
	if left_content_pnl:
		left_content_pnl.position = Vector2(LEFT_GAP, RIGHT_MARGIN)
		left_content_pnl.size     = Vector2(lcp_right - LEFT_GAP, H - RIGHT_MARGIN * 2.0)


# ── 模式切换（纯本地页面切换，不触发任何联网）─────────────────────────────────
func _on_mode_btn_pressed(idx: int) -> void:
	if idx == _selected_idx:
		return  # 同 tab 重复点击：忽略
	_selected_idx = idx
	_apply_selection(idx)
	_refresh_left_content()


func _apply_selection(idx: int) -> void:
	var sel   := _selected_style()
	var unsel := _unselected_style()
	for i in _mode_btns.size():
		ThemeFactory.apply_button_styles(_mode_btns[i], sel if i == idx else unsel)


# ── 内容渲染：根据 selected_idx 构建 LeftContentPnl（全部只读）────────────────
func _refresh_left_content() -> void:
	if left_content_pnl == null:
		return
	# 清空旧内容（包括 .tscn 中的静态 Center/VBox）
	for child in left_content_pnl.get_children():
		child.queue_free()

	# 创建一个全填充的 MarginContainer 作为内容容器
	var holder := MarginContainer.new()
	holder.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	holder.add_theme_constant_override("margin_left",   24)
	holder.add_theme_constant_override("margin_right",  24)
	holder.add_theme_constant_override("margin_top",    24)
	holder.add_theme_constant_override("margin_bottom", 24)
	left_content_pnl.add_child(holder)

	match _selected_idx:
		0: _build_unavailable(holder, UNAVAILABLE_HINT_0)
		1: _build_unavailable(holder, UNAVAILABLE_HINT_1)
		2: _build_placeholder(holder, MODE_NAMES[2])
		3: _build_placeholder(holder, MODE_NAMES[3])


# ── 「联机功能暂未开放」页（我的房间 / 加入房间）──────────────────────────────
# 保留页面外观与模式标题，明确告知当前不可用 —— 不再有任何创建 / 加入入口。
func _build_unavailable(holder: Control, hint_text: String) -> void:
	var vbox := _make_vbox(16)
	holder.add_child(vbox)

	vbox.add_child(_make_title(MODE_NAMES[_selected_idx]))
	vbox.add_child(_make_spacer(8))
	vbox.add_child(_make_label(UNAVAILABLE_TITLE, FONT_SIZE_TITLE, ACCENT))

	var hint := _make_label(hint_text, FONT_SIZE_BODY, TEXT_MUTED)
	hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(hint)

	vbox.add_child(_make_spacer(8))
	var local_hint := _make_label("可玩内容：主菜单 →「战役」/「演武切磋 → 随机匹配（施工中）」或直接进入本地对战。",
		FONT_SIZE_SMALL, TEXT_MUTED)
	local_hint.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(local_hint)


# ── 占位模式（随机匹配 / 随机排位）────────────────────────────────────────────
func _build_placeholder(holder: Control, title: String) -> void:
	var vbox := _make_vbox(16)
	holder.add_child(vbox)
	vbox.add_child(_make_title(title))
	vbox.add_child(_make_label("（施工中）", FONT_SIZE_BODY, TEXT_MUTED))


# ── UI 工厂 ──────────────────────────────────────────────────────────────────
func _make_vbox(sep: int) -> VBoxContainer:
	var vbox := VBoxContainer.new()
	vbox.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	vbox.add_theme_constant_override("separation", sep)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	return vbox


func _make_label(text: String, font_size: int, color: Color) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", color)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return lbl


func _make_title(text: String) -> Label:
	return _make_label(text, FONT_SIZE_TITLE, ACCENT)


func _make_spacer(h: int) -> Control:
	var c := Control.new()
	c.custom_minimum_size = Vector2(0, h)
	return c
