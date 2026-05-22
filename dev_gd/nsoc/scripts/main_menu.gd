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

# 当前显示的二级面板（任意主菜单导航按钮触发）。
# 反向时与转场同步淡出并销毁。
var _secondary_panel: SecondaryPanel
# 当前扩展态下被点中的按钮（用于按钮名 → 二级面板场景的路由）
var _origin_btn: Control

# 按钮名 → 二级面板 PackedScene 路由表。所有主菜单导航按钮一一对应。
# ProfilePnl 没有按钮节点，使用面板自身节点名 "ProfilePnl" 作 key。
const SECONDARY_PANEL_SCENES: Dictionary = {
	"GrowBtn": preload("res://scenes/GrowPanel.tscn"),
	"PrepareBtn": preload("res://scenes/PreparePanel.tscn"),
	"FriendBtn": preload("res://scenes/FriendPanel.tscn"),
	"CollectionBtn": preload("res://scenes/CollectionPanel.tscn"),
	"CustomBtn": preload("res://scenes/CustomPanel.tscn"),
	"CampaignBtn": preload("res://scenes/CampaignPanel.tscn"),
	"JourneyBtn": preload("res://scenes/JourneyPanel.tscn"),
	"SparringBtn": preload("res://scenes/SparringPanel.tscn"),
	"ProfilePnl": preload("res://scenes/ProfileSubPanel.tscn"),
}

# ---------------- 选项二级菜单 ----------------
# 复用游玩场景 SettingsPanelController：暗色 overlay + 居中圆角面板，
# 一级"返回/设置/退出游戏"，"设置"切到二级配置。
# 主菜单已自建 _options_btn（位置在右上），故 create_trigger_button=false。
var _settings: SettingsPanelController

# ---------------- 转场动画 ----------------
# 点击非"选项"按钮 → 该按钮所在面板内全部按钮淡出 + 其余面板/按钮水平滑出
# + 被点中面板以中心快速扩大覆盖全屏。
# 调试期右键反向播放，便于来回验证。
const TRANSITION_DURATION: float = 0.45
const FADE_DURATION: float = 0.15
# 扩展终态四周留白，使面板边框/圆角不被屏幕切掉
const EXPANDED_MARGIN: float = 24.0

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
	_build_settings_controller()
	if _test_btn:
		_test_btn.pressed.connect(_on_test_pressed)
	if _options_btn:
		_options_btn.pressed.connect(_on_options_pressed)
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

# ---------------- 选项二级菜单实现 ----------------

func _build_settings_controller() -> void:
	_settings = SettingsPanelController.new()
	_settings.name = "SettingsController"
	add_child(_settings)
	_settings.setup(self, {
		"create_trigger_button": false,
		"resume_label": "返回",
		"exit_label": "退出游戏",
		"exit_action": Callable(self, "_on_settings_exit"),
		"can_open": Callable(self, "_can_open_settings"),
	})

func _on_settings_exit() -> void:
	# 走全局退出确认弹窗（autoload QuitConfirm，挂在 /root/QuitConfirm），
	# 玩家在弹窗内确认才真正 quit。用绝对路径取节点避免 autoload 名解析依赖。
	var qc := get_node_or_null("/root/QuitConfirm")
	if qc:
		qc.request_quit()
	else:
		get_tree().quit()

func _can_open_settings() -> bool:
	# 转场展开期间禁用选项弹窗。
	return not _is_transitioning and not _is_expanded

func _on_options_pressed() -> void:
	_settings.open()

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
	# 玩家信息面板：套一层透明 Button 接管点击，享受 hover/press/聚焦反馈，
	# 同时保留 Panel + Avatar + Label 的原有视觉。
	if profile:
		_install_profile_button(profile)

	# 来自 SplashScreen：消费 meta，播放首次入场水平滑入动画。
	# meta key 与 splash_screen.gd 的 INTRO_META_KEY 保持一致。
	if Engine.has_meta("play_main_menu_intro"):
		Engine.remove_meta("play_main_menu_intro")
		_play_intro_animation()

