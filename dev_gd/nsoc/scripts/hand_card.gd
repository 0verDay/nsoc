extends Panel

var card_data = {}
var card_id = 0

@onready var cost_lbl = $CostBg/CostLbl
@onready var name_lbl = $NameLbl
@onready var atk_lbl = $AtkBg/AtkLbl

var hp_labels = {}

func create_style(bg_color: Color, border_color: Color, border_width: int, corner_radius: int, shadow: bool = false) -> StyleBoxFlat:
	var sb = StyleBoxFlat.new()
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
		sb.shadow_color = Color(0, 0, 0, 0.06)
		sb.shadow_size = 5
	return sb

func _ready():
	add_theme_stylebox_override("panel", create_style(Color.WHITE, Color("#e1e8ed"), 1, 15, true))
	
	var cost_style = StyleBoxFlat.new()
	cost_style.bg_color = Color("#339af0")
	cost_style.corner_radius_top_left = 12
	cost_style.corner_radius_top_right = 12
	cost_style.corner_radius_bottom_left = 12
	cost_style.corner_radius_bottom_right = 12
	cost_style.shadow_color = Color(0, 0, 0, 0.1)
	cost_style.shadow_size = 3
	$CostBg.add_theme_stylebox_override("panel", cost_style)
	
	var atk_style = StyleBoxFlat.new()
	atk_style.bg_color = Color("#ff6b6b")
	atk_style.corner_radius_top_left = 12
	atk_style.corner_radius_top_right = 12
	atk_style.corner_radius_bottom_left = 12
	atk_style.corner_radius_bottom_right = 12
	atk_style.shadow_color = Color(0, 0, 0, 0.1)
	atk_style.shadow_size = 3
	$AtkBg.add_theme_stylebox_override("panel", atk_style)
	
	hp_labels["top"] = $TopHp
	hp_labels["bottom"] = $BottomHp
	hp_labels["left"] = $LeftHp
	hp_labels["right"] = $RightHp
	
	for d in hp_labels.values():
		var sb = StyleBoxFlat.new()
		sb.bg_color = Color("#51cf66")
		sb.corner_radius_top_left = 10
		sb.corner_radius_top_right = 10
		sb.corner_radius_bottom_left = 10
		sb.corner_radius_bottom_right = 10
		d.add_theme_stylebox_override("normal", sb)
	
	pivot_offset = custom_minimum_size / 2.0
	gui_input.connect(_on_gui_input)
	mouse_exited.connect(_on_mouse_exit)

func _on_gui_input(event):
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.is_pressed():
			_on_mouse_enter()
			var main = get_tree().current_scene
			if main and main.has_method("start_long_press"):
				main.start_long_press(card_data)
		else:
			_on_mouse_exit()

func _on_mouse_enter():
	if modulate.a < 1.0: return
	if get_tree():
		var tween = create_tween()
		tween.tween_property(self, "scale", Vector2(1.1, 1.1), 0.1)

func _on_mouse_exit():
	var main = get_tree().current_scene
	if main and main.has_method("cancel_long_press"):
		main.cancel_long_press()
		
	if get_tree():
		var tween = create_tween()
		tween.tween_property(self, "scale", Vector2.ONE, 0.1)

func _process(delta):
	if get_tree() and get_tree().current_scene:
		var main = get_tree().current_scene
		if "is_action_running" in main and main.is_action_running:
			mouse_default_cursor_shape = Control.CURSOR_FORBIDDEN
		else:
			mouse_default_cursor_shape = Control.CURSOR_ARROW

func setup(data, id):
	card_data = data
	card_id = id
	cost_lbl.text = str(data.cost)
	name_lbl.text = data.name
	
	var is_unit = false
	if typeof(data) == TYPE_DICTIONARY:
		is_unit = (data.type == "单位")
	else:
		is_unit = (data is CardUnit)
	
	if is_unit:
		atk_lbl.text = str(data.attack)
		for d in hp_labels.keys():
			hp_labels[d].text = str(data.health[d])
		atk_lbl.visible = true
		$AtkBg.visible = true
		for lbl in hp_labels.values():
			lbl.visible = true
	else:
		atk_lbl.visible = false
		$AtkBg.visible = false
		for lbl in hp_labels.values():
			lbl.visible = false
	
	var badge_container = get_node_or_null("EffectBadges")
	if badge_container:
		for c in badge_container.get_children():
			c.queue_free()
		var effs = data.get("effects", []) if typeof(data) == TYPE_DICTIONARY else data.effects
		for eff in effs:
			var badge_name = EffectUtils.get_display_name(eff)
			
			var vertical_text = ""
			for i in range(badge_name.length()):
				vertical_text += badge_name[i]
				if i < badge_name.length() - 1:
					vertical_text += "\n"
			
			var panel = PanelContainer.new()
			var sb = StyleBoxFlat.new()
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
			panel.add_theme_stylebox_override("panel", sb)
			panel.mouse_filter = Control.MOUSE_FILTER_IGNORE
			
			var lbl = Label.new()
			lbl.text = vertical_text
			lbl.add_theme_color_override("font_color", Color.WHITE)
			lbl.add_theme_font_size_override("font_size", 12)
			lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			panel.add_child(lbl)
			badge_container.add_child(panel)

func _get_drag_data(at_position):
	var main = get_tree().current_scene
	if main and "is_action_running" in main and main.is_action_running:
		return null
		
	var root = Control.new()
	var preview = Panel.new()
	preview.size = self.size
	preview.position = -at_position
	preview.add_theme_stylebox_override("panel", create_style(Color.WHITE, Color("#339af0"), 2, 15, true))
	var pl = Label.new()
	pl.text = name_lbl.text
	pl.add_theme_color_override("font_color", Color("#339af0"))
	pl.add_theme_font_size_override("font_size", 24)
	pl.set_anchors_preset(PRESET_FULL_RECT)
	pl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	preview.add_child(pl)
	root.add_child(preview)
	set_drag_preview(root)
	
	modulate.a = 0.5
	_on_mouse_exit()
	
	var drag_dict = {
		"type": card_data.type,
		"cost": card_data.cost,
		"card_name": card_data.name,
		"source_card": self,
		"full_data": card_data
	}
	
	var is_unit = false
	if typeof(card_data) == TYPE_DICTIONARY:
		is_unit = (card_data.type == "单位")
	else:
		is_unit = (card_data is CardUnit)
		
	if is_unit:
		drag_dict["attack"] = card_data.attack
		drag_dict["health"] = {"top": card_data.health["top"], "bottom": card_data.health["bottom"], "left": card_data.health["left"], "right": card_data.health["right"]}
		
	return drag_dict

func _notification(what):
	if what == NOTIFICATION_DRAG_END:
		modulate.a = 1.0
