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