# 在 ProfilePnl 上叠一个 flat 透明 Button 占满面板。
# - 视觉：StyleBox 全透明，hover/press 时 Panel 整体微缩放（与 hand_card/cell 一致）
# - 行为：触发同样的 _trigger_transition；按钮天然支持键盘聚焦/触屏 InputEvent 系
func _install_profile_button(profile: Panel) -> void:
	# pivot 已由 _record_initial 设为面板中心，缩放反馈基于该枢轴。
	# Panel 自身不再处理输入，避免与覆盖按钮重复响应
	profile.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var btn := Button.new()
	btn.name = "ClickArea"
	btn.flat = true
	btn.focus_mode = Control.FOCUS_NONE
	btn.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	btn.mouse_filter = Control.MOUSE_FILTER_STOP
	# 标记：转场淡出收集器跳过它。ClickArea 是点击代理，不应被冻结/淡出，
	# 否则反向后 top_level 切换会破坏其 PRESET_FULL_RECT 锚定，导致点击区位错。
	btn.set_meta("transition_skip", true)
	# 全透明 StyleBox：屏蔽 Button 默认外观，保留 Panel 视觉
	var empty := StyleBoxEmpty.new()
	for slot in ["normal", "hover", "pressed", "focus", "disabled", "hover_pressed"]:
		btn.add_theme_stylebox_override(slot, empty)
	# 子节点（Avatar/Label）需让出鼠标，让 ClickArea 拿到事件
	for child in profile.get_children():
		if child is Control and child != btn:
			_disable_mouse_recursive(child)
	profile.add_child(btn)
	# 微视觉反馈：仅保留按下缩小，去掉 hover 放大（用户偏好：避免悬停响应）
	btn.button_down.connect(func(): _profile_press(profile, true))
	btn.button_up.connect(func(): _profile_press(profile, false))
	btn.pressed.connect(func(): _trigger_transition(profile, profile))

static func _disable_mouse_recursive(c: Control) -> void:
	c.mouse_filter = Control.MOUSE_FILTER_IGNORE
	for sub in c.get_children():
		if sub is Control:
			_disable_mouse_recursive(sub)

func _profile_hover(profile: Control, entered: bool) -> void:
	if _is_transitioning or _is_expanded:
		return
	var t := profile.create_tween()
	t.tween_property(profile, "scale", Vector2(1.02, 1.02) if entered else Vector2.ONE, 0.1)

func _profile_press(profile: Control, pressed: bool) -> void:
	if _is_transitioning or _is_expanded:
		return
	var t := profile.create_tween()
	t.tween_property(profile, "scale", Vector2(0.98, 0.98) if pressed else Vector2.ONE, 0.08)

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
	_origin_btn = _clicked_btn
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

	# 3) origin_panel 以自身中心为锚扩大覆盖全屏（四周留 EXPANDED_MARGIN，让边框/圆角可见）。
	#    用 Tween size + position 而非 scale —— scale 形变会拉扯圆角变椭圆。
	#    扩展后 size = 屏幕 - 2*margin，position = (margin, margin)。
	var init_origin: Dictionary = _initial_state[origin_panel]
	var panel_size: Vector2 = init_origin.size
	var panel_center: Vector2 = init_origin.position + panel_size * 0.5
	var expanded_size: Vector2 = screen - Vector2(EXPANDED_MARGIN * 2.0, EXPANDED_MARGIN * 2.0)
	var expanded_pos: Vector2 = Vector2(EXPANDED_MARGIN, EXPANDED_MARGIN)
	# 目标 size 锁屏幕内边距；目标 position 让面板中心从 panel_center 平移到屏幕中心。
	# 因 size 增大时左上角默认朝 +x/+y 扩，需主动减去半屏使其以 panel_center 为锚扩展，
	# 最终 position 即扩到 (margin, margin)。
	_current_tween.tween_property(origin_panel, "size", expanded_size, TRANSITION_DURATION)
	_current_tween.tween_property(origin_panel, "position", expanded_pos, TRANSITION_DURATION)
	# pivot 同步移到新 size 中心，保证扩展期间视觉重心稳定（虽 scale=1 时影响小）。
	_current_tween.tween_property(origin_panel, "pivot_offset", expanded_size * 0.5, TRANSITION_DURATION)
	# 提到最前避免被其他面板遮挡。
	origin_panel.move_to_front()
	# 防止未用警告
	var _unused_center: Vector2 = panel_center

	await _current_tween.finished
	_is_transitioning = false
	_is_expanded = true
	# 转场完成：按按钮名路由到对应二级面板场景；该场景自带返回按钮。
	_spawn_secondary_panel(origin_panel)

