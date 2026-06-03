class_name HeroPanelDragController
extends Node

# 玩家英雄面板（LeftSidePnl）的拖拽 + 边界反弹 + 按压缩放控制器。
# 比 main.gd 的简单按压版本多出：
# - 拖拽阈值检测（避免按压被误判为拖拽）
# - 鼠标投影到合法区域（防止拖到 BottomBar 外）
# - 边界回弹（接触边时弹簧动画）
# - 离开范围自动收回
#
# 使用方式：
#   var ctrl := HeroPanelDragController.new()
#   add_child(ctrl)
#   ctrl.setup({
#       "panel": $LeftSidePnl,
#       "bottom_bar": $BottomBar,
#       "detail_panel": detail_panel,
#       "long_press_hero_args": Callable(self, "_get_player_hero_args"),
#   })
#   $LeftSidePnl.gui_input.connect(ctrl.on_gui_input)

const DRAG_THRESHOLD: float = 6.0
const SNAP_DURATION: float = 0.25
const BOUNCE_DIST: float = 20.0
const BOUNCE_DURATION: float = 0.45

var _panel: Control = null
var _bottom_bar: Control = null
var _detail_panel = null
# Callable() -> Array  返回 [full_name, ability_id, max_health]
var _hero_args_resolver: Callable = Callable()

var _dragging: bool = false
var _drag_start_pos: Vector2 = Vector2.ZERO
var _drag_prev_pos: Vector2 = Vector2.ZERO
var _drag_w: float = 0.0
var _drag_h: float = 0.0
var _snap_tween: Tween = null
# 装备面板展开动画期间阻断拖拽
var _drag_blocked: bool = false
# Press 是否来自 panel 本身（防止手牌拖拽的 motion 事件误触发面板拖拽）
var _press_received: bool = false

func setup(deps: Dictionary) -> void:
	_panel              = deps.get("panel")
	_bottom_bar         = deps.get("bottom_bar")
	_detail_panel       = deps.get("detail_panel")
	_hero_args_resolver = deps.get("long_press_hero_args", Callable())

func _process(_delta: float) -> void:
	if _drag_blocked or not _dragging:
		return
	if not Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		_bounce_from_boundary()
		_animate_release()
		_dragging = false
		return
	_apply_drag(_panel.get_global_mouse_position())

# ── 公开输入入口 ──────────────────────────────────────────────────────
func on_gui_input(event: InputEvent) -> void:
	if _drag_blocked:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.pressed:
			_on_press(event.global_position)
		else:
			_on_release()

	if event is InputEventMouseMotion and Input.is_mouse_button_pressed(MOUSE_BUTTON_LEFT):
		if not _press_received:
			return   # motion 来自 panel 以外的按下（如手牌拖拽），忽略
		if not _dragging:
			if event.global_position.distance_to(_drag_start_pos) > DRAG_THRESHOLD:
				_dragging = true
				_animate_release()
				if is_instance_valid(_detail_panel):
					_detail_panel.cancel_long_press()
		if _dragging:
			_apply_drag(event.global_position)

# 外部需要访问按压松开时机（_input 的全局松开）
func handle_global_release() -> void:
	_press_received = false
	if _dragging:
		_bounce_from_boundary()
		_dragging = false
	else:
		# 非拖拽情况下也要还原按压缩放，否则点击装备/技能按钮后面板停留在 1.08x。
		# _animate_release 内部用 ONE 判断不会重复触发动画。
		_animate_release()

# 动画期间阻断 / 恢复拖拽（由 HeroActionBar 发信号时调用）。
func set_drag_blocked(blocked: bool) -> void:
	_drag_blocked = blocked
	if blocked and _dragging:
		# 立即结束当前拖拽，弹回边界
		_bounce_from_boundary()
		_animate_release()
		_dragging = false

