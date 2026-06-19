class_name EmpireHeroDetailPanel
extends Node

# 帝国地图人才详情面板控制器。
# 与 EmpireLocationPanel 结构相同，从左侧滑入，二者互斥显示。
# 结构：
#   顶栏  : 人才名（左）
#   badge : Lv.X（统一紫色）
#   分隔线
#   属性面板（白底圆角）：统帅 / 武力 / 智力 / 魅力
#   配属部队面板（白底圆角）：暂空

const PANEL_WIDTH: float = 360.0
const PANEL_LEFT_INSET: float = 10.0
const PANEL_TOP: float = 200.0
const PANEL_BOTTOM_INSET: float = 10.0
const ANIM_DURATION: float = 0.2

const BADGE_COLOR: Color = Color("#7b68ee")

const ATTR_KEYS: Array = ["command", "force", "intelligence", "charisma"]
const ATTR_LABELS: Array = ["统帅", "武力", "智力", "魅力"]
const ATTR_COLORS: Array = [
	Color("#e67e22"),
	Color("#c0392b"),
	Color("#2980b9"),
	Color("#9b59b6"),
]

var _parent: Control
var _clip: Control
var _panel: Panel
var _is_open: bool = false
var _animating: bool = false

# 当前显示的 hero_key（供 EmpireTest 判断点击同一头像 = 关闭）
var current_hero_key: String = ""

# 内容节点引用
var _name_lbl: Label = null
var _badge_lbl: Label = null
var _faction_lbl: Label = null
var _faction_dot: Panel = null
var _attr_val_labels: Array = []
# 配属部队列表（卡名 x 数量）
var _troop_list: VBoxContainer = null
var _troop_empty_lbl: Label = null


func setup(parent: Control) -> void:
	_parent = parent
	_build_panel()


func is_open() -> bool:
	return _is_open


