class_name EmpireTalentPanel
extends SecondaryPanel

# 帝国"人才"二级界面（res://scenes/EmpireTalentPanel.tscn）。
# 布局（中部 MiddleVBox）：
#   Row1（HBoxContainer）
#     ├─ DiamondPanel（暗色底板，菱形四维图）
#     └─ AttrPanel   （白底，5列风格化属性标签，长按弹出详情）
#   Panel2 / Panel3（白底占位）

const HERO_JSON: String = "res://data/empire_hero.json"
const ATTR_KEYS:  Array = ["command", "force", "intelligence", "charisma"]
const COL_NAMES:  Array = ["总体", "统帅", "武力", "智力", "魅力"]

const ATTR_DESC: Dictionary = {
	"总体": "这是该属性的描述占位文本",
	"统帅": "这是该属性的描述占位文本",
	"武力": "这是该属性的描述占位文本",
	"智力": "这是该属性的描述占位文本",
	"魅力": "这是该属性的描述占位文本",
}

const NAME_FONT_SIZE: int = 24
const VAL_FONT_SIZE:  int = 36

const NAME_COLOR: Color = Color(0.68, 0.46, 0.10)
const VAL_COLOR:  Color = Color(0.15, 0.52, 0.96)
const SEP_COLOR:  Color = Color(0.68, 0.46, 0.10, 0.55)

const DARK_PANEL_BG:     Color = Color(0.07, 0.11, 0.20, 0.95)
const DARK_PANEL_BORDER: Color = Color(0.20, 0.35, 0.65, 0.60)

# 由 EmpireTest 监听：请求进入部署模式 / 请求流放（撤销部署）
signal deploy_requested(hero_key: String)
signal recall_requested(hero_key: String)

@onready var _middle_vbox: VBoxContainer = $MiddleVBox
@onready var _right_vbox:  VBoxContainer = $RightVBox

var _hero_data:    Dictionary            = {}
var _diamond:      _DiamondChart         = null
var _val_labels:   Array[Label]          = []
var _level_lbl:      Label                 = null
var _cur_exp_lbl:    Label                 = null
var _next_exp_lbl:   Label                 = null
var _exp_bar:        ProgressBar           = null
var _background_lbl: Label                 = null
var _detail_panel: DetailPanelController = null

# 当前已部署人才集合的引用（EmpireTest 管理，attach 时通过 set_deployed_state 注入）
var _deployed_heroes_ref: Dictionary = {}
var _deploy_btn: Button = null
var _carousel_ref: EmpireCarousel = null

# 当前未被流放的人才池（由 EmpireTest 在 attach 后注入）。
# 用于：1）轮播过滤 2）拒绝流放最后一人时把按钮置灰。
var _alive_pool: Array = ["A", "B", "C"]
# EmpireTest 在 attach 后通过 goto_hero 设定的初始 hero_key，
# 在 _apply_styles（延迟一帧）执行时用于最终定位，避免 deferred 时序覆盖。
var _initial_hero: String = ""


