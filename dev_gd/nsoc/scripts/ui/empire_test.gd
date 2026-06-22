class_name EmpireTest
extends Control

# 进入前由调用方写入目标地图路径；空串则回退到默认测试地图。
static var pending_map_path: String = ""
# 载入存档时由调用方（YanyiPanel）写入槽 id；空串 = 普通新游戏。
static var pending_load_slot: String = ""

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
# 流放名单（仅本次运行有效，重启后人才复现）。hero_key → true。
# 被流放的人才：从地图抹除、不出现在轮播中、卡组清空（单位放回公共牌池）。
var _exiled_heroes: Dictionary = {}
# 完整人才池（与 EmpireCarousel.HERO_NAMES 对齐，过滤后即 alive 池）
const ALL_HERO_KEYS: Array = ["A", "B", "C"]
# 人才面板最后一次查看的 hero_key。
# 空串 = 从未打开过 → 打开时默认定位到第一个未流放人才。
# 退出面板时记录，再进则恢复；若上次记录者已被流放，退化回第一个未流放者。
var _talent_last_hero: String = ""

# 行棋（移动）系统
# _connections_data：JSON 中 connections 数组（{from,to}），用于相邻判断
# _id_to_node：node_id → _MapShapeNode 索引
# _pending_moves：hero_key → 目标 _MapShapeNode。
#   拖放成功后写入，本回合内该 hero 不可再拖。结束回合时统一提交。
var _connections_data: Array = []
var _id_to_node: Dictionary = {}
var _pending_moves: Dictionary = {}

# 出征系统（势力不同的拖入 = 出征意向；支持多线出征）
# _pending_campaigns：target_id → Array[hero_key]，按拖入顺序。第一项 = 主控将领。
# _pending_campaign_sources：hero_key → 该 hero 出发前所在的 source node id，
#   战斗失败后用来把 hero 还原到原位。
# _battle_select_mode：结束回合按下后置 true，等待玩家点击战斗方框。
#   多场出征：每打完一场目标移出 _pending_campaigns；若仍非空则保持模式。
# _faction_overrides：node_id → faction_id。占领后写入。
# 容量上限：仅约束 hostile target（敌方/中立目标）。
var _pending_campaigns: Dictionary = {}
var _pending_campaign_sources: Dictionary = {}
var _battle_select_mode: bool = false
var _faction_overrides: Dictionary = {}

const CAMPAIGN_CAPACITY_BY_KIND: Dictionary = {
	"triangle": 1,  # 关隘
	"circle":   2,  # 村镇
	"square":   3,  # 城市
}

# 当前拖拽状态
var _drag_active: bool = false
var _drag_hero_key: String = ""
var _drag_source_node = null
var _drag_ghost: Control = null
var _drag_adjacent: Array = []  # 当前呼吸高亮中的相邻节点

const DRAG_START_THRESHOLD: float = 8.0
const PENDING_GHOST_ALPHA: float = 0.45
const DRAGGING_GHOST_ALPHA: float = 0.7
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

# 存读档相关
var _turn_number: int = 0
var _current_map_path: String = ""   # _load_map 时记录，供快照使用


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
			{"label": "存档", "action": Callable(self, "_on_manual_save_pressed"), "embed": true},
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
	# 统一注入未流放人才池，供 carousel 过滤 / 流放按钮置灰判断
	if _secondary_panel.has_method("set_alive_pool"):
		_secondary_panel.set_alive_pool(_alive_hero_keys())
	# 人才面板：恢复上次查看的人才（首次打开则定位到第一个未流放者）
	if _secondary_panel is EmpireTalentPanel:
		var alive := _alive_hero_keys()
		var initial: String = _talent_last_hero if (not _talent_last_hero.is_empty() and alive.has(_talent_last_hero)) else (String(alive[0]) if not alive.is_empty() else "")
		if not initial.is_empty():
			(_secondary_panel as EmpireTalentPanel).goto_hero(initial)


func _trigger_reverse() -> void:
	# 人才面板关闭前：记录当前查看的 hero_key，下次打开时恢复
	if _secondary_panel is EmpireTalentPanel and is_instance_valid(_secondary_panel):
		var car := (_secondary_panel as EmpireTalentPanel).get_node_or_null("HeroPnl/Carousel") as EmpireCarousel
		if car:
			_talent_last_hero = car.current_hero_key()
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
	# 由人才面板「流放」按钮触发：
	#   1) 从地图抹去该人才
	#   2) 加入流放名单（轮播过滤）
	#   3) 清空其军队卡组（下属单位放回公共牌池）
	#   4) 若被流放者为当前 selected_hero，切到首个未流放者
	#   5) 触发反向转场关闭二级人才面板
	# 拒绝流放最后一人。
	if not _deployed_heroes.has(hero_key):
		return
	if _alive_hero_keys().size() <= 1:
		return

	var node = _deployed_heroes[hero_key]
	_deployed_heroes.erase(hero_key)
	if is_instance_valid(node):
		_refresh_deploy_icons_for(node)

	_exiled_heroes[hero_key] = true

	EmpireDeckStorage.save_deck(hero_key, {}, [], "no_sort")

	if EmpireDeckStorage.get_selected_hero() == hero_key:
		var new_alive: Array = _alive_hero_keys()
		if not new_alive.is_empty():
			EmpireDeckStorage.save_selected_hero(String(new_alive[0]))

	_trigger_reverse()