func _build_panel() -> void:
	# ── 裁剪层 ──────────────────────────────────────────────────────────────
	_clip = Control.new()
	_clip.name = "EmpireHeroClip"
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
	_panel.name = "EmpireHeroPanel"
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

	# ── 内容 VBox ───────────────────────────────────────────────────────────
	var root_vbox := VBoxContainer.new()
	root_vbox.name = "RootVBox"
	root_vbox.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	root_vbox.offset_left   = 18
	root_vbox.offset_right  = -18
	root_vbox.offset_top    = 20
	root_vbox.offset_bottom = -16
	root_vbox.add_theme_constant_override("separation", 12)
	_panel.add_child(root_vbox)

	# ── 顶栏：人才名 ─────────────────────────────────────────────────────────
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

	# 势力名（右，与色点一起靠右）
	_faction_lbl = Label.new()
	_faction_lbl.name = "FactionLbl"
	_faction_lbl.text = ""
	_faction_lbl.add_theme_font_size_override("font_size", 16)
	_faction_lbl.add_theme_color_override("font_color", Color(0.35, 0.35, 0.35))
	_faction_lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	header.add_child(_faction_lbl)

	# 势力色点
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

	# ── 等级 Badge ───────────────────────────────────────────────────────────
	var badge_row := HBoxContainer.new()
	badge_row.name = "BadgeRow"
	badge_row.add_theme_constant_override("separation", 0)
	root_vbox.add_child(badge_row)

	var badge_style := StyleBoxFlat.new()
	badge_style.bg_color = BADGE_COLOR
	badge_style.corner_radius_top_left = 8
	badge_style.corner_radius_top_right = 8
	badge_style.corner_radius_bottom_left = 8
	badge_style.corner_radius_bottom_right = 8
	badge_style.content_margin_left = 10
	badge_style.content_margin_right = 10
	badge_style.content_margin_top = 4
	badge_style.content_margin_bottom = 4

	var badge_pc := PanelContainer.new()
	badge_pc.name = "LevelBadge"
	badge_pc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge_pc.add_theme_stylebox_override("panel", badge_style)
	badge_row.add_child(badge_pc)

	_badge_lbl = Label.new()
	_badge_lbl.name = "BadgeLbl"
	_badge_lbl.text = "Lv.1"
	_badge_lbl.add_theme_font_size_override("font_size", 15)
	_badge_lbl.add_theme_color_override("font_color", Color.WHITE)
	_badge_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge_pc.add_child(_badge_lbl)

	var badge_spacer := Control.new()
	badge_spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	badge_spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	badge_row.add_child(badge_spacer)

	# ── 分隔线 ────────────────────────────────────────────────────────────
	var sep := HSeparator.new()
	sep.add_theme_color_override("color", Color(0.8, 0.8, 0.8))
	sep.add_theme_constant_override("separation", 2)
	root_vbox.add_child(sep)

	# ── 属性面板 ─────────────────────────────────────────────────────────────
	var attr_pc := PanelContainer.new()
	attr_pc.name = "AttrPanel"
	attr_pc.mouse_filter = Control.MOUSE_FILTER_IGNORE
	attr_pc.add_theme_stylebox_override(
		"panel",
		ThemeFactory.panel(Color.WHITE, Color(0.88, 0.88, 0.88, 1.0), 1, 12, false)
	)
	root_vbox.add_child(attr_pc)

	var attr_margin := MarginContainer.new()
	attr_margin.add_theme_constant_override("margin_left",   14)
	attr_margin.add_theme_constant_override("margin_right",  14)
	attr_margin.add_theme_constant_override("margin_top",    12)
	attr_margin.add_theme_constant_override("margin_bottom", 12)
	attr_margin.mouse_filter = Control.MOUSE_FILTER_IGNORE
	attr_pc.add_child(attr_margin)

	var attr_vbox := VBoxContainer.new()
	attr_vbox.add_theme_constant_override("separation", 8)
	attr_vbox.mouse_filter = Control.MOUSE_FILTER_IGNORE
	attr_margin.add_child(attr_vbox)

	_attr_val_labels.clear()
	for i in ATTR_LABELS.size():
		var val_lbl: Label = EmpireLocationPanel._add_res_row(attr_vbox, ATTR_LABELS[i], "—", ATTR_COLORS[i])
		_attr_val_labels.append(val_lbl)

	# ── 配属部队面板 ─────────────────────────────────────────────────────────
	var troop_pc := PanelContainer.new()
	troop_pc.name = "TroopPanel"
	troop_pc.custom_minimum_size = Vector2(0, 80)
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
	troop_title.text = "配属部队"
	troop_title.add_theme_font_size_override("font_size", 14)
	troop_title.add_theme_color_override("font_color", Color(0.4, 0.4, 0.4))
	troop_vbox.add_child(troop_title)

	# 滚动容器 + 内层 VBox 存放卡牌行（卡很多时可滚）
	var troop_scroll := ScrollContainer.new()
	troop_scroll.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	troop_scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	troop_scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	troop_scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	troop_vbox.add_child(troop_scroll)

	_troop_list = VBoxContainer.new()
	_troop_list.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_troop_list.add_theme_constant_override("separation", 4)
	_troop_list.mouse_filter = Control.MOUSE_FILTER_IGNORE
	troop_scroll.add_child(_troop_list)

	_troop_empty_lbl = Label.new()
	_troop_empty_lbl.text = "（无）"
	_troop_empty_lbl.add_theme_font_size_override("font_size", 14)
	_troop_empty_lbl.add_theme_color_override("font_color", Color(0.65, 0.65, 0.65))
	_troop_empty_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_troop_empty_lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_troop_list.add_child(_troop_empty_lbl)

	# ── 训练按钮（置灰）─────────────────────────────────────────────────
	var train_btn := Button.new()
	train_btn.name = "TrainBtn"
	train_btn.text = "训练"
	train_btn.disabled = true
	train_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	train_btn.custom_minimum_size = Vector2(0, 64)
	train_btn.add_theme_font_size_override("font_size", 22)
	train_btn.add_theme_color_override("font_color",         Color.WHITE)
	train_btn.add_theme_color_override("font_hover_color",   Color.WHITE)
	train_btn.add_theme_color_override("font_pressed_color", Color.WHITE)
	var btn_styles := ThemeFactory.primary_button_styles()
	ThemeFactory.apply_button_styles(train_btn, btn_styles)
	root_vbox.add_child(train_btn)


