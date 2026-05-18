extends Panel

var row = 0
var col = 0
var has_card = false
var is_enemy = false
var card_name = ""
var attack = 0
var health = 0
var has_attacked = false
var is_phantom = false

@onready var inner_panel = $InnerPanel
@onready var name_lbl = $InnerPanel/NameLbl
@onready var atk_lbl = $InnerPanel/AtkBg/AtkLbl
@onready var hp_lbl = $InnerPanel/HpBg/HpLbl

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
		sb.shadow_color = Color(0, 0, 0, 0.05)
		sb.shadow_size = 5
	return sb

func _ready():
	add_theme_stylebox_override("panel", create_style(Color.WHITE, Color("#d1d9e0"), 2, 12))
	$InnerPanel/AtkBg.add_theme_stylebox_override("panel", create_style(Color("#ff6b6b"), Color.TRANSPARENT, 0, 6))
	$InnerPanel/HpBg.add_theme_stylebox_override("panel", create_style(Color("#51cf66"), Color.TRANSPARENT, 0, 6))
	clear_card()
	
	inner_panel.pivot_offset = custom_minimum_size / 2.0
	mouse_entered.connect(_on_mouse_enter)
	mouse_exited.connect(_on_mouse_exit)

func _on_mouse_enter():
	if has_card and get_tree():
		var tween = create_tween()
		tween.tween_property(inner_panel, "scale", Vector2(1.08, 1.08), 0.1)

func _on_mouse_exit():
	if (has_card or is_phantom) and get_tree():
		var tween = create_tween()
		tween.tween_property(inner_panel, "scale", Vector2.ONE, 0.1)

func set_phantom(cname, atk, hp, enemy=false):
	set_card(cname, atk, hp, enemy)
	has_card = false
	is_phantom = true
	inner_panel.modulate.a = 0.4

func set_card(cname, atk, hp, enemy=false):
	has_card = true
	is_phantom = false
	inner_panel.modulate.a = 1.0
	card_name = cname
	attack = atk
	health = hp
	is_enemy = enemy
	name_lbl.text = cname
	atk_lbl.text = str(attack)
	hp_lbl.text = str(health)
	
	if is_enemy:
		inner_panel.add_theme_stylebox_override("panel", create_style(Color("#fff5f5"), Color("#ffc9c9"), 1, 12, true))
		name_lbl.add_theme_color_override("font_color", Color("#fa5252"))
	else:
		inner_panel.add_theme_stylebox_override("panel", create_style(Color.WHITE, Color("#e1e8ed"), 1, 12, true))
		name_lbl.add_theme_color_override("font_color", Color("#495057"))

	inner_panel.visible = true

func clear_card():
	has_card = false
	card_name = ""
	is_enemy = false
	is_phantom = false
	inner_panel.visible = false
	inner_panel.scale = Vector2.ONE
	inner_panel.modulate.a = 1.0
	
func play_damage_effect():
	inner_panel.self_modulate = Color("#ffc9c9") if is_enemy else Color("#ffe3e3")
	if get_tree():
		var tween = get_tree().create_tween()
		tween.tween_property(inner_panel, "self_modulate", Color.WHITE, 0.5)

func play_death_effect():
	self_modulate = Color("#ffc9c9")
	if get_tree():
		var tween = get_tree().create_tween()
		tween.tween_property(self, "self_modulate", Color.WHITE, 0.5)

func receive_damage(dmg):
	health -= dmg
	play_damage_effect()
	if health <= 0: return true
	hp_lbl.text = str(health)
	return false

func _can_drop_data(at_position, data):
	if has_card: return false
	if typeof(data) == TYPE_DICTIONARY and data.has("type"):
		if data.type == "单位" and row <= 2: return false
		return true
	return false

func _drop_data(at_position, data):
	var main = get_tree().current_scene
	if main.current_mana >= data.cost:
		main.current_mana -= data.cost
		main.update_mana()
		set_card(data.card_name, data.attack, data.health, false)
		data.source_card.get_parent().remove_child(data.source_card)
		data.source_card.queue_free()
		main.ensure_min_hand_size()