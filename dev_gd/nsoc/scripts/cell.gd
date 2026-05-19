extends Panel

var row = 0
var col = 0
var has_card = false
var is_enemy = false
var card_name = ""
var attack = 0
var health = {"top": 0, "bottom": 0, "left": 0, "right": 0}
var effects = []
var has_attacked = false
var is_phantom = false

@onready var inner_panel = $InnerPanel
@onready var name_lbl = $InnerPanel/NameLbl
@onready var atk_lbl = $InnerPanel/AtkBg/AtkLbl

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
		sb.shadow_color = Color(0, 0, 0, 0.05)
		sb.shadow_size = 5
	return sb

func _ready():
	add_theme_stylebox_override("panel", create_style(Color.WHITE, Color("#d1d9e0"), 2, 20))
	$InnerPanel/AtkBg.add_theme_stylebox_override("panel", create_style(Color("#ff6b6b"), Color.TRANSPARENT, 0, 8))
	
	hp_labels["top"] = $InnerPanel/TopHp
	hp_labels["bottom"] = $InnerPanel/BottomHp
	hp_labels["left"] = $InnerPanel/LeftHp
	hp_labels["right"] = $InnerPanel/RightHp
	
	for d in hp_labels.values():
		var sb = StyleBoxFlat.new()
		sb.bg_color = Color("#51cf66")
		sb.corner_radius_top_left = 10
		sb.corner_radius_top_right = 10
		sb.corner_radius_bottom_left = 10
		sb.corner_radius_bottom_right = 10
		d.add_theme_stylebox_override("normal", sb)

	clear_card()
	
	inner_panel.pivot_offset = custom_minimum_size / 2.0
	gui_input.connect(_on_gui_input)
	mouse_exited.connect(_on_mouse_exit)

func _on_gui_input(event):
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.is_pressed():
			_on_mouse_enter()
			if has_card:
				var main = get_tree().current_scene
				if main and main.has_method("start_long_press"):
					main.start_long_press({"name": card_name, "attack": attack, "health": health})
		else:
			_on_mouse_exit()

func _on_mouse_enter():
	if has_card and get_tree():
		var tween = create_tween()
		tween.tween_property(inner_panel, "scale", Vector2(1.08, 1.08), 0.1)

func _on_mouse_exit():
	var main = get_tree().current_scene
	if main and main.has_method("cancel_long_press"):
		main.cancel_long_press()
		
	if (has_card or is_phantom) and get_tree():
		var tween = create_tween()
		tween.tween_property(inner_panel, "scale", Vector2.ONE, 0.1)

func set_phantom(cname, atk, hp, enemy=false, effects_in=[]):
	set_card(cname, atk, hp, enemy, effects_in)
	has_card = false
	is_phantom = true
	inner_panel.modulate.a = 0.4

func set_card(cname, atk, hp, enemy=false, effects_in=[]):
	has_card = true
	is_phantom = false
	inner_panel.modulate.a = 1.0
	card_name = cname
	attack = atk
	health = {"top": hp["top"], "bottom": hp["bottom"], "left": hp["left"], "right": hp["right"]}
	effects = effects_in
	is_enemy = enemy
	name_lbl.text = cname
	atk_lbl.text = str(attack)
	
	_update_hp_labels()
	
	if is_enemy:
		inner_panel.add_theme_stylebox_override("panel", create_style(Color("#fff5f5"), Color("#ffc9c9"), 1, 20, true))
		name_lbl.add_theme_color_override("font_color", Color("#fa5252"))
	else:
		inner_panel.add_theme_stylebox_override("panel", create_style(Color.WHITE, Color("#e1e8ed"), 1, 20, true))
		name_lbl.add_theme_color_override("font_color", Color("#495057"))

	var badge_container = inner_panel.get_node_or_null("EffectBadges")
	if badge_container:
		for c in badge_container.get_children():
			c.queue_free()
		for eff in effects:
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

	inner_panel.visible = true

func _update_hp_labels():
	for d in hp_labels.keys():
		hp_labels[d].text = str(health[d])

var active_tween = null

func clear_card():
	if active_tween:
		active_tween.kill()
		active_tween = null
		
	has_card = false
	card_name = ""
	is_enemy = false
	is_phantom = false
	inner_panel.visible = false
	inner_panel.scale = Vector2.ONE
	inner_panel.modulate.a = 1.0
	inner_panel.self_modulate = Color.WHITE
	
	if get_tree() and get_tree().current_scene and get_tree().current_scene.has_method("update_phantoms"):
		get_tree().current_scene.update_phantoms()
	
func play_damage_effect():
	if active_tween:
		active_tween.kill()
	inner_panel.self_modulate = Color("#ffc9c9") if is_enemy else Color("#ffe3e3")
	if get_tree():
		active_tween = get_tree().create_tween()
		active_tween.tween_property(inner_panel, "self_modulate", Color.WHITE, 0.4)

