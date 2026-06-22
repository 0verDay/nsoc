class_name EmpireTransitionController
extends RefCounted

# 帝国地图大地图 ↔ 二级面板的转场控制器。
# 与 EmpireTest 解耦：不持有场景树引用，而是在构建时接收需要操控的节点列表 + 回调。
#
# 使用方式（EmpireTest._ready 后调用 setup）：
#   var _transition := EmpireTransitionController.new()
#   _transition.setup(owner_node, map_root, secondary_panel_scenes, profile_panel_scene)
#   _transition.deploy_requested.connect(...)
#   _transition.recall_requested.connect(...)
#
# 转场发起：_transition.trigger(origin_panel, origin_btn)
# 反向转场：_transition.trigger_reverse()

signal secondary_attached(panel)       # 二级面板 attach 完成
signal reverse_finished                # 反向转场完成

const TRANSITION_DURATION: float = 0.45
const FADE_DURATION: float        = 0.15
const EXPANDED_MARGIN: float      = 20.0

var _owner: Control         = null   # EmpireTest 根节点
var _map_root: Node2D       = null
var _transition_targets: Array = []   # [{node: Control, dir: int}]
var _initial_state: Dictionary = {}   # Control → {position, size, scale, modulate, pivot}
var _frozen_children: Array = []
var _frozen_state: Dictionary = {}
var _current_tween: Tween = null
var _origin_panel: Control = null
var _origin_btn: Control   = null

var is_expanded: bool     = false
var is_transitioning: bool = false

var _secondary_panel: SecondaryPanel = null
var _secondary_panel_scenes: Dictionary = {}
var _profile_panel_scene: PackedScene = null

# 人才最后查看记录（由 EmpireTest 注入/读取）
var talent_last_hero: String = ""

# 部署/流放信号（由挂载的二级面板转发）
signal deploy_requested(hero_key: String)
signal recall_requested(hero_key: String)


func setup(
		owner: Control,
		map_root: Node2D,
		secondary_panel_scenes: Dictionary,
		profile_panel_scene: PackedScene
) -> void:
	_owner = owner
	_map_root = map_root
	_secondary_panel_scenes = secondary_panel_scenes
	_profile_panel_scene = profile_panel_scene


# 注册参与转场的节点，记录初始状态。
# dir: -1=左滑 1=右滑
func register_target(node: Control, dir: int) -> void:
	_transition_targets.append({"node": node, "dir": dir})
	_record_initial(node)


# 安装 InfoPanel 点击代理按钮（点击 InfoPanel 触发 trigger）。
# faction_dot_class 用于 _collect_fade_targets 类型判断，传 EmpireFactionDot。
func install_info_panel_button(pnl: Panel) -> void:
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
		if is_transitioning or is_expanded: return
		var t := pnl.create_tween()
		t.tween_property(pnl, "scale", Vector2(0.98, 0.98), 0.08))
	btn.button_up.connect(func():
		if is_transitioning or is_expanded: return
		var t := pnl.create_tween()
		t.tween_property(pnl, "scale", Vector2.ONE, 0.08))
	btn.pressed.connect(func(): trigger(pnl, pnl))


func trigger(origin_panel: Control, origin_btn: Control) -> void:
	if is_transitioning or is_expanded:
		return
	is_transitioning = true
	_origin_panel = origin_panel
	_origin_btn   = origin_btn

	if _current_tween and _current_tween.is_valid():
		_current_tween.kill()
	_current_tween = _owner.create_tween()
	_current_tween.set_parallel(true)
	_current_tween.set_trans(Tween.TRANS_CUBIC)
	_current_tween.set_ease(Tween.EASE_IN_OUT)

	var screen := _owner.get_viewport_rect().size

	# 1) origin_panel 内可见子控件淡出
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
	is_transitioning = false
	is_expanded = true

	for c in _frozen_children:
		if is_instance_valid(c) and c is Control:
			(c as Control).mouse_filter = Control.MOUSE_FILTER_IGNORE

	# 5) attach 二级面板
	if _secondary_panel and is_instance_valid(_secondary_panel):
		_secondary_panel.queue_free()
	var btn_key: String = _origin_btn.name if _origin_btn else ""
	var panel_scene: PackedScene = _secondary_panel_scenes.get(btn_key, _profile_panel_scene)
	_secondary_panel = panel_scene.instantiate()
	_secondary_panel.back_pressed.connect(trigger_reverse)
	_secondary_panel.attach(origin_panel)
	secondary_attached.emit(_secondary_panel)


func trigger_reverse() -> void:
	# 人才面板关闭前：记录当前查看的 hero_key
	if _secondary_panel is EmpireTalentPanel and is_instance_valid(_secondary_panel):
		var car := (_secondary_panel as EmpireTalentPanel).get_node_or_null("HeroPnl/Carousel") as EmpireCarousel
		if car:
			talent_last_hero = car.current_hero_key()

	if _current_tween and _current_tween.is_valid():
		_current_tween.kill()
	if _secondary_panel and is_instance_valid(_secondary_panel):
		_secondary_panel.detach_with_fade(TRANSITION_DURATION)
		_secondary_panel = null

	is_transitioning = true
	is_expanded = false

	for c in _frozen_children:
		if is_instance_valid(c):
			c.top_level = false
			if c is Control:
				(c as Control).mouse_filter = Control.MOUSE_FILTER_STOP
	_frozen_children.clear()
	_frozen_state.clear()

	_current_tween = _owner.create_tween()
	_current_tween.set_parallel(true)
	_current_tween.set_trans(Tween.TRANS_CUBIC)
	_current_tween.set_ease(Tween.EASE_IN_OUT)

	if _map_root:
		_current_tween.tween_property(_map_root, "modulate:a", 1.0, TRANSITION_DURATION)

	for node in _initial_state.keys():
		var init: Dictionary = _initial_state[node]
		_current_tween.tween_property(node, "position",     init.position,  TRANSITION_DURATION)
		_current_tween.tween_property(node, "size",         init.size,      TRANSITION_DURATION)
		_current_tween.tween_property(node, "scale",        init.scale,     TRANSITION_DURATION)
		_current_tween.tween_property(node, "pivot_offset", init.pivot,     TRANSITION_DURATION)
		_current_tween.tween_property(node, "modulate",     init.modulate,  TRANSITION_DURATION)

	var fade_delay := TRANSITION_DURATION - FADE_DURATION
	if _origin_panel:
		for b in _collect_fade_targets(_origin_panel):
			b.modulate.a = 0.0
			_current_tween.tween_property(b, "modulate:a", 1.0, FADE_DURATION).set_delay(fade_delay)

	await _current_tween.finished
	is_transitioning = false
	reverse_finished.emit()


func get_secondary_panel() -> SecondaryPanel:
	return _secondary_panel


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


func _collect_fade_targets(root: Node) -> Array:
	var out: Array = []
	if root.has_meta("transition_skip"):
		return out
	if root is Button or root is Label or root is TextureRect or root is EmpireFactionDot:
		out.append(root)
		return out
	for child in root.get_children():
		if child is Node and child.has_meta("transition_skip"):
			continue
		if child is Button or child is Label or child is TextureRect or child is EmpireFactionDot:
			out.append(child)
		elif child is Node:
			out.append_array(_collect_fade_targets(child))
	return out


static func _disable_mouse_recursive(c: Control) -> void:
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for sub in c.get_children():
		if sub is Control:
			_disable_mouse_recursive(sub)
