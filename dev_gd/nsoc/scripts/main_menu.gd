extends Control

# MainMenu —— 启动后首个场景。
# - 中央 test 按钮 → 进入主游玩场景
# - 右上角"选项"按钮（暂无逻辑，仅占位，风格与游玩场景一致）
# - 右下角面板 RightSidePnl，尺寸与游玩场景英雄面板 LeftSidePnl 相同（暂无逻辑）

const MAIN_SCENE_PATH := "res://scenes/Main.tscn"

# 与游玩场景 SettingsPanelController 中按钮一致：160 x 80，font 32
const OPTIONS_BTN_W: float = 160.0
const OPTIONS_BTN_H: float = 80.0
const OPTIONS_BTN_MARGIN: float = 20.0

@onready var _test_btn: Button = $CenterContainer/TestButton

var _options_btn: Button
var _back_btn: Button

# ---------------- 转场动画 ----------------
# 点击非"选项"按钮 → 该按钮所在面板内全部按钮淡出 + 其余面板/按钮水平滑出
# + 被点中面板以中心快速扩大覆盖全屏。
# 调试期右键反向播放，便于来回验证。
const TRANSITION_DURATION: float = 0.45
const FADE_DURATION: float = 0.15

# Control -> { "position": Vector2, "scale": Vector2, "modulate": Color, "pivot": Vector2 }
var _initial_state: Dictionary = {}
# 转场参与节点（除被点中面板外，其余面板/按钮记录其滑出方向，1=向右,-1=向左,0=不滑）
var _transition_targets: Array = []
var _is_transitioning: bool = false
var _is_reversed: bool = false
# 正向展开完成后置 true；反向开始时清零。锁住期间忽略所有新的正向触发，
# 防止点击已扩展面板（如 ProfilePnl 空白处）重入导致返回按钮闪烁。
var _is_expanded: bool = false
# 转场期间被 top_level=true 冻结的子控件，反向时需还原 top_level=false。
var _frozen_children: Array = []
var _frozen_state: Dictionary = {}
# 当前播放的 Tween（右键时 kill 以便倒回）
var _current_tween: Tween

func _ready() -> void:
	_apply_bg_style()
	_apply_right_panel_style()
	_apply_profile_panel_style()
	_apply_left_nav_panel_style()
	_style_right_panel_buttons()
	_style_left_nav_buttons()
	_build_options_button()
	if _test_btn:
		_test_btn.pressed.connect(_on_test_pressed)
	# 延迟一帧待 layout 稳定后记录初始状态、装配转场。
	call_deferred("_setup_transition")

# 与 main.gd:264 一致：白底 + 浅灰边 + 圆角 0
func _apply_bg_style() -> void:
	var bg: Panel = $Bg
	if bg:
		bg.add_theme_stylebox_override(
			"panel",
			ThemeFactory.panel(Color.WHITE, Color("#e1e8ed"), 1, 0)
		)

# 与 main.gd:270 一致：白底 + 半透白边 + 圆角 20 + 阴影（与 LeftSidePnl 同款）
func _apply_right_panel_style() -> void:
	var pnl: Panel = $RightSidePnl
	if pnl:
		pnl.add_theme_stylebox_override(
			"panel",
			ThemeFactory.panel(Color.WHITE, Color(1, 1, 1, 0.6), 1, 20, true)
		)

# 左上玩家信息面板：与右下面板同款风格，保持视觉统一。
func _apply_profile_panel_style() -> void:
	var pnl: Panel = $ProfilePnl
	if pnl:
		pnl.add_theme_stylebox_override(
			"panel",
			ThemeFactory.panel(Color.WHITE, Color(1, 1, 1, 0.6), 1, 20, true)
		)

# 左侧竖向导航面板：同款风格。
func _apply_left_nav_panel_style() -> void:
	var pnl: Panel = $LeftNavPnl
	if pnl:
		pnl.add_theme_stylebox_override(
			"panel",
			ThemeFactory.panel(Color.WHITE, Color(1, 1, 1, 0.6), 1, 20, true)
		)

