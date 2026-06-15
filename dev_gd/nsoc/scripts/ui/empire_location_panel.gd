class_name EmpireLocationPanel
extends Node

# 帝国地图地点详情面板控制器。
# 左侧从屏幕外滑入，结构：
#   顶栏  : 地点名(左) + 势力(右)
#   badge : 地点类型彩色标签
#   分隔线
#   资源面板（白底圆角）：资金/粮草/特化
#   军队面板（白底圆角）：容纳军队（暂空）
#   特化按钮（全宽，置灰）

const PANEL_WIDTH: float = 360.0
const PANEL_LEFT_INSET: float = 10.0
const PANEL_TOP: float = 200.0       # InfoPanel.bottom(180) + 20px 间隙
const PANEL_BOTTOM_INSET: float = 10.0
const ANIM_DURATION: float = 0.2

# 地点类型 → {label, color}
const KIND_META: Dictionary = {
	"triangle": {"label": "关隘",    "color": Color("#6abf69")},
	"circle":   {"label": "村镇",    "color": Color("#4a90d9")},
	"square":   {"label": "城市",    "color": Color("#e07b54")},
}
# square 的 category → 具体城市名
const CITY_CATEGORY: Dictionary = {
	1: {"label": "大都市",    "color": Color("#c0392b")},
	2: {"label": "商业城市",  "color": Color("#e67e22")},
	3: {"label": "农业城市",  "color": Color("#27ae60")},
	4: {"label": "军事城市",  "color": Color("#2980b9")},
}

var _parent: Control
var _clip: Control
var _panel: Panel
var _is_open: bool = false
var _animating: bool = false

# 内容节点引用（供 show_for 刷新）
var _name_lbl: Label
var _faction_dot: Panel
var _faction_lbl: Label
var _badge_lbl: Label
var _badge_panel: PanelContainer
var _gold_val_lbl: Label
var _food_val_lbl: Label


func setup(parent: Control) -> void:
	_parent = parent
	_build_panel()