func _apply_styles() -> void:
	_load_hero_data()

	var diamond_pnl: PanelContainer = get_node_or_null("MiddleVBox/Row1/DiamondPanel")
	if diamond_pnl:
		diamond_pnl.add_theme_stylebox_override("panel",
			ThemeFactory.panel(DARK_PANEL_BG, DARK_PANEL_BORDER, 1, 20, true))

	var white_style := ThemeFactory.panel(Color.WHITE, Color(1, 1, 1, 0.6), 1, 20, true)
	var attr_pnl: PanelContainer = get_node_or_null("MiddleVBox/Row1/AttrPanel")
	if attr_pnl:
		attr_pnl.add_theme_stylebox_override("panel", white_style)
	for child in _middle_vbox.get_children():
		if child is PanelContainer:
			child.add_theme_stylebox_override("panel", white_style)

	var btn_styles := ThemeFactory.primary_button_styles()
	for child in _right_vbox.get_children():
		if child is Button:
			ThemeFactory.apply_button_styles(child, btn_styles)
			child.add_theme_color_override("font_color",         Color.WHITE)
			child.add_theme_color_override("font_hover_color",   Color.WHITE)
			child.add_theme_color_override("font_pressed_color", Color.WHITE)
	# 训练、升级、招募尚未实现，置灰禁用
	for btn_name in ["TrainBtn", "UpgradeBtn", "RecruitBtn"]:
		var btn := _right_vbox.get_node_or_null(btn_name) as Button
		if btn:
			btn.disabled = true

	if diamond_pnl:
		_build_diamond_panel(diamond_pnl)
	if attr_pnl:
		_build_attr_panel(attr_pnl)

	var panel2: PanelContainer = _middle_vbox.get_node_or_null("Panel2")
	if panel2:
		_build_level_panel(panel2)

	var panel3: PanelContainer = _middle_vbox.get_node_or_null("Panel3")
	if panel3:
		_build_background_panel(panel3)

	_install_detail_panel()

	var carousel: EmpireCarousel = get_node_or_null("HeroPnl/Carousel")
	if carousel:
		_carousel_ref = carousel
		carousel.current_hero_changed.connect(_on_hero_changed)
		# _apply_styles 由 call_deferred 延后，_alive_pool 在此之前可能已由
		# EmpireTest.set_alive_pool 更新；此处补传确保 carousel 侧也同步过滤。
		carousel.set_alive_pool(_alive_pool)
		# 恢复 EmpireTest 指定的初始位置（首次打开 = 第一个 alive，之后 = 上次退出位置）。
		if not _initial_hero.is_empty():
			carousel.goto_hero(_initial_hero)
		_refresh_attr(carousel.current_hero_key())

	_deploy_btn = _right_vbox.get_node_or_null("DeployBtn") as Button
	if _deploy_btn:
		_deploy_btn.pressed.connect(_on_deploy_btn_pressed)
	_refresh_deploy_btn()


# 由 EmpireTest 在 attach 后调用，注入已部署人才的字典引用，用于刷新按钮文案。
func set_deployed_state(deployed: Dictionary) -> void:
	_deployed_heroes_ref = deployed
	_refresh_deploy_btn()


# 由 EmpireTest 在 attach 后调用，注入未被流放的人才池：
#   - 透传给 carousel 进行轮播过滤
#   - 当 alive 池仅剩 1 人时，已部署者的"流放"按钮置灰
# 注：SecondaryPanel._apply_styles 由 call_deferred 延后一帧执行；
# 此函数可能在 _apply_styles 之前调用，故用节点直访兜底（不依赖 _carousel_ref）。
func set_alive_pool(arr: Array) -> void:
	_alive_pool = arr.duplicate()
	var car: EmpireCarousel = _carousel_ref
	if car == null:
		car = get_node_or_null("HeroPnl/Carousel") as EmpireCarousel
	if car:
		car.set_alive_pool(_alive_pool)
		_refresh_attr(car.current_hero_key())
	_refresh_deploy_btn()


func _refresh_deploy_btn() -> void:
	if _deploy_btn == null:
		return
	var hero_key: String = ""
	if _carousel_ref:
		hero_key = _carousel_ref.current_hero_key()
	var is_deployed: bool = _deployed_heroes_ref.has(hero_key)
	_deploy_btn.text = "流\n放" if is_deployed else "部\n署"
	# 拒绝流放最后一人：alive 池仅剩 1 人时禁用流放按钮
	_deploy_btn.disabled = is_deployed and _alive_pool.size() <= 1


# 直接跳转到指定 hero_key（外部调用，须在 set_alive_pool 之后调用）。
# 用节点直访兜底，兼容 _apply_styles 延迟场景。
# 同时存入 _initial_hero，供 _apply_styles 延迟完成后再次定位。
func goto_hero(hero_key: String) -> void:
	_initial_hero = hero_key
	var car: EmpireCarousel = _carousel_ref
	if car == null:
		car = get_node_or_null("HeroPnl/Carousel") as EmpireCarousel
	if car:
		car.goto_hero(hero_key)
		_refresh_attr(hero_key)
	_refresh_deploy_btn()


