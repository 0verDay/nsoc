class_name SettingsPanelController
extends Node

# 选项面板控制器。游玩场景 + 主菜单共用。
# 视觉：暗色 overlay + 居中圆角面板 + 一级"继续/设置/退出"+ 二级（主音量 + 返回）。
# 动效：0.2s TRANS_QUAD，居中缩放 0.85→1.0 + 淡入；EASE_OUT 开 / EASE_IN 关。
# 子菜单切换：0.15s 横向滑动 + 淡入淡出。
#
# 调用方传 config 决定：
#   - create_trigger_button: 是否由控制器自建左上"选项"按钮（游玩场景=true，主菜单已自带按钮=false）
#   - resume_label / resume_action: 一级菜单第一项标签 + 行为（默认"继续"+ close）
#   - exit_label / exit_action:    一级菜单第三项标签 + 行为（默认"退回菜单"切回 MainMenu）
#   - can_open: Callable→bool。控制器在打开前询问；主菜单转场期间需禁用。

const OPEN_DURATION: float = 0.2
const SUBMENU_DURATION: float = 0.15
const PANEL_OPEN_SCALE: Vector2 = Vector2(0.85, 0.85)
const SUBMENU_SLIDE_OFFSET: float = 30.0

var _parent: Control
var _btn: Button
var _overlay: ColorRect
var _panel: Panel
var _menu_vbox: VBoxContainer
var _config_vbox: VBoxContainer
var _is_open: bool = false

# 防止重叠：开关面板/子菜单切换中途反复点击导致多 tween 叠加。
var _open_tween: Tween
var _submenu_tween: Tween

# 缓存两个 vbox 的初始 anchored offsets。子菜单切换动画通过修改 position
# 实现平移，会写回 offset_left/right；动画结束后必须恢复，否则下次显示位置歪。
var _menu_offsets: Dictionary = {}
var _config_offsets: Dictionary = {}

# 配置项（见文件头注释）。
var _resume_label: String = "继续"
var _resume_action: Callable
var _exit_label: String = "退回菜单"
var _exit_action: Callable
var _can_open: Callable

func setup(parent: Control, config: Dictionary = {}) -> void:
	_parent = parent
	_resume_label = String(config.get("resume_label", _resume_label))
	_exit_label = String(config.get("exit_label", _exit_label))
	if config.has("resume_action") and config["resume_action"] is Callable:
		_resume_action = config["resume_action"]
	if config.has("exit_action") and config["exit_action"] is Callable:
		_exit_action = config["exit_action"]
	if config.has("can_open") and config["can_open"] is Callable:
		_can_open = config["can_open"]
	if bool(config.get("create_trigger_button", true)):
		_build_button()
	_build_overlay_and_panel()
	# 缓存 vbox 初始 offsets（子菜单切换动画后需恢复）。
	_menu_offsets = _capture_offsets(_menu_vbox)
	_config_offsets = _capture_offsets(_config_vbox)

static func _capture_offsets(c: Control) -> Dictionary:
	return {
		"left": c.offset_left,
		"top": c.offset_top,
		"right": c.offset_right,
		"bottom": c.offset_bottom,
	}

static func _restore_offsets(c: Control, o: Dictionary) -> void:
	c.offset_left = o.left
	c.offset_top = o.top
	c.offset_right = o.right
	c.offset_bottom = o.bottom

func _build_button() -> void:
	_btn = Button.new()
	_btn.name = "SettingsBtn"
	_btn.text = "选项"
	_btn.add_theme_font_size_override("font_size", 32)
	_btn.set_anchors_preset(Control.PRESET_TOP_LEFT, false)
	_btn.offset_left = 20
	_btn.offset_top = 20
	_btn.offset_right = 180
	_btn.offset_bottom = 100
	ThemeFactory.apply_button_styles(_btn, ThemeFactory.primary_button_styles())
	_btn.add_theme_color_override("font_color", Color.WHITE)
	_parent.add_child(_btn)
	_btn.pressed.connect(_on_btn_pressed)

func _build_overlay_and_panel() -> void:
	_overlay = ColorRect.new()
	_overlay.name = "SettingsOverlay"
	_overlay.color = Color(0, 0, 0, 0.5)
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_overlay.visible = false
	_parent.add_child(_overlay)
	_overlay.gui_input.connect(_on_overlay_input)

	_panel = Panel.new()
	_panel.name = "SettingsPanel"
	_panel.set_anchors_preset(Control.PRESET_CENTER, false)
	_panel.offset_left = -300
	_panel.offset_top = -200
	_panel.offset_right = 300
	_panel.offset_bottom = 200
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.add_theme_stylebox_override("panel", ThemeFactory.panel(Color(0.96, 0.97, 0.98, 1.0), Color("#d1d9e0"), 1, 20, true))
	# 缩放动效需以面板中心为枢轴。offset_right-offset_left = 600，offset_bottom-offset_top = 400。
	_panel.pivot_offset = Vector2(300, 200)
	_overlay.add_child(_panel)

	var vbox := VBoxContainer.new()
	vbox.name = "SettingsVBox"
	vbox.set_anchors_preset(Control.PRESET_CENTER, false)
	vbox.offset_left = -140
	vbox.offset_top = -135
	vbox.offset_right = 140
	vbox.offset_bottom = 135
	vbox.add_theme_constant_override("separation", 20)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	_panel.add_child(vbox)
	_menu_vbox = vbox

	var resume_btn := _make_button(_resume_label)
	resume_btn.pressed.connect(_on_resume_pressed)
	vbox.add_child(resume_btn)

	var config_btn := _make_button("设置")
	config_btn.pressed.connect(_show_config)
	vbox.add_child(config_btn)

	var exit_btn := _make_button(_exit_label)
	exit_btn.pressed.connect(_on_exit_pressed)
	vbox.add_child(exit_btn)

	_build_config_vbox()