# 给右下面板内三按钮套蓝色主按钮风格，与游玩场景 "选项 / 英雄技能" 一致。
func _style_right_panel_buttons() -> void:
	var btns: Array = [
		$RightSidePnl/VBox/TopRow/CampaignBtn,
		$RightSidePnl/VBox/TopRow/JourneyBtn,
		$RightSidePnl/VBox/SparringBtn,
	]
	var styles := ThemeFactory.primary_button_styles()
	for b in btns:
		if b == null:
			continue
		ThemeFactory.apply_button_styles(b, styles)
		b.add_theme_font_size_override("font_size", 28)
		b.add_theme_color_override("font_color", Color.WHITE)
		b.add_theme_color_override("font_hover_color", Color.WHITE)
		b.add_theme_color_override("font_pressed_color", Color.WHITE)

# 左侧导航四按钮：同款蓝色主按钮风格。
func _style_left_nav_buttons() -> void:
	var btns: Array = [
		$LeftNavPnl/VBox/GrowBtn,
		$LeftNavPnl/VBox/PrepareBtn,
		$LeftNavPnl/VBox/FriendBtn,
		$LeftNavPnl/VBox/CollectionBtn,
		$LeftNavPnl/VBox/CustomBtn,
	]
	var styles := ThemeFactory.primary_button_styles()
	for b in btns:
		if b == null:
			continue
		ThemeFactory.apply_button_styles(b, styles)
		b.add_theme_font_size_override("font_size", 32)
		b.add_theme_color_override("font_color", Color.WHITE)
		b.add_theme_color_override("font_hover_color", Color.WHITE)
		b.add_theme_color_override("font_pressed_color", Color.WHITE)

# 右上角"选项"按钮：尺寸/风格与 SettingsPanelController 创建的按钮一致。
func _build_options_button() -> void:
	_options_btn = Button.new()
	_options_btn.name = "OptionsBtn"
	_options_btn.text = "选项"
	_options_btn.add_theme_font_size_override("font_size", 32)
	_options_btn.set_anchors_preset(Control.PRESET_TOP_RIGHT, false)
	_options_btn.offset_left = -OPTIONS_BTN_MARGIN - OPTIONS_BTN_W
	_options_btn.offset_top = OPTIONS_BTN_MARGIN
	_options_btn.offset_right = -OPTIONS_BTN_MARGIN
	_options_btn.offset_bottom = OPTIONS_BTN_MARGIN + OPTIONS_BTN_H
	ThemeFactory.apply_button_styles(_options_btn, ThemeFactory.primary_button_styles())
	_options_btn.add_theme_color_override("font_color", Color.WHITE)
	add_child(_options_btn)

func _on_test_pressed() -> void:
	get_tree().change_scene_to_file(MAIN_SCENE_PATH)

# ---------------- 转场实现 ----------------

# 收集所有参与转场的节点 + 记录初始状态 + 连接按钮信号。
func _setup_transition() -> void:
	var profile: Panel = $ProfilePnl
	var left_nav: Panel = $LeftNavPnl
	var right_side: Panel = $RightSidePnl
	# 滑出方向：左侧面板 → 向左，右侧 → 向右，选项按钮 → 向右
	_transition_targets = [
		{"node": profile, "dir": -1},
		{"node": left_nav, "dir": -1},
		{"node": right_side, "dir": 1},
		{"node": _options_btn, "dir": 1},
	]
	for entry in _transition_targets:
		_record_initial(entry.node)
	# 左侧 5 按钮 → 所在面板 LeftNavPnl
	for b in [$LeftNavPnl/VBox/GrowBtn, $LeftNavPnl/VBox/PrepareBtn,
			$LeftNavPnl/VBox/FriendBtn, $LeftNavPnl/VBox/CollectionBtn,
			$LeftNavPnl/VBox/CustomBtn]:
		if b: b.pressed.connect(func(): _trigger_transition(left_nav, b))
	# 右下 3 按钮 → 所在面板 RightSidePnl
	for b in [$RightSidePnl/VBox/TopRow/CampaignBtn,
			$RightSidePnl/VBox/TopRow/JourneyBtn,
			$RightSidePnl/VBox/SparringBtn]:
		if b: b.pressed.connect(func(): _trigger_transition(right_side, b))
	# 玩家信息面板：整面板可点击触发转场（淡出的是头像 + Label）。
	if profile:
		profile.mouse_filter = Control.MOUSE_FILTER_STOP
		profile.gui_input.connect(func(ev): _on_profile_gui_input(ev, profile))

