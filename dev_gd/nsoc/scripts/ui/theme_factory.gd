class_name ThemeFactory
extends RefCounted

# 统一样式工厂。原 main.gd / cell.gd / hand_card.gd 三份 create_style 合并于此。

static func panel(bg_color: Color, border_color: Color, border_width: int, corner_radius: int, shadow: bool = false) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg_color
	sb.border_width_left = border_width
	sb.border_width_right = border_width
	sb.border_width_top = border_width
	sb.border_width_bottom = border_width
	sb.border_color = border_color
	sb.corner_radius_top_left = corner_radius
	sb.corner_radius_top_right = corner_radius
	sb.corner_radius_bottom_left = corner_radius
	sb.corner_radius_bottom_right = corner_radius
	if shadow:
		sb.shadow_color = Color(0, 0, 0, 0.08)
		sb.shadow_size = 15
	return sb

# cell.gd 中的轻阴影版本（shadow 较小）。
static func cell_panel(bg_color: Color, border_color: Color, border_width: int, corner_radius: int, shadow: bool = false) -> StyleBoxFlat:
	var sb := panel(bg_color, border_color, border_width, corner_radius, false)
	if shadow:
		sb.shadow_color = Color(0, 0, 0, 0.05)
		sb.shadow_size = 5
	return sb

# hand_card.gd 中的轻阴影版本。
static func card_panel(bg_color: Color, border_color: Color, border_width: int, corner_radius: int, shadow: bool = false) -> StyleBoxFlat:
	var sb := panel(bg_color, border_color, border_width, corner_radius, false)
	if shadow:
		sb.shadow_color = Color(0, 0, 0, 0.06)
		sb.shadow_size = 5
	return sb

# 蓝色主按钮三态：返回 {normal, hover, pressed}。
static func primary_button_styles() -> Dictionary:
	return {
		"normal": panel(Color("#339af0"), Color.TRANSPARENT, 0, 12, true),
		"hover": panel(Color("#228be6"), Color.TRANSPARENT, 0, 12, true),
		"pressed": panel(Color("#228be6"), Color.TRANSPARENT, 0, 12),
		"disabled": panel(Color("#999999"), Color.TRANSPARENT, 0, 12),
	}

static func apply_button_styles(btn: Button, styles: Dictionary) -> void:
	if styles.has("normal"):
		btn.add_theme_stylebox_override("normal", styles.normal)
	if styles.has("hover"):
		btn.add_theme_stylebox_override("hover", styles.hover)
	if styles.has("pressed"):
		btn.add_theme_stylebox_override("pressed", styles.pressed)
	if styles.has("disabled"):
		btn.add_theme_stylebox_override("disabled", styles.disabled)

# 设置面板按钮的略深三态。
static func settings_button_styles() -> Dictionary:
	return {
		"normal": panel(Color("#339af0"), Color.TRANSPARENT, 0, 12, true),
		"hover": panel(Color("#228be6"), Color.TRANSPARENT, 0, 12, true),
		"pressed": panel(Color("#1c7ed6"), Color.TRANSPARENT, 0, 12),
	}

# 圆角胶囊（HP/费用/攻击数字底图）。
static func pill(bg_color: Color, radius: int = 12, shadow: bool = false) -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = bg_color
	sb.corner_radius_top_left = radius
	sb.corner_radius_top_right = radius
	sb.corner_radius_bottom_left = radius
	sb.corner_radius_bottom_right = radius
	if shadow:
		sb.shadow_color = Color(0, 0, 0, 0.1)
		sb.shadow_size = 3
	return sb

# 效果徽章样式。
static func badge() -> StyleBoxFlat:
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("#868e96")
	sb.border_width_left = 1
	sb.border_width_right = 1
	sb.border_width_top = 1
	sb.border_width_bottom = 1
	sb.border_color = Color.BLACK
	sb.corner_radius_top_left = 4
	sb.corner_radius_top_right = 4
	sb.corner_radius_bottom_left = 4
	sb.corner_radius_bottom_right = 4
	sb.content_margin_left = 4
	sb.content_margin_right = 4
	sb.content_margin_top = 4
	sb.content_margin_bottom = 4
	return sb

# 侧栏列表项三态样式。
static func list_item_styles() -> Dictionary:
	var base := StyleBoxFlat.new()
	base.bg_color = Color(1, 1, 1, 0.6)
	base.corner_radius_top_left = 8
	base.corner_radius_top_right = 8
	base.corner_radius_bottom_left = 8
	base.corner_radius_bottom_right = 8
	base.content_margin_top = 10
	base.content_margin_bottom = 10
	var hover := base.duplicate()
	hover.bg_color = Color(1, 1, 1, 0.8)
	var pressed := base.duplicate()
	pressed.bg_color = Color(0.9, 0.9, 0.9, 0.9)
	return {"normal": base, "hover": hover, "pressed": pressed, "focus": StyleBoxEmpty.new()}

