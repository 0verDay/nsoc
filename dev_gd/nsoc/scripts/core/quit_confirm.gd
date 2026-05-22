extends Node

# 退出确认弹窗（autoload 单例，挂在 /root 下）。
#
# 触发入口：
#   1. 主菜单"退出游戏"按钮（main_menu._on_settings_exit）
#   2. Android 返回键（_notification(NOTIFICATION_WM_GO_BACK_REQUEST)）
#
# UI：
#   - 全屏半透 overlay（点击 = 取消）
#   - 居中大面板（约屏宽/高的 70%/50%，面积约屏 1/2）
#   - 面板上写"点击该面板以退出游戏"，点击 = 退出
#   - 重复请求时只显示一份（_is_open 防抖）
#
# 不拦桌面窗口 X 关闭：让 Godot 默认行为接管（NOTIFICATION_WM_CLOSE_REQUEST 不监听）。

const PANEL_WIDTH_RATIO: float = 0.7
const PANEL_HEIGHT_RATIO: float = 0.5
const FADE_DURATION: float = 0.18

var _is_open: bool = false
var _root_layer: CanvasLayer
var _overlay: ColorRect
var _panel: Panel


func _ready() -> void:
	# 拦住手机端"返回"按键，避免被 Godot 默认 quit 直接吞掉。
	# 当 quit_on_go_back = true 时 NOTIFICATION_WM_GO_BACK_REQUEST 触发后引擎会立刻 quit，
	# 我们在此 notification 内调 request_quit() 挂出弹窗即可（弹窗自己决定是否真的 quit）。
	# 要让本回调先于默认行为生效，project.godot 需关掉 application/config/quit_on_go_back。
	pass


# 外部入口：弹窗已开则忽略。
func request_quit() -> void:
	if _is_open:
		return
	_is_open = true
	_build_ui()
	_play_open_anim()


# Android 返回键 + 桌面右上 X 都会派 NOTIFICATION_WM_*_REQUEST 给所有 Node。
# 用户需求：只拦 Android 返回（手机），不拦桌面 X。
# Godot 4 中 NOTIFICATION_WM_GO_BACK_REQUEST 是 Android 返回；
# NOTIFICATION_WM_CLOSE_REQUEST 是桌面关闭请求。
func _notification(what: int) -> void:
	if what == NOTIFICATION_WM_GO_BACK_REQUEST:
		request_quit()


# CanvasLayer 保证弹窗显示在所有 UI 之上（z_index 在 CanvasLayer 间生效）。
func _build_ui() -> void:
	_root_layer = CanvasLayer.new()
	_root_layer.layer = 100  # 高于游戏层
	add_child(_root_layer)

	# 半透黑 overlay：点击 = 取消
	_overlay = ColorRect.new()
	_overlay.color = Color(0, 0, 0, 0.5)
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	_overlay.gui_input.connect(_on_overlay_input)
	_root_layer.add_child(_overlay)

	# 中央大面板：点击 = 退出
	var vp_w: float = float(ProjectSettings.get_setting("display/window/size/viewport_width", 1920))
	var vp_h: float = float(ProjectSettings.get_setting("display/window/size/viewport_height", 1080))
	var pw: float = vp_w * PANEL_WIDTH_RATIO
	var ph: float = vp_h * PANEL_HEIGHT_RATIO

	_panel = Panel.new()
	# 锚 (0.5,0.5) 让面板中心对齐父中心；offset 给出半宽/半高即 PRESET_CENTER + 居中尺寸。
	_panel.anchor_left = 0.5
	_panel.anchor_right = 0.5
	_panel.anchor_top = 0.5
	_panel.anchor_bottom = 0.5
	_panel.offset_left = -pw / 2.0
	_panel.offset_right = pw / 2.0
	_panel.offset_top = -ph / 2.0
	_panel.offset_bottom = ph / 2.0
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.gui_input.connect(_on_panel_input)
	# 复用 ThemeFactory 风格保持视觉一致（白底 + 圆角 + 阴影）。
	_panel.add_theme_stylebox_override(
		"panel",
		ThemeFactory.panel(Color.WHITE, Color(1, 1, 1, 0.6), 1, 24, true)
	)
	_overlay.add_child(_panel)

	var lbl := Label.new()
	lbl.text = "点击该面板以退出游戏"
	lbl.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 48)
	lbl.add_theme_color_override("font_color", Color(0.2, 0.2, 0.2))
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_panel.add_child(lbl)


func _on_overlay_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_close()


func _on_panel_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		# 阻止冒泡到 overlay（panel 是 overlay 的子，事件在 panel STOP 时不再冒泡）。
		_panel.accept_event()
		_do_quit()


func _play_open_anim() -> void:
	if _root_layer == null:
		return
	_overlay.modulate.a = 0.0
	_panel.scale = Vector2(0.9, 0.9)
	# pivot_offset 用 anchor 解析后的尺寸：anchor 已设 (0.5,0.5) + offset 半宽半高，
	# 等一帧让 Container 计算 size，再设 pivot 为中心。
	await get_tree().process_frame
	if not is_instance_valid(_panel):
		return
	_panel.pivot_offset = _panel.size / 2.0
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(_overlay, "modulate:a", 1.0, FADE_DURATION).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tw.tween_property(_panel, "scale", Vector2.ONE, FADE_DURATION).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)


func _close() -> void:
	if not _is_open:
		return
	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(_overlay, "modulate:a", 0.0, FADE_DURATION).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tw.tween_property(_panel, "scale", Vector2(0.9, 0.9), FADE_DURATION).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	await tw.finished
	if is_instance_valid(_root_layer):
		_root_layer.queue_free()
	_root_layer = null
	_overlay = null
	_panel = null
	_is_open = false


func _do_quit() -> void:
	get_tree().quit()