func _on_resume_pressed() -> void:
	if _resume_action.is_valid():
		_resume_action.call()
	else:
		close()

func _on_exit_pressed() -> void:
	if _exit_action.is_valid():
		_exit_action.call()
	else:
		get_tree().change_scene_to_file("res://scenes/MainMenu.tscn")

func _build_config_vbox() -> void:
	var vbox := VBoxContainer.new()
	vbox.name = "ConfigVBox"
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	vbox.offset_left = 30
	vbox.offset_top = 25
	vbox.offset_right = -30
	vbox.offset_bottom = -25
	vbox.add_theme_constant_override("separation", 14)
	vbox.visible = false
	_panel.add_child(vbox)
	_config_vbox = vbox

	# 标题
	var title := Label.new()
	title.text = "设置"
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", Color("#1c7ed6"))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(title)

	var sep := HSeparator.new()
	var sep_style := StyleBoxFlat.new()
	sep_style.bg_color = Color("#d1d9e0")
	sep_style.content_margin_top = 1
	sep_style.content_margin_bottom = 1
	sep.add_theme_stylebox_override("separator", sep_style)
	vbox.add_child(sep)

	# 主音量
	var vol_label := Label.new()
	vol_label.text = "主音量"
	vol_label.add_theme_font_size_override("font_size", 22)
	vol_label.add_theme_color_override("font_color", Color("#1f2937"))
	vbox.add_child(vol_label)

	var vol_slider := HSlider.new()
	vol_slider.name = "MasterVolumeSlider"
	vol_slider.min_value = 0.0
	vol_slider.max_value = 100.0
	vol_slider.step = 1.0
	vol_slider.value = 80.0
	vol_slider.custom_minimum_size = Vector2(0, 32)
	ThemeFactory.apply_slider_style(vol_slider)
	vbox.add_child(vol_slider)

	# 占位间隔
	var spacer := Control.new()
	spacer.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(spacer)

	var back_btn := _make_button("返回")
	back_btn.pressed.connect(_show_menu)
	vbox.add_child(back_btn)

func _show_config() -> void:
	_animate_submenu_swap(_menu_vbox, _config_vbox, 1)

func _show_menu() -> void:
	_animate_submenu_swap(_config_vbox, _menu_vbox, -1)

# 子菜单横向滑动淡入淡出。dir=1：新内容自右滑入；dir=-1：自左滑入。
# 风格对齐 detail_panel/侧栏：TRANS_QUAD + 0.15s。
# 注意：两个 vbox 都是 anchored 容器，赋值 position 会写回 offset_left/right。
# 这里先把双方 offsets 复位到基准，再以基准为锚做相对位移；动画结束后再
# 强制 restore，确保下次显示对齐 panel 设计的留白。
func _animate_submenu_swap(from_vbox: VBoxContainer, to_vbox: VBoxContainer, dir: int) -> void:
	if _submenu_tween and _submenu_tween.is_valid():
		_submenu_tween.kill()

	var from_offsets: Dictionary = _menu_offsets if from_vbox == _menu_vbox else _config_offsets
	var to_offsets: Dictionary = _menu_offsets if to_vbox == _menu_vbox else _config_offsets

	# 双方先复位基准 offsets，避免上次动画中途打断残留。
	_restore_offsets(from_vbox, from_offsets)
	_restore_offsets(to_vbox, to_offsets)

	# to_vbox 起始：基准位置 + 偏移。直接 tween offset_left/right 而非 position，
	# 避免 anchored 容器 position 赋值被解算为 offsets 的副作用混乱。
	to_vbox.modulate.a = 0.0
	to_vbox.visible = true
	to_vbox.offset_left = to_offsets.left + SUBMENU_SLIDE_OFFSET * dir
	to_vbox.offset_right = to_offsets.right + SUBMENU_SLIDE_OFFSET * dir

	_submenu_tween = get_tree().create_tween()
	_submenu_tween.set_parallel(true)
	_submenu_tween.set_trans(Tween.TRANS_QUAD)

	# 旧内容：从基准向反方向滑出 + 淡出
	_submenu_tween.tween_property(from_vbox, "modulate:a", 0.0, SUBMENU_DURATION).set_ease(Tween.EASE_IN)
	_submenu_tween.tween_property(from_vbox, "offset_left", from_offsets.left - SUBMENU_SLIDE_OFFSET * dir, SUBMENU_DURATION).set_ease(Tween.EASE_IN)
	_submenu_tween.tween_property(from_vbox, "offset_right", from_offsets.right - SUBMENU_SLIDE_OFFSET * dir, SUBMENU_DURATION).set_ease(Tween.EASE_IN)

	# 新内容：从偏移位置回到基准 + 淡入
	_submenu_tween.tween_property(to_vbox, "modulate:a", 1.0, SUBMENU_DURATION).set_ease(Tween.EASE_OUT)
	_submenu_tween.tween_property(to_vbox, "offset_left", to_offsets.left, SUBMENU_DURATION).set_ease(Tween.EASE_OUT)
	_submenu_tween.tween_property(to_vbox, "offset_right", to_offsets.right, SUBMENU_DURATION).set_ease(Tween.EASE_OUT)

	# 动画结束：旧内容隐藏，并把双方 offsets 强制 restore 到基准（兜底）。
	_submenu_tween.chain().tween_callback(func():
		from_vbox.visible = false
		_restore_offsets(from_vbox, from_offsets)
		_restore_offsets(to_vbox, to_offsets))