# 给 HSlider 上 NSOC 风格：浅灰槽 + 蓝色已填充 + 方形按钮把手。
static func apply_slider_style(slider: HSlider) -> void:
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color("#dee2e6")
	bg.corner_radius_top_left = 6
	bg.corner_radius_top_right = 6
	bg.corner_radius_bottom_left = 6
	bg.corner_radius_bottom_right = 6
	bg.content_margin_top = 6
	bg.content_margin_bottom = 6
	slider.add_theme_stylebox_override("slider", bg)

	var fill := StyleBoxFlat.new()
	fill.bg_color = Color("#339af0")
	fill.corner_radius_top_left = 6
	fill.corner_radius_top_right = 6
	fill.corner_radius_bottom_left = 6
	fill.corner_radius_bottom_right = 6
	slider.add_theme_stylebox_override("grabber_area", fill)
	slider.add_theme_stylebox_override("grabber_area_highlight", fill)

	# 方形按钮把手（程序生成纹理）。
	var w: int = 48
	var h: int = 26
	var radius: int = 8
	var normal_tex := _make_rect_grabber(w, h, Color("#228be6"), Color.WHITE, 2, radius)
	var hover_tex := _make_rect_grabber(w, h, Color("#1c7ed6"), Color.WHITE, 2, radius)
	slider.add_theme_icon_override("grabber", normal_tex)
	slider.add_theme_icon_override("grabber_highlight", hover_tex)
	slider.add_theme_icon_override("grabber_disabled", _make_rect_grabber(w, h, Color("#adb5bd"), Color.WHITE, 2, radius))

# 生成圆角长方形按钮把手纹理：实色填充 + 描边。
static func _make_rect_grabber(w: int, h: int, fill: Color, border: Color, border_w: int, radius: int) -> ImageTexture:
	var img := Image.create(w, h, false, Image.FORMAT_RGBA8)
	img.fill(Color(0, 0, 0, 0))
	var r: float = float(radius)
	for y in h:
		for x in w:
			var px: float = float(x) + 0.5
			var py: float = float(y) + 0.5
			# 圆角四个圆心（像素坐标系）
			var cx: float = -1.0
			var cy: float = -1.0
			if px < r and py < r:
				cx = r
				cy = r
			elif px > float(w) - r and py < r:
				cx = float(w) - r
				cy = r
			elif px < r and py > float(h) - r:
				cx = r
				cy = float(h) - r
			elif px > float(w) - r and py > float(h) - r:
				cx = float(w) - r
				cy = float(h) - r
			var dist_to_corner: float = -1.0
			if cx >= 0.0:
				var dx: float = px - cx
				var dy: float = py - cy
				dist_to_corner = sqrt(dx * dx + dy * dy)
				if dist_to_corner > r:
					continue
			# 描边判定：距任何外边的最小距离 < border_w 即为描边
			var min_edge: float = min(min(px, float(w) - px), min(py, float(h) - py))
			var is_border: bool = min_edge < float(border_w)
			# 圆角区按到圆心的距离判定描边（避免方形描边在圆角处错位）
			if dist_to_corner >= 0.0:
				is_border = (r - dist_to_corner) < float(border_w)
			img.set_pixel(x, y, border if is_border else fill)
	return ImageTexture.create_from_image(img)

# 给 OptionButton 上 NSOC 风格：白底蓝边 + 蓝弹出列表。
static func apply_option_button_style(opt: OptionButton) -> void:
	var make_box := func(bg: Color, border: Color) -> StyleBoxFlat:
		var sb := StyleBoxFlat.new()
		sb.bg_color = bg
		sb.border_color = border
		sb.border_width_left = 2
		sb.border_width_right = 2
		sb.border_width_top = 2
		sb.border_width_bottom = 2
		sb.corner_radius_top_left = 10
		sb.corner_radius_top_right = 10
		sb.corner_radius_bottom_left = 10
		sb.corner_radius_bottom_right = 10
		sb.content_margin_left = 14
		sb.content_margin_right = 14
		sb.content_margin_top = 8
		sb.content_margin_bottom = 8
		return sb
	opt.add_theme_stylebox_override("normal", make_box.call(Color.WHITE, Color("#339af0")))
	opt.add_theme_stylebox_override("hover", make_box.call(Color("#e7f5ff"), Color("#228be6")))
	opt.add_theme_stylebox_override("pressed", make_box.call(Color("#d0ebff"), Color("#1c7ed6")))
	opt.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	opt.add_theme_color_override("font_color", Color("#1f2937"))
	opt.add_theme_color_override("font_hover_color", Color("#1f2937"))
	opt.add_theme_color_override("font_pressed_color", Color("#1f2937"))

	var popup := opt.get_popup()
	var pop_panel := StyleBoxFlat.new()
	pop_panel.bg_color = Color.WHITE
	pop_panel.border_color = Color("#339af0")
	pop_panel.border_width_left = 2
	pop_panel.border_width_right = 2
	pop_panel.border_width_top = 2
	pop_panel.border_width_bottom = 2
	pop_panel.corner_radius_top_left = 10
	pop_panel.corner_radius_top_right = 10
	pop_panel.corner_radius_bottom_left = 10
	pop_panel.corner_radius_bottom_right = 10
	pop_panel.content_margin_left = 6
	pop_panel.content_margin_right = 6
	pop_panel.content_margin_top = 6
	pop_panel.content_margin_bottom = 6
	popup.add_theme_stylebox_override("panel", pop_panel)

	var hover_item := StyleBoxFlat.new()
	hover_item.bg_color = Color("#e7f5ff")
	hover_item.corner_radius_top_left = 6
	hover_item.corner_radius_top_right = 6
	hover_item.corner_radius_bottom_left = 6
	hover_item.corner_radius_bottom_right = 6
	popup.add_theme_stylebox_override("hover", hover_item)
	popup.add_theme_color_override("font_color", Color("#1f2937"))
	popup.add_theme_color_override("font_hover_color", Color("#1c7ed6"))