func _on_deploy_btn_pressed() -> void:
	if _carousel_ref == null:
		return
	var hero_key: String = _carousel_ref.current_hero_key()
	if _deployed_heroes_ref.has(hero_key):
		recall_requested.emit(hero_key)
		_refresh_deploy_btn()
	else:
		deploy_requested.emit(hero_key)


func _load_hero_data() -> void:
	if not FileAccess.file_exists(HERO_JSON):
		return
	var f := FileAccess.open(HERO_JSON, FileAccess.READ)
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) != TYPE_DICTIONARY:
		return
	_hero_data = parsed.get("heroes", {})


func _build_level_panel(panel2: PanelContainer) -> void:
	var cjk: Font   = load("res://assets/NotoSerifCJKsc-Regular.otf")
	var muster_bg   := ThemeFactory.panel(Color(0.94, 0.95, 0.96, 1.0), Color(1, 1, 1, 1.0), 1, 20, false)
	var list_styles := ThemeFactory.list_item_styles()

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left",   10)
	margin.add_theme_constant_override("margin_right",  10)
	margin.add_theme_constant_override("margin_top",    10)
	margin.add_theme_constant_override("margin_bottom", 10)
	panel2.add_child(margin)

	var outer := HBoxContainer.new()
	outer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	outer.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	outer.add_theme_constant_override("separation", 12)
	margin.add_child(outer)

	# ── 左侧：等级 / 经验面板 ───────────────────────────────────────────────────
	var lv_pnl := PanelContainer.new()
	lv_pnl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lv_pnl.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	lv_pnl.add_theme_stylebox_override("panel", muster_bg)
	outer.add_child(lv_pnl)

	var lv_margin := MarginContainer.new()
	lv_margin.add_theme_constant_override("margin_left",   14)
	lv_margin.add_theme_constant_override("margin_right",  14)
	lv_margin.add_theme_constant_override("margin_top",    12)
	lv_margin.add_theme_constant_override("margin_bottom", 12)
	lv_pnl.add_child(lv_margin)

	var lv_vbox := VBoxContainer.new()
	lv_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	lv_vbox.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	lv_vbox.alignment             = BoxContainer.ALIGNMENT_CENTER
	lv_vbox.add_theme_constant_override("separation", 8)
	lv_margin.add_child(lv_vbox)

	# Lv. 1
	_level_lbl = Label.new()
	_level_lbl.text                 = "Lv. 1"
	_level_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_level_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_level_lbl.add_theme_font_size_override("font_size", 30)
	_level_lbl.add_theme_color_override("font_color", Color(0.15, 0.15, 0.15))
	if cjk: _level_lbl.add_theme_font_override("font", cjk)
	lv_vbox.add_child(_level_lbl)

	# 当前经验值 行
	_cur_exp_lbl  = _make_exp_row(lv_vbox, "当前经验值", "0", cjk)
	# 下一级经验 行
	_next_exp_lbl = _make_exp_row(lv_vbox, "下一级经验", "100", cjk)

	# 经验值进度条
	_exp_bar = ProgressBar.new()
	_exp_bar.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_exp_bar.custom_minimum_size   = Vector2(0.0, 14.0)
	_exp_bar.max_value             = 100.0
	_exp_bar.value                 = 0.0
	_exp_bar.show_percentage       = false
	var bar_bg := StyleBoxFlat.new()
	bar_bg.bg_color                   = Color(0.80, 0.82, 0.85)
	bar_bg.corner_radius_top_left     = 7
	bar_bg.corner_radius_top_right    = 7
	bar_bg.corner_radius_bottom_left  = 7
	bar_bg.corner_radius_bottom_right = 7
	var bar_fill := StyleBoxFlat.new()
	bar_fill.bg_color                   = Color(0.15, 0.52, 0.96)
	bar_fill.corner_radius_top_left     = 7
	bar_fill.corner_radius_top_right    = 7
	bar_fill.corner_radius_bottom_left  = 7
	bar_fill.corner_radius_bottom_right = 7
	_exp_bar.add_theme_stylebox_override("background", bar_bg)
	_exp_bar.add_theme_stylebox_override("fill",       bar_fill)
	lv_vbox.add_child(_exp_bar)

	# ── 右侧：升级列表 ────────────────────────────────────────────────────────
	var upgrade_pnl := PanelContainer.new()
	upgrade_pnl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	upgrade_pnl.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	upgrade_pnl.add_theme_stylebox_override("panel", muster_bg)
	outer.add_child(upgrade_pnl)

	var upgrade_margin := MarginContainer.new()
	upgrade_margin.add_theme_constant_override("margin_left",   10)
	upgrade_margin.add_theme_constant_override("margin_right",  10)
	upgrade_margin.add_theme_constant_override("margin_top",    10)
	upgrade_margin.add_theme_constant_override("margin_bottom", 10)
	upgrade_pnl.add_child(upgrade_margin)

	# HBoxContainer 撑满升级面板，元素左起固定宽度排列
	var upgrade_vbox := HBoxContainer.new()
	upgrade_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	upgrade_vbox.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	upgrade_vbox.alignment             = BoxContainer.ALIGNMENT_BEGIN
	upgrade_vbox.add_theme_constant_override("separation", 6)
	upgrade_margin.add_child(upgrade_vbox)

	# 占位列表项：固定 112px（1920px 分辨率下与上方属性列宽对齐）
	var item_btn := Button.new()
	item_btn.text                  = "占位"
	item_btn.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	item_btn.custom_minimum_size   = Vector2(112.0, 0.0)
	item_btn.focus_mode            = Control.FOCUS_NONE
	item_btn.add_theme_font_size_override("font_size", 22)
	item_btn.add_theme_color_override("font_color",         Color(0.15, 0.15, 0.15))
	item_btn.add_theme_color_override("font_hover_color",   Color(0.0,  0.0,  0.0))
	item_btn.add_theme_color_override("font_pressed_color", Color(0.0,  0.0,  0.0))
	if cjk: item_btn.add_theme_font_override("font", cjk)
	ThemeFactory.apply_button_styles(item_btn, list_styles)
	upgrade_vbox.add_child(item_btn)

	item_btn.button_down.connect(_on_upgrade_item_press)
	item_btn.button_up.connect(_on_upgrade_item_release)
	item_btn.mouse_exited.connect(_on_upgrade_item_release)