func _make_button(label: String) -> Button:
	var b := Button.new()
	b.text = label
	b.custom_minimum_size = Vector2(280, 70)
	b.add_theme_font_size_override("font_size", 26)
	b.add_theme_color_override("font_color", Color.WHITE)
	ThemeFactory.apply_button_styles(b, ThemeFactory.settings_button_styles())
	return b

func _on_btn_pressed() -> void:
	open()

# 公开打开入口。主菜单（不自建按钮）通过此方法触发。
func open() -> void:
	if _is_open:
		return
	if _can_open.is_valid() and not bool(_can_open.call()):
		return
	_is_open = true
	_overlay.move_to_front()
	_overlay.visible = true
	# 重置主菜单为可见、子设置为隐藏（避免上次关闭时残留状态）。
	_menu_vbox.visible = true
	_menu_vbox.modulate.a = 1.0
	_restore_offsets(_menu_vbox, _menu_offsets)
	_config_vbox.visible = false
	_config_vbox.modulate.a = 1.0
	_restore_offsets(_config_vbox, _config_offsets)
	_animate_open()

# 居中面板打开：overlay 淡入 + panel 缩放放大 + 淡入。
# 风格：0.2s TRANS_QUAD EASE_OUT，与项目其他面板一致。
func _animate_open() -> void:
	if _open_tween and _open_tween.is_valid():
		_open_tween.kill()
	_overlay.modulate.a = 0.0
	_panel.scale = PANEL_OPEN_SCALE
	_panel.modulate.a = 0.0
	_open_tween = get_tree().create_tween()
	_open_tween.set_parallel(true)
	_open_tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	_open_tween.tween_property(_overlay, "modulate:a", 1.0, OPEN_DURATION)
	_open_tween.tween_property(_panel, "scale", Vector2.ONE, OPEN_DURATION)
	_open_tween.tween_property(_panel, "modulate:a", 1.0, OPEN_DURATION)

func _on_overlay_input(event) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var mp := _overlay.get_local_mouse_position()
		if not _panel.get_rect().has_point(mp):
			close()

func close() -> void:
	if not _is_open:
		return
	_is_open = false
	_animate_close()

# 居中面板关闭：与打开反向，EASE_IN，结束后 overlay.visible = false。
func _animate_close() -> void:
	if _open_tween and _open_tween.is_valid():
		_open_tween.kill()
	_open_tween = get_tree().create_tween()
	_open_tween.set_parallel(true)
	_open_tween.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	_open_tween.tween_property(_overlay, "modulate:a", 0.0, OPEN_DURATION)
	_open_tween.tween_property(_panel, "scale", PANEL_OPEN_SCALE, OPEN_DURATION)
	_open_tween.tween_property(_panel, "modulate:a", 0.0, OPEN_DURATION)
	_open_tween.chain().tween_callback(func():
		_overlay.visible = false
		# 复位下次打开的初始视觉态。
		_panel.scale = Vector2.ONE
		_panel.modulate.a = 1.0
		_overlay.modulate.a = 1.0
		# 子菜单复位
		_config_vbox.visible = false
		_menu_vbox.visible = true
		_menu_vbox.modulate.a = 1.0
		_config_vbox.modulate.a = 1.0
		_restore_offsets(_menu_vbox, _menu_offsets)
		_restore_offsets(_config_vbox, _config_offsets))

func is_open() -> bool:
	return _is_open


# 暴露左上"选项"按钮节点，供外部播放入场动画。
# 仅当 setup 时 create_trigger_button=true（游玩场景）时返回非 null。
func get_trigger_button() -> Button:
	return _btn
