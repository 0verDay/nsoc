class_name EmpireSavePanel
extends RefCounted

# 帝国模式手动存档 UI 构建器。
# 构建可嵌入 SettingsPanelController 的存档选择视图；
# 通过 save_requested 信号把槽位 id 回传给调用方，由调用方执行实际写盘。

signal save_requested(slot_id: String)


# 构建嵌入视图根节点，传给 SettingsPanelController.show_embedded_view()。
func build_embed_view(on_save_cb: Callable, on_cancel_cb: Callable) -> Control:
	var container := Control.new()
	container.mouse_filter = Control.MOUSE_FILTER_PASS

	var vb := VBoxContainer.new()
	vb.name = "SaveEmbedVBox"
	vb.set_anchors_preset(Control.PRESET_FULL_RECT)
	vb.offset_left   = 30;  vb.offset_right  = -30
	vb.offset_top    = 25;  vb.offset_bottom = -25
	vb.add_theme_constant_override("separation", 14)
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.mouse_filter = Control.MOUSE_FILTER_PASS
	container.add_child(vb)

	var title := Label.new()
	title.text = "选择存档槽"
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.add_theme_font_size_override("font_size", 28)
	title.add_theme_color_override("font_color", Color("#1c7ed6"))
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	vb.add_child(title)

	var sep := HSeparator.new()
	var sep_style := StyleBoxFlat.new()
	sep_style.bg_color = Color("#d1d9e0")
	sep_style.content_margin_top = 1; sep_style.content_margin_bottom = 1
	sep.add_theme_stylebox_override("separator", sep_style)
	vb.add_child(sep)

	var entries := _get_save_slot_entries()
	for entry in entries:
		var row := _make_save_slot_row(entry, container, on_save_cb, on_cancel_cb)
		vb.add_child(row)

	var cancel_btn := Button.new()
	cancel_btn.text = "取消"
	cancel_btn.custom_minimum_size = Vector2(280, 70)
	cancel_btn.add_theme_font_size_override("font_size", 26)
	ThemeFactory.apply_button_styles(cancel_btn, ThemeFactory.settings_button_styles())
	cancel_btn.add_theme_color_override("font_color",         Color.WHITE)
	cancel_btn.add_theme_color_override("font_hover_color",   Color.WHITE)
	cancel_btn.add_theme_color_override("font_pressed_color", Color.WHITE)
	cancel_btn.pressed.connect(on_cancel_cb)
	vb.add_child(cancel_btn)

	return container


func _make_save_slot_row(entry: Dictionary, container: Control,
		on_save_cb: Callable, on_cancel_cb: Callable) -> Button:
	var exists: bool = bool(entry.get("exists", false))
	var row := Button.new()
	row.custom_minimum_size = Vector2(0, 70)
	row.flat = false
	row.focus_mode = Control.FOCUS_NONE
	row.mouse_filter = Control.MOUSE_FILTER_STOP

	var normal_c := Color.WHITE if exists else Color("#e9ecef")
	var styles := {
		"normal":   ThemeFactory.panel(normal_c,         Color("#ced4da"), 1, 12, true),
		"hover":    ThemeFactory.panel(Color("#d0ebff"), Color("#74c0fc"), 1, 12, true),
		"pressed":  ThemeFactory.panel(Color("#a5d8ff"), Color("#4dabf7"), 1, 12, true),
		"disabled": ThemeFactory.panel(Color("#e9ecef"), Color("#dee2e6"), 1, 12, false),
	}
	ThemeFactory.apply_button_styles(row, styles)

	var hb := HBoxContainer.new()
	hb.set_anchors_preset(Control.PRESET_FULL_RECT)
	hb.offset_left = 16; hb.offset_right = -16
	hb.offset_top  = 0;  hb.offset_bottom = 0
	hb.add_theme_constant_override("separation", 10)
	hb.alignment = BoxContainer.ALIGNMENT_CENTER
	hb.mouse_filter = Control.MOUSE_FILTER_IGNORE
	row.add_child(hb)

	var lbl_name := Label.new()
	lbl_name.text = str(entry.get("label", ""))
	lbl_name.add_theme_font_size_override("font_size", 24)
	lbl_name.add_theme_color_override("font_color", Color("#1f2937") if exists else Color("#adb5bd"))
	lbl_name.size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	lbl_name.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_child(lbl_name)

	var spacer := Control.new()
	spacer.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	spacer.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_child(spacer)

	var lbl_meta := Label.new()
	lbl_meta.text = str(entry.get("meta_text", "（空）"))
	lbl_meta.add_theme_font_size_override("font_size", 18)
	lbl_meta.add_theme_color_override("font_color", Color("#6c757d") if exists else Color("#ced4da"))
	lbl_meta.size_flags_horizontal = Control.SIZE_SHRINK_END
	lbl_meta.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hb.add_child(lbl_meta)

	var sid: String = str(entry.get("slot_id", ""))
	row.pressed.connect(func(): _on_save_row_pressed(sid, exists, container, on_save_cb, on_cancel_cb))
	return row


