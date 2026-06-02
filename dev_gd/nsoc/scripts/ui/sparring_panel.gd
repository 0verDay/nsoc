class_name SparringPanel
extends SecondaryPanel

# 演武切磋二级界面（res://scenes/SparringPanel.tscn）。
# 继承 SecondaryPanel 复用 BackBtn 风格 + 转场淡入淡出。
#
# 布局（全部静态节点，在 .tscn 中定义）：
#   BackBtn                   : 右上 160×80
#   RightActionPnl/Margin/VBox/ModeBtn0~3 : 右侧 4 个模式选择按钮
#   LeftContentPnl/Center/VBox/TitleLbl   : 左侧占位面板
#
# 默认选中：随机排位（INDEX 3）。
#
# ⚠️  父节点（RightSidePnl）由 MainMenu 以绝对 Tween size/position 控制，
#     不走 Container 路径，anchor 布局时序不可靠。
#     因此本脚本在 _notification(NOTIFICATION_RESIZED) 里手动计算并设置
#     RightActionPnl / LeftContentPnl 的 position + size，
#     完全绕开 anchor 系统，确保在任何 size 下都能正确布局。

const DEFAULT_MODE: int = 3

const MODE_NAMES: Array = [
	"我的房间",
	"加入房间",
	"随机匹配",
	"随机排位",
]

# ── 右侧面板布局参数（与 BackBtn 保持对齐） ───────────────────────────────
const RIGHT_MARGIN:   float = 20.0   # 距屏幕右边 / 上边 / 下边的留白
const RIGHT_WIDTH:    float = 160.0  # BackBtn 及 RightActionPnl 宽度
const BACKBTN_H:      float = 80.0   # BackBtn 高度
const GAP:            float = 20.0   # BackBtn 与 RightActionPnl 的间距
const LEFT_GAP:       float = 20.0   # LeftContentPnl 左边留白
const LR_GAP:         float = 20.0   # LeftContentPnl 与 RightActionPnl 之间的间距

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
@onready var right_action_pnl: Panel  = $RightActionPnl
@onready var left_content_pnl: Panel  = $LeftContentPnl
@onready var title_lbl: Label         = $LeftContentPnl/Center/VBox/TitleLbl
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

	_apply_selection(DEFAULT_MODE)
	# 当前 size 可能还是 0，先做一次布局；size 更新后 NOTIFICATION_RESIZED 还会再来。
	_do_layout()


# ── 手动布局：完全绕开 anchor 系统 ───────────────────────────────────────────
# 每次自身 size 变化时调用，直接计算并写入子面板的 position + size。
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


# ── 选中逻辑 ─────────────────────────────────────────────────────────────────
func _on_mode_btn_pressed(idx: int) -> void:
	if idx == _selected_idx:
		return
	_selected_idx = idx
	_apply_selection(idx)
	title_lbl.text = MODE_NAMES[idx]


func _apply_selection(idx: int) -> void:
	var sel   := _selected_style()
	var unsel := _unselected_style()
	for i in _mode_btns.size():
		ThemeFactory.apply_button_styles(_mode_btns[i], sel if i == idx else unsel)