# 返回当前未流放的人才 key 列表，保持 ALL_HERO_KEYS 顺序。
func _alive_hero_keys() -> Array:
	var out: Array = []
	for k in ALL_HERO_KEYS:
		if not _exiled_heroes.has(k):
			out.append(k)
	return out


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
	# 实体：在此节点 deployed 且没有 pending move/campaign 的英雄
	# 虚影：pending_moves 目标 / pending_campaigns 任一目标 是此节点的英雄
	var key_flag: Dictionary = {}  # hero_key → is_ghost
	# 收集"已被分派出征/行棋"的 hero set，用于过滤实体
	var dispatched: Dictionary = {}
	for k in _pending_moves.keys():
		dispatched[String(k)] = true
	for tid in _pending_campaigns.keys():
		for k in _pending_campaigns[tid]:
			dispatched[String(k)] = true

	for k in _deployed_heroes.keys():
		var ks: String = String(k)
		if _deployed_heroes[k] == node and not dispatched.has(ks):
			key_flag[ks] = false
	for k in _pending_moves.keys():
		var ks: String = String(k)
		if _pending_moves[k] == node:
			key_flag[ks] = true
	# 出征虚影：所有指向本节点的 hero 都显示为 ghost
	var node_id: int = int(node._id)
	if _pending_campaigns.has(node_id):
		for k in _pending_campaigns[node_id]:
			key_flag[String(k)] = true

	var keys: Array = key_flag.keys()
	keys.sort()
	var textures: Array = []
	var ghost_flags: Array = []
	for k in keys:
		textures.append(DEPLOY_ICON_TEX)
		ghost_flags.append(bool(key_flag[k]))
	node.set_deployed_icons(keys, textures, ghost_flags)


# 根据 connections 返回与 node 直接相邻的所有 _MapShapeNode。
func _get_adjacent_nodes(node) -> Array:
	if node == null or not is_instance_valid(node):
		return []
	var sid: int = int(node._id)
	var out: Array = []
	for conn in _connections_data:
		var f: int = int(conn.get("from", -1))
		var t: int = int(conn.get("to", -1))
		var other: int = -1
		if f == sid:
			other = t
		elif t == sid:
			other = f
		if other >= 0 and _id_to_node.has(other):
			var adj = _id_to_node[other]
			if is_instance_valid(adj) and not out.has(adj):
				out.append(adj)
	return out


# 返回某地点的驻军列表：仅"实际部署在此节点 且 未在 pending_moves 中"的人才。
# 虚影人才（无论起点或终点）一律不计入。
# 返回每项：{"name": String, "level": int}（取自 empire_hero.json）
func _compute_garrison_for(node) -> Array:
	var out: Array = []
	if node == null or not is_instance_valid(node):
		return out
	var keys: Array = []
	for k in _deployed_heroes.keys():
		var ks: String = String(k)
		if _deployed_heroes[k] == node and not _pending_moves.has(ks):
			keys.append(ks)
	keys.sort()
	for ks in keys:
		var hd: Dictionary = _empire_hero_db.get(ks, {})
		out.append({
			"name": String(hd.get("display_name", ks)),
			"level": int(hd.get("level", 1)),
		})
	return out


# 命中测试：找到全局坐标 global_pos 下的 _MapShapeNode；无则返回 null。
# 地图有缩放，必须把全局坐标转换到节点本地空间后再做矩形命中，
# 否则 Rect2(global_position, size) 在缩放时尺寸不匹配。
func _find_node_at(global_pos: Vector2):
	for n in _shape_nodes:
		if not is_instance_valid(n):
			continue
		var local_pos: Vector2 = n.get_global_transform().affine_inverse() * global_pos
		if Rect2(Vector2.ZERO, n.size).has_point(local_pos):
			return n
	return null


# ── 行棋：头像拖拽到相邻地点 ─────────────────────────────────────────────────
# _HeroIconBtn 在按下 + 移动超过阈值后通过父链调用此方法。
# 拖拽过程中：
#   - 起点头像设为虚（_HeroIconBtn.set_ghost）
#   - 创建跟随鼠标的虚影 _drag_ghost
#   - 相邻节点呼吸高亮
# 拖拽结束（_input 捕获 LMB 释放）：见 _on_hero_drag_end。
func _on_hero_drag_start(hero_key: String, source_node, global_start_pos: Vector2) -> void:
	if _deploy_mode or _drag_active:
		return
	if _pending_moves.has(hero_key):
		return  # 本回合已经定下移动，禁止再拖
	if source_node == null or not is_instance_valid(source_node):
		return
	_drag_active = true
	_drag_hero_key = hero_key
	_drag_source_node = source_node
	# 立即取消地图平移（_input 先于 GUI dispatch 执行，图标按下那帧 _pan_active 可能已被激活）
	_pan_active = false

	# 相邻高亮（呼吸缩放复用部署模式的实现）
	_drag_adjacent.clear()
	for adj in _get_adjacent_nodes(source_node):
		adj.set_breathing(true)
		_drag_adjacent.append(adj)

	# 跟随鼠标的虚影图标
	_drag_ghost = TextureRect.new()
	_drag_ghost.texture = DEPLOY_ICON_TEX
	_drag_ghost.modulate.a = DRAGGING_GHOST_ALPHA
	_drag_ghost.size = _MapShapeNode.DEPLOY_ICON_SIZE
	_drag_ghost.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_drag_ghost.top_level = true
	_drag_ghost.z_index = 1000
	add_child(_drag_ghost)
	_drag_ghost.global_position = global_start_pos - _drag_ghost.size * 0.5

	# 起点头像变虚
	if source_node.has_method("set_hero_icon_ghost"):
		source_node.set_hero_icon_ghost(hero_key, true)


