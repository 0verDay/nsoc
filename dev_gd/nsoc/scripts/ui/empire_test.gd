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

# 转场状态（委托给 EmpireTransitionController）
var _transition: EmpireTransitionController = null

# 兼容旧代码的属性转发
var _is_transitioning: bool:
	get: return _transition != null and _transition.is_transitioning
var _is_expanded: bool:
	get: return _transition != null and _transition.is_expanded
var _secondary_panel: SecondaryPanel:
	get: return _transition.get_secondary_panel() if _transition else null

var _info_panel: Panel = null

var _location_panel: EmpireLocationPanel
var _hero_detail_panel: EmpireHeroDetailPanel

# 当前在地图上选中的人才 key（点同一头像关闭，与地点选中互斥）
var _selected_hero_key: String = ""
# 从 empire_hero.json 加载的英雄数据库（供人才详情面板使用）
var _empire_hero_db: Dictionary = {}

var _settings: SettingsPanelController
var _map_root: Node2D
var _line_layer: EmpireLineLayer
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
var _info_faction_dot: EmpireFactionDot = null
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

	_line_layer = EmpireLineLayer.new()
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
	call_deferred("_init_transition")
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

	var faction_dot := EmpireFactionDot.new()
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


# ── 转场系统（委托给 EmpireTransitionController）────────────────────────────

func _init_transition() -> void:
	_transition = EmpireTransitionController.new()
	_transition.setup(self, _map_root, SECONDARY_PANEL_SCENES, PROFILE_PANEL_SCENE)
	_transition.reverse_finished.connect(_on_reverse_finished)
	_transition.secondary_attached.connect(_on_secondary_panel_attached)

	var side_panel := get_node_or_null("SidePanel")
	var end_btn    := get_node_or_null("EndTurnBtn")
	var settings_btn: Control = get_node_or_null("SettingsBtn")

	if _info_panel:
		_transition.register_target(_info_panel, -1)
	if side_panel:
		_transition.register_target(side_panel, 1)
	if end_btn:
		_transition.register_target(end_btn, 1)
	if settings_btn:
		_transition.register_target(settings_btn, 1)

	if _info_panel:
		call_deferred("_install_info_panel_button", _info_panel)

	if side_panel:
		for btn_name in ["ArmyBtn", "TalentBtn", "StrategyBtn"]:
			var btn: Button = side_panel.get_node_or_null("SideVBox/" + btn_name)
			if btn:
				btn.pressed.connect(func(b = btn): _transition.trigger(side_panel, b))


func _install_info_panel_button(pnl: Panel) -> void:
	_transition.install_info_panel_button(pnl)


func _trigger_transition(origin_panel: Control, origin_btn: Control) -> void:
	# 进入二级面板前清掉地点选中态与人才选中态
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
	_transition.trigger(origin_panel, origin_btn)


func _trigger_reverse() -> void:
	_transition.trigger_reverse()


func _on_secondary_panel_attached(panel: SecondaryPanel) -> void:
	if panel is EmpireTalentPanel:
		var tp: EmpireTalentPanel = panel as EmpireTalentPanel
		tp.set_deployed_state(_deployed_heroes)
		tp.deploy_requested.connect(_on_deploy_requested)
		tp.recall_requested.connect(_on_recall_requested)
	if panel.has_method("set_alive_pool"):
		panel.set_alive_pool(_alive_hero_keys())
	if panel is EmpireTalentPanel:
		var alive := _alive_hero_keys()
		var initial: String = _transition.talent_last_hero \
			if (not _transition.talent_last_hero.is_empty() and alive.has(_transition.talent_last_hero)) \
			else (String(alive[0]) if not alive.is_empty() else "")
		if not initial.is_empty():
			(panel as EmpireTalentPanel).goto_hero(initial)


func _on_reverse_finished() -> void:
	if _deploy_pending_hero != "":
		_enter_deploy_mode()


