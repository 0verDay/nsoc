class_name SideBoardUi
extends RefCounted

# 附盘 UI 构造工具。把"建 container + bg + grid + hp 面板 + 墓地/除外按钮"
# 的固定代码集中。返回字典含所有节点引用，由调用方进一步装入 BoardSlot。
#
# 参数：
#   parent       : 挂载所有节点的根 Control
#   center_x     : 棋盘视觉水平中心（相对 parent 中心的 x 偏移）
#   side_top     : true = 上排（敌方），bg/hp 锚定屏幕上半；false = 下排（友方），锚定下半
#   suffix       : 节点名后缀，避免冲突，例如 "_AllyLeft"
#   show_pile_btns: 是否生成墓地/除外按钮（敌方盘需要，友方盘按需）

const BOARD_HALF_W: float = 230.0
const TOP_NEAR: float = 20.0
const TOP_FAR: float  = 470.0
const BTN_H: float = 40.0
const GAP: float = 10.0
const BTN_W: float = (BOARD_HALF_W * 2.0 - GAP * 2.0) / 3.0
const TOP_BTN_Y: float = 15.0
const BOTTOM_BTN_Y: float = -55.0   # 下排时贴底，相对 anchor_bottom

static func build(parent: Control, center_x: float, side_top: bool,
		suffix: String, show_pile_btns: bool = true) -> Dictionary:
	var grid_bg_style := ThemeFactory.panel(Color("#f0f3f5"), Color("#e1e8ed"), 1, 16)
	var ui_nodes: Array = []

	var container := Control.new()
	container.name = "BoardContainer" + suffix
	container.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	container.mouse_filter = Control.MOUSE_FILTER_IGNORE
	container.visible = false
	parent.add_child(container)

	# ── BG ──────────────────────────────────────────────
	var bg := Panel.new()
	bg.name = "GridBg" + suffix
	bg.anchor_left = 0.5; bg.anchor_top = 0.5
	bg.anchor_right = 0.5; bg.anchor_bottom = 0.5
	bg.offset_left   = center_x - BOARD_HALF_W
	bg.offset_right  = center_x + BOARD_HALF_W
	if side_top:
		bg.offset_top    = -TOP_FAR
		bg.offset_bottom = -TOP_NEAR
	else:
		bg.offset_top    = TOP_NEAR
		bg.offset_bottom = TOP_FAR
	bg.grow_horizontal = 2; bg.grow_vertical = 2
	bg.add_theme_stylebox_override("panel", grid_bg_style)
	container.add_child(bg)

	# ── Grid ────────────────────────────────────────────
	var grid := GridContainer.new()
	grid.name = "Grid" + suffix
	grid.anchor_left = 0.5; grid.anchor_top = 0.5
	grid.anchor_right = 0.5; grid.anchor_bottom = 0.5
	grid.offset_left = -205.0; grid.offset_right = 205.0
	grid.offset_top  = -205.0; grid.offset_bottom = 205.0
	grid.grow_horizontal = 2; grid.grow_vertical = 2
	grid.add_theme_constant_override("h_separation", 25)
	grid.add_theme_constant_override("v_separation", 25)
	grid.columns = 3
	bg.add_child(grid)

	# ── HP Panel + Label（敌方贴顶；友方贴底）────────────
	var hp_pnl := Panel.new()
	hp_pnl.name = "HpPnl" + suffix
	hp_pnl.anchor_left = 0.5; hp_pnl.anchor_right = 0.5
	hp_pnl.offset_left  = center_x - BTN_W / 2.0
	hp_pnl.offset_right = center_x + BTN_W / 2.0
	if side_top:
		hp_pnl.anchor_top = 0.0; hp_pnl.anchor_bottom = 0.0
		hp_pnl.offset_top    = TOP_BTN_Y
		hp_pnl.offset_bottom = TOP_BTN_Y + BTN_H
	else:
		hp_pnl.anchor_top = 1.0; hp_pnl.anchor_bottom = 1.0
		hp_pnl.offset_top    = BOTTOM_BTN_Y
		hp_pnl.offset_bottom = BOTTOM_BTN_Y + BTN_H
	hp_pnl.add_theme_stylebox_override("panel",
		ThemeFactory.panel(Color.WHITE, Color("#ff6b6b"), 2, 12, true))
	parent.add_child(hp_pnl); ui_nodes.append(hp_pnl)

	var lbl := Label.new()
	lbl.name = "HealthLabel" + suffix
	lbl.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	lbl.add_theme_color_override("font_color", Color(1, 0.419608, 0.419608, 1))
	lbl.add_theme_font_size_override("font_size", 22)
	lbl.text = "30"
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	hp_pnl.add_child(lbl)

	# ── 墓地 / 除外 按钮（可选）────────────────────────
	var grave_btn: Button = null
	var banished_btn: Button = null
	if show_pile_btns:
		grave_btn = _make_pile_btn("GraveBtn" + suffix, "墓地",
			center_x - BOARD_HALF_W, side_top)
		parent.add_child(grave_btn); ui_nodes.append(grave_btn)
		banished_btn = _make_pile_btn("BanishedBtn" + suffix, "除外",
			center_x + BOARD_HALF_W - BTN_W, side_top)
		parent.add_child(banished_btn); ui_nodes.append(banished_btn)

	return {
		"container": container,
		"bg": bg,
		"grid": grid,
		"hp_panel": hp_pnl,
		"hp_label": lbl,
		"grave_btn": grave_btn,
		"banished_btn": banished_btn,
		"ui_nodes": ui_nodes,
	}

static func _make_pile_btn(name_str: String, text: String,
		center_x_offset: float, side_top: bool) -> Button:
	var btn := Button.new()
	btn.name = name_str
	btn.text = text
	btn.anchor_left = 0.5; btn.anchor_right = 0.5
	btn.offset_left  = center_x_offset
	btn.offset_right = center_x_offset + BTN_W
	if side_top:
		btn.anchor_top = 0.0; btn.anchor_bottom = 0.0
		btn.offset_top    = TOP_BTN_Y
		btn.offset_bottom = TOP_BTN_Y + BTN_H
	else:
		btn.anchor_top = 1.0; btn.anchor_bottom = 1.0
		btn.offset_top    = BOTTOM_BTN_Y
		btn.offset_bottom = BOTTOM_BTN_Y + BTN_H
	btn.add_theme_font_size_override("font_size", 22)
	ThemeFactory.apply_button_styles(btn, ThemeFactory.primary_button_styles())
	return btn
