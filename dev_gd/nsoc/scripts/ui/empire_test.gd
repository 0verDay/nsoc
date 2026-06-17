extends Control

const MAP_PATH := "res://data/empire_maps/test_map.json"
const PROFILE_PANEL_SCENE := preload("res://scenes/ProfileSubPanel.tscn")
const DEPLOY_ICON_TEX: Texture2D = preload("res://icon.svg")

const SECONDARY_PANEL_SCENES: Dictionary = {
	"ArmyBtn":    preload("res://scenes/EmpireArmyPanel.tscn"),
	"TalentBtn":  preload("res://scenes/EmpireTalentPanel.tscn"),
	"StrategyBtn":preload("res://scenes/EmpireStrategyPanel.tscn"),
}

const NODE_RADIUS: float = 28.0

const SIDE_BTN_TOP: float = 120.0

# 转场参数（与主菜单一致）
const TRANSITION_DURATION: float = 0.45
const FADE_DURATION: float = 0.15
const EXPANDED_MARGIN: float = 20.0

# 转场状态
var _initial_state: Dictionary = {}        # Control → {position, size, scale, modulate, pivot}
var _transition_targets: Array = []        # [{node, dir}]  dir: -1=左滑 1=右滑 0=仅淡出
var _is_transitioning: bool = false
var _is_expanded: bool = false
var _frozen_children: Array = []
var _frozen_state: Dictionary = {}
var _current_tween: Tween
var _secondary_panel: SecondaryPanel = null
var _origin_panel: Control = null
var _origin_btn: Control = null

var _info_panel: Panel = null

var _location_panel: EmpireLocationPanel
var _hero_detail_panel: EmpireHeroDetailPanel

# 当前在地图上选中的人才 key（点同一头像关闭，与地点选中互斥）
var _selected_hero_key: String = ""
# 从 empire_hero.json 加载的英雄数据库（供人才详情面板使用）
var _empire_hero_db: Dictionary = {}

var _settings: SettingsPanelController
var _map_root: Node2D
var _line_layer: _LineLayer
var _shape_nodes: Array = []
var _selected_node = null

# 势力数据（从地图 JSON 加载）
# 每项：{"id": int, "name": String, "color": Color}
var _factions: Array = []

# 玩家状态（势力 id = 1 即 Ap）
const PLAYER_FACTION_ID: int = 1
var _player_gold: int = 0
var _player_food: int = 0

# 部署系统状态
# _deployed_heroes：hero_key → _MapShapeNode（人才唯一，地点可多）
# _deploy_mode：true 时己方地点呼吸缩放，等待玩家点选目标
# _deploy_pending_hero：从二级面板触发部署后保留的待部署 hero_key
var _deployed_heroes: Dictionary = {}
var _deploy_mode: bool = false
var _deploy_pending_hero: String = ""
# 空白点击取消部署模式：在 _gui_input 中按下记录起点，松开时若未拖动则取消
var _deploy_blank_press: bool = false
var _deploy_blank_press_pos: Vector2 = Vector2.ZERO
const DEPLOY_BLANK_TAP_THRESHOLD: float = 8.0

# InfoPanel 内容节点引用（供回合结算后刷新）
var _info_faction_dot: _FactionDot = null
var _info_faction_lbl: Label = null
var _info_food_lbl: Label = null
var _info_gold_lbl: Label = null

# 视角状态
var _pan_active: bool = false
var _pan_start_mouse: Vector2 = Vector2.ZERO
var _pan_start_pos: Vector2 = Vector2.ZERO

# 双指缩放
var _pinch_active: bool = false
var _pinch_last_dist: float = 0.0
var _pinch_last_center: Vector2 = Vector2.ZERO

# 双指触摸追踪（手机捏合缩放）
var _touch_points: Dictionary = {}   # index → Vector2

const ZOOM_MIN: float = 0.2
const ZOOM_MAX: float = 5.0
const ZOOM_STEP: float = 1.12

var _map_world_size: Vector2 = Vector2.ZERO
var _map_world_origin: Vector2 = Vector2.ZERO


func _ready() -> void:
	set_anchors_preset(Control.PRESET_FULL_RECT)

	var bg := ColorRect.new()
	bg.color = Color.WHITE
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	add_child(bg)

	_map_root = Node2D.new()
	add_child(_map_root)

	_line_layer = _LineLayer.new()
	_map_root.add_child(_line_layer)

	_settings = SettingsPanelController.new()
	_settings.name = "SettingsPanel"
	add_child(_settings)
	_settings.setup(self, {
		"create_trigger_button": true,
		"button_align": "right",
		"resume_label": "继续",
		"exit_label": "退回菜单",
		"extra_buttons": [
			{"label": "存档", "action": Callable()},
		],
	})

	_build_side_panel()
	_build_info_panel()
	_location_panel = EmpireLocationPanel.new()
	_location_panel.name = "LocationPanel"
	add_child(_location_panel)
	_location_panel.setup(self)

	_hero_detail_panel = EmpireHeroDetailPanel.new()
	_hero_detail_panel.name = "HeroDetailPanel"
	add_child(_hero_detail_panel)
	_hero_detail_panel.setup(self)

	_load_empire_hero_db()
	call_deferred("_setup_transition")
	call_deferred("_load_map")