# 打开面板并显示指定人才数据。
# hero_data: empire_hero.json 中该 hero_key 对应的字典。
# faction_name/faction_color: 该人才所在地点的势力信息。
func show_for(hero_key: String, hero_data: Dictionary,
		faction_name: String = "", faction_color: Color = Color("#adb5bd")) -> void:
	current_hero_key = hero_key
	_refresh_content(hero_data, faction_name, faction_color)

	if _is_open:
		return
	_is_open = true
	_clip.visible = true
	_panel.offset_left  = -PANEL_WIDTH
	_panel.offset_right = 0
	_animating = true
	var tween := _parent.get_tree().create_tween()
	tween.tween_property(_panel, "offset_left",  0.0,         ANIM_DURATION).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(_panel, "offset_right", PANEL_WIDTH,  ANIM_DURATION).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_callback(func(): _animating = false)


# 已开着时刷新内容（切换到另一人才，不重新播放滑入动画）。
func refresh_for(hero_key: String, hero_data: Dictionary,
		faction_name: String = "", faction_color: Color = Color("#adb5bd")) -> void:
	current_hero_key = hero_key
	_refresh_content(hero_data, faction_name, faction_color)


func hide_panel() -> void:
	if not _is_open:
		return
	_is_open = false
	current_hero_key = ""
	_animating = true
	var tween := _parent.get_tree().create_tween()
	tween.tween_property(_panel, "offset_left",  -PANEL_WIDTH, ANIM_DURATION).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.parallel().tween_property(_panel, "offset_right", 0.0,          ANIM_DURATION).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_callback(func():
		_animating = false
		_clip.visible = false)


func _refresh_content(hero_data: Dictionary,
		faction_name: String = "", faction_color: Color = Color("#adb5bd")) -> void:
	var display_name: String = String(hero_data.get("display_name", "—"))
	var level: int           = int(hero_data.get("level", 1))

	if _name_lbl:
		_name_lbl.text = display_name
	if _badge_lbl:
		_badge_lbl.text = "Lv." + str(level)
	if _faction_lbl:
		_faction_lbl.text = faction_name
	if _faction_dot:
		_faction_dot.add_theme_stylebox_override(
			"panel", ThemeFactory.panel(faction_color, Color.TRANSPARENT, 0, 9))

	for i in ATTR_KEYS.size():
		if i < _attr_val_labels.size() and _attr_val_labels[i] != null:
			_attr_val_labels[i].text = str(int(hero_data.get(ATTR_KEYS[i], 0)))

	_refresh_troops(current_hero_key)


# 刷新配属部队列表：从 EmpireDeckStorage 读出该 hero 当前的卡组，按 order 渲染为
# 「卡名 x 数量」行；空则显示"（无）"。
func _refresh_troops(hero_key: String) -> void:
	if _troop_list == null:
		return
	for c in _troop_list.get_children():
		if c == _troop_empty_lbl:
			continue
		c.queue_free()
	if hero_key == "":
		if _troop_empty_lbl:
			_troop_empty_lbl.visible = true
		return
	var saved: Dictionary = EmpireDeckStorage.load_deck(hero_key)
	var cards: Dictionary = saved.get("cards", {})
	if cards.is_empty():
		if _troop_empty_lbl:
			_troop_empty_lbl.visible = true
		return
	if _troop_empty_lbl:
		_troop_empty_lbl.visible = false
	var order: Array = saved.get("order", [])
	var iter: Array = order if not order.is_empty() else cards.keys()
	for name in iter:
		var count: int = int(cards.get(String(name), 0))
		if count <= 0:
			continue
		var lbl := Label.new()
		lbl.text = "%s x %d" % [String(name), count]
		lbl.add_theme_font_size_override("font_size", 16)
		lbl.add_theme_color_override("font_color", Color(0.2, 0.2, 0.2))
		lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_troop_list.add_child(lbl)