func _build_panel() -> void:
	# ── 裁剪层 ─────────────────────────────────────────────────────────────
	_clip = Control.new()
	_clip.name = "EmpireLocationClip"
	_parent.add_child(_clip)
	_clip.set_anchors_preset(Control.PRESET_LEFT_WIDE, false)
	_clip.offset_left   = PANEL_LEFT_INSET
	_clip.offset_right  = PANEL_LEFT_INSET + PANEL_WIDTH
	_clip.offset_top    = PANEL_TOP
	_clip.offset_bottom = -PANEL_BOTTOM_INSET
	_clip.mouse_filter  = Control.MOUSE_FILTER_IGNORE
	_clip.clip_contents = true
	_clip.visible       = false
	_clip.z_index       = 200

	# ── 主面板 ──────────────────────────────────────────────────────────────
	_panel = Panel.new()
	_panel.name = "EmpireLocPanel"
	_clip.add_child(_panel)
	_panel.set_anchors_preset(Control.PRESET_LEFT_WIDE, false)
	_panel.offset_left   = -PANEL_WIDTH
	_panel.offset_right  = 0
	_panel.offset_top    = 0
	_panel.offset_bottom = 0
	_panel.mouse_filter  = Control.MOUSE_FILTER_STOP
	_panel.add_theme_stylebox_override(
		"panel",
		ThemeFactory.panel(Color(0.94, 0.95, 0.96, 1.0), Color(1, 1, 1, 1.0), 1, 20)
	)

	# ── 内容 VBox（带内边距）─────────────────────────────────────────────────
	var root_vbox := VBoxContainer.new()
	root_vbox.name = "RootVBox"
	root_vbox.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	root_vbox.offset_left   = 18
	root_vbox.offset_right  = -18
	root_vbox.offset_top    = 20
	root_vbox.offset_bottom = -16
	root_vbox.add_theme_constant_override("separation", 12)
	_panel.add_child(root_vbox)

	# ── 顶栏：地点名（左）+ 势力（右）───────────────────────────────────────
	var header := HBoxContainer.new()
	header.name = "Header"
	header.add_theme_constant_override("separation", 8)
	root_vbox.add_child(header)

	_name_lbl = Label.new()
	_name_lbl.name = "NameLbl"
	_name_lbl.add_theme_font_size_override("font_size", 22)
	_name_lbl.add_theme_color_override("font_color", Color(0.1, 0.1, 0.1))
	_name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_name_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	header.add_child(_name_lbl)

	# 势力名（右，与圆点一起靠右）
	_faction_lbl = Label.new()
	_faction_lbl.name = "FactionLbl"
	_faction_lbl.text = "中立"
	_faction_lbl.add_theme_font_size_override("font_size", 16)
	_faction_lbl.add_theme_color_override("font_color", Color(0.35, 0.35, 0.35))
	_faction_lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header.add_child(_faction_lbl)

	# 势力色点（Panel + StyleBoxFlat 圆形，corner_radius = 9 = size/2）
	var dot_wrap := Control.new()
	dot_wrap.custom_minimum_size = Vector2(18, 18)
	dot_wrap.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header.add_child(dot_wrap)
	var dot_panel := Panel.new()
	dot_panel.name = "FactionDot"
	dot_panel.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	dot_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	dot_panel.add_theme_stylebox_override(
		"panel", ThemeFactory.panel(Color("#adb5bd"), Color.TRANSPARENT, 0, 9))
	dot_wrap.add_child(dot_panel)
	_faction_dot = dot_panel

	# ── 类型 Badge ────────────────────────────────────────────────────────
	# 用 PanelContainer 让 Panel 尺寸自动跟内容走
	var badge_row := HBoxContainer.new()
	badge_row.name = "BadgeRow"
	badge_row.add_theme_constant_override("separation", 0)
	root_vbox.add_child(badge_row)

	var badge_style := StyleBoxFlat.new()
	badge_style.bg_color = Color("#6abf69")
	badge_style.corner_radius_top_left = 8
	badge_style.corner_radius_top_right = 8
	badge_style.corner_radius_bottom_left = 8
	badge_style.corner_radius_bottom_right = 8
	badge_style.content_margin_left = 10
	badge_style.content_margin_right = 10
	badge_style.content_margin_top = 4
	badge_style.content_margin_bottom = 4

	_badge_panel = PanelContainer.new()
	_badge_panel.name = "TypeBadge"
	_badge_panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_badge_panel.add_theme_stylebox_override("panel", badge_style)
	badge_row.add_child(_badge_panel)

	_badge_lbl = Label.new()
	_badge_lbl.name = "BadgeLbl"
	_badge_lbl.text = "关隘"
	_badge_lbl.add_theme_font_size_override("font_size", 15)
	_badge_lbl.add_theme_color_override("font_color", Color.WHITE)
	_badge_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_badge_panel.add_child(_badge_lbl)

	# 右侧 spacer 把 badge 推到左边
	var badge_spacer := Control.new()
	badge_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	badge_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge_row.add_child(badge_spacer)

	# ── 分隔线 ────────────────────────────────────────────────────────────
	var sep := HSeparator.new()
	sep.add_theme_color_override("color", Color(0.8, 0.8, 0.8))
	sep.add_theme_constant_override("separation", 2)
	root_vbox.add_child(sep)

	# ── 资源面板（PanelContainer → MarginContainer → VBox）────────────────
	var res_pc := PanelContainer.new()
	res_pc.name = "ResPanel"
	res_pc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	res_pc.add_theme_stylebox_override(
		"panel",
		ThemeFactory.panel(Color.WHITE, Color(0.88, 0.88, 0.88, 1.0), 1, 12, false)
	)
	root_vbox.add_child(res_pc)

	var res_margin := MarginContainer.new()
	res_margin.add_theme_constant_override("margin_left",   14)
	res_margin.add_theme_constant_override("margin_right",  14)
	res_margin.add_theme_constant_override("margin_top",    12)
	res_margin.add_theme_constant_override("margin_bottom", 12)
	res_margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	res_pc.add_child(res_margin)

	var res_vbox := VBoxContainer.new()
	res_vbox.add_theme_constant_override("separation", 8)
	res_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	res_margin.add_child(res_vbox)

	var gold_val_lbl := _add_res_row(res_vbox, "资金",   "+0 / 回合", Color("#e67e22"))
	var food_val_lbl := _add_res_row(res_vbox, "粮草",   "0",         Color("#27ae60"))
	_add_res_row(res_vbox, "特化",   "无",        Color("#adb5bd"))
	_gold_val_lbl = gold_val_lbl
	_food_val_lbl = food_val_lbl

	# ── 军队面板（PanelContainer → MarginContainer → VBox）──────────────
	var troop_pc := PanelContainer.new()
	troop_pc.name = "TroopPanel"
	troop_pc.custom_minimum_size = Vector2(0, 90)
	troop_pc.size_flags_vertical = Control.SIZE_EXPAND_FILL
	troop_pc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	troop_pc.add_theme_stylebox_override(
		"panel",
		ThemeFactory.panel(Color.WHITE, Color(0.88, 0.88, 0.88, 1.0), 1, 12, false)
	)
	root_vbox.add_child(troop_pc)

	var troop_margin := MarginContainer.new()
	troop_margin.add_theme_constant_override("margin_left",   14)
	troop_margin.add_theme_constant_override("margin_right",  14)
	troop_margin.add_theme_constant_override("margin_top",    10)
	troop_margin.add_theme_constant_override("margin_bottom", 10)
	troop_margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	troop_pc.add_child(troop_margin)

	var troop_vbox := VBoxContainer.new()
	troop_vbox.add_theme_constant_override("separation", 6)
	troop_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	troop_margin.add_child(troop_vbox)

	var troop_title := Label.new()
	troop_title.text = "驻军"
	troop_title.add_theme_font_size_override("font_size", 14)
	troop_title.add_theme_color_override("font_color", Color(0.4, 0.4, 0.4))
	troop_vbox.add_child(troop_title)

	var troop_empty := Label.new()
	troop_empty.text = "（无）"
	troop_empty.add_theme_font_size_override("font_size", 14)
	troop_empty.add_theme_color_override("font_color", Color(0.65, 0.65, 0.65))
	troop_empty.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	troop_vbox.add_child(troop_empty)

	# ── 特化按钮（置灰）─────────────────────────────────────────────────
	var specialize_btn := Button.new()
	specialize_btn.name = "SpecializeBtn"
	specialize_btn.text = "特化"
	specialize_btn.disabled = true
	specialize_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	specialize_btn.custom_minimum_size = Vector2(0, 64)
	specialize_btn.add_theme_font_size_override("font_size", 22)
	specialize_btn.add_theme_color_override("font_color",         Color.WHITE)
	specialize_btn.add_theme_color_override("font_hover_color",   Color.WHITE)
	specialize_btn.add_theme_color_override("font_pressed_color", Color.WHITE)
	var btn_styles := ThemeFactory.primary_button_styles()
	ThemeFactory.apply_button_styles(specialize_btn, btn_styles)
	root_vbox.add_child(specialize_btn)


