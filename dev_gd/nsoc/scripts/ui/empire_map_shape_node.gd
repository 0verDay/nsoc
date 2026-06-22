class_name EmpireMapShapeNode
extends Control

# 帝国地图上的单个地点节点（圆/方/三角）。
# 负责：绘制形状、选中态、呼吸动画、出征战斗外框、人才头像横排。

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
const DEPLOY_ICON_OFFSET_Y: float = 14.0

# 出征战斗外框
const CAMPAIGN_FRAME_MARGIN: float = 14.0
const CAMPAIGN_FRAME_COLOR: Color = Color("#ff5555")
const CAMPAIGN_FRAME_WIDTH: float = 3.0
const CAMPAIGN_FRAME_BREATH_SCALE: Vector2 = Vector2(1.12, 1.12)
const CAMPAIGN_FRAME_PERIOD: float = 1.0
var _campaign_frame: Control = null
var _campaign_frame_tween: Tween = null


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


func set_hero_icon_selected(hero_key: String, selected: bool) -> void:
	if _deploy_icon_row == null:
		return
	for child in _deploy_icon_row.get_children():
		if "_hero_key" in child and String(child._hero_key) == hero_key:
			if child.has_method("set_selected_state"):
				child.set_selected_state(selected)
			break


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
	var cur_frame: int = Engine.get_process_frames()
	if cur_frame == _last_click_frame:
		get_viewport().set_input_as_handled()
		return
	_last_click_frame = cur_frame
	clicked.emit(self)
	get_viewport().set_input_as_handled()


# ── 出征战斗方框 ─────────────────────────────────────────────────────────────
class _CampaignFrame extends Control:
	var line_color: Color = Color("#ff5555")
	var line_width: float = 3.0

	func _draw() -> void:
		draw_rect(Rect2(Vector2.ZERO, size), line_color, false, line_width)


# ── 人才头像按钮 ─────────────────────────────────────────────────────────────
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
	var _press_start_global: Vector2 = Vector2.ZERO
	var _dragging: bool = false
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
			if _pressing and not _dragging and not _is_ghost:
				var dist: float = event.global_position.distance_to(_press_start_global)
				if dist >= DRAG_START_THRESHOLD:
					_dragging = true
					_pressing = false
					queue_redraw()
					_fire_drag_start(event.global_position)

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
		var p: Node = get_parent()
		while p != null:
			if p.has_method("_on_hero_icon_clicked"):
				p._on_hero_icon_clicked(_hero_key)
				return
			p = p.get_parent()

	func _fire_drag_start(global_pos: Vector2) -> void:
		var source_node: Node = get_parent()
		if source_node:
			source_node = source_node.get_parent()
		var p: Node = get_parent()
		while p != null:
			if p.has_method("_on_hero_drag_start"):
				p._on_hero_drag_start(_hero_key, source_node, global_pos)
				return
			p = p.get_parent()