func _on_hero_drag_end(global_pos: Vector2) -> void:
	if not _drag_active:
		return
	var target = _find_node_at(global_pos)
	var is_adjacent: bool = target != null and _drag_adjacent.has(target)
	var is_valid: bool = false
	var is_campaign_drop: bool = false

	if is_adjacent:
		var tgt_faction: int = int(target._faction_id)
		if tgt_faction == PLAYER_FACTION_ID:
			# 同势力：普通行棋
			is_valid = true
		else:
			# 势力不同（含中立）：出征
			# 容量校验：按 target 的 kind 决定上限；hero 已在该目标列表中视作"重复"，允许（先移除再加，等同覆盖）
			var tid: int = int(target._id)
			var cap: int = int(CAMPAIGN_CAPACITY_BY_KIND.get(String(target._kind), 1))
			var existing: Array = _pending_campaigns.get(tid, [])
			var already_in_target: bool = existing.has(_drag_hero_key)
			if already_in_target or existing.size() < cap:
				is_valid = true
				is_campaign_drop = true

	if is_valid:
		# 同 hero 的旧 pending 状态全部清理（普通行棋 + 任意出征列表）
		_remove_hero_from_all_pending(_drag_hero_key)
		if is_campaign_drop:
			var tid: int = int(target._id)
			var arr: Array = _pending_campaigns.get(tid, [])
			arr.append(_drag_hero_key)
			_pending_campaigns[tid] = arr
			# 记录该 hero 出发前的源节点（_deployed_heroes 仍指向出发位置）
			var src_node = _deployed_heroes.get(_drag_hero_key, _drag_source_node)
			if src_node and is_instance_valid(src_node) and "_id" in src_node:
				_pending_campaign_sources[_drag_hero_key] = int(src_node._id)
		else:
			_pending_moves[_drag_hero_key] = target

	# 起点头像若未被刷新移除则恢复实（失败时）；成功时下面 refresh 会重建为"无"
	if _drag_source_node and is_instance_valid(_drag_source_node):
		if _drag_source_node.has_method("set_hero_icon_ghost"):
			_drag_source_node.set_hero_icon_ghost(_drag_hero_key, false)

	# 清相邻呼吸
	for adj in _drag_adjacent:
		if is_instance_valid(adj):
			adj.set_breathing(false)
	_drag_adjacent.clear()

	# 销毁跟随虚影
	if _drag_ghost and is_instance_valid(_drag_ghost):
		_drag_ghost.queue_free()
	_drag_ghost = null

	# 刷新涉及节点：起点 + 目标 + （旧 pending 的目标也已清理，需一并刷新）
	var refresh_set: Dictionary = {}
	if _drag_source_node and is_instance_valid(_drag_source_node):
		refresh_set[_drag_source_node] = true
	if is_valid and not refresh_set.has(target):
		refresh_set[target] = true
	# 全量保险刷新（量级小，可忽略开销）
	for n in _shape_nodes:
		if is_instance_valid(n) and not refresh_set.has(n):
			refresh_set[n] = true
	for n in refresh_set.keys():
		_refresh_deploy_icons_for(n)

	_drag_active = false
	_drag_hero_key = ""
	_drag_source_node = null


# 把 hero 从所有 pending 状态中清除：普通行棋表 + 所有出征列表 + 出征源记录。
# 用于重新拖拽前的"擦除旧约定"。
func _remove_hero_from_all_pending(hero_key: String) -> void:
	_pending_moves.erase(hero_key)
	var to_remove_keys: Array = []
	for tid in _pending_campaigns.keys():
		var arr: Array = _pending_campaigns[tid]
		var idx: int = arr.find(hero_key)
		if idx >= 0:
			arr.remove_at(idx)
		if arr.is_empty():
			to_remove_keys.append(tid)
		else:
			_pending_campaigns[tid] = arr
	for tid in to_remove_keys:
		_pending_campaigns.erase(tid)
	_pending_campaign_sources.erase(hero_key)


# 回合结束统一提交所有待生效移动：虚影变实，hero 解除本回合的移动锁定。
func _commit_pending_moves() -> void:
	if _pending_moves.is_empty():
		return
	var affected: Dictionary = {}
	for hero_key in _pending_moves.keys():
		var target = _pending_moves[hero_key]
		var prev = _deployed_heroes.get(hero_key, null)
		_deployed_heroes[hero_key] = target
		if prev and is_instance_valid(prev):
			affected[prev] = true
		if target and is_instance_valid(target):
			affected[target] = true
	_pending_moves.clear()
	for n in affected.keys():
		_refresh_deploy_icons_for(n)




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
	# 战斗选择模式：仅当点击的是某个 pending_campaigns 目标时进入战斗
	if _battle_select_mode:
		if node != null and "_id" in node:
			var nid: int = int(node._id)
			if _pending_campaigns.has(nid):
				_launch_empire_battle(nid)
		return

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
			_location_panel.show_for(node, _compute_garrison_for(node))


func _load_map() -> void:
	var path: String = EmpireTest.pending_map_path if EmpireTest.pending_map_path != "" else MAP_PATH
	EmpireTest.pending_map_path = ""
	_current_map_path = path
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_error("EmpireTest: cannot open " + path)
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
		_id_to_node[sid] = node

	_connections_data = connections_data
	_line_layer.set_data(id_to_pos, connections_data)
	# 地图内容 bounding box（world 坐标，即 _map_root 本地坐标）
	var content_min := Vector2(ox - NODE_RADIUS, oy - NODE_RADIUS)
	var content_max := Vector2(ox + span_x * sc + NODE_RADIUS, oy + span_y * sc + NODE_RADIUS)
	_map_world_origin = content_min
	_map_world_size   = content_max - content_min
	_line_layer.set_bounds(content_min, content_max)

	# 帝国战斗回流：恢复战斗前快照、应用结果、刷新 UI
	_restore_empire_state_if_any()

	# 存档载入 / 新游戏分支（仅当非战斗回流时生效）
	if Game.empire_state.is_empty():
		if EmpireTest.pending_load_slot != "":
			var slot_id: String = EmpireTest.pending_load_slot
			EmpireTest.pending_load_slot = ""
			_apply_save_slot(slot_id)
		else:
			# 新游戏：清空军队缓存（避免继承上次的卡组配置）
			EmpireDeckStorage.reset_session()


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
	if _battle_select_mode:
		return
	_commit_pending_moves()
	_player_gold += _calc_player_gold_income_runtime()
	_player_food = _calc_total_food_runtime()
	_turn_number += 1
	_refresh_info_panel()
	# 多线出征：置灰按钮，所有出征目标节点显示外框呼吸方框
	if not _pending_campaigns.is_empty():
		_enter_battle_select_mode()
	else:
		# 回合结束自动存档（无出征时立即写；有出征在 _exit_battle_select_mode 后写）
		_write_save_slot(EmpireSaveStorage.SLOT_AUTO)