func _on_save_row_pressed(slot_id: String, exists: bool, container: Control,
		on_save_cb: Callable, on_cancel_cb: Callable) -> void:
	if exists:
		_show_overwrite_confirm(slot_id, container, on_save_cb, on_cancel_cb)
	else:
		save_requested.emit(slot_id)
		on_save_cb.call()


func _show_overwrite_confirm(slot_id: String, container: Control,
		on_save_cb: Callable, on_cancel_cb: Callable) -> void:
	var co := Control.new()
	co.set_anchors_preset(Control.PRESET_FULL_RECT)
	co.mouse_filter = Control.MOUSE_FILTER_STOP
	co.z_index = 50
	container.add_child(co)

	var bg := Panel.new()
	bg.add_theme_stylebox_override("panel",
		ThemeFactory.panel(Color(0.96, 0.97, 0.98, 0.96), Color("#d1d9e0"), 1, 20, false))
	bg.set_anchors_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	co.add_child(bg)

	var vb := VBoxContainer.new()
	vb.set_anchors_preset(Control.PRESET_CENTER, false)
	vb.offset_left = -140; vb.offset_right  = 140
	vb.offset_top  = -80;  vb.offset_bottom = 80
	vb.add_theme_constant_override("separation", 20)
	vb.alignment = BoxContainer.ALIGNMENT_CENTER
	co.add_child(vb)

	var lbl := Label.new()
	lbl.text = "覆盖已有存档？"
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 26)
	lbl.add_theme_color_override("font_color", Color("#1f2937"))
	vb.add_child(lbl)

	var hb := HBoxContainer.new()
	hb.add_theme_constant_override("separation", 20)
	hb.alignment = BoxContainer.ALIGNMENT_CENTER
	vb.add_child(hb)

	var ok_btn := Button.new()
	ok_btn.text = "覆盖"
	ok_btn.custom_minimum_size = Vector2(140, 64)
	ok_btn.add_theme_font_size_override("font_size", 24)
	ThemeFactory.apply_button_styles(ok_btn, ThemeFactory.primary_button_styles())
	ok_btn.add_theme_color_override("font_color",         Color.WHITE)
	ok_btn.add_theme_color_override("font_hover_color",   Color.WHITE)
	ok_btn.add_theme_color_override("font_pressed_color", Color.WHITE)
	ok_btn.pressed.connect(func():
		save_requested.emit(slot_id)
		on_save_cb.call())
	hb.add_child(ok_btn)

	var no_btn := Button.new()
	no_btn.text = "返回"
	no_btn.custom_minimum_size = Vector2(140, 64)
	no_btn.add_theme_font_size_override("font_size", 24)
	ThemeFactory.apply_button_styles(no_btn, ThemeFactory.settings_button_styles())
	no_btn.add_theme_color_override("font_color",         Color.WHITE)
	no_btn.add_theme_color_override("font_hover_color",   Color.WHITE)
	no_btn.add_theme_color_override("font_pressed_color", Color.WHITE)
	no_btn.pressed.connect(func(): co.queue_free())
	hb.add_child(no_btn)


# 返回手动槽位描述列表。每项：{slot_id, label, meta_text, exists}
func _get_save_slot_entries() -> Array:
	var out: Array = []
	var all_slots := EmpireSaveStorage.list_slots()
	var slot_meta: Dictionary = {}
	for item in all_slots:
		slot_meta[String(item["slot_id"])] = item.get("meta", {})

	var manual_ids: Array = [
		EmpireSaveStorage.SLOT_1,
		EmpireSaveStorage.SLOT_2,
		EmpireSaveStorage.SLOT_3,
	]
	for i in manual_ids.size():
		var sid: String = manual_ids[i]
		var meta: Dictionary = slot_meta.get(sid, {})
		out.append({
			"slot_id":   sid,
			"label":     "存档 " + str(i + 1),
			"meta_text": _format_meta(meta) if not meta.is_empty() else "（空）",
			"exists":    not meta.is_empty(),
		})
	return out


static func _format_meta(meta: Dictionary) -> String:
	if meta.is_empty():
		return "（空）"
	var ts: float = float(meta.get("timestamp", 0.0))
	var dt := Time.get_datetime_dict_from_unix_time(int(ts))
	var date_str: String = "%04d-%02d-%02d %02d:%02d" % [
		int(dt.get("year", 0)), int(dt.get("month", 0)), int(dt.get("day", 0)),
		int(dt.get("hour", 0)), int(dt.get("minute", 0)),
	]
	var scenario: String = str(meta.get("scenario_name", ""))
	var turn: int = int(meta.get("turn_number", 0))
	var gold: int = int(meta.get("gold", 0))
	var food: int = int(meta.get("food", 0))
	return "%s  %s  第%d回合  金:%d 粮:%d" % [date_str, scenario, turn, gold, food]