# 资源行：左侧彩色 badge + 右侧值 Label。返回值 Label 引用。
static func _add_res_row(parent: VBoxContainer, key: String, value: String, key_color: Color) -> Label:
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	parent.add_child(row)

	var key_lbl := Label.new()
	key_lbl.text = key
	key_lbl.add_theme_font_size_override("font_size", 14)
	key_lbl.add_theme_color_override("font_color", key_color)
	key_lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	key_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(key_lbl)

	var val_lbl := Label.new()
	val_lbl.text = value
	val_lbl.add_theme_font_size_override("font_size", 14)
	val_lbl.add_theme_color_override("font_color", Color(0.25, 0.25, 0.25))
	val_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	val_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	val_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(val_lbl)
	return val_lbl


# 显示某个地图节点的详情，刷新所有内容节点。
func show_for(node) -> void:
	if node == null:
		return
	_refresh_content(node)

	if _is_open:
		return
	_is_open = true
	_clip.visible = true
	_panel.offset_left  = -PANEL_WIDTH
	_panel.offset_right = 0
	_animating = true
	var tween := _parent.get_tree().create_tween()
	tween.tween_property(_panel, "offset_left",  0.0,         ANIM_DURATION).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(_panel, "offset_right", PANEL_WIDTH, ANIM_DURATION).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_callback(func(): _animating = false)