# 经验值行辅助：「名称」左 + 「数值」右，返回数值 Label 用于后续刷新
func _make_exp_row(parent: VBoxContainer, row_name: String, init_val: String, cjk: Font) -> Label:
	var hbox := HBoxContainer.new()
	hbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	hbox.add_theme_constant_override("separation", 6)
	parent.add_child(hbox)

	var name_lbl := Label.new()
	name_lbl.text                  = row_name
	name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	name_lbl.add_theme_font_size_override("font_size", 20)
	name_lbl.add_theme_color_override("font_color", Color(0.35, 0.35, 0.35))
	if cjk: name_lbl.add_theme_font_override("font", cjk)
	hbox.add_child(name_lbl)

	var val_lbl := Label.new()
	val_lbl.text                  = init_val
	val_lbl.horizontal_alignment  = HORIZONTAL_ALIGNMENT_RIGHT
	val_lbl.add_theme_font_size_override("font_size", 20)
	val_lbl.add_theme_color_override("font_color", VAL_COLOR)
	if cjk: val_lbl.add_theme_font_override("font", cjk)
	hbox.add_child(val_lbl)
	return val_lbl


func _build_background_panel(panel3: PanelContainer) -> void:
	var cjk: Font = load("res://assets/NotoSerifCJKsc-Regular.otf")

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left",   16)
	margin.add_theme_constant_override("margin_right",  16)
	margin.add_theme_constant_override("margin_top",    14)
	margin.add_theme_constant_override("margin_bottom", 14)
	panel3.add_child(margin)

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", 10)
	margin.add_child(vbox)

	# 标题"背景"
	var title := Label.new()
	title.text                 = "背景"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_LEFT
	title.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	title.add_theme_font_size_override("font_size", 26)
	title.add_theme_color_override("font_color", Color(0.20, 0.20, 0.20))
	if cjk: title.add_theme_font_override("font", cjk)
	vbox.add_child(title)

	# 细分隔线
	var sep := ColorRect.new()
	sep.color                 = Color(0.68, 0.46, 0.10, 0.45)
	sep.custom_minimum_size   = Vector2(0.0, 2.0)
	sep.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_child(sep)

	# 背景文案
	_background_lbl = Label.new()
	_background_lbl.text                  = "这是该人才的背景占位文案"
	_background_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_background_lbl.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	_background_lbl.autowrap_mode         = TextServer.AUTOWRAP_WORD_SMART
	_background_lbl.vertical_alignment    = VERTICAL_ALIGNMENT_TOP
	_background_lbl.add_theme_font_size_override("font_size", 22)
	_background_lbl.add_theme_color_override("font_color", Color(0.25, 0.25, 0.25))
	if cjk: _background_lbl.add_theme_font_override("font", cjk)
	vbox.add_child(_background_lbl)