func _build_info_panel() -> void:
	# 外层 Panel：白色背景 + 半透明白边 + 圆角20 + 阴影，与主菜单 ProfilePnl 同款
	var pnl := Panel.new()
	pnl.name = "InfoPanel"
	pnl.set_anchors_preset(Control.PRESET_TOP_LEFT)
	pnl.offset_left   = 20.0
	pnl.offset_top    = 20.0
	pnl.offset_right  = 190.0
	pnl.offset_bottom = 180.0
	pnl.add_theme_stylebox_override("panel",
		ThemeFactory.panel(Color.WHITE, Color(1, 1, 1, 0.6), 1, 20, true))

	# 内层 VBox：三行
	var vbox := VBoxContainer.new()
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left   = 16.0
	vbox.offset_top    = 14.0
	vbox.offset_right  = -16.0
	vbox.offset_bottom = -14.0
	vbox.add_theme_constant_override("separation", 8)
	pnl.add_child(vbox)

	# 第一行：势力色块 + 势力名（运行时由 _refresh_info_panel 填充）
	var row1 := HBoxContainer.new()
	row1.add_theme_constant_override("separation", 10)
	row1.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(row1)

	var faction_dot := _FactionDot.new()
	faction_dot.init(Color.GRAY)
	faction_dot.custom_minimum_size = Vector2(28, 28)
	faction_dot.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row1.add_child(faction_dot)
	_info_faction_dot = faction_dot

	var faction_lbl := Label.new()
	faction_lbl.text = ""
	faction_lbl.add_theme_font_size_override("font_size", 22)
	faction_lbl.add_theme_color_override("font_color", Color("#1f2937"))
	faction_lbl.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row1.add_child(faction_lbl)
	_info_faction_lbl = faction_lbl

	# 第二行：粮草
	var food_lbl := Label.new()
	food_lbl.text = "粮草：—"
	food_lbl.add_theme_font_size_override("font_size", 18)
	food_lbl.add_theme_color_override("font_color", Color("#374151"))
	food_lbl.size_flags_vertical = Control.SIZE_EXPAND_FILL
	food_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	vbox.add_child(food_lbl)
	_info_food_lbl = food_lbl

	# 第三行：资金
	var gold_lbl := Label.new()
	gold_lbl.text = "资金：—"
	gold_lbl.add_theme_font_size_override("font_size", 18)
	gold_lbl.add_theme_color_override("font_color", Color("#374151"))
	gold_lbl.size_flags_vertical = Control.SIZE_EXPAND_FILL
	gold_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	vbox.add_child(gold_lbl)
	_info_gold_lbl = gold_lbl

	add_child(pnl)
	_info_panel = pnl


# ── 转场系统（与主菜单一致）─────────────────────────────────────────────────

func _setup_transition() -> void:
	# 收集参与转场的所有顶层节点，记录初始状态，拍平 anchor
	var side_panel := get_node_or_null("SidePanel")
	var end_btn    := get_node_or_null("EndTurnBtn")
	# SettingsPanelController 的触发按钮直接挂在场景根下
	var settings_btn: Control = get_node_or_null("SettingsBtn")

	_transition_targets = []
	# info_panel：向左滑出（但它是被展开目标，只在"其余面板"滑出逻辑里参与）
	if _info_panel:
		_transition_targets.append({"node": _info_panel, "dir": -1})
	if side_panel:
		_transition_targets.append({"node": side_panel, "dir": 1})
	if end_btn:
		_transition_targets.append({"node": end_btn, "dir": 1})
	if settings_btn:
		_transition_targets.append({"node": settings_btn, "dir": 1})

	for entry in _transition_targets:
		_record_initial(entry.node)

	# 安装 InfoPanel 点击代理按钮
	if _info_panel:
		call_deferred("_install_info_panel_button", _info_panel)

	# 连接 SidePanel 三按钮：各自以自身为 origin_btn，以 SidePanel 为 origin_panel 触发转场
	if side_panel:
		for btn_name in ["ArmyBtn", "TalentBtn", "StrategyBtn"]:
			var btn: Button = side_panel.get_node_or_null("SideVBox/" + btn_name)
			if btn:
				btn.pressed.connect(func(b = btn): _trigger_transition(side_panel, b))


func _record_initial(ctrl: Control) -> void:
	if ctrl == null:
		return
	var gpos := ctrl.position
	var gsize := ctrl.size
	ctrl.set_anchors_preset(Control.PRESET_TOP_LEFT, false)
	ctrl.position = gpos
	ctrl.size = gsize
	ctrl.pivot_offset = gsize * 0.5
	_initial_state[ctrl] = {
		"position": gpos, "size": gsize,
		"scale": ctrl.scale, "modulate": ctrl.modulate,
		"pivot": ctrl.pivot_offset,
	}


func _install_info_panel_button(pnl: Panel) -> void:
	pnl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_disable_mouse_recursive(pnl)

	var btn := Button.new()
	btn.name = "ClickArea"
	btn.flat = true
	btn.focus_mode = Control.FOCUS_NONE
	btn.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	btn.mouse_filter = Control.MOUSE_FILTER_STOP
	btn.set_meta("transition_skip", true)
	var empty := StyleBoxEmpty.new()
	for slot in ["normal", "hover", "pressed", "focus", "disabled", "hover_pressed"]:
		btn.add_theme_stylebox_override(slot, empty)
	pnl.add_child(btn)

	btn.button_down.connect(func():
		if _is_transitioning or _is_expanded: return
		var t := pnl.create_tween()
		t.tween_property(pnl, "scale", Vector2(0.98, 0.98), 0.08))
	btn.button_up.connect(func():
		if _is_transitioning or _is_expanded: return
		var t := pnl.create_tween()
		t.tween_property(pnl, "scale", Vector2.ONE, 0.08))
	btn.pressed.connect(func(): _trigger_transition(_info_panel, _info_panel))