func _on_profile_gui_input(event: InputEvent, profile: Control) -> void:
	if event is InputEventMouseButton and event.pressed and event.button_index == MOUSE_BUTTON_LEFT:
		_trigger_transition(profile, profile)

func _record_initial(ctrl: Control) -> void:
	if ctrl == null:
		return
	# 拍平 anchor 为 TOP_LEFT，把 position/size 完全交给代码 Tween 控制，
	# 避免父布局/锚点在动画中把 position 拽回原位。
	var gpos: Vector2 = ctrl.position
	var gsize: Vector2 = ctrl.size
	ctrl.set_anchors_preset(Control.PRESET_TOP_LEFT, false)
	ctrl.position = gpos
	ctrl.size = gsize
	ctrl.pivot_offset = gsize * 0.5
	_initial_state[ctrl] = {
		"position": gpos,
		"size": gsize,
		"scale": ctrl.scale,
		"modulate": ctrl.modulate,
		"pivot": ctrl.pivot_offset,
	}

# 触发正向转场。origin_panel 是被点中按钮所在面板（或按钮自身）。
func _trigger_transition(origin_panel: Control, _clicked_btn: Control) -> void:
	if _is_transitioning or _is_expanded:
		return
	_is_transitioning = true
	_is_reversed = false
	if _current_tween and _current_tween.is_valid():
		_current_tween.kill()
	_current_tween = create_tween()
	_current_tween.set_parallel(true)
	_current_tween.set_trans(Tween.TRANS_CUBIC)
	_current_tween.set_ease(Tween.EASE_IN_OUT)

	var screen: Vector2 = get_viewport_rect().size

	# 1) origin_panel 内全部按钮淡出。
	#    淡出期间面板会扩大 → 默认 VBox 子节点会被拉伸。
	#    先将子控件 top_level=true 脱离父布局，并固定 global_position/size，避免跟随放大。
	var fade_targets: Array = _collect_buttons_in(origin_panel)
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

	# 2) 其余面板/按钮水平滑出 + 淡出
	for entry in _transition_targets:
		var node: Control = entry.node
		if node == null or node == origin_panel:
			continue
		var dir: int = entry.dir
		var init: Dictionary = _initial_state[node]
		var off_x: float
		if dir > 0:
			off_x = screen.x  # 滑到屏幕右外
		elif dir < 0:
			off_x = -node.size.x - 40.0  # 滑到屏幕左外（含面板宽度）
		else:
			off_x = 0.0
		if dir != 0:
			_current_tween.tween_property(node, "position", Vector2(init.position.x + off_x, init.position.y), TRANSITION_DURATION)
		_current_tween.tween_property(node, "modulate:a", 0.0, TRANSITION_DURATION)

	# 3) origin_panel 以自身中心为锚扩大覆盖全屏。
	#    用 Tween size + position 而非 scale —— scale 形变会拉扯圆角变椭圆。
	#    扩展后 size = 屏幕，position = (0,0)，四边精确贴齐。
	var init_origin: Dictionary = _initial_state[origin_panel]
	var panel_size: Vector2 = init_origin.size
	var panel_center: Vector2 = init_origin.position + panel_size * 0.5
	# 目标 size 锁屏幕；目标 position 让面板中心从 panel_center 平移到屏幕中心。
	# 因 size 增大时左上角默认朝 +x/+y 扩，需主动减去半屏使其以 panel_center 为锚扩展，
	# 最终 position 即 (panel_center - screen/2) 进一步过渡到 (0,0)（即扩满全屏的位置）。
	_current_tween.tween_property(origin_panel, "size", screen, TRANSITION_DURATION)
	_current_tween.tween_property(origin_panel, "position", Vector2.ZERO, TRANSITION_DURATION)
	# pivot 同步移到新 size 中心，保证扩展期间视觉重心稳定（虽 scale=1 时影响小）。
	_current_tween.tween_property(origin_panel, "pivot_offset", screen * 0.5, TRANSITION_DURATION)
	# 提到最前避免被其他面板遮挡。
	origin_panel.move_to_front()
	# 防止未用警告
	var _unused_center: Vector2 = panel_center

	await _current_tween.finished
	_is_transitioning = false
	_is_expanded = true
	# 转场完成后在扩展面板右上角挂"返回"按钮。
	_spawn_back_button(origin_panel)

