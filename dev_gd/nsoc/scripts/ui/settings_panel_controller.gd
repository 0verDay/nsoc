class_name SettingsPanelController
extends Node

# 设置按钮 + 居中面板。原 main.gd:813-918 迁移于此。

var _parent: Control
var _btn: Button
var _overlay: ColorRect
var _panel: Panel
var _is_open: bool = false

func setup(parent: Control) -> void:
	_parent = parent
	_build_button()
	_build_overlay_and_panel()

func _build_button() -> void:
	_btn = Button.new()
	_btn.name = "SettingsBtn"
	_btn.text = "设置"
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

	var resume_btn := _make_button("继续")
	resume_btn.pressed.connect(close)
	vbox.add_child(resume_btn)

	var config_btn := _make_button("设置")
	vbox.add_child(config_btn)

	var exit_btn := _make_button("退出")
	exit_btn.pressed.connect(func(): get_tree().quit())
	vbox.add_child(exit_btn)

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

func is_open() -> bool:
	return _is_open