# ── 按下 / 松开 ───────────────────────────────────────────────────────
func _on_press(global_pos: Vector2) -> void:
	if not is_instance_valid(_panel):
		return
	_press_received = true
	if _snap_tween and _snap_tween.is_running():
		_snap_tween.kill()
	_snap_tween = null
	_drag_start_pos = global_pos
	_drag_prev_pos  = global_pos
	_drag_w = _panel.size.x; _drag_h = _panel.size.y

	# 切到 TOP_LEFT anchor，便于直接修改 offset
	var gpos: Vector2 = _panel.global_position
	_panel.set_anchors_preset(Control.PRESET_TOP_LEFT, false)
	_panel.offset_left   = gpos.x;            _panel.offset_top    = gpos.y
	_panel.offset_right  = gpos.x + _drag_w;  _panel.offset_bottom = gpos.y + _drag_h
	_dragging = false

	if is_instance_valid(_detail_panel) and _hero_args_resolver.is_valid():
		var args: Array = _hero_args_resolver.call()
		if args.size() >= 3:
			var equip_descs: Array = args[3] if args.size() >= 4 else []
			_detail_panel.start_long_press_hero(args[0], args[1], args[2], equip_descs)
	_animate_press()

func _on_release() -> void:
	_press_received = false
	if _dragging:
		_bounce_from_boundary()
	else:
		_animate_release()
	_dragging = false

# ── 边界反弹 ──────────────────────────────────────────────────────────
func _bounce_from_boundary() -> void:
	if _drag_w == 0.0 or _drag_h == 0.0:
		return
	if not is_instance_valid(_panel) or not is_instance_valid(_bottom_bar):
		return
	var bar_left: float = _bottom_bar.get_global_rect().position.x
	var vp_h: float = _panel.get_viewport().get_visible_rect().size.y
	var tgt_left: float = _panel.offset_left
	var tgt_top: float  = _panel.offset_top
	var use_spring: bool = false

	if _panel.offset_right >= bar_left - BOUNCE_DIST:
		tgt_left = bar_left - _drag_w - BOUNCE_DIST; use_spring = true
	elif _panel.offset_left <= BOUNCE_DIST:
		tgt_left = BOUNCE_DIST; use_spring = true
	if _panel.offset_bottom >= vp_h - BOUNCE_DIST:
		tgt_top = vp_h - _drag_h - BOUNCE_DIST; use_spring = true
	elif _panel.offset_top <= BOUNCE_DIST:
		tgt_top = BOUNCE_DIST; use_spring = true

	if not use_spring:
		var dist_right:  float = bar_left - _panel.offset_right
		var dist_left:   float = _panel.offset_left
		var dist_bottom: float = vp_h - _panel.offset_bottom
		var dist_top:    float = _panel.offset_top
		var min_h: float = min(dist_right, dist_left)
		var min_v: float = min(dist_bottom, dist_top)
		if min_h <= min_v:
			tgt_left = bar_left - _drag_w - BOUNCE_DIST if dist_right <= dist_left else BOUNCE_DIST
		else:
			tgt_top = vp_h - _drag_h - BOUNCE_DIST if dist_bottom <= dist_top else BOUNCE_DIST

	if tgt_left == _panel.offset_left and tgt_top == _panel.offset_top:
		return

	var trans := Tween.TRANS_SPRING if use_spring else Tween.TRANS_QUAD
	_snap_tween = _panel.create_tween()
	_snap_tween.set_parallel(true)
	_snap_tween.tween_property(_panel, "offset_left",   tgt_left,            BOUNCE_DURATION).set_trans(trans).set_ease(Tween.EASE_OUT)
	_snap_tween.tween_property(_panel, "offset_right",  tgt_left + _drag_w,  BOUNCE_DURATION).set_trans(trans).set_ease(Tween.EASE_OUT)
	_snap_tween.tween_property(_panel, "offset_top",    tgt_top,             BOUNCE_DURATION).set_trans(trans).set_ease(Tween.EASE_OUT)
	_snap_tween.tween_property(_panel, "offset_bottom", tgt_top + _drag_h,   BOUNCE_DURATION).set_trans(trans).set_ease(Tween.EASE_OUT)