func _trigger_transition(origin_panel: Control, origin_btn: Control) -> void:
	if _is_transitioning or _is_expanded:
		return
	_is_transitioning = true
	_origin_panel = origin_panel
	_origin_btn = origin_btn

	# 进入二级面板前清掉地点选中态与人才选中态，关闭所有详情面板，避免遮挡。
	if _selected_node != null and is_instance_valid(_selected_node):
		_selected_node.set_selected(false)
	_selected_node = null
	if _location_panel:
		_location_panel.hide_panel()
	if _selected_hero_key != "":
		var prev_hero_node = _deployed_heroes.get(_selected_hero_key, null)
		if prev_hero_node != null and is_instance_valid(prev_hero_node):
			prev_hero_node.set_hero_icon_selected(_selected_hero_key, false)
		_selected_hero_key = ""
	if _hero_detail_panel and _hero_detail_panel.is_open():
		_hero_detail_panel.hide_panel()

	if _current_tween and _current_tween.is_valid():
		_current_tween.kill()
	_current_tween = create_tween()
	_current_tween.set_parallel(true)
	_current_tween.set_trans(Tween.TRANS_CUBIC)
	_current_tween.set_ease(Tween.EASE_IN_OUT)

	var screen := get_viewport_rect().size

	# 1) origin_panel 内可见子控件淡出（跳过 transition_skip）
	var fade_targets := _collect_fade_targets(origin_panel)
	_frozen_children = fade_targets.duplicate()
	_frozen_state.clear()
	for c in fade_targets:
		var gpos: Vector2 = c.global_position
		var csize: Vector2 = c.size
		_frozen_state[c] = {"gpos": gpos, "size": csize}
		c.top_level = true
		c.global_position = gpos
		c.size = csize
	for b in fade_targets:
		_current_tween.tween_property(b, "modulate:a", 0.0, FADE_DURATION)

	# 2) 地图淡出
	if _map_root:
		_current_tween.tween_property(_map_root, "modulate:a", 0.0, TRANSITION_DURATION)

	# 3) 其余面板/按钮滑出 + 淡出
	for entry in _transition_targets:
		var node: Control = entry.node
		if node == null or node == origin_panel:
			continue
		var dir: int = entry.dir
		var init: Dictionary = _initial_state.get(node, {})
		if init.is_empty():
			continue
		if dir > 0:
			_current_tween.tween_property(node, "position",
				Vector2(init.position.x + screen.x, init.position.y), TRANSITION_DURATION)
		elif dir < 0:
			_current_tween.tween_property(node, "position",
				Vector2(init.position.x - node.size.x - 40.0, init.position.y), TRANSITION_DURATION)
		_current_tween.tween_property(node, "modulate:a", 0.0, TRANSITION_DURATION)

	# 4) origin_panel 展开至全屏
	var expanded_size := screen - Vector2(EXPANDED_MARGIN * 2.0, EXPANDED_MARGIN * 2.0)
	var expanded_pos  := Vector2(EXPANDED_MARGIN, EXPANDED_MARGIN)
	origin_panel.move_to_front()
	_current_tween.tween_property(origin_panel, "size",         expanded_size,         TRANSITION_DURATION)
	_current_tween.tween_property(origin_panel, "position",     expanded_pos,          TRANSITION_DURATION)
	_current_tween.tween_property(origin_panel, "pivot_offset", expanded_size * 0.5,   TRANSITION_DURATION)

	await _current_tween.finished
	_is_transitioning = false
	_is_expanded = true

	for c in _frozen_children:
		if is_instance_valid(c) and c is Control:
			(c as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE

	# attach 二级面板（按 origin_btn 名路由）
	if _secondary_panel and is_instance_valid(_secondary_panel):
		_secondary_panel.queue_free()
	var btn_key: String = _origin_btn.name if _origin_btn else ""
	var panel_scene: PackedScene = SECONDARY_PANEL_SCENES.get(btn_key, PROFILE_PANEL_SCENE)
	_secondary_panel = panel_scene.instantiate()
	_secondary_panel.back_pressed.connect(_trigger_reverse)
	_secondary_panel.attach(origin_panel)
	# 人才面板需要查询/请求部署相关状态
	if _secondary_panel is EmpireTalentPanel:
		var tp: EmpireTalentPanel = _secondary_panel as EmpireTalentPanel
		tp.set_deployed_state(_deployed_heroes)
		tp.deploy_requested.connect(_on_deploy_requested)
		tp.recall_requested.connect(_on_recall_requested)


func _trigger_reverse() -> void:
	if _current_tween and _current_tween.is_valid():
		_current_tween.kill()
	if _secondary_panel and is_instance_valid(_secondary_panel):
		_secondary_panel.detach_with_fade(TRANSITION_DURATION)
		_secondary_panel = null

	_is_transitioning = true
	_is_expanded = false

	# 解冻子控件
	for c in _frozen_children:
		if is_instance_valid(c):
			c.top_level = false
			if c is Control:
				(c as Control).mouse_filter = Control.MOUSE_FILTER_STOP
	_frozen_children.clear()
	_frozen_state.clear()

	_current_tween = create_tween()
	_current_tween.set_parallel(true)
	_current_tween.set_trans(Tween.TRANS_CUBIC)
	_current_tween.set_ease(Tween.EASE_IN_OUT)

	# 地图淡回
	if _map_root:
		_current_tween.tween_property(_map_root, "modulate:a", 1.0, TRANSITION_DURATION)

	# 所有节点回初始状态
	for node in _initial_state.keys():
		var init: Dictionary = _initial_state[node]
		_current_tween.tween_property(node, "position",     init.position,  TRANSITION_DURATION)
		_current_tween.tween_property(node, "size",         init.size,      TRANSITION_DURATION)
		_current_tween.tween_property(node, "scale",        init.scale,     TRANSITION_DURATION)
		_current_tween.tween_property(node, "pivot_offset", init.pivot,     TRANSITION_DURATION)
		_current_tween.tween_property(node, "modulate",     init.modulate,  TRANSITION_DURATION)

	# 面板内子控件延迟淡回
	var fade_delay := TRANSITION_DURATION - FADE_DURATION
	if _origin_panel:
		for b in _collect_fade_targets(_origin_panel):
			b.modulate.a = 0.0
			_current_tween.tween_property(b, "modulate:a", 1.0, FADE_DURATION).set_delay(fade_delay)

	await _current_tween.finished
	_is_transitioning = false

	# 反向转场结束后，若挂着部署请求则进入部署模式（人才面板触发）
	if _deploy_pending_hero != "":
		_enter_deploy_mode()


# ── 部署系统 ────────────────────────────────────────────────────────────────

func _on_deploy_requested(hero_key: String) -> void:
	# 由人才面板「部署」按钮触发：暂存待部署人才，再走反向转场退回大地图
	_deploy_pending_hero = hero_key
	_trigger_reverse()


func _on_recall_requested(hero_key: String) -> void:
	# 由人才面板「流放」按钮触发：撤销该人才部署，不退回大地图
	if not _deployed_heroes.has(hero_key):
		return
	var node = _deployed_heroes[hero_key]
	_deployed_heroes.erase(hero_key)
	if is_instance_valid(node):
		_refresh_deploy_icons_for(node)


func _enter_deploy_mode() -> void:
	_deploy_mode = true
	for n in _shape_nodes:
		if is_instance_valid(n) and "_faction_id" in n and int(n._faction_id) == PLAYER_FACTION_ID:
			n.set_breathing(true)


func _exit_deploy_mode() -> void:
	if not _deploy_mode and _deploy_pending_hero == "":
		return
	_deploy_mode = false
	_deploy_pending_hero = ""
	_deploy_blank_press = false
	for n in _shape_nodes:
		if is_instance_valid(n):
			n.set_breathing(false)


# 完成部署：人才唯一 → 若已在别处先移走，再插到目标节点。
func _commit_deploy(target_node) -> void:
	var hero_key: String = _deploy_pending_hero
	var prev_node = _deployed_heroes.get(hero_key, null)
	_deployed_heroes[hero_key] = target_node
	if prev_node != null and prev_node != target_node and is_instance_valid(prev_node):
		_refresh_deploy_icons_for(prev_node)
	_refresh_deploy_icons_for(target_node)
	_exit_deploy_mode()


# 重建该地点上方的人才头像横排（按 hero_key 字典序稳定）。
func _refresh_deploy_icons_for(node) -> void:
	if node == null or not is_instance_valid(node):
		return
	var keys: Array = []
	for k in _deployed_heroes.keys():
		if _deployed_heroes[k] == node:
			keys.append(String(k))
	keys.sort()
	var textures: Array = []
	for _k in keys:
		textures.append(DEPLOY_ICON_TEX)
	node.set_deployed_icons(keys, textures)


# ── 英雄数据库 ───────────────────────────────────────────────────────────────

func _load_empire_hero_db() -> void:
	const EMPIRE_HERO_JSON: String = "res://data/empire_hero.json"
	if not FileAccess.file_exists(EMPIRE_HERO_JSON):
		push_warning("EmpireTest: missing " + EMPIRE_HERO_JSON)
		return
	var f := FileAccess.open(EMPIRE_HERO_JSON, FileAccess.READ)
	if f == null:
		return
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	if typeof(parsed) == TYPE_DICTIONARY:
		_empire_hero_db = parsed.get("heroes", {})


# ── 人才头像点击 ─────────────────────────────────────────────────────────────

func _on_hero_icon_clicked(hero_key: String) -> void:
	if _deploy_mode:
		return
	if _selected_hero_key == hero_key:
		# 点同一头像 = 取消选中
		var prev_node = _deployed_heroes.get(_selected_hero_key, null)
		if prev_node != null and is_instance_valid(prev_node):
			prev_node.set_hero_icon_selected(_selected_hero_key, false)
		_selected_hero_key = ""
		if _hero_detail_panel:
			_hero_detail_panel.hide_panel()
	else:
		# 切换：先取消旧选中图标
		if _selected_hero_key != "":
			var prev_node = _deployed_heroes.get(_selected_hero_key, null)
			if prev_node != null and is_instance_valid(prev_node):
				prev_node.set_hero_icon_selected(_selected_hero_key, false)
		_selected_hero_key = hero_key
		if _selected_node != null:
			_selected_node.set_selected(false)
			_selected_node = null
		if _location_panel:
			_location_panel.hide_panel()
		# 选中新图标
		var new_node = _deployed_heroes.get(hero_key, null)
		if new_node != null and is_instance_valid(new_node):
			new_node.set_hero_icon_selected(hero_key, true)
		var hero_data: Dictionary = _empire_hero_db.get(hero_key, {})
		var faction_name: String = ""
		var faction_color: Color = Color("#adb5bd")
		var deployed_node = _deployed_heroes.get(hero_key, null)
		if deployed_node != null and is_instance_valid(deployed_node):
			if "_faction_name" in deployed_node:
				faction_name = String(deployed_node._faction_name)
			if "_fill" in deployed_node:
				faction_color = deployed_node._fill as Color
		if _hero_detail_panel:
			if _hero_detail_panel.is_open():
				_hero_detail_panel.refresh_for(hero_key, hero_data, faction_name, faction_color)
			else:
				_hero_detail_panel.show_for(hero_key, hero_data, faction_name, faction_color)


func _collect_fade_targets(root: Node) -> Array:
	var out: Array = []
	if root.has_meta("transition_skip"):
		return out
	if root is Button or root is Label or root is TextureRect or root is _FactionDot:
		out.append(root)
		return out
	for child in root.get_children():
		if child is Node and child.has_meta("transition_skip"):
			continue
		if child is Button or child is Label or child is TextureRect or child is _FactionDot:
			out.append(child)
		elif child is Node:
			out.append_array(_collect_fade_targets(child))
	return out


static func _disable_mouse_recursive(c: Control) -> void:
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for sub in c.get_children():
		if sub is Control:
			_disable_mouse_recursive(sub)


func _build_side_panel() -> void:
	const BTN_SIZE    := 340.0
	const END_BTN_H   := 140.0
	const GAP         := 12.0
	const RIGHT_MARGIN := 20.0
	const PANEL_W     := 120.0

	# ── SidePanel：Panel 白底+圆角+阴影，与主菜单 LeftNavPnl 同款
	var container := Panel.new()
	container.name = "SidePanel"
	container.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
	container.offset_left   = -(RIGHT_MARGIN + PANEL_W)
	container.offset_right  = -RIGHT_MARGIN
	container.offset_top    = SIDE_BTN_TOP
	container.offset_bottom = -(RIGHT_MARGIN + END_BTN_H + GAP)
	container.add_theme_stylebox_override("panel",
		ThemeFactory.panel(Color.WHITE, Color(1, 1, 1, 0.6), 1, 20, true))
	add_child(container)

	var vbox := VBoxContainer.new()
	vbox.name = "SideVBox"
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left   = 10.0
	vbox.offset_top    = 16.0
	vbox.offset_right  = -10.0
	vbox.offset_bottom = -16.0
	vbox.add_theme_constant_override("separation", 12)
	container.add_child(vbox)

	var side_btn_defs: Array = [
		{"name": "ArmyBtn",    "text": "军\n队"},
		{"name": "TalentBtn",  "text": "人\n才"},
		{"name": "StrategyBtn","text": "方\n略"},
	]
	var btn_styles := ThemeFactory.primary_button_styles()
	for def in side_btn_defs:
		var btn := Button.new()
		btn.name = def.name
		btn.text = def.text
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.size_flags_vertical   = Control.SIZE_EXPAND_FILL
		btn.add_theme_font_size_override("font_size", 26)
		btn.add_theme_color_override("font_color",         Color.WHITE)
		btn.add_theme_color_override("font_hover_color",   Color.WHITE)
		btn.add_theme_color_override("font_pressed_color", Color.WHITE)
		ThemeFactory.apply_button_styles(btn, btn_styles)
		vbox.add_child(btn)

	# ── "结束回合"按钮：单独锚定右下角
	var end_btn := Button.new()
	end_btn.name = "EndTurnBtn"
	end_btn.text = "结束回合"
	end_btn.add_theme_font_size_override("font_size", 26)
	end_btn.add_theme_color_override("font_color",         Color.WHITE)
	end_btn.add_theme_color_override("font_hover_color",   Color.WHITE)
	end_btn.add_theme_color_override("font_pressed_color", Color.WHITE)
	ThemeFactory.apply_button_styles(end_btn, btn_styles)
	end_btn.set_anchor(SIDE_RIGHT,  1.0)
	end_btn.set_anchor(SIDE_LEFT,   1.0)
	end_btn.set_anchor(SIDE_BOTTOM, 1.0)
	end_btn.set_anchor(SIDE_TOP,    1.0)
	end_btn.offset_right  = -RIGHT_MARGIN
	end_btn.offset_left   = -RIGHT_MARGIN - BTN_SIZE
	end_btn.offset_bottom = -RIGHT_MARGIN
	end_btn.offset_top    = -RIGHT_MARGIN - END_BTN_H
	add_child(end_btn)


func _on_shape_clicked(node) -> void:
	# 部署模式：己方地点 = 部署成功；其他地点 = 取消部署模式
	if _deploy_mode:
		if node != null and "_faction_id" in node and int(node._faction_id) == PLAYER_FACTION_ID:
			_commit_deploy(node)
		else:
			_exit_deploy_mode()
		return

	# 选中地点时清除人才选中状态（互斥）
	if _selected_hero_key != "":
		var prev_hero_node = _deployed_heroes.get(_selected_hero_key, null)
		if prev_hero_node != null and is_instance_valid(prev_hero_node):
			prev_hero_node.set_hero_icon_selected(_selected_hero_key, false)
		_selected_hero_key = ""
	if _hero_detail_panel and _hero_detail_panel.is_open():
		_hero_detail_panel.hide_panel()

	if _selected_node == node:
		_selected_node.set_selected(false)
		_selected_node = null
		if _location_panel:
			_location_panel.hide_panel()
	else:
		if _selected_node != null:
			_selected_node.set_selected(false)
		_selected_node = node
		_selected_node.set_selected(true)
		if _location_panel:
			_location_panel.show_for(node)


func _load_map() -> void:
	var file := FileAccess.open(MAP_PATH, FileAccess.READ)
	if file == null:
		push_error("EmpireTest: cannot open " + MAP_PATH)
		return
	var json := JSON.new()
	if json.parse(file.get_as_text()) != OK:
		push_error("EmpireTest: JSON parse error: " + json.get_error_message())
		file.close()
		return
	file.close()
	_build_map(json.get_data())


func _build_map(data: Dictionary) -> void:
	var shapes_data: Array = data.get("shapes", [])
	var connections_data: Array = data.get("connections", [])
	if shapes_data.is_empty():
		return

	# ── 解析势力表 ────────────────────────────────────────────────────────────
	_factions.clear()
	for f in data.get("factions", []):
		_factions.append({
			"id":    int(f.get("id", 0)),
			"name":  String(f.get("name", "中立")),
			"color": Color(String(f.get("color", "#808080"))),
		})
	# 若 JSON 无 factions 字段，补默认中立
	if _factions.is_empty():
		_factions.append({"id": 0, "name": "中立", "color": Color.GRAY})

	# ── 初始化玩家状态 ─────────────────────────────────────────────────────────
	_player_gold = 0
	_player_food = _calc_total_food(shapes_data)
	_refresh_info_panel()

	# ── 连接结束回合按钮 ───────────────────────────────────────────────────────
	var end_btn: Button = get_node_or_null("EndTurnBtn")
	if end_btn and not end_btn.pressed.is_connected(_on_end_turn):
		end_btn.pressed.connect(_on_end_turn.bind(shapes_data))

	var vp: Vector2 = get_viewport_rect().size
	var margin: float = 80.0

	var xs: Array = shapes_data.map(func(s): return float(s.get("x", 0.0)))
	var ys: Array = shapes_data.map(func(s): return float(s.get("y", 0.0)))
	var min_x: float = xs.min();  var max_x: float = xs.max()
	var min_y: float = ys.min();  var max_y: float = ys.max()
	var span_x: float = max(max_x - min_x, 1.0)
	var span_y: float = max(max_y - min_y, 1.0)
	var usable_w: float = vp.x - margin * 2.0
	var usable_h: float = vp.y - margin * 2.0
	var sc: float = min(usable_w / span_x, usable_h / span_y)
	var ox: float = margin + (usable_w - span_x * sc) * 0.5
	var oy: float = margin + (usable_h - span_y * sc) * 0.5

	var id_to_pos: Dictionary = {}
	for s in shapes_data:
		var sid: int = s.get("id", 0)
		var pos := Vector2(
			ox + (float(s.get("x", 0.0)) - min_x) * sc,
			oy + (float(s.get("y", 0.0)) - min_y) * sc
		)
		id_to_pos[sid] = pos

		var node := _MapShapeNode.new()
		var cat_label: String = ""
		if s.get("kind", "") == "square":
			var cat = s.get("category", null)
			if cat != null:
				var cat_int: int = int(cat)
				var cat_map: Dictionary = {1: "大", 2: "商", 3: "农", 4: "军"}
				if cat_map.has(cat_int):
					cat_label = cat_map[cat_int]
		var faction_id: int = int(s.get("faction", 0))
		var faction_color: Color = _faction_color(faction_id)
		var faction_nm: String = _faction_name(faction_id)
		node.init(sid, s.get("kind", "circle"), cat_label, pos, NODE_RADIUS,
				s.get("name", ""), int(s.get("gold", 0)), int(s.get("food", 0)),
				faction_color, faction_nm, faction_id)
		node.clicked.connect(_on_shape_clicked)
		_map_root.add_child(node)
		_shape_nodes.append(node)

	_line_layer.set_data(id_to_pos, connections_data)
	# 地图内容 bounding box（world 坐标，即 _map_root 本地坐标）
	var content_min := Vector2(ox - NODE_RADIUS, oy - NODE_RADIUS)
	var content_max := Vector2(ox + span_x * sc + NODE_RADIUS, oy + span_y * sc + NODE_RADIUS)
	_map_world_origin = content_min
	_map_world_size   = content_max - content_min
	_line_layer.set_bounds(content_min, content_max)


# 根据势力 id 查颜色，找不到返回 GRAY
func _faction_color(faction_id: int) -> Color:
	for f in _factions:
		if f.id == faction_id:
			return f.color
	return Color.GRAY


func _faction_name(faction_id: int) -> String:
	for f in _factions:
		if f.id == faction_id:
			return f.name
	return "中立"


# 计算玩家势力（PLAYER_FACTION_ID）所有地点的粮草供应量总值
func _calc_total_food(shapes_data: Array) -> int:
	var total: int = 0
	for s in shapes_data:
		if int(s.get("faction", 0)) == PLAYER_FACTION_ID:
			total += int(s.get("food", 0))
	return total


# 计算玩家势力（PLAYER_FACTION_ID）所有地点的资金产出总值
func _calc_player_gold_income(shapes_data: Array) -> int:
	var total: int = 0
	for s in shapes_data:
		if int(s.get("faction", 0)) == PLAYER_FACTION_ID:
			total += int(s.get("gold", 0))
	return total


func _on_end_turn(shapes_data: Array) -> void:
	_player_gold += _calc_player_gold_income(shapes_data)
	_player_food = _calc_total_food(shapes_data)
	_refresh_info_panel()


func _refresh_info_panel() -> void:
	if _info_faction_dot == null:
		return
	var faction_color := _faction_color(PLAYER_FACTION_ID)
	var faction_name  := _faction_name(PLAYER_FACTION_ID)
	_info_faction_dot.init(faction_color)
	_info_faction_dot.queue_redraw()
	if _info_faction_lbl:
		_info_faction_lbl.text = faction_name
	if _info_food_lbl:
		_info_food_lbl.text = "粮草：" + str(_player_food)
	if _info_gold_lbl:
		_info_gold_lbl.text = "资金：" + str(_player_gold)


# ── 输入：平移 + 滚轮缩放 + 双指缩放 ─────────────────────────────────────────
func _gui_input(event: InputEvent) -> void:
	# 滚轮缩放
	if event is InputEventMouseButton and event.pressed:
		if event.button_index == MOUSE_BUTTON_WHEEL_UP:
			_zoom_at(event.position, ZOOM_STEP)
			accept_event()
			return
		elif event.button_index == MOUSE_BUTTON_WHEEL_DOWN:
			_zoom_at(event.position, 1.0 / ZOOM_STEP)
			accept_event()
			return

	# 部署模式下的空白点击取消：按下记起点，松开时未拖动则取消。
	# 子节点（_MapShapeNode）的点击会被自身 _gui_input 吃掉，事件不会冒到此处。
	if _deploy_mode and event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		var mb := event as InputEventMouseButton
		if mb.pressed:
			_deploy_blank_press = true
			_deploy_blank_press_pos = mb.position
		else:
			if _deploy_blank_press and mb.position.distance_to(_deploy_blank_press_pos) <= DEPLOY_BLANK_TAP_THRESHOLD:
				_exit_deploy_mode()
			_deploy_blank_press = false

func _input(event: InputEvent) -> void:
	if _is_expanded or _is_transitioning:
		return
	# 左键拖拽平移（全局输入，不受子节点遮挡影响）
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_pan_active = true
			_pan_start_mouse = event.position
			_pan_start_pos = _map_root.position
		else:
			_pan_active = false

	elif event is InputEventMouseMotion and _pan_active and (event.button_mask & MOUSE_BUTTON_MASK_LEFT):
		var delta: Vector2 = event.position - _pan_start_mouse
		if delta.length() > 4.0:
			_map_root.position = _clamp_pan(_pan_start_pos + delta)

	elif event is InputEventMagnifyGesture:
		_zoom_at(event.position, event.factor)
		accept_event()

	elif event is InputEventPanGesture:
		_map_root.position = _clamp_pan(_map_root.position - event.delta * 2.0)
		accept_event()

	# ── 手机双指捏合缩放 ──────────────────────────────────────────────────────
	elif event is InputEventScreenTouch:
		if event.pressed:
			_touch_points[event.index] = event.position
		else:
			_touch_points.erase(event.index)
			if _touch_points.size() < 2:
				_pinch_active = false
				# 单指抬起时重置平移起点，避免跳变
				if _touch_points.size() == 1:
					var remaining_pos: Vector2 = _touch_points.values()[0]
					_pan_start_mouse = remaining_pos
					_pan_start_pos = _map_root.position
					_pan_active = true
				else:
					_pan_active = false

	elif event is InputEventScreenDrag:
		_touch_points[event.index] = event.position
		var fingers: Array = _touch_points.values()

		if fingers.size() >= 2:
			var p0: Vector2 = fingers[0]
			var p1: Vector2 = fingers[1]
			var cur_dist: float = p0.distance_to(p1)
			var cur_center: Vector2 = (p0 + p1) * 0.5

			if _pinch_active:
				# 缩放
				if _pinch_last_dist > 0.0:
					var factor: float = cur_dist / _pinch_last_dist
					_zoom_at(cur_center, factor)
				# 双指平移
				var pan_delta: Vector2 = cur_center - _pinch_last_center
				_map_root.position = _clamp_pan(_map_root.position + pan_delta)
			else:
				_pinch_active = true

			_pinch_last_dist = cur_dist
			_pinch_last_center = cur_center
			_pan_active = false
			accept_event()

		elif fingers.size() == 1 and _pan_active:
			var delta: Vector2 = event.position - _pan_start_mouse
			if delta.length() > 4.0:
				_map_root.position = _clamp_pan(_pan_start_pos + delta)


func _zoom_at(screen_pos: Vector2, factor: float) -> void:
	var vp: Vector2 = get_viewport_rect().size
	var old_scale: float = _map_root.scale.x
	# 缩放下限：地图全貌刚好适配视口（取较小轴，保证全部可见）
	var min_scale: float = ZOOM_MIN
	if _map_world_size.x > 0 and _map_world_size.y > 0:
		min_scale = max(ZOOM_MIN,
			min(vp.x / _map_world_size.x, vp.y / _map_world_size.y))
	var new_scale: float = clamp(old_scale * factor, min_scale, ZOOM_MAX)
	var real_factor: float = new_scale / old_scale
	var new_pos: Vector2 = screen_pos + (_map_root.position - screen_pos) * real_factor
	_map_root.position = _clamp_pan(new_pos, new_scale)
	_map_root.scale = Vector2(new_scale, new_scale)


# 限制平移：屏幕中心 (vp/2) 始终在地图内容范围内
# 内容左边屏幕坐标 = pos + origin*sc，右边 = pos + (origin+size)*sc
# 要求左边 <= vp/2 <= 右边：
#   pos <= vp/2 - origin*sc
#   pos >= vp/2 - (origin+size)*sc
func _clamp_pan(pos: Vector2, sc: float = -1.0) -> Vector2:
	var vp: Vector2 = get_viewport_rect().size
	if sc < 0.0:
		sc = _map_root.scale.x
	if _map_world_size == Vector2.ZERO:
		return pos
	var half: Vector2 = vp * 0.5
	var max_pos := half - _map_world_origin * sc
	var min_pos := half - (_map_world_origin + _map_world_size) * sc
	return Vector2(clamp(pos.x, min_pos.x, max_pos.x), clamp(pos.y, min_pos.y, max_pos.y))


# ── connection line layer ─────────────────────────────────────────────────────
class _LineLayer extends Node2D:
	var _id_to_pos: Dictionary = {}
	var _connections: Array = []
	var _bounds_min: Vector2 = Vector2.ZERO
	var _bounds_max: Vector2 = Vector2.ZERO

	func set_data(id_to_pos: Dictionary, connections: Array) -> void:
		_id_to_pos = id_to_pos
		_connections = connections
		queue_redraw()

	func set_bounds(bmin: Vector2, bmax: Vector2) -> void:
		_bounds_min = bmin
		_bounds_max = bmax
		queue_redraw()

	func _draw() -> void:
		for conn in _connections:
			var a: Vector2 = _id_to_pos.get(int(conn.get("from", -1)), Vector2.ZERO)
			var b: Vector2 = _id_to_pos.get(int(conn.get("to",   -1)), Vector2.ZERO)
			draw_line(a, b, Color("#7ec8e3"), 2.0, true)


# ── individual map shape node ─────────────────────────────────────────────────
class _MapShapeNode extends Control:
	signal clicked(node)

	var _id: int
	var _kind: String
	var _cat_label: String = ""
	var _radius: float
	var _fill: Color
	var _selected: bool = false
	var _name_text: String = ""
	var _gold: int = 0
	var _food: int = 0
	var _faction_name: String = "中立"
	var _faction_id: int = 0

	# 呼吸缩放
	var _breathing_tween: Tween = null
	const BREATH_SCALE: Vector2 = Vector2(1.18, 1.18)
	const BREATH_PERIOD: float = 0.9

	# 已部署人才头像横排（节点上方）
	var _deploy_icon_row: HBoxContainer = null
	const DEPLOY_ICON_SIZE: Vector2 = Vector2(36, 36)
	const DEPLOY_ICON_GAP: int = 4
	const DEPLOY_ICON_OFFSET_Y: float = 14.0   # 节点上沿与图标底部的间距

	func init(id: int, kind: String, cat_label: String, center: Vector2, radius: float,
			name_text: String = "", gold: int = 0, food: int = 0,
			faction_color: Color = Color.GRAY,
			faction_name: String = "中立", faction_id: int = 0) -> void:
		_id = id
		_kind = kind
		_cat_label = cat_label
		_radius = radius
		_name_text = name_text
		_gold = gold
		_food = food
		_fill = faction_color
		_faction_name = faction_name
		_faction_id = faction_id
		var d: float = radius * 2.0
		size = Vector2(d, d)
		position = center - Vector2(radius, radius)
		# 中心枢轴：让 scale 缩放围绕节点几何中心
		pivot_offset = size * 0.5

	func _ready() -> void:
		if _kind == "square" and _cat_label != "":
			var lbl := Label.new()
			lbl.text = _cat_label
			lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
			lbl.add_theme_font_size_override("font_size", int(_radius * 1.0))
			lbl.add_theme_color_override("font_color", Color.WHITE)
			lbl.add_theme_font_override("font", load("res://assets/NotoSerifCJKsc-Regular.otf"))
			lbl.size = Vector2(_radius * 2.0, _radius * 2.0)
			lbl.position = Vector2.ZERO
			lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
			add_child(lbl)

	func set_selected(val: bool) -> void:
		_selected = val
		queue_redraw()

	# 设置指定 hero_key 头像的选中状态（用于 EmpireTest 同步视觉）。
	func set_hero_icon_selected(hero_key: String, selected: bool) -> void:
		if _deploy_icon_row == null:
			return
		for child in _deploy_icon_row.get_children():
			if "_hero_key" in child and String(child._hero_key) == hero_key:
				if child.has_method("set_selected_state"):
					child.set_selected_state(selected)
				break

	# 启停呼吸缩放：scale 在 1.0 ↔ BREATH_SCALE 之间循环。
	func set_breathing(active: bool) -> void:
		if active:
			if _breathing_tween != null and _breathing_tween.is_valid():
				return
			scale = Vector2.ONE
			_breathing_tween = create_tween().set_loops()
			_breathing_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
			_breathing_tween.tween_property(self, "scale", BREATH_SCALE, BREATH_PERIOD * 0.5)
			_breathing_tween.tween_property(self, "scale", Vector2.ONE,  BREATH_PERIOD * 0.5)
		else:
			if _breathing_tween != null and _breathing_tween.is_valid():
				_breathing_tween.kill()
			_breathing_tween = null
			scale = Vector2.ONE

	# 重建节点上方的人才头像横排。
	# hero_keys 和 textures 平行数组，长度相同。
	# 图标可点击，点击后通过父链找到 EmpireTest 调用 _on_hero_icon_clicked。
	func set_deployed_icons(hero_keys: Array, textures: Array) -> void:
		if _deploy_icon_row == null:
			_deploy_icon_row = HBoxContainer.new()
			_deploy_icon_row.name = "DeployIconRow"
			_deploy_icon_row.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_deploy_icon_row.add_theme_constant_override("separation", DEPLOY_ICON_GAP)
			add_child(_deploy_icon_row)
		for c in _deploy_icon_row.get_children():
			c.queue_free()
		var n: int = min(hero_keys.size(), textures.size())
		if n == 0:
			_deploy_icon_row.visible = false
			return
		_deploy_icon_row.visible = true
		for i in n:
			var btn := _HeroIconBtn.new()
			btn.init(hero_keys[i], textures[i], DEPLOY_ICON_SIZE)
			_deploy_icon_row.add_child(btn)
		var row_w: float = float(n) * DEPLOY_ICON_SIZE.x + float(max(0, n - 1)) * float(DEPLOY_ICON_GAP)
		_deploy_icon_row.size = Vector2(row_w, DEPLOY_ICON_SIZE.y)
		_deploy_icon_row.position = Vector2(
			(size.x - row_w) * 0.5,
			-DEPLOY_ICON_SIZE.y - DEPLOY_ICON_OFFSET_Y
		)

	func _draw() -> void:
		var r: float = _radius
		var c: Vector2 = Vector2(r, r)
		var outline: Color = Color("#ffe066") if _selected else Color.WHITE

		match _kind:
			"circle":
				draw_circle(c, r, _fill)
				draw_arc(c, r, 0.0, TAU, 48, outline, 2.0, true)
			"square":
				draw_rect(Rect2(Vector2.ZERO, size), _fill)
				draw_rect(Rect2(Vector2.ZERO, size), outline, false, 2.0)
			"triangle":
				var pts := PackedVector2Array([
					c + Vector2(0.0, -r),
					c + Vector2(-r,  r),
					c + Vector2( r,  r),
				])
				draw_colored_polygon(pts, _fill)
				draw_polyline(PackedVector2Array([pts[0], pts[1], pts[2], pts[0]]),
					outline, 2.0, true)

	var _last_click_frame: int = -1

	func _gui_input(event: InputEvent) -> void:
		var is_touch: bool = event is InputEventScreenTouch and (event as InputEventScreenTouch).pressed and (event as InputEventScreenTouch).index == 0
		var is_mouse: bool = event is InputEventMouseButton and (event as InputEventMouseButton).button_index == MOUSE_BUTTON_LEFT and (event as InputEventMouseButton).pressed
		if not is_touch and not is_mouse:
			return
		# 同一帧内两种事件只响应一次（应对 emulate_mouse_from_touch 顺序不定问题）
		var cur_frame: int = Engine.get_process_frames()
		if cur_frame == _last_click_frame:
			get_viewport().set_input_as_handled()
			return
		_last_click_frame = cur_frame
		clicked.emit(self)
		get_viewport().set_input_as_handled()


# ── 势力色块：纯色圆 + 细白描边 ──────────────────────────────────────────────
class _FactionDot extends Control:
	var _color: Color = Color.GREEN

	func init(c: Color) -> void:
		_color = c
		mouse_filter = Control.MOUSE_FILTER_IGNORE

	func _draw() -> void:
		var r: float = min(size.x, size.y) * 0.5
		var c := Vector2(size.x * 0.5, size.y * 0.5)
		draw_circle(c, r, _color)
		draw_arc(c, r, 0.0, TAU, 32, Color(1, 1, 1, 0.7), 1.5, true)


# ── 人才头像按钮：可点击的图标，点击后沿父链回调 EmpireTest ──────────────────────
class _HeroIconBtn extends Control:
	var _hero_key: String = ""
	const OUTLINE_NORMAL:   Color = Color(1, 1, 1, 0.55)
	const OUTLINE_HOVER:    Color = Color(0.55, 0.9, 1.0, 0.9)
	const OUTLINE_PRESSED:  Color = Color(1, 0.6, 0.1, 1.0)
	const OUTLINE_SELECTED: Color = Color("#ffe066")

	var _tex: Texture2D = null
	var _icon_size: Vector2 = Vector2(36, 36)
	var _hover: bool = false
	var _pressing: bool = false
	var _is_selected: bool = false
	var _last_click_frame: int = -1

	func init(hero_key: String, tex: Texture2D, icon_size: Vector2) -> void:
		_hero_key = hero_key
		_tex = tex
		_icon_size = icon_size
		custom_minimum_size = icon_size
		size = icon_size
		mouse_filter = Control.MOUSE_FILTER_STOP

	func set_selected_state(val: bool) -> void:
		_is_selected = val
		queue_redraw()

	func _draw() -> void:
		if _tex:
			draw_texture_rect(_tex, Rect2(Vector2.ZERO, _icon_size), false)
		var outline_col: Color
		if _pressing:
			outline_col = OUTLINE_PRESSED
		elif _is_selected:
			outline_col = OUTLINE_SELECTED
		elif _hover:
			outline_col = OUTLINE_HOVER
		else:
			outline_col = OUTLINE_NORMAL
		draw_rect(Rect2(Vector2.ZERO, _icon_size), outline_col, false, 2.0)

	func _gui_input(event: InputEvent) -> void:
		if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			_pressing = event.pressed
			queue_redraw()
			# press 和 release 都阻断，防止冒泡到父 _MapShapeNode 触发地点选中逻辑
			get_viewport().set_input_as_handled()
			if not event.pressed:
				var cur_frame := Engine.get_process_frames()
				if cur_frame != _last_click_frame:
					_last_click_frame = cur_frame
					_fire_click()
		elif event is InputEventScreenTouch and event.index == 0:
			_pressing = event.pressed
			queue_redraw()
			get_viewport().set_input_as_handled()
			if not event.pressed:
				var cur_frame := Engine.get_process_frames()
				if cur_frame != _last_click_frame:
					_last_click_frame = cur_frame
					_fire_click()
		elif event is InputEventMouseMotion:
			var was_hover: bool = _hover
			_hover = Rect2(Vector2.ZERO, _icon_size).has_point(event.position)
			if _hover != was_hover:
				queue_redraw()

	func _fire_click() -> void:
		# 沿父链找到第一个有 _on_hero_icon_clicked 方法的节点（即 EmpireTest）
		var p: Node = get_parent()
		while p != null:
			if p.has_method("_on_hero_icon_clicked"):
				p._on_hero_icon_clicked(_hero_key)
				return
			p = p.get_parent()