# 进入/恢复战斗选择模式：禁用结束回合按钮，所有 _pending_campaigns 目标显示外框呼吸。
# 单场战斗结束后若仍有剩余目标，也由本方法重新点亮剩余目标。
func _enter_battle_select_mode() -> void:
	_battle_select_mode = true
	var btn: Button = get_node_or_null("EndTurnBtn")
	if btn:
		btn.disabled = true
	for tid in _pending_campaigns.keys():
		var n = _id_to_node.get(int(tid), null)
		if n and is_instance_valid(n) and n.has_method("set_campaign_frame"):
			n.set_campaign_frame(true)


# 退出战斗选择模式（所有出征已结算）。重置按钮可点击 + 关闭所有方框。
func _exit_battle_select_mode() -> void:
	var was_active: bool = _battle_select_mode
	_battle_select_mode = false
	for n in _shape_nodes:
		if is_instance_valid(n) and n.has_method("set_campaign_frame"):
			n.set_campaign_frame(false)
	var btn: Button = get_node_or_null("EndTurnBtn")
	if btn:
		btn.disabled = false
	# 出征全部结算完毕 → 写自动存档
	if was_active:
		_write_save_slot(EmpireSaveStorage.SLOT_AUTO)


# 计算玩家势力当前所有持有地点的资源（按运行时 _shape_nodes._faction_id，含战斗后占领）
func _calc_total_food_runtime() -> int:
	var total: int = 0
	for n in _shape_nodes:
		if is_instance_valid(n) and "_faction_id" in n and int(n._faction_id) == PLAYER_FACTION_ID:
			total += int(n._food)
	return total


func _calc_player_gold_income_runtime() -> int:
	var total: int = 0
	for n in _shape_nodes:
		if is_instance_valid(n) and "_faction_id" in n and int(n._faction_id) == PLAYER_FACTION_ID:
			total += int(n._gold)
	return total


# ── 帝国战斗：进入 / 状态持久化 / 结果回流 ─────────────────────────────────────

# 玩家点击某个出征目标方框 → 保存状态、写入 pending_empire_battle、切到 Main.tscn。
# target_id：本场战斗对应的目标地点 id。攻方阵容来自 _pending_campaigns[target_id]。
func _launch_empire_battle(target_id: int) -> void:
	var attackers: Array = _pending_campaigns.get(target_id, [])
	if attackers.is_empty():
		return
	var attacker_payload: Array = []
	for hk in attackers:
		var hd: Dictionary = _empire_hero_db.get(String(hk), {})
		attacker_payload.append({
			"hero_key":     String(hk),
			"hero_force":   int(hd.get("force", 1)),
			"hero_display": String(hd.get("display_name", hk)),
		})

	_save_empire_state(target_id)
	Game.pending_empire_battle = {
		"target_id": target_id,
		"attackers": attacker_payload,
	}
	Game.empire_battle_result = ""
	# 延迟切场景：当前帧 _gui_input 链路尚未结束，避免 viewport null 崩溃。
	get_tree().call_deferred("change_scene_to_file", "res://scenes/Main.tscn")


# 保存当前地图状态到 Game.empire_state。current_battle_target_id 标记本次出场的目标。
func _save_empire_state(current_battle_target_id: int) -> void:
	var snap := _build_full_snapshot()
	snap["current_battle_target_id"] = int(current_battle_target_id)
	Game.empire_state = snap


# ── 完整快照 / 存读档 ────────────────────────────────────────────────────────

# 构建可序列化的全量快照字典（不含 current_battle_target_id，由各调用方按需追加）。
func _build_full_snapshot() -> Dictionary:
	var deployed: Dictionary = {}
	for k in _deployed_heroes.keys():
		var n = _deployed_heroes[k]
		if is_instance_valid(n) and "_id" in n:
			deployed[String(k)] = int(n._id)

	var faction_snap: Dictionary = {}
	for n in _shape_nodes:
		if is_instance_valid(n) and "_id" in n and "_faction_id" in n:
			faction_snap[int(n._id)] = int(n._faction_id)

	var camps_dump: Dictionary = {}
	for tid in _pending_campaigns.keys():
		camps_dump[str(int(tid))] = (_pending_campaigns[tid] as Array).duplicate()

	var moves_dump: Dictionary = {}
	for hk in _pending_moves.keys():
		var mn = _pending_moves[hk]
		if is_instance_valid(mn) and "_id" in mn:
			moves_dump[String(hk)] = int(mn._id)

	# 卡组快照：完整 dump 当前会话缓存（含 selected_hero）
	var decks_snap: Dictionary = EmpireDeckStorage.dump_for_save()

	return {
		"deployed":                 deployed,
		"exiled":                   _exiled_heroes.duplicate(),
		"pending_campaigns":        camps_dump,
		"pending_campaign_sources": _pending_campaign_sources.duplicate(),
		"pending_moves":            moves_dump,
		"battle_select_mode":       _battle_select_mode,
		"faction_overrides":        faction_snap,
		"gold":                     _player_gold,
		"food":                     _player_food,
		"turn_number":              _turn_number,
		"talent_last_hero":         _talent_last_hero,
		"map_path":                 _current_map_path,
		"decks":                    decks_snap,
	}