# ── 拖拽核心 ──────────────────────────────────────────────────────────
func _apply_drag(raw_mouse: Vector2) -> void:
	var vp_size: Vector2 = _panel.get_viewport().get_visible_rect().size
	var bar_left: float  = _bottom_bar.get_global_rect().position.x
	var mouse_pos: Vector2 = _project_to_valid_area(raw_mouse, vp_size, bar_left)
	var delta: Vector2 = mouse_pos - _drag_prev_pos
	if delta.x == 0.0 and delta.y == 0.0:
		return
	_drag_prev_pos = mouse_pos
	_panel.offset_left  += delta.x; _panel.offset_right  += delta.x
	_panel.offset_top   += delta.y; _panel.offset_bottom += delta.y
	_panel.offset_right  = _panel.offset_left + _drag_w
	_panel.offset_bottom = _panel.offset_top  + _drag_h
	var vp_h: float = vp_size.y
	if _panel.offset_right > bar_left:
		_panel.offset_left = bar_left - _drag_w; _panel.offset_right = bar_left
	if _panel.offset_left < 0.0:
		_panel.offset_left = 0.0; _panel.offset_right = _drag_w
	if _panel.offset_top < 0.0:
		_panel.offset_top = 0.0; _panel.offset_bottom = _drag_h
	if _panel.offset_bottom > vp_h:
		_panel.offset_top = vp_h - _drag_h; _panel.offset_bottom = vp_h

# 把鼠标点投影到合法矩形内（左上 0,0 ~ bar_left, vp_h），保证拖拽不会把面板拉到 BottomBar 外。
func _project_to_valid_area(point: Vector2, vp_size: Vector2, bar_left: float) -> Vector2:
	var vp_h: float = vp_size.y
	var rect: Rect2 = Rect2(Vector2.ZERO, Vector2(bar_left, vp_h))
	if rect.has_point(point):
		return point
	var center: Vector2 = Vector2(bar_left * 0.5, vp_h * 0.5)
	var dir: Vector2 = point - center
	if dir == Vector2.ZERO:
		return center
	var best: Vector2 = center
	var best_t: float = INF
	if dir.x != 0.0:
		var t := (bar_left - center.x) / dir.x
		if t > 0.0:
			var y := center.y + t * dir.y
			if y >= 0.0 and y <= vp_h and t < best_t:
				best_t = t; best = Vector2(bar_left, y)
		t = (0.0 - center.x) / dir.x
		if t > 0.0:
			var y := center.y + t * dir.y
			if y >= 0.0 and y <= vp_h and t < best_t:
				best_t = t; best = Vector2(0.0, y)
	if dir.y != 0.0:
		var t := (0.0 - center.y) / dir.y
		if t > 0.0:
			var x := center.x + t * dir.x
			if x >= 0.0 and x <= bar_left and t < best_t:
				best_t = t; best = Vector2(x, 0.0)
		t = (vp_h - center.y) / dir.y
		if t > 0.0:
			var x := center.x + t * dir.x
			if x >= 0.0 and x <= bar_left and t < best_t:
				best_t = t; best = Vector2(x, vp_h)
	return best

# ── 按压动画 ─────────────────────────────────────────────────────────
func _animate_press() -> void:
	if not is_instance_valid(_panel): return
	var tween := _panel.create_tween()
	tween.tween_property(_panel, "scale", Vector2(1.08, 1.08), 0.1)

func _animate_release() -> void:
	if not is_instance_valid(_panel): return
	if _panel.scale == Vector2.ONE: return
	var tween := _panel.create_tween()
	tween.tween_property(_panel, "scale", Vector2.ONE, 0.1)