func _collect_fade_targets(root: Node) -> Array:
	if _transition:
		return _transition._collect_fade_targets(root)
	return []


static func _disable_mouse_recursive(c: Control) -> void:
	EmpireTransitionController._disable_mouse_recursive(c)



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
	_drag_ghost.size = EmpireMapShapeNode.DEPLOY_ICON_SIZE
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

		var node := EmpireMapShapeNode.new()
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


# ── 完整快照 / 存读档（委托给 EmpireStateIO）────────────────────────────────

func _build_full_snapshot() -> Dictionary:
	return EmpireStateIO.build_snapshot(
		_deployed_heroes, _exiled_heroes,
		_pending_campaigns, _pending_campaign_sources, _pending_moves,
		_shape_nodes, _battle_select_mode,
		_player_gold, _player_food, _turn_number,
		_transition.talent_last_hero if _transition else _talent_last_hero,
		_current_map_path
	)


func _write_save_slot(slot_id: String) -> void:
	var snap := _build_full_snapshot()
	EmpireStateIO.write_save_slot(
		slot_id, snap, _current_map_path,
		_turn_number, _player_gold, _player_food,
		_alive_hero_keys().size()
	)


func _apply_save_slot(slot_id: String) -> void:
	var entry := EmpireSaveStorage.load_slot(slot_id)
	if entry.is_empty():
		return
	var snap: Dictionary = entry.get("state", {})
	if snap.is_empty():
		return
	var result := EmpireStateIO.apply_snapshot(snap, _id_to_node,
		Callable(self, "_faction_color"), Callable(self, "_faction_name"))
	_deployed_heroes            = result["deployed_heroes"]
	_exiled_heroes              = result["exiled_heroes"]
	_pending_campaigns          = result["pending_campaigns"]
	_pending_campaign_sources   = result["pending_campaign_sources"]
	_pending_moves              = result["pending_moves"]
	_player_gold                = result["player_gold"]
	_player_food                = result["player_food"]
	_turn_number                = result["turn_number"]
	_talent_last_hero           = result["talent_last_hero"]
	if _transition:
		_transition.talent_last_hero = _talent_last_hero
	for n in _shape_nodes:
		_refresh_deploy_icons_for(n)
	_refresh_info_panel()
	if result["battle_select_mode"] and not _pending_campaigns.is_empty():
		_enter_battle_select_mode()
	else:
		_exit_battle_select_mode()


func _restore_empire_state_if_any() -> void:
	if Game.empire_state.is_empty():
		return
	var snap: Dictionary = Game.empire_state
	var result := EmpireStateIO.apply_snapshot(snap, _id_to_node,
		Callable(self, "_faction_color"), Callable(self, "_faction_name"))
	_deployed_heroes            = result["deployed_heroes"]
	_exiled_heroes              = result["exiled_heroes"]
	_pending_campaigns          = result["pending_campaigns"]
	_pending_campaign_sources   = result["pending_campaign_sources"]
	_pending_moves              = result["pending_moves"]
	_player_gold                = result["player_gold"]
	_player_food                = result["player_food"]
	var current_tid: int = int(snap.get("current_battle_target_id", -1))
	_apply_battle_result(current_tid)
	for n in _shape_nodes:
		_refresh_deploy_icons_for(n)
	_refresh_info_panel()
	if not _pending_campaigns.is_empty():
		_enter_battle_select_mode()
	else:
		_exit_battle_select_mode()
	Game.empire_state = {}
	Game.empire_battle_result = ""




# ── 手动存档（设置面板「存档」按钮）────────────────────────────────────────────

func _on_manual_save_pressed() -> void:
	if _battle_select_mode or _drag_active:
		return
	var save_panel := EmpireSavePanel.new()
	save_panel.save_requested.connect(_write_save_slot)
	var container := save_panel.build_embed_view(
		func(): _settings.hide_embedded_view(); _settings.close(),
		func(): _settings.hide_embedded_view()
	)
	_settings.show_embedded_view(container)


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