# 把快照写入指定槽位（附带 meta 摘要）。
# 供手动存档（设置面板按钮）和自动存档（回合结束）调用。
func _write_save_slot(slot_id: String) -> void:
	var snap := _build_full_snapshot()
	# 解析 scenario 信息（从 map_path 对应的 JSON 中）
	var scenario_id: String = ""
	var scenario_name: String = ""
	var file := FileAccess.open(_current_map_path, FileAccess.READ)
	if file != null:
		var j := JSON.new()
		if j.parse(file.get_as_text()) == OK:
			var sc: Dictionary = (j.get_data() as Dictionary).get("scenario", {})
			scenario_id   = str(sc.get("id",   ""))
			scenario_name = str(sc.get("name", ""))
		file.close()
	var meta: Dictionary = {
		"timestamp":     Time.get_unix_time_from_system(),
		"scenario_id":   scenario_id,
		"scenario_name": scenario_name,
		"map_path":      _current_map_path,
		"turn_number":   _turn_number,
		"gold":          _player_gold,
		"food":          _player_food,
		"hero_count":    _alive_hero_keys().size(),
	}
	EmpireSaveStorage.save_slot(slot_id, meta, snap)


# 从指定槽位读取并应用快照（仅在地图构建完成后调用）。
func _apply_save_slot(slot_id: String) -> void:
	var entry := EmpireSaveStorage.load_slot(slot_id)
	if entry.is_empty():
		return
	var snap: Dictionary = entry.get("state", {})
	if snap.is_empty():
		return

	# --- 恢复卡组（注入到会话缓存）---
	var decks_snap: Dictionary = snap.get("decks", {})
	EmpireDeckStorage.inject_from_save(decks_snap)

	# --- 节点势力 ---
	var fmap: Dictionary = snap.get("faction_overrides", {})
	for nid in fmap.keys():
		var node = _id_to_node.get(int(nid), null)
		if node and is_instance_valid(node):
			var fid: int = int(fmap[nid])
			node._faction_id = fid
			node._fill       = _faction_color(fid)
			node._faction_name = _faction_name(fid)
			node.queue_redraw()

	# --- 部署 ---
	_deployed_heroes.clear()
	var dep: Dictionary = snap.get("deployed", {})
	for hk in dep.keys():
		var n = _id_to_node.get(int(dep[hk]), null)
		if n and is_instance_valid(n):
			_deployed_heroes[String(hk)] = n

	# --- 流放 / 出征 / 行棋 ---
	_exiled_heroes = (snap.get("exiled", {}) as Dictionary).duplicate()

	_pending_campaigns.clear()
	var camps_dump: Dictionary = snap.get("pending_campaigns", {})
	for sid in camps_dump.keys():
		_pending_campaigns[int(sid)] = (camps_dump[sid] as Array).duplicate()
	_pending_campaign_sources = (snap.get("pending_campaign_sources", {}) as Dictionary).duplicate()

	_pending_moves.clear()
	var moves_dump: Dictionary = snap.get("pending_moves", {})
	for hk in moves_dump.keys():
		var n = _id_to_node.get(int(moves_dump[hk]), null)
		if n and is_instance_valid(n):
			_pending_moves[String(hk)] = n

	# --- 资源 / 回合 ---
	_player_gold   = int(snap.get("gold", 0))
	_player_food   = int(snap.get("food", 0))
	_turn_number   = int(snap.get("turn_number", 0))
	_talent_last_hero = String(snap.get("talent_last_hero", ""))

	# --- 全量刷新图标 + 信息面板 ---
	for n in _shape_nodes:
		_refresh_deploy_icons_for(n)
	_refresh_info_panel()

	# --- 战斗选择模式 ---
	if bool(snap.get("battle_select_mode", false)) and not _pending_campaigns.is_empty():
		_enter_battle_select_mode()
	else:
		_exit_battle_select_mode()


# 战斗回流后还原。在 _build_map 完成后调用。
func _restore_empire_state_if_any() -> void:
	if Game.empire_state.is_empty():
		return
	var snap: Dictionary = Game.empire_state
	# 1) 节点势力按快照覆盖（含上一场战斗的占领结果）
	var fmap: Dictionary = snap.get("faction_overrides", {})
	for nid in fmap.keys():
		var node = _id_to_node.get(int(nid), null)
		if node and is_instance_valid(node):
			var fid: int = int(fmap[nid])
			node._faction_id = fid
			node._fill = _faction_color(fid)
			node._faction_name = _faction_name(fid)
			node.queue_redraw()

	# 2) 还原 _deployed_heroes
	_deployed_heroes.clear()
	var dep: Dictionary = snap.get("deployed", {})
	for hk in dep.keys():
		var n = _id_to_node.get(int(dep[hk]), null)
		if n and is_instance_valid(n):
			_deployed_heroes[String(hk)] = n

	# 3) 还原 _pending_campaigns / sources / 资源 / exiled
	_pending_campaigns.clear()
	var camps_dump: Dictionary = snap.get("pending_campaigns", {})
	for sid in camps_dump.keys():
		_pending_campaigns[int(sid)] = (camps_dump[sid] as Array).duplicate()
	_pending_campaign_sources = (snap.get("pending_campaign_sources", {}) as Dictionary).duplicate()
	_exiled_heroes = (snap.get("exiled", {}) as Dictionary).duplicate()
	_player_gold = int(snap.get("gold", 0))
	_player_food = int(snap.get("food", 0))

	# 4) 应用本场战斗结果（current_battle_target_id 指出哪个目标）
	var current_tid: int = int(snap.get("current_battle_target_id", -1))
	_apply_battle_result(current_tid)

	# 5) 全图刷新图标 + 信息面板
	for n in _shape_nodes:
		_refresh_deploy_icons_for(n)
	_refresh_info_panel()

	# 6) 若仍有剩余出征 → 继续战斗选择模式；否则回归正常状态
	if not _pending_campaigns.is_empty():
		_enter_battle_select_mode()
	else:
		_exit_battle_select_mode()

	# 一次性消费：清空快照与结果
	Game.empire_state = {}
	Game.empire_battle_result = ""