func _install_detail_panel() -> void:
	_detail_panel = DetailPanelController.new()
	_detail_panel.name = "AttrDetailPanel"
	add_child(_detail_panel)
	_detail_panel.setup(self, null)           # 属性详情不需要卡牌 scene
	_detail_panel.get_clip().move_to_front()
	var hero_pnl: Control = get_node_or_null("HeroPnl")
	if hero_pnl:
		_detail_panel.attach_to_rect(hero_pnl)


func _build_diamond_panel(panel: PanelContainer) -> void:
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left",   14)
	margin.add_theme_constant_override("margin_right",  14)
	margin.add_theme_constant_override("margin_top",    14)
	margin.add_theme_constant_override("margin_bottom", 14)
	panel.add_child(margin)

	_diamond = _DiamondChart.new()
	_diamond.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_diamond.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	margin.add_child(_diamond)


func _build_attr_panel(panel: PanelContainer) -> void:
	var cjk: Font = load("res://assets/NotoSerifCJKsc-Regular.otf")
	var list_styles := ThemeFactory.list_item_styles()

	# 与点兵面板相同的灰色底板
	var muster_style := ThemeFactory.panel(
		Color(0.94, 0.95, 0.96, 1.0), Color(1, 1, 1, 1.0), 1, 20, false)
	panel.add_theme_stylebox_override("panel", muster_style)

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left",   10)
	margin.add_theme_constant_override("margin_right",  10)
	margin.add_theme_constant_override("margin_top",    10)
	margin.add_theme_constant_override("margin_bottom", 10)
	panel.add_child(margin)

	# 横排 5 列，列间间隔 8px
	var cols_box := HBoxContainer.new()
	cols_box.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cols_box.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	cols_box.add_theme_constant_override("separation", 8)
	margin.add_child(cols_box)

	_val_labels.clear()
	for col_name in COL_NAMES:
		# 每列：独立 Button，list_item_styles 灰色底板
		var col_btn := Button.new()
		col_btn.text                  = ""
		col_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		col_btn.size_flags_vertical   = Control.SIZE_EXPAND_FILL
		col_btn.focus_mode            = Control.FOCUS_NONE
		ThemeFactory.apply_button_styles(col_btn, list_styles)
		cols_box.add_child(col_btn)

		# 列内容：VBoxContainer 锚满按钮（anchor-based）
		var col := VBoxContainer.new()
		col.set_anchors_preset(Control.PRESET_FULL_RECT, false)
		col.alignment    = BoxContainer.ALIGNMENT_CENTER
		col.mouse_filter = Control.MOUSE_FILTER_IGNORE
		col.add_theme_constant_override("separation", 4)
		col_btn.add_child(col)

		# 属性名：每字一行，金色
		var name_lbl := Label.new()
		name_lbl.text                  = col_name[0] + "\n" + col_name[1]
		name_lbl.horizontal_alignment  = HORIZONTAL_ALIGNMENT_CENTER
		name_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		name_lbl.mouse_filter          = Control.MOUSE_FILTER_IGNORE
		name_lbl.add_theme_font_size_override("font_size", NAME_FONT_SIZE)
		name_lbl.add_theme_color_override("font_color", NAME_COLOR)
		if cjk:
			name_lbl.add_theme_font_override("font", cjk)
		col.add_child(name_lbl)

		# 金色分隔线
		var sep := ColorRect.new()
		sep.color                 = SEP_COLOR
		sep.custom_minimum_size   = Vector2(0.0, 2.0)
		sep.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		sep.mouse_filter          = Control.MOUSE_FILTER_IGNORE
		col.add_child(sep)

		# 数值：大号蓝色
		var val_lbl := Label.new()
		val_lbl.text                  = "-"
		val_lbl.horizontal_alignment  = HORIZONTAL_ALIGNMENT_CENTER
		val_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		val_lbl.mouse_filter          = Control.MOUSE_FILTER_IGNORE
		val_lbl.add_theme_font_size_override("font_size", VAL_FONT_SIZE)
		val_lbl.add_theme_color_override("font_color", VAL_COLOR)
		if cjk:
			val_lbl.add_theme_font_override("font", cjk)
		col.add_child(val_lbl)
		_val_labels.append(val_lbl)

		# 长按信号
		col_btn.button_down.connect(_on_attr_press.bind(col_name))
		col_btn.button_up.connect(_on_attr_release)
		col_btn.mouse_exited.connect(_on_attr_release)