# 路由：按 _origin_btn.name 取 PackedScene → 实例化 → attach 到扩展面板。
# ProfilePnl 自身（无按钮）：origin_btn 与 origin_panel 同节点，name 为 "ProfilePnl"。
func _spawn_secondary_panel(origin_panel: Control) -> void:
	if _secondary_panel and is_instance_valid(_secondary_panel):
		_secondary_panel.queue_free()
		_secondary_panel = null
	var key: String = _origin_btn.name if _origin_btn else ""
	var scene: PackedScene = SECONDARY_PANEL_SCENES.get(key)
	if scene == null:
		push_warning("MainMenu: 未找到 %s 对应的二级面板场景，未生成返回按钮。" % key)
		return
	_secondary_panel = scene.instantiate()
	_secondary_panel.back_pressed.connect(_trigger_reverse)
	_secondary_panel.attach(origin_panel)

# 反向：把所有节点 Tween 回 _initial_state。
func _trigger_reverse() -> void:
	if _current_tween and _current_tween.is_valid():
		_current_tween.kill()
	# 二级面板与转场同步淡出（duration 与 TRANSITION_DURATION 相同）。
	if _secondary_panel and is_instance_valid(_secondary_panel):
		_secondary_panel.detach_with_fade(TRANSITION_DURATION)
		_secondary_panel = null
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
	# 排除带 "transition_skip" 元数据的节点（如 ProfilePnl 上的透明 ClickArea
	# 代理 Button —— 它不是要淡出的视觉元素，且 top_level 切换会破坏其 anchor 布局）。
	# 子树标记 "transition_skip" 时整棵子树跳过（用于 PreparePanel：它有自身淡入/淡出节奏）。
	var out: Array = []
	if root.has_meta("transition_skip"):
		return out
	if root is Button or root is Label or root is TextureRect:
		out.append(root)
		return out
	for child in root.get_children():
		if child is Node and child.has_meta("transition_skip"):
			continue
		if child is Button or child is Label or child is TextureRect:
			out.append(child)
		elif child is Node:
			out.append_array(_collect_buttons_in(child))
	return out

# 反向由"返回"按钮触发，不再监听右键。

# 首次进入 MainMenu 的水平滑入动画（由 SplashScreen 触发）。
# 复用 _transition_targets 的 dir：左侧节点从屏左滑入、右侧从屏右滑入；
# 各面板内按钮先 alpha=0，等面板归位后再淡入（与反向同节奏）。
const INTRO_DURATION: float = 0.55

func _play_intro_animation() -> void:
	if _initial_state.is_empty():
		return
	# 入场动画期间禁止点击按钮触发新转场。
	_is_transitioning = true
	var screen_w: float = get_viewport_rect().size.x
	# 1) 节点起点：水平偏移 dir * screen_w，alpha = 0（中心节点 dir=0 无偏移）。
	for entry in _transition_targets:
		var node: Control = entry.node
		if node == null or not is_instance_valid(node):
			continue
		var init: Dictionary = _initial_state.get(node, {})
		if init.is_empty():
			continue
		var dir: int = int(entry.dir)
		node.position = (init.position as Vector2) + Vector2(float(dir) * screen_w, 0.0)
		node.modulate = Color(1, 1, 1, 0)

	# 2) 面板内按钮起点 alpha=0，由后续延迟 tween 淡入。
	for pnl in [$LeftNavPnl, $RightSidePnl, $ProfilePnl]:
		for b in _collect_buttons_in(pnl):
			b.modulate.a = 0.0

	# 3) tween 回归初始状态。
	if _current_tween and _current_tween.is_valid():
		_current_tween.kill()
	_current_tween = create_tween()
	_current_tween.set_parallel(true)
	_current_tween.set_trans(Tween.TRANS_CUBIC)
	_current_tween.set_ease(Tween.EASE_OUT)
	for entry in _transition_targets:
		var node: Control = entry.node
		if node == null or not is_instance_valid(node):
			continue
		var init: Dictionary = _initial_state.get(node, {})
		if init.is_empty():
			continue
		_current_tween.tween_property(node, "position", init.position, INTRO_DURATION)
		_current_tween.tween_property(node, "modulate", init.modulate, INTRO_DURATION)

	# 按钮淡入：稍晚启动，与面板归位收尾对齐。
	var fade_delay: float = INTRO_DURATION - FADE_DURATION
	for pnl in [$LeftNavPnl, $RightSidePnl, $ProfilePnl]:
		for b in _collect_buttons_in(pnl):
			_current_tween.tween_property(b, "modulate:a", 1.0, FADE_DURATION).set_delay(fade_delay)

	await _current_tween.finished
	_is_transitioning = false