# ── 手动存档（设置面板「存档」按钮）────────────────────────────────────────────

func _on_manual_save_pressed() -> void:
	if _battle_select_mode or _drag_active:
		return
	# 构建内嵌存档槽内容（3 个手动槽，适配选项面板尺寸）
	var container := _build_save_embed_view()
	_settings.show_embedded_view(container)


func _build_save_embed_view() -> Control:
	var container := Control.new()
	container.mouse_filter = Control.MOUSE_FILTER_PASS

	var vb := VBoxContainer.new()
	vb.name = "SaveEmbedVBox"
	vb.set_anchors_preset(Control.PRESET_FULL_RECT)
	vb.offset_left   = 30;  vb.offset_right  = -30
	vb.offset_top    = 25;  vb.offset_bottom = -25
	vb.add_theme_constant_override("separation", 14)
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.mouse_filter = Control.MOUSE_FILTER_PASS
	container.add_child(vb)

	# 标题
	var title := Label.new()
	title.text = "选择存档槽"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", Color("#1c7ed6"))
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(title)

	var sep := HSeparator.new()
	var sep_style := StyleBoxFlat.new()
	sep_style.bg_color = Color("#d1d9e0")
	sep_style.content_margin_top = 1; sep_style.content_margin_bottom = 1
	sep.add_theme_stylebox_override("separator", sep_style)
	vb.add_child(sep)

	# 3 个手动槽
	var entries := _get_save_slot_entries()
	for entry in entries:
		var row := _make_save_slot_row(entry, container)
		vb.add_child(row)

	# 取消按钮
	var cancel_btn := Button.new()
	cancel_btn.text = "取消"
	cancel_btn.custom_minimum_size = Vector2(280, 70)
	cancel_btn.add_theme_font_size_override("font_size", 26)
	ThemeFactory.apply_button_styles(cancel_btn, ThemeFactory.settings_button_styles())
	cancel_btn.add_theme_color_override("font_color",         Color.WHITE)
	cancel_btn.add_theme_color_override("font_hover_color",   Color.WHITE)
	cancel_btn.add_theme_color_override("font_pressed_color", Color.WHITE)
	cancel_btn.pressed.connect(func(): _settings.hide_embedded_view())
	vb.add_child(cancel_btn)

	return container


func _make_save_slot_row(entry: Dictionary, container: Control) -> Button:
	var exists: bool = bool(entry.get("exists", false))
	var row := Button.new()
	row.custom_minimum_size = Vector2(0, 70)
	row.flat = false
	row.focus_mode = Control.FOCUS_NONE
	row.mouse_filter = Control.MOUSE_FILTER_STOP

	var normal_c := Color.WHITE if exists else Color("#e9ecef")
	var styles := {
		"normal":   ThemeFactory.panel(normal_c,         Color("#ced4da"), 1, 12, true),
		"hover":    ThemeFactory.panel(Color("#d0ebff"), Color("#74c0fc"), 1, 12, true),
		"pressed":  ThemeFactory.panel(Color("#a5d8ff"), Color("#4dabf7"), 1, 12, true),
		"disabled": ThemeFactory.panel(Color("#e9ecef"), Color("#dee2e6"), 1, 12, false),
	}
	ThemeFactory.apply_button_styles(row, styles)

	# 左标签 + 右摘要 HBox
	var hb := HBoxContainer.new()
	hb.set_anchors_preset(Control.PRESET_FULL_RECT)
	hb.offset_left = 16; hb.offset_right = -16
	hb.offset_top  = 0;  hb.offset_bottom = 0
	hb.add_theme_constant_override("separation", 10)
	hb.alignment = BoxContainer.ALIGNMENT_CENTER
	hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(hb)

	var lbl_name := Label.new()
	lbl_name.text = str(entry.get("label", ""))
	lbl_name.add_theme_font_size_override("font_size", 24)
	lbl_name.add_theme_color_override("font_color", Color("#1f2937") if exists else Color("#adb5bd"))
	lbl_name.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	lbl_name.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_child(lbl_name)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_child(spacer)

	var lbl_meta := Label.new()
	lbl_meta.text = str(entry.get("meta_text", "（空）"))
	lbl_meta.add_theme_font_size_override("font_size", 18)
	lbl_meta.add_theme_color_override("font_color", Color("#6c757d") if exists else Color("#ced4da"))
	lbl_meta.size_flags_horizontal = Control.SIZE_SHRINK_END
	lbl_meta.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_child(lbl_meta)

	var sid: String = str(entry.get("slot_id", ""))
	row.pressed.connect(func(): _on_save_row_pressed(sid, exists, container))
	return row


func _on_save_row_pressed(slot_id: String, exists: bool, container: Control) -> void:
	if exists:
		_show_overwrite_confirm(slot_id, container)
	else:
		_write_save_slot(slot_id)
		_settings.hide_embedded_view()
		_settings.close()