func _on_attr_press(col_name: String) -> void:
	if _detail_panel == null:
		return
	_detail_panel.start_long_press_attr(
		col_name,
		ATTR_DESC.get(col_name, "这是该属性的描述占位文本")
	)


func _on_attr_release() -> void:
	if _detail_panel == null:
		return
	_detail_panel.cancel_long_press()
	_detail_panel.hide_panel()


func _on_upgrade_item_press() -> void:
	if _detail_panel:
		_detail_panel.start_long_press_attr("占位", "此为该升级的占位描述")


func _on_upgrade_item_release() -> void:
	if _detail_panel:
		_detail_panel.cancel_long_press()
		_detail_panel.hide_panel()


func _on_hero_changed(hero_key: String) -> void:
	_refresh_attr(hero_key)
	_refresh_deploy_btn()


func _refresh_attr(hero_key: String) -> void:
	if _hero_data.is_empty() or hero_key.is_empty() or _val_labels.is_empty():
		return
	var hero = _hero_data.get(hero_key, null)
	if hero == null:
		return

	var cmd:   int = int(hero.get("command",       0))
	var frc:   int = int(hero.get("force",         0))
	var intel: int = int(hero.get("intelligence",  0))
	var charm: int = int(hero.get("charisma",      0))
	var total: int = cmd + frc + intel + charm

	var values: Array = [total, cmd, frc, intel, charm]
	for i in _val_labels.size():
		_val_labels[i].text = str(values[i])

	if _diamond:
		var hero_max: int = max(cmd, max(frc, max(intel, charm)))
		_diamond.set_values(float(cmd), float(frc), float(intel), float(charm), float(hero_max))

	var lv:       int = int(hero.get("level",         1))
	var cur_exp:  int = int(hero.get("current_exp",   0))
	var next_exp: int = int(hero.get("next_level_exp", 100))
	if _level_lbl:    _level_lbl.text    = "Lv. " + str(lv)
	if _cur_exp_lbl:  _cur_exp_lbl.text  = str(cur_exp)
	if _next_exp_lbl: _next_exp_lbl.text = str(next_exp)
	if _exp_bar:
		_exp_bar.max_value = float(next_exp) if next_exp > 0 else 1.0
		_exp_bar.value     = float(cur_exp)

	if _background_lbl:
		_background_lbl.text = String(hero.get("background", "这是该人才的背景占位文案"))


