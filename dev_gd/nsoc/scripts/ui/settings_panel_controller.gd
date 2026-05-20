class_name SettingsPanelController
extends Node

# 设置按钮 + 居中面板。原 main.gd:813-918 迁移于此。

var _parent: Control
var _btn: Button
var _overlay: ColorRect
var _panel: Panel
var _menu_vbox: VBoxContainer
var _config_vbox: VBoxContainer
var _is_open: bool = false

func setup(parent: Control) -> void:
	_parent = parent
	_build_button()
	_build_overlay_and_panel()

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

	var resume_btn := _make_button("继续")
	resume_btn.pressed.connect(close)
	vbox.add_child(resume_btn)

	var config_btn := _make_button("设置")
	config_btn.pressed.connect(_show_config)
	vbox.add_child(config_btn)

	var exit_btn := _make_button("退出")
	exit_btn.pressed.connect(func(): get_tree().quit())
	vbox.add_child(exit_btn)

	_build_config_vbox()

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
	_menu_vbox.visible = false
	_config_vbox.visible = true

func _show_menu() -> void:
	_config_vbox.visible = false
	_menu_vbox.visible = true

func _make_button(label: String) -> Button:
	var b := Button.new()
	b.text = label
	b.custom_minimum_size = Vector2(280, 70)
	b.add_theme_font_size_override("font_size", 26)
	b.add_theme_color_override("font_color", Color.WHITE)
	ThemeFactory.apply_button_styles(b, ThemeFactory.settings_button_styles())
	return b

func _on_btn_pressed() -> void:
	_is_open = true
	_overlay.move_to_front()
	_overlay.visible = true

func _on_overlay_input(event) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		var mp := _overlay.get_local_mouse_position()
		if not _panel.get_rect().has_point(mp):
			close()

func close() -> void:
	_is_open = false
	_overlay.visible = false
	_show_menu()

func is_open() -> bool:
	return _is_open
