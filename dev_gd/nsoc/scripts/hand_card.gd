extends Panel

var card_data = {}
var card_id = 0

@onready var cost_lbl = $CostBg/CostLbl
@onready var name_lbl = $NameLbl
@onready var atk_lbl = $AtkBg/AtkLbl
@onready var hp_lbl = $HpBg/HpLbl

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
	add_theme_stylebox_override("panel", create_style(Color.WHITE, Color("#e1e8ed"), 1, 8, true))
	
	var cost_style = StyleBoxFlat.new()
	cost_style.bg_color = Color("#339af0")
	cost_style.corner_radius_top_left = 9
	cost_style.corner_radius_top_right = 9
	cost_style.corner_radius_bottom_left = 9
	cost_style.corner_radius_bottom_right = 9
	cost_style.shadow_color = Color(0, 0, 0, 0.1)
	cost_style.shadow_size = 3
	$CostBg.add_theme_stylebox_override("panel", cost_style)
	
	$AtkBg.add_theme_stylebox_override("panel", create_style(Color("#ff6b6b"), Color.TRANSPARENT, 0, 6))
	$HpBg.add_theme_stylebox_override("panel", create_style(Color("#51cf66"), Color.TRANSPARENT, 0, 6))
	
	pivot_offset = custom_minimum_size / 2.0
	mouse_entered.connect(_on_mouse_enter)
	mouse_exited.connect(_on_mouse_exit)

func _on_mouse_enter():
	if modulate.a < 1.0: return
	if get_tree():
		var tween = create_tween()
		tween.tween_property(self, "scale", Vector2(1.1, 1.1), 0.1)

func _on_mouse_exit():
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
	atk_lbl.text = str(data.attack)
	hp_lbl.text = str(data.health)

func _get_drag_data(at_position):
	var main = get_tree().current_scene
	if main and "is_action_running" in main and main.is_action_running:
		return null
		
	var root = Control.new()
	var preview = Panel.new()
	preview.size = self.size
	preview.position = -at_position
	preview.add_theme_stylebox_override("panel", create_style(Color.WHITE, Color("#339af0"), 2, 8, true))
	var pl = Label.new()
	pl.text = name_lbl.text
	pl.add_theme_color_override("font_color", Color("#339af0"))
	pl.set_anchors_preset(PRESET_FULL_RECT)
	pl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	preview.add_child(pl)
	root.add_child(preview)
	set_drag_preview(root)
	
	modulate.a = 0.5
	_on_mouse_exit()
	
	return {
		"type": card_data.type,
		"cost": card_data.cost,
		"card_name": card_data.name,
		"attack": card_data.attack,
		"health": card_data.health,
		"source_card": self
	}

func _notification(what):
	if what == NOTIFICATION_DRAG_END:
		modulate.a = 1.0