# 在 origin_panel 右上角创建返回按钮（样式/大小同 OptionsBtn）。
func _spawn_back_button(origin_panel: Control) -> void:
	if _back_btn and is_instance_valid(_back_btn):
		_back_btn.queue_free()
	_back_btn = Button.new()
	_back_btn.name = "BackBtn"
	_back_btn.text = "返回"
	_back_btn.add_theme_font_size_override("font_size", 32)
	# 直接挂到 MainMenu 根节点（而非 origin_panel）—— 反向 Tween 时 origin_panel 会缩回小尺寸，
	# 若挂内部按钮会随之缩小/裁剪。挂根节点定位屏幕右上角即可。
	add_child(_back_btn)
	_back_btn.set_anchors_preset(Control.PRESET_TOP_RIGHT, false)
	_back_btn.offset_left = -OPTIONS_BTN_MARGIN - OPTIONS_BTN_W
	_back_btn.offset_top = OPTIONS_BTN_MARGIN
	_back_btn.offset_right = -OPTIONS_BTN_MARGIN
	_back_btn.offset_bottom = OPTIONS_BTN_MARGIN + OPTIONS_BTN_H
	ThemeFactory.apply_button_styles(_back_btn, ThemeFactory.primary_button_styles())
	_back_btn.add_theme_color_override("font_color", Color.WHITE)
	_back_btn.add_theme_color_override("font_hover_color", Color.WHITE)
	_back_btn.add_theme_color_override("font_pressed_color", Color.WHITE)
	_back_btn.pressed.connect(_trigger_reverse)

# 反向：把所有节点 Tween 回 _initial_state。
func _trigger_reverse() -> void:
	if _current_tween and _current_tween.is_valid():
		_current_tween.kill()
	# 立刻移除返回按钮，避免反向期间被点击重入。
	if _back_btn and is_instance_valid(_back_btn):
		_back_btn.queue_free()
		_back_btn = null
	_is_transitioning = true
	_is_reversed = true
	_is_expanded = false
	# 解冻 top_level 让子控件重新回到父布局，反向期间面板收缩它们随之归位。
	for c in _frozen_children:
		if is_instance_valid(c):
			c.top_level = false
	_frozen_children.clear()
	_frozen_state.clear()
	_current_tween = create_tween()
	_current_tween.set_parallel(true)
	_current_tween.set_trans(Tween.TRANS_CUBIC)
	_current_tween.set_ease(Tween.EASE_IN_OUT)

	for node in _initial_state.keys():
		var init: Dictionary = _initial_state[node]
		_current_tween.tween_property(node, "position", init.position, TRANSITION_DURATION)
		_current_tween.tween_property(node, "size", init.size, TRANSITION_DURATION)
		_current_tween.tween_property(node, "scale", init.scale, TRANSITION_DURATION)
		_current_tween.tween_property(node, "pivot_offset", init.pivot, TRANSITION_DURATION)
		_current_tween.tween_property(node, "modulate", init.modulate, TRANSITION_DURATION)

	# 面板内按钮 alpha 复原 —— 延迟到面板收缩接近完成时才淡入，
	# 与正向"面板未完全覆盖前按钮就透明"对称：反向"面板未完全收缩前按钮保持透明"。
	var fade_delay: float = TRANSITION_DURATION - FADE_DURATION
	for pnl in [$LeftNavPnl, $RightSidePnl, $ProfilePnl]:
		for b in _collect_buttons_in(pnl):
			# 先确保起点为 0（正向已设，但避免重入异常）
			b.modulate.a = 0.0
			_current_tween.tween_property(b, "modulate:a", 1.0, FADE_DURATION).set_delay(fade_delay)

	await _current_tween.finished
	_is_transitioning = false

func _collect_buttons_in(root: Node) -> Array:
	# 收集面板内需要随转场淡出/淡入的子控件：Button / Label / TextureRect。
	# 不包含面板自身（其需扩大显示，不能淡）。
	var out: Array = []
	if root is Button or root is Label or root is TextureRect:
		out.append(root)
		return out
	for child in root.get_children():
		if child is Button or child is Label or child is TextureRect:
			out.append(child)
		elif child is Node:
			out.append_array(_collect_buttons_in(child))
	return out

# 反向由"返回"按钮触发，不再监听右键。