# ── 菱形四维图 ────────────────────────────────────────────────────────────────
class _DiamondChart extends Control:
	var _cmd:   float = 0.0
	var _frc:   float = 0.0
	var _intel: float = 0.0
	var _charm: float = 0.0
	var _max:   float = 10.0

	const VERTEX_LABELS:    Array  = ["统", "武", "智", "魅"]
	const VERTEX_FONT_SIZE: int    = 20
	const VERTEX_OFFSET:    float  = 8.0

	const GRID_COLOR:   Color = Color(0.45, 0.65, 0.95, 0.35)
	const AXIS_COLOR:   Color = Color(0.55, 0.75, 1.00, 0.50)
	const BORDER_COLOR: Color = Color(0.70, 0.85, 1.00, 0.80)
	const FILL_COLOR:   Color = Color(0.25, 0.55, 1.00, 0.42)
	const VAL_BORDER:   Color = Color(0.85, 0.93, 1.00, 0.95)
	const LABEL_COLOR:  Color = Color(0.90, 0.92, 1.00, 1.00)

	func _ready() -> void:
		resized.connect(queue_redraw)

	func set_values(cmd: float, frc: float, intel: float, charm: float, max_val: float) -> void:
		_cmd   = cmd
		_frc   = frc
		_intel = intel
		_charm = charm
		_max   = max(max_val, 1.0)
		queue_redraw()

	func _draw() -> void:
		if size.x <= 0.0 or size.y <= 0.0:
			return
		var cx: float = size.x * 0.5
		var cy: float = size.y * 0.5
		var r: float  = min(cx, cy) * 0.65

		for i in range(1, 4):
			_draw_ring(cx, cy, r * float(i) / 4.0, GRID_COLOR, 1.0)
		for pt in _axis_pts(cx, cy, r):
			draw_line(Vector2(cx, cy), pt, AXIS_COLOR, 1.0, true)
		_draw_ring(cx, cy, r, BORDER_COLOR, 2.0)

		var val_pts := PackedVector2Array([
			Vector2(cx,               cy - r * (_cmd   / _max)),
			Vector2(cx + r * (_frc   / _max), cy             ),
			Vector2(cx,               cy + r * (_intel / _max)),
			Vector2(cx - r * (_charm / _max), cy             ),
		])
		draw_colored_polygon(val_pts, FILL_COLOR)
		draw_polyline(
			PackedVector2Array([val_pts[0], val_pts[1], val_pts[2], val_pts[3], val_pts[0]]),
			VAL_BORDER, 2.0, true
		)

		var font: Font = get_theme_font("font")
		var fs: int    = VERTEX_FONT_SIZE
		var off: float = VERTEX_OFFSET
		draw_string(font, Vector2(cx - fs * 0.5, cy - r - off),
			VERTEX_LABELS[0], HORIZONTAL_ALIGNMENT_LEFT, -1, fs, LABEL_COLOR)
		draw_string(font, Vector2(cx + r + off, cy + fs * 0.38),
			VERTEX_LABELS[1], HORIZONTAL_ALIGNMENT_LEFT, -1, fs, LABEL_COLOR)
		draw_string(font, Vector2(cx - fs * 0.5, cy + r + off + fs),
			VERTEX_LABELS[2], HORIZONTAL_ALIGNMENT_LEFT, -1, fs, LABEL_COLOR)
		draw_string(font, Vector2(cx - r - off - fs, cy + fs * 0.38),
			VERTEX_LABELS[3], HORIZONTAL_ALIGNMENT_LEFT, -1, fs, LABEL_COLOR)

	static func _axis_pts(cx: float, cy: float, r: float) -> Array:
		return [
			Vector2(cx,     cy - r),
			Vector2(cx + r, cy    ),
			Vector2(cx,     cy + r),
			Vector2(cx - r, cy    ),
		]

	func _draw_ring(cx: float, cy: float, r: float, color: Color, width: float) -> void:
		draw_polyline(PackedVector2Array([
			Vector2(cx,     cy - r),
			Vector2(cx + r, cy    ),
			Vector2(cx,     cy + r),
			Vector2(cx - r, cy    ),
			Vector2(cx,     cy - r),
		]), color, width, true)