func _show_overwrite_confirm(slot_id: String, container: Control) -> void:
	# 覆盖确认弹层，附加在 _panel 内（z_index 高于 container）
	var co := Control.new()
	co.set_anchors_preset(Control.PRESET_FULL_RECT)
	co.mouse_filter = Control.MOUSE_FILTER_STOP
	co.z_index = 50
	container.add_child(co)

	var bg := Panel.new()
	bg.add_theme_stylebox_override("panel",
		ThemeFactory.panel(Color(0.96, 0.97, 0.98, 0.96), Color("#d1d9e0"), 1, 20, false))
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	co.add_child(bg)

	var vb := VBoxContainer.new()
	vb.set_anchors_preset(Control.PRESET_CENTER, false)
	vb.offset_left = -140; vb.offset_right  = 140
	vb.offset_top  = -80;  vb.offset_bottom = 80
	vb.add_theme_constant_override("separation", 20)
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	co.add_child(vb)

	var lbl := Label.new()
	lbl.text = "覆盖已有存档？"
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 26)
	lbl.add_theme_color_override("font_color", Color("#1f2937"))
	vb.add_child(lbl)

	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 20)
	hb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_child(hb)

	var ok_btn := Button.new()
	ok_btn.text = "覆盖"
	ok_btn.custom_minimum_size = Vector2(140, 64)
	ok_btn.add_theme_font_size_override("font_size", 24)
	ThemeFactory.apply_button_styles(ok_btn, ThemeFactory.primary_button_styles())
	ok_btn.add_theme_color_override("font_color",         Color.WHITE)
	ok_btn.add_theme_color_override("font_hover_color",   Color.WHITE)
	ok_btn.add_theme_color_override("font_pressed_color", Color.WHITE)
	ok_btn.pressed.connect(func():
		_write_save_slot(slot_id)
		_settings.hide_embedded_view()
		_settings.close())
	hb.add_child(ok_btn)

	var no_btn := Button.new()
	no_btn.text = "返回"
	no_btn.custom_minimum_size = Vector2(140, 64)
	no_btn.add_theme_font_size_override("font_size", 24)
	ThemeFactory.apply_button_styles(no_btn, ThemeFactory.settings_button_styles())
	no_btn.add_theme_color_override("font_color",         Color.WHITE)
	no_btn.add_theme_color_override("font_hover_color",   Color.WHITE)
	no_btn.add_theme_color_override("font_pressed_color", Color.WHITE)
	no_btn.pressed.connect(func(): co.queue_free())
	hb.add_child(no_btn)


# 槽位信息列表，供 picker 渲染。每项：
#   {slot_id, label, meta_text, is_auto, exists}
func _get_save_slot_entries() -> Array:
	var out: Array = []
	var all_slots := EmpireSaveStorage.list_slots()
	var slot_meta: Dictionary = {}
	for item in all_slots:
		slot_meta[String(item["slot_id"])] = item.get("meta", {})

	var manual_ids: Array = [
		EmpireSaveStorage.SLOT_1,
		EmpireSaveStorage.SLOT_2,
		EmpireSaveStorage.SLOT_3,
	]
	for i in manual_ids.size():
		var sid: String = manual_ids[i]
		var meta: Dictionary = slot_meta.get(sid, {})
		out.append({
			"slot_id":   sid,
			"label":     "存档 " + str(i + 1),
			"meta_text": _format_meta(meta) if not meta.is_empty() else "（空）",
			"is_auto":   false,
			"exists":    not meta.is_empty(),
		})
	return out


func _format_meta(meta: Dictionary) -> String:
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


func _apply_battle_result(target_id: int) -> void:
	if target_id < 0 or not _pending_campaigns.has(target_id):
		return
	var attackers: Array = _pending_campaigns[target_id]
	var result: String = String(Game.empire_battle_result)
	var target = _id_to_node.get(target_id, null)

	if result == "win" and target != null and is_instance_valid(target):
		target._faction_id = PLAYER_FACTION_ID
		target._fill = _faction_color(PLAYER_FACTION_ID)
		target._faction_name = _faction_name(PLAYER_FACTION_ID)
		target.queue_redraw()
		for hk in attackers:
			_deployed_heroes[String(hk)] = target
	# 失败：_deployed_heroes 已经是 source（出征前未变更），无需操作

	# 清掉该场出征记录
	_pending_campaigns.erase(target_id)
	for hk in attackers:
		_pending_campaign_sources.erase(String(hk))


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
	# ── 行棋拖拽优先：拦截 motion + LMB 释放，防止误触地图平移 ─────────────────
	if _drag_active:
		if event is InputEventMouseMotion:
			if _drag_ghost and is_instance_valid(_drag_ghost):
				_drag_ghost.global_position = event.global_position - _drag_ghost.size * 0.5
			return  # 拖拽中不走平移逻辑
		elif event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
			if not event.pressed:
				_on_hero_drag_end(event.global_position)
				get_viewport().set_input_as_handled()
			# press / release 均 return，防止 _pan_active 被重设
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

	# 出征战斗方框：节点外圈方形描边 + 呼吸缩放，用于结算阶段提示玩家点击进入战斗。
	# 与 set_breathing 不同：set_breathing 缩放节点本身；本方法独立子节点，描边由子节点自身呼吸缩放，
	# 不影响节点已有 hero icon 的相对位置。
	const CAMPAIGN_FRAME_MARGIN: float = 14.0
	const CAMPAIGN_FRAME_COLOR: Color = Color("#ff5555")
	const CAMPAIGN_FRAME_WIDTH: float = 3.0
	const CAMPAIGN_FRAME_BREATH_SCALE: Vector2 = Vector2(1.12, 1.12)
	const CAMPAIGN_FRAME_PERIOD: float = 1.0
	var _campaign_frame: Control = null
	var _campaign_frame_tween: Tween = null

	func set_campaign_frame(active: bool) -> void:
		if active:
			if _campaign_frame != null and is_instance_valid(_campaign_frame):
				return
			var frame := _CampaignFrame.new()
			frame.line_color = CAMPAIGN_FRAME_COLOR
			frame.line_width = CAMPAIGN_FRAME_WIDTH
			frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
			var inset: float = -CAMPAIGN_FRAME_MARGIN
			frame.size = size + Vector2(CAMPAIGN_FRAME_MARGIN * 2.0, CAMPAIGN_FRAME_MARGIN * 2.0)
			frame.position = Vector2(inset, inset)
			frame.pivot_offset = frame.size * 0.5
			add_child(frame)
			_campaign_frame = frame
			_campaign_frame_tween = create_tween().set_loops()
			_campaign_frame_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
			_campaign_frame_tween.tween_property(frame, "scale",
				CAMPAIGN_FRAME_BREATH_SCALE, CAMPAIGN_FRAME_PERIOD * 0.5)
			_campaign_frame_tween.tween_property(frame, "scale",
				Vector2.ONE, CAMPAIGN_FRAME_PERIOD * 0.5)
		else:
			if _campaign_frame_tween != null and _campaign_frame_tween.is_valid():
				_campaign_frame_tween.kill()
			_campaign_frame_tween = null
			if _campaign_frame != null and is_instance_valid(_campaign_frame):
				_campaign_frame.queue_free()
			_campaign_frame = null

	# 重建节点上方的人才头像横排。
	# hero_keys 和 textures 平行数组，长度相同。
	# ghost_flags 可选，对应位置 true 时图标显示为虚影（不可拖、半透明）。
	# 图标可点击，点击后通过父链找到 EmpireTest 调用 _on_hero_icon_clicked。
	func set_deployed_icons(hero_keys: Array, textures: Array, ghost_flags: Array = []) -> void:
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
			if i < ghost_flags.size() and bool(ghost_flags[i]):
				btn.set_ghost(true)
			_deploy_icon_row.add_child(btn)
		var row_w: float = float(n) * DEPLOY_ICON_SIZE.x + float(max(0, n - 1)) * float(DEPLOY_ICON_GAP)
		_deploy_icon_row.size = Vector2(row_w, DEPLOY_ICON_SIZE.y)
		_deploy_icon_row.position = Vector2(
			(size.x - row_w) * 0.5,
			-DEPLOY_ICON_SIZE.y - DEPLOY_ICON_OFFSET_Y
		)

	# 临时把某 hero_key 头像设为/取消虚化（拖拽中使用）。
	func set_hero_icon_ghost(hero_key: String, ghost: bool) -> void:
		if _deploy_icon_row == null:
			return
		for child in _deploy_icon_row.get_children():
			if "_hero_key" in child and String(child._hero_key) == hero_key:
				if child.has_method("set_ghost"):
					child.set_ghost(ghost)
				break

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