func play_attack_effect():
	if active_tween:
		active_tween.kill()
	inner_panel.self_modulate = Color("#ffe066") # 发动攻击的黄色特效
	if get_tree():
		active_tween = get_tree().create_tween()
		active_tween.tween_property(inner_panel, "self_modulate", Color.WHITE, 0.4)

func play_death_effect():
	if active_tween:
		active_tween.kill()
	inner_panel.self_modulate = Color.WHITE
	if get_tree():
		active_tween = get_tree().create_tween()
		active_tween.tween_property(inner_panel, "self_modulate", Color(0.5, 0.5, 0.5), 0.4)

func receive_damage(dir, dmg, dying=false):
	health[dir] -= dmg
	_update_hp_labels()
	if dying:
		play_death_effect()
	else:
		play_damage_effect()
	if health[dir] <= 0: return true
	return false

var is_drag_hovered = false

func set_drag_hover(hovered: bool):
	if is_drag_hovered == hovered: return
	is_drag_hovered = hovered
	
	if is_drag_hovered:
		var highlight_style = create_style(Color.WHITE, Color("#339af0"), 2, 20, true)
		if has_card:
			inner_panel.add_theme_stylebox_override("panel", highlight_style)
		else:
			add_theme_stylebox_override("panel", highlight_style)
	else:
		if has_card:
			if is_enemy:
				inner_panel.add_theme_stylebox_override("panel", create_style(Color("#fff5f5"), Color("#ffc9c9"), 1, 20, true))
			else:
				inner_panel.add_theme_stylebox_override("panel", create_style(Color.WHITE, Color("#e1e8ed"), 1, 20, true))
		add_theme_stylebox_override("panel", create_style(Color.WHITE, Color("#d1d9e0"), 2, 20))

func _notification(what):
	if what == NOTIFICATION_DRAG_END:
		set_drag_hover(false)

func _process(delta):
	if is_drag_hovered:
		if not get_global_rect().has_point(get_global_mouse_position()):
			set_drag_hover(false)

func _can_drop_data(at_position, data):
	if typeof(data) == TYPE_DICTIONARY and data.has("type"):
		var main = get_tree().current_scene
		if main and main.current_mana < data.cost: return false
		
		var can_drop = false
		if data.type == "法术": can_drop = true
		elif has_card: can_drop = false
		elif data.type == "单位" and row <= 2: can_drop = false
		else: can_drop = true
		
		if can_drop:
			set_drag_hover(true)
			return true
	return false

func _extract_effects(data):
	var full = null
	if typeof(data) == TYPE_DICTIONARY:
		full = data.get("full_data", null)
	else:
		full = data
	if full == null:
		return []
	if typeof(full) == TYPE_DICTIONARY:
		return full.get("effects", [])
	if "effects" in full and full.effects != null:
		return full.effects
	return []

func _drop_data(at_position, data):
	var main = get_tree().current_scene
	if main.current_mana >= data.cost:
		main.current_mana -= data.cost
		main.update_mana()
		
		var drop_global_pos = global_position + at_position
		data.source_card.get_parent().remove_child(data.source_card)
		data.source_card.queue_free()
		
		if data.type == "法术":
			if main.has_method("play_spell"):
				main.play_spell(data.get("full_data", null), self)
			main.ensure_min_hand_size()
			return
			
		main.ensure_min_hand_size()
		
		var effs = _extract_effects(data)
		var full_data = data.get("full_data", null)
		if full_data != null and main.has_method("trigger_unit_play_effects"):
			main.trigger_unit_play_effects(full_data, self)
		var visual = main.cell_scene.instantiate()
		main.add_child(visual)
		# 让棋子的中心对齐鼠标/手指释放的位置
		visual.global_position = drop_global_pos - (visual.custom_minimum_size / 2.0)
		visual.z_index = 100
		visual.pivot_offset = visual.custom_minimum_size / 2.0
		visual.set_card(data.card_name, data.attack, data.health, false, effs)
		
		var tween = get_tree().create_tween()
		var mid_pos = (visual.global_position + global_position) / 2.0
		var offset = Vector2(0, -70)
		
		tween.tween_property(visual, "global_position", mid_pos + offset, 0.15).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		tween.parallel().tween_property(visual, "scale", Vector2(1.08, 1.08), 0.15).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		
		tween.tween_property(visual, "global_position", global_position, 0.15).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		tween.parallel().tween_property(visual, "scale", Vector2(1.0, 1.0), 0.15).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		
		await tween.finished
		if is_instance_valid(visual):
			visual.queue_free()
			
		set_card(data.card_name, data.attack, data.health, false, effs)