func hide_panel() -> void:
	if not _is_open:
		return
	_is_open = false
	_animating = true
	var tween := _parent.get_tree().create_tween()
	tween.tween_property(_panel, "offset_left",  -PANEL_WIDTH, ANIM_DURATION).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.parallel().tween_property(_panel, "offset_right", 0.0, ANIM_DURATION).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_callback(func():
		_animating = false
		_clip.visible = false)


# 刷新所有内容（切换地点时调用，面板已开着也生效）。
func _refresh_content(node) -> void:
	var kind: String = ""
	var id: int = -1
	var cat: int = -1
	var name_text: String = ""
	var gold: int = 0
	var food: int = 0
	if node and "_kind" in node:
		kind = String(node._kind)
	if node and "_id" in node:
		id = int(node._id)
	if node and "_cat_label" in node:
		# _cat_label 存的是显示字符串（大/商/农/军），转成 int category
		var cat_map: Dictionary = {"大": 1, "商": 2, "农": 3, "军": 4}
		cat = int(cat_map.get(String(node._cat_label), -1))
	if node and "_name_text" in node:
		name_text = String(node._name_text)
	if node and "_gold" in node:
		gold = int(node._gold)
	if node and "_food" in node:
		food = int(node._food)

	# 地点名
	if _name_lbl:
		if name_text != "":
			_name_lbl.text = name_text
		else:
			_name_lbl.text = _format_title(kind, id)

	# 势力（占位：全灰+中立）
	if _faction_lbl:
		_faction_lbl.text = "中立"
	if _faction_dot:
		_faction_dot.add_theme_stylebox_override(
			"panel", ThemeFactory.panel(Color("#adb5bd"), Color.TRANSPARENT, 0, 9))

	# 类型 Badge
	if _badge_lbl and _badge_panel:
		var meta: Dictionary = _resolve_badge(kind, cat)
		_badge_lbl.text = String(meta["label"])
		var bs := StyleBoxFlat.new()
		bs.bg_color = meta["color"] as Color
		bs.corner_radius_top_left = 8
		bs.corner_radius_top_right = 8
		bs.corner_radius_bottom_left = 8
		bs.corner_radius_bottom_right = 8
		bs.content_margin_left = 10
		bs.content_margin_right = 10
		bs.content_margin_top = 4
		bs.content_margin_bottom = 4
		_badge_panel.add_theme_stylebox_override("panel", bs)

	# 资源
	if _gold_val_lbl:
		_gold_val_lbl.text = "+%d / 回合" % gold
	if _food_val_lbl:
		_food_val_lbl.text = str(food)


static func _format_title(kind: String, id: int) -> String:
	var kind_label: String = {
		"square":   "城市",
		"triangle": "关隘",
		"circle":   "村镇",
	}.get(kind, "地点")
	return "%s #%d" % [kind_label, id]


static func _resolve_badge(kind: String, cat: int) -> Dictionary:
	if kind == "square" and CITY_CATEGORY.has(cat):
		return CITY_CATEGORY[cat]
	if KIND_META.has(kind):
		return KIND_META[kind]
	return {"label": "地点", "color": Color("#868e96")}