# ── 出征战斗方框：节点外侧矩形描边，呼吸缩放靠 _MapShapeNode 的 tween ─────────
class _CampaignFrame extends Control:
	var line_color: Color = Color("#ff5555")
	var line_width: float = 3.0

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), line_color, false, line_width)


# ── 人才头像按钮：可点击的图标，点击后沿父链回调 EmpireTest ──────────────────────
class _HeroIconBtn extends Control:
	var _hero_key: String = ""
	const OUTLINE_NORMAL:   Color = Color(1, 1, 1, 0.55)
	const OUTLINE_HOVER:    Color = Color(0.55, 0.9, 1.0, 0.9)
	const OUTLINE_PRESSED:  Color = Color(1, 0.6, 0.1, 1.0)
	const OUTLINE_SELECTED: Color = Color("#ffe066")
	const DRAG_START_THRESHOLD: float = 8.0

	var _tex: Texture2D = null
	var _icon_size: Vector2 = Vector2(36, 36)
	var _hover: bool = false
	var _pressing: bool = false
	var _is_selected: bool = false
	var _last_click_frame: int = -1
	# 拖拽相关
	var _press_start_global: Vector2 = Vector2.ZERO
	var _dragging: bool = false
	# 虚影态（pending 移动或拖拽中的源）= 不可再拖
	var _is_ghost: bool = false

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

	# 虚影态：半透明，且不可再拖。
	func set_ghost(val: bool) -> void:
		_is_ghost = val
		modulate.a = 0.45 if val else 1.0

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
			if event.pressed:
				_pressing = true
				_press_start_global = event.global_position
				_dragging = false
				queue_redraw()
				get_viewport().set_input_as_handled()
			else:
				_pressing = false
				queue_redraw()
				get_viewport().set_input_as_handled()
				# 仅在未发生拖拽时 fire click；拖拽释放由 EmpireTest._input 处理
				if not _dragging:
					var cur_frame := Engine.get_process_frames()
					if cur_frame != _last_click_frame:
						_last_click_frame = cur_frame
						_fire_click()
				_dragging = false
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
			# 按下且未拖拽 → 距离超阈值则启动拖拽
			if _pressing and not _dragging and not _is_ghost:
				var dist: float = event.global_position.distance_to(_press_start_global)
				if dist >= DRAG_START_THRESHOLD:
					_dragging = true
					# 启动拖拽后把"按下"状态交出去：EmpireTest 接管 motion/release。
					# 保持 _dragging=true，release 时仍按未点击处理。
					_pressing = false
					queue_redraw()
					_fire_drag_start(event.global_position)

	# 全局输入：按下且未触发拖拽时，光标移出图标后仍能侦测拖拽阈值。
	func _input(event: InputEvent) -> void:
		if _is_ghost or _dragging or not _pressing:
			return
		if event is InputEventMouseMotion:
			var dist: float = event.global_position.distance_to(_press_start_global)
			if dist >= DRAG_START_THRESHOLD:
				_dragging = true
				_pressing = false
				queue_redraw()
				_fire_drag_start(event.global_position)
				get_viewport().set_input_as_handled()

	func _fire_click() -> void:
		# 沿父链找到第一个有 _on_hero_icon_clicked 方法的节点（即 EmpireTest）
		var p: Node = get_parent()
		while p != null:
			if p.has_method("_on_hero_icon_clicked"):
				p._on_hero_icon_clicked(_hero_key)
				return
			p = p.get_parent()

	func _fire_drag_start(global_pos: Vector2) -> void:
		# 沿父链查找 EmpireTest，附带源 _MapShapeNode（祖父节点）
		var source_node: Node = get_parent()
		if source_node:
			source_node = source_node.get_parent()
		var p: Node = get_parent()
		while p != null:
			if p.has_method("_on_hero_drag_start"):
				p._on_hero_drag_start(_hero_key, source_node, global_pos)
				return
			p = p.get_parent()
