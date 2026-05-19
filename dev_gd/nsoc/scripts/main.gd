extends Control

const MIN_HAND_SIZE = 5
const MAX_MANA_CAP = 10
var max_mana = 1
var current_mana = 1
var card_counter = 1

var player_health = 30
var enemy_health = 30
var is_action_running = false

var testCards = []
var draw_pile = []
var graveyard = []
var banished = []
var unit_config = []
var spawners = []
var autophagy_counter = 0

var grid_cells = {}
@onready var hand_container = $BottomBar/HandClip/HandContainer
@onready var enemy_health_label = $EnemyHpPnl/EnemyHealthLabel
@onready var player_health_label = $BottomBar/PHpPnl/PlayerHealthLabel
@onready var mana_label = $BottomBar/ManaPnl/ManaLabel
@onready var end_turn_btn = $BottomBar/EndTurnBtn
@onready var deck_btn = $BottomBar/SideButtonsBox/DeckBtn
@onready var grave_btn = $BottomBar/SideButtonsBox/GraveBtn
@onready var banished_btn = $BottomBar/SideButtonsBox/BanishedBtn

@onready var top_grid = $TopGridBg/TopGrid
@onready var bottom_grid = $BottomGridBg/BottomGrid

var cell_scene = preload("res://scenes/Cell.tscn")
var hand_card_scene = preload("res://scenes/HandCard.tscn")

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
		sb.shadow_color = Color(0, 0, 0, 0.08)
		sb.shadow_size = 15
	return sb

var ui_panels = {}
var current_open_panel = ""

var long_press_timer: Timer
var long_press_target = null

var detail_panel_clip: Control
var detail_panel: Panel
var is_detail_panel_open = false

var settings_btn: Button
var settings_overlay: ColorRect
var settings_panel: Panel
var is_settings_open = false

func _init_detail_panel():
	detail_panel_clip = Control.new()
	detail_panel_clip.name = "DetailPanelClip"
	add_child(detail_panel_clip)
	detail_panel_clip.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	detail_panel_clip.offset_left = 10
	detail_panel_clip.offset_right = 330
	detail_panel_clip.offset_top = 10
	detail_panel_clip.offset_bottom = -10
	detail_panel_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	detail_panel_clip.clip_contents = true
	detail_panel_clip.visible = false
	
	detail_panel = Panel.new()
	detail_panel.name = "DetailPanel"
	detail_panel_clip.add_child(detail_panel)
	detail_panel.set_anchors_preset(Control.PRESET_LEFT_WIDE)
	detail_panel.offset_left = -320
	detail_panel.offset_right = 0
	detail_panel.offset_top = 0
	detail_panel.offset_bottom = 0
	detail_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	
	var sb = create_style(Color(0.94, 0.95, 0.96, 1.0), Color(1, 1, 1, 1.0), 1, 20)
	detail_panel.add_theme_stylebox_override("panel", sb)

	var vbox = VBoxContainer.new()
	vbox.name = "DetailVBox"
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT)
	vbox.offset_left = 20
	vbox.offset_right = -20
	vbox.offset_top = 30
	vbox.offset_bottom = -20
	vbox.add_theme_constant_override("separation", 20)
	detail_panel.add_child(vbox)
	
	var card_center = CenterContainer.new()
	card_center.name = "CardCenter"
	card_center.custom_minimum_size = Vector2(0, 240)
	vbox.add_child(card_center)
	
	var name_lbl = Label.new()
	name_lbl.name = "NameLbl"
	name_lbl.add_theme_font_size_override("font_size", 24)
	name_lbl.add_theme_color_override("font_color", Color(0.2, 0.2, 0.2, 1))
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(name_lbl)
	
	var cost_lbl = Label.new()
	cost_lbl.name = "CostLbl"
	cost_lbl.add_theme_font_size_override("font_size", 20)
	cost_lbl.add_theme_color_override("font_color", Color(0.3, 0.3, 0.3, 1))
	vbox.add_child(cost_lbl)
	
	var effect_lbl = Label.new()
	effect_lbl.name = "EffectLbl"
	effect_lbl.add_theme_font_size_override("font_size", 18)
	effect_lbl.add_theme_color_override("font_color", Color(0.4, 0.4, 0.4, 1))
	effect_lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	vbox.add_child(effect_lbl)

func start_long_press(target_data):
	long_press_target = target_data
	if long_press_timer:
		long_press_timer.start()

func cancel_long_press():
	if long_press_timer:
		long_press_timer.stop()
	long_press_target = null

func _on_long_press_timeout():
	show_detail_panel(long_press_target)

func show_detail_panel(data=null):
	if data == null: return
	
	var vbox = detail_panel.get_node_or_null("DetailVBox")
	if vbox:
		var card_center = vbox.get_node("CardCenter")
		var name_lbl = vbox.get_node("NameLbl")
		var cost_lbl = vbox.get_node("CostLbl")
		var effect_lbl = vbox.get_node("EffectLbl")
		
		for c in card_center.get_children():
			c.queue_free()
			
		var cname = ""
		if typeof(data) == TYPE_DICTIONARY:
			cname = String(data.get("name", "")).split(" x ")[0]
		else:
			cname = data.name
			
		var cdata = _get_card_data(cname)
		if not cdata and typeof(data) != TYPE_DICTIONARY:
			cdata = data
			
		if cdata:
			var visual = hand_card_scene.instantiate()
			card_center.add_child(visual)
			visual.setup(cdata, 0)
			visual.mouse_filter = Control.MOUSE_FILTER_IGNORE
			visual.scale = Vector2.ONE
			
			name_lbl.text = cname
			cost_lbl.text = "费用: " + str(cdata.cost)
			
			var effect_texts = []
			for eff in cdata.effects:
				effect_texts.append(EffectUtils.get_description(eff))
			
			if effect_texts.size() > 0:
				effect_lbl.text = "\n".join(effect_texts)
			else:
				effect_lbl.text = "无附加效果"

	if is_detail_panel_open: return
	is_detail_panel_open = true
	detail_panel_clip.visible = true
	detail_panel.offset_left = -320
	detail_panel.offset_right = 0
	var tween = get_tree().create_tween()
	tween.tween_property(detail_panel, "offset_left", 0.0, 0.2).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(detail_panel, "offset_right", 320.0, 0.2).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

func hide_detail_panel():
	if not is_detail_panel_open: return
	is_detail_panel_open = false
	var tween = get_tree().create_tween()
	tween.tween_property(detail_panel, "offset_left", -320.0, 0.2).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.parallel().tween_property(detail_panel, "offset_right", 0.0, 0.2).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_callback(func(): detail_panel_clip.visible = false)

func _ready():
	var fallback_blanket = CardUnit.new("填线宝宝", 1, 1, {"top": 1, "bottom": 1, "left": 1, "right": 1}, [])
	fallback_blanket.count = 5
	var fallback_pro = CardUnit.new("灰烬填线宝宝", 2, 2, {"top": 2, "bottom": 2, "left": 2, "right": 2}, ["ash"])
	fallback_pro.count = 3
	testCards = [fallback_blanket, fallback_pro]
	
	_load_game_data()
	player_health_label.text = str(player_health)
	enemy_health_label.text = str(enemy_health)
	_apply_styles()
	_init_grid()
	_init_units()
	update_phantoms()
	ensure_min_hand_size()
	update_mana()
	end_turn_btn.pressed.connect(_on_end_turn_pressed)
	
	_init_side_panels()
	deck_btn.pressed.connect(_on_deck_btn_pressed)
	grave_btn.pressed.connect(_on_grave_btn_pressed)
	banished_btn.pressed.connect(_on_banished_btn_pressed)
	
	_init_detail_panel()
	long_press_timer = Timer.new()
	long_press_timer.wait_time = 0.4
	long_press_timer.one_shot = true
	long_press_timer.timeout.connect(_on_long_press_timeout)
	add_child(long_press_timer)
	
	_init_settings_panel()

func _init_side_panels():
	var bottom_bar = $BottomBar
	for p_name in ["deck", "grave", "banished"]:
		var clip_node = Control.new()
		clip_node.name = p_name + "_clip"
		add_child(clip_node) # Explicitly leave it after BottomBar so it draws on top
		
		clip_node.set_anchors_preset(Control.PRESET_RIGHT_WIDE)
		clip_node.offset_left = -640
		clip_node.offset_right = -320
		clip_node.offset_top = 10
		clip_node.offset_bottom = -10
		clip_node.mouse_filter = Control.MOUSE_FILTER_IGNORE
		clip_node.clip_contents = true
		clip_node.visible = false
		
		var pnl = Panel.new()
		pnl.name = p_name + "_panel"
		clip_node.add_child(pnl)
		pnl.set_anchors_preset(Control.PRESET_LEFT_WIDE)
		pnl.offset_left = 320
		pnl.offset_right = 640
		pnl.offset_top = 0
		pnl.offset_bottom = 0
		pnl.mouse_filter = Control.MOUSE_FILTER_STOP
		
		# Match exactly the same style and radiuses as the right sidebar for seamless look
		var sb = create_style(Color(0.94, 0.95, 0.96, 1.0), Color(1, 1, 1, 1.0), 1, 20)
		pnl.add_theme_stylebox_override("panel", sb)
		
		var lbl = Label.new()
		if p_name == "deck": lbl.text = "牌堆"
		elif p_name == "grave": lbl.text = "墓地"
		elif p_name == "banished": lbl.text = "除外"
		
		lbl.set_anchors_preset(Control.PRESET_TOP_WIDE)
		lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
		lbl.add_theme_font_size_override("font_size", 28)
		lbl.add_theme_color_override("font_color", Color(0.2, 0.2, 0.2, 1))
		lbl.offset_top = 20
		lbl.offset_bottom = 60
		pnl.add_child(lbl)
		
		var scroll = ScrollContainer.new()
		scroll.name = "Scroll"
		scroll.set_anchors_preset(Control.PRESET_FULL_RECT)
		scroll.offset_top = 80
		scroll.offset_bottom = -20
		scroll.offset_left = 20
		scroll.offset_right = -20
		scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
		pnl.add_child(scroll)
		
		var vbox = VBoxContainer.new()
		vbox.name = "ListVBox"
		vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		vbox.add_theme_constant_override("separation", 10)
		scroll.add_child(vbox)
		
		ui_panels[p_name] = clip_node

func _refresh_panel_content(p_name: String):
	var clip_node = ui_panels[p_name]
	var pnl = clip_node.get_node(p_name + "_panel")
	var vbox = pnl.get_node("Scroll/ListVBox")
	for c in vbox.get_children():
		c.queue_free()
	
	if p_name == "deck":
		var counts = {}
		for card in draw_pile:
			counts[card.name] = counts.get(card.name, 0) + 1
		var names = counts.keys()
		names.sort()
		for n in names:
			vbox.add_child(_create_list_item(n + " x " + str(counts[n])))
	elif p_name == "grave":
		for i in range(graveyard.size() - 1, -1, -1):
			vbox.add_child(_create_list_item(graveyard[i].name))
	elif p_name == "banished":
		for i in range(banished.size() - 1, -1, -1):
			vbox.add_child(_create_list_item(banished[i].name))

func _create_list_item(text: String) -> Button:
	var b = Button.new()
	b.text = text
	b.add_theme_font_size_override("font_size", 22)
	b.add_theme_color_override("font_color", Color(0.2, 0.2, 0.2, 1))
	b.add_theme_color_override("font_hover_color", Color(0.1, 0.1, 0.1, 1))
	b.add_theme_color_override("font_pressed_color", Color(0.0, 0.0, 0.0, 1))
	var sb = StyleBoxFlat.new()
	sb.bg_color = Color(1, 1, 1, 0.6)
	sb.corner_radius_top_left = 8
	sb.corner_radius_top_right = 8
	sb.corner_radius_bottom_left = 8
	sb.corner_radius_bottom_right = 8
	sb.content_margin_top = 10
	sb.content_margin_bottom = 10
	
	var sb_hover = sb.duplicate()
	sb_hover.bg_color = Color(1, 1, 1, 0.8)
	var sb_pressed = sb.duplicate()
	sb_pressed.bg_color = Color(0.9, 0.9, 0.9, 0.9)
	
	b.add_theme_stylebox_override("normal", sb)
	b.add_theme_stylebox_override("hover", sb_hover)
	b.add_theme_stylebox_override("pressed", sb_pressed)
	b.add_theme_stylebox_override("focus", StyleBoxEmpty.new())
	
	b.button_down.connect(func(): start_long_press({"name": text}))
	b.button_up.connect(func(): cancel_long_press())
	b.mouse_exited.connect(func(): cancel_long_press())
	
	return b

func _on_deck_btn_pressed(): _toggle_panel("deck")
func _on_grave_btn_pressed(): _toggle_panel("grave")
func _on_banished_btn_pressed(): _toggle_panel("banished")

func _toggle_panel(p_name: String):
	if current_open_panel == p_name:
		_close_current_panel()
	else:
		if current_open_panel != "":
			# Quick close current one
			var old_clip = ui_panels[current_open_panel]
			old_clip.visible = false
			var old_pnl = old_clip.get_node(current_open_panel + "_panel")
			old_pnl.offset_left = 320
			old_pnl.offset_right = 640
		_open_panel(p_name)

func _open_panel(p_name: String):
	current_open_panel = p_name
	_refresh_panel_content(p_name)
	var clip_node = ui_panels[p_name]
	clip_node.visible = true
	var pnl = clip_node.get_node(p_name + "_panel")
	var tween = get_tree().create_tween()
	tween.tween_property(pnl, "offset_left", 0.0, 0.3).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(pnl, "offset_right", 320.0, 0.3).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

func _close_current_panel():
	if current_open_panel == "": return
	var clip_node = ui_panels[current_open_panel]
	current_open_panel = ""
	var pnl = clip_node.get_node(clip_node.name.replace("_clip", "_panel"))
	var tween = get_tree().create_tween()
	tween.tween_property(pnl, "offset_left", 320.0, 0.3).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.parallel().tween_property(pnl, "offset_right", 640.0, 0.3).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_callback(func(): clip_node.visible = false)

func _input(event):
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if not event.pressed:
			cancel_long_press()
			hide_detail_panel()
		elif event.pressed:
			if current_open_panel != "":
				var p = get_global_mouse_position()
				var clip_node = ui_panels[current_open_panel]
				var pnl = clip_node.get_node(current_open_panel + "_panel")
				if pnl.get_global_rect().has_point(p): return
				if deck_btn.get_global_rect().has_point(p): return
				if grave_btn.get_global_rect().has_point(p): return
				if banished_btn.get_global_rect().has_point(p): return
				_close_current_panel()

func _load_game_data():
	if FileAccess.file_exists("res://data/test_hero.json"):
		var hero_file = FileAccess.open("res://data/test_hero.json", FileAccess.READ)
		var hero_json = JSON.parse_string(hero_file.get_as_text())
		if typeof(hero_json) == TYPE_DICTIONARY:
			if hero_json.has("player"):
				player_health = int(hero_json["player"]["health"])
			if hero_json.has("enemy"):
				enemy_health = int(hero_json["enemy"]["health"])
	
	if FileAccess.file_exists("res://data/test_card.json"):
		var card_file = FileAccess.open("res://data/test_card.json", FileAccess.READ)
		var card_json = JSON.parse_string(card_file.get_as_text())
		if typeof(card_json) == TYPE_ARRAY and card_json.size() > 0:
			var parsed_cards = []
			for card in card_json:
				var c_name = card.get("name", "Unknown")
				var c_type = card.get("type", "单位")
				var c_cost = int(card.get("cost", 0))
				var c_effects = card.get("effects", [])
				var c_count = int(card.get("count", 1))
				
				var new_card
				if c_type == "单位":
					var c_atk = int(card.get("attack", 0))
					var hp = {"top": 1, "bottom": 1, "left": 1, "right": 1}
					if card.has("health"):
						if typeof(card["health"]) == TYPE_DICTIONARY:
							hp = {
								"top": int(card["health"].get("top", 1)),
								"bottom": int(card["health"].get("bottom", 1)),
								"left": int(card["health"].get("left", 1)),
								"right": int(card["health"].get("right", 1))
							}
						else:
							var hv = int(card["health"])
							hp = {"top": hv, "bottom": hv, "left": hv, "right": hv}
					new_card = CardUnit.new(c_name, c_cost, c_atk, hp, c_effects)
				else:
					new_card = CardSpell.new(c_name, c_cost, c_effects)
					
				new_card.count = c_count
				parsed_cards.append(new_card)
			testCards = parsed_cards
	
	if FileAccess.file_exists("res://data/test_level.json"):
		var level_file = FileAccess.open("res://data/test_level.json", FileAccess.READ)
		var level_json = JSON.parse_string(level_file.get_as_text())
		if typeof(level_json) == TYPE_DICTIONARY:
			unit_config.clear()
			spawners.clear()
			if level_json.has("initial_units") and typeof(level_json["initial_units"]) == TYPE_ARRAY:
				for cfg in level_json["initial_units"]:
					var new_cfg = { "name": cfg["name"], "faction": int(cfg["faction"]), "positions": [] }
					for pos in cfg["positions"]:
						new_cfg["positions"].append(Vector2(int(pos["row"]), int(pos["col"])))
					unit_config.append(new_cfg)
			if level_json.has("spawners") and typeof(level_json["spawners"]) == TYPE_ARRAY:
					for sp in level_json["spawners"]:
						var new_sp = {
							"name": sp["name"],
							"faction": int(sp["faction"]),
							"position": Vector2(int(sp["position"]["row"]), int(sp["position"]["col"])),
							"interval": int(sp["interval"]),
							"timer": 0
						}
						spawners.append(new_sp)
	
	_reshuffle_deck(true)

func _reshuffle_deck(initial = false):
	draw_pile.clear()
	if initial:
		for card in testCards:
			for i in range(card.count):
				draw_pile.append(card)
	else:
		draw_pile.append_array(graveyard)
		graveyard.clear()
	draw_pile.shuffle()

func _apply_styles():
	$Bg.add_theme_stylebox_override("panel", create_style(Color.WHITE, Color("#e1e8ed"), 1, 0))
	$EnemyHpPnl.add_theme_stylebox_override("panel", create_style(Color.WHITE, Color("#ff6b6b"), 2, 20, true))
	
	var grid_bg_style = create_style(Color("#f0f3f5"), Color("#e1e8ed"), 1, 16)
	$TopGridBg.add_theme_stylebox_override("panel", grid_bg_style)
	$BottomGridBg.add_theme_stylebox_override("panel", grid_bg_style)
	
	var bb_style = create_style(Color(0.94, 0.95, 0.96, 0.85), Color(1, 1, 1, 0.6), 1, 20)
	$BottomBar.add_theme_stylebox_override("panel", bb_style)
	
	hand_container.add_theme_constant_override("separation", 50)
	
	$BottomBar/PHpPnl.add_theme_stylebox_override("panel", create_style(Color.WHITE, Color("#ff6b6b"), 2, 12, true))
	$BottomBar/ManaPnl.add_theme_stylebox_override("panel", create_style(Color.WHITE, Color("#339af0"), 2, 12, true))
	
	var btn_normal = create_style(Color("#339af0"), Color.TRANSPARENT, 0, 12, true)
	var btn_hover = create_style(Color("#228be6"), Color.TRANSPARENT, 0, 12, true)
	var btn_pressed = create_style(Color("#228be6"), Color.TRANSPARENT, 0, 12)
	var btn_disabled = create_style(Color("#999999"), Color.TRANSPARENT, 0, 12)
	end_turn_btn.add_theme_stylebox_override("normal", btn_normal)
	end_turn_btn.add_theme_stylebox_override("hover", btn_hover)
	end_turn_btn.add_theme_stylebox_override("pressed", btn_pressed)
	end_turn_btn.add_theme_stylebox_override("disabled", btn_disabled)
	
	deck_btn.add_theme_stylebox_override("normal", btn_normal)
	deck_btn.add_theme_stylebox_override("hover", btn_hover)
	deck_btn.add_theme_stylebox_override("pressed", btn_pressed)
	
	grave_btn.add_theme_stylebox_override("normal", btn_normal)
	grave_btn.add_theme_stylebox_override("hover", btn_hover)
	grave_btn.add_theme_stylebox_override("pressed", btn_pressed)
	
	banished_btn.add_theme_stylebox_override("normal", btn_normal)
	banished_btn.add_theme_stylebox_override("hover", btn_hover)
	banished_btn.add_theme_stylebox_override("pressed", btn_pressed)

func _init_grid():
	for r in range(6):
		for c in range(3):
			var cell = cell_scene.instantiate()
			cell.row = r
			cell.col = c
			grid_cells[Vector2(r, c)] = cell
			if r < 3:
				top_grid.add_child(cell)
			else:
				bottom_grid.add_child(cell)

func _init_units():
	for cfg in unit_config:
		var cdata = _get_card_data(cfg.name)
		if cdata:
				for pos in cfg.positions:
					var cell = grid_cells[pos]
					cell.set_card(cdata.name, cdata.attack, cdata.health, cfg.faction == 1, cdata.effects)

func _get_card_data(name_str):
	for c in testCards:
		if c.name == name_str: return c
	return null

func get_random_card():
	if draw_pile.size() == 0:
		_reshuffle_deck(false)
	if draw_pile.size() == 0:
		var new_void = CardSpell.new("虚空", 1, ["autophagy"])
		draw_pile.append(new_void)
	return draw_pile.pop_back()

func ensure_min_hand_size():
	while hand_container.get_child_count() < MIN_HAND_SIZE:
		var data = get_random_card()
		if not data:
			break
		var c = hand_card_scene.instantiate()
		hand_container.add_child(c)
		c.setup(data, card_counter)
		card_counter += 1

func apply_damage_to_hero(is_enemy, damage):
	if is_enemy:
		enemy_health -= damage
		enemy_health_label.text = str(enemy_health)
	else:
		player_health -= damage
		player_health_label.text = str(player_health)
		
	var pnl = $EnemyHpPnl if is_enemy else $BottomBar/PHpPnl
	pnl.self_modulate = Color("#ffc9c9")
	
	if get_tree():
		var tween = get_tree().create_tween()
		tween.tween_property(pnl, "self_modulate", Color.WHITE, 0.5)

func update_mana():
	mana_label.text = str(current_mana) + "/" + str(max_mana)

func _on_end_turn_pressed():
	end_turn_btn.disabled = true
	end_turn_btn.text = "行动中"
	is_action_running = true
	await run_turn_sequence()
	is_action_running = false
	
	if max_mana < MAX_MANA_CAP:
		max_mana += 1
	current_mana = max_mana
	update_mana()
	
	end_turn_btn.disabled = false
	end_turn_btn.text = "结束回合"
	
func run_turn_sequence():
	for r in range(6):
		for c in range(3):
			var cell = grid_cells[Vector2(r, c)]
			if cell.has_card and not cell.is_enemy and not cell.has_attacked:
				var enemies = find_adjacent_enemies(cell, false)
				if enemies.size() > 0:
					await attack_cells(cell, enemies)
					cell.has_attacked = true
					continue
				if r == 0:
					apply_damage_to_hero(true, cell.attack)
					cell.has_attacked = true
					await get_tree().create_timer(0.5).timeout
					continue
				
				var target_r = r - 1
				if target_r >= 0:
					var target = grid_cells[Vector2(target_r, c)]
					if not target.has_card:
						await move_card(cell, target)
						target.has_attacked = true 
						await get_tree().create_timer(0.5).timeout

	var spawned_any = false
	for sp in spawners:
		sp.timer += 1
		if sp.timer >= sp.interval:
			var target_cell = grid_cells[sp.position]
			if not target_cell.has_card:
				var cdata = _get_card_data(sp.name)
				if cdata:
					target_cell.set_card(cdata.name, cdata.attack, cdata.health, sp.faction == 1, cdata.effects)
					sp.timer = 0
					spawned_any = true
	if spawned_any:
		await get_tree().create_timer(0.5).timeout

	for r in range(5, -1, -1):
		for c in range(2, -1, -1):
			var cell = grid_cells[Vector2(r, c)]
			if cell.has_card and cell.is_enemy and not cell.has_attacked:
				var enemies = find_adjacent_enemies(cell, true)
				if enemies.size() > 0:
					await attack_cells(cell, enemies)
					cell.has_attacked = true
					continue
				if r == 5:
					apply_damage_to_hero(false, cell.attack)
					cell.has_attacked = true
					await get_tree().create_timer(0.5).timeout
					continue
				
				var target_r = r + 1
				if target_r <= 5:
					var target = grid_cells[Vector2(target_r, c)]
					if not target.has_card:
						await move_card(cell, target)
						target.has_attacked = true
						await get_tree().create_timer(0.5).timeout

	for r in range(6):
		for c in range(3):
			grid_cells[Vector2(r, c)].has_attacked = false
	update_phantoms()

func update_phantoms():
	for sp in spawners:
		if sp.timer >= sp.interval - 1:
			var target_cell = grid_cells[sp.position]
			if not target_cell.has_card:
				var cdata = _get_card_data(sp.name)
				if cdata:
					target_cell.set_phantom(cdata.name, cdata.attack, cdata.health, sp.faction == 1, cdata.effects)

func find_adjacent_enemies(cell, for_enemy):
	var r = cell.row
	var c = cell.col
	var checks = []
	if for_enemy:
		checks = [
			{"pos": Vector2(r+1,c), "dir": "bottom", "opp_dir": "top"},
			{"pos": Vector2(r,c-1), "dir": "left", "opp_dir": "right"},
			{"pos": Vector2(r,c+1), "dir": "right", "opp_dir": "left"},
			{"pos": Vector2(r-1,c), "dir": "top", "opp_dir": "bottom"}
		]
	else:
		checks = [
			{"pos": Vector2(r-1,c), "dir": "top", "opp_dir": "bottom"},
			{"pos": Vector2(r,c-1), "dir": "left", "opp_dir": "right"},
			{"pos": Vector2(r,c+1), "dir": "right", "opp_dir": "left"},
			{"pos": Vector2(r+1,c), "dir": "bottom", "opp_dir": "top"}
		]
	var found = []
	for check in checks:
		if grid_cells.has(check.pos):
			var tgt = grid_cells[check.pos]
			if tgt.has_card:
				if for_enemy and not tgt.is_enemy: found.append({"cell": tgt, "dir": check.dir, "opp_dir": check.opp_dir})
				if not for_enemy and tgt.is_enemy: found.append({"cell": tgt, "dir": check.dir, "opp_dir": check.opp_dir})
	return found

func _handle_card_death(cell):
	if cell.is_enemy: return
	var cdata = _get_card_data(cell.card_name)
	if cdata:
		var handled = false
		var effs = _extract_effects(cdata)
		for eff in effs:
			if EffectUtils.trigger_death(eff, cdata, self):
				handled = true
		if not handled:
			graveyard.append(cdata)

func _extract_effects(card_data) -> Array:
	if card_data == null:
		return []
	if typeof(card_data) == TYPE_DICTIONARY:
		var v = card_data.get("effects", [])
		return v if v != null else []
	if "effects" in card_data and card_data.effects != null:
		return card_data.effects
	return []

func attack_cells(attacker, defender_data_list):
	var a_atk = attacker.attack
	var dead_cells = []
	
	# 同步触发攻击者的黄色发起攻击特效
	attacker.play_attack_effect()
	
	# 首先只削减防守者的生命值（不再承受反击）
	for defender_data in defender_data_list:
		var defender = defender_data.cell
		defender.health[defender_data.opp_dir] -= a_atk
		defender._update_hp_labels()
		# 同时生成所有红色的受击特效
		defender.play_damage_effect()
		
	# 等待受击的红色特效和攻击者的黄色特效结束（它们用时一致）
	await get_tree().create_timer(0.45).timeout
	
	# 判定是否有单位死亡
	for defender_data in defender_data_list:
		var defender = defender_data.cell
		if defender.health[defender_data.opp_dir] <= 0:
			if not dead_cells.has(defender):
				dead_cells.append(defender)
				
	# 若有死亡目标
	if dead_cells.size() > 0:
		for dc in dead_cells:
			# 同时生成所有灰色的即死特效
			dc.play_death_effect()
		
		# 等待灰色特效结束
		await get_tree().create_timer(0.45).timeout
		
		# 处理单位的彻底销毁和移除
		for dc in dead_cells:
			_handle_card_death(dc)
			if dc.has_card:
				dc.clear_card()

func move_card(start, end):
	var cname = start.card_name
	var atk = start.attack
	var hp = start.health
	var is_e = start.is_enemy
	var effs = start.effects
	
	var visual = cell_scene.instantiate()
	add_child(visual)
	visual.global_position = start.global_position
	visual.z_index = 100
	visual.pivot_offset = visual.custom_minimum_size / 2.0
	visual.set_card(cname, atk, hp, is_e, effs)
	visual.self_modulate.a = 0.0
	
	start.clear_card()
	
	var tween = get_tree().create_tween()
	var mid_pos = (start.global_position + end.global_position) / 2.0
	var offset = Vector2(0, -70)
	
	tween.tween_property(visual, "global_position", mid_pos + offset, 0.2).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(visual, "scale", Vector2(1.08, 1.08), 0.2).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	
	tween.tween_property(visual, "global_position", end.global_position, 0.2).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.parallel().tween_property(visual, "scale", Vector2(1.0, 1.0), 0.2).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	
	await tween.finished
	visual.queue_free()
	
	end.set_card(cname, atk, hp, is_e, effs)

func play_spell(spell_data, target_cell):
	if spell_data:
		var effs = _extract_effects(spell_data)
		var is_exhausted = false
		for eff in effs:
			if eff == "exhaust":
				is_exhausted = true
				continue
			EffectUtils.trigger_play(eff, spell_data, self)
		
		if is_exhausted:
			banished.append(spell_data)
		else:
			graveyard.append(spell_data)

func trigger_unit_play_effects(unit_data, target_cell):
	if unit_data == null:
		return
	for eff in _extract_effects(unit_data):
		EffectUtils.trigger_play(eff, unit_data, self)

func _init_settings_panel():
	# 左上角设置按钮
	settings_btn = Button.new()
	settings_btn.name = "SettingsBtn"
	settings_btn.text = "设置"
	settings_btn.add_theme_font_size_override("font_size", 32)
	settings_btn.set_anchors_preset(Control.PRESET_TOP_LEFT)
	settings_btn.offset_left = 20
	settings_btn.offset_top = 20
	settings_btn.offset_right = 180
	settings_btn.offset_bottom = 100
	
	var btn_normal = create_style(Color("#339af0"), Color.TRANSPARENT, 0, 12, true)
	var btn_hover = create_style(Color("#228be6"), Color.TRANSPARENT, 0, 12, true)
	var btn_pressed = create_style(Color("#228be6"), Color.TRANSPARENT, 0, 12)
	settings_btn.add_theme_stylebox_override("normal", btn_normal)
	settings_btn.add_theme_stylebox_override("hover", btn_hover)
	settings_btn.add_theme_stylebox_override("pressed", btn_pressed)
	settings_btn.add_theme_color_override("font_color", Color.WHITE)
	add_child(settings_btn)
	settings_btn.pressed.connect(_on_settings_btn_pressed)
	# 让左侧弹出面板（详情/牌堆/墓地/除外）显示在设置按钮之上
	for p_name in ui_panels.keys():
		ui_panels[p_name].move_to_front()
	if detail_panel_clip:
		detail_panel_clip.move_to_front()
	
	# 全屏遮罩（变灰背景 + 拦截外部点击）
	settings_overlay = ColorRect.new()
	settings_overlay.name = "SettingsOverlay"
	settings_overlay.color = Color(0, 0, 0, 0.5)
	settings_overlay.set_anchors_preset(Control.PRESET_FULL_RECT)
	settings_overlay.mouse_filter = Control.MOUSE_FILTER_STOP
	settings_overlay.visible = false
	add_child(settings_overlay)
	settings_overlay.gui_input.connect(_on_settings_overlay_input)
	
	# 中央设置面板（暂无内容）
	settings_panel = Panel.new()
	settings_panel.name = "SettingsPanel"
	settings_panel.set_anchors_preset(Control.PRESET_CENTER)
	settings_panel.offset_left = -300
	settings_panel.offset_top = -200
	settings_panel.offset_right = 300
	settings_panel.offset_bottom = 200
	settings_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	var sb = create_style(Color(0.96, 0.97, 0.98, 1.0), Color("#d1d9e0"), 1, 20, true)
	settings_panel.add_theme_stylebox_override("panel", sb)
	settings_overlay.add_child(settings_panel)
	
	# 按钮区：垂直排列，按钮宽 > 高
	var vbox = VBoxContainer.new()
	vbox.name = "SettingsVBox"
	vbox.set_anchors_preset(Control.PRESET_CENTER)
	vbox.offset_left = -140
	vbox.offset_top = -135
	vbox.offset_right = 140
	vbox.offset_bottom = 135
	vbox.add_theme_constant_override("separation", 20)
	vbox.alignment = BoxContainer.ALIGNMENT_CENTER
	settings_panel.add_child(vbox)
	
	var resume_btn = _make_settings_button("继续")
	resume_btn.pressed.connect(_on_settings_resume_pressed)
	vbox.add_child(resume_btn)
	
	var config_btn = _make_settings_button("设置")
	# 设置按钮：仅点击效果，无逻辑
	vbox.add_child(config_btn)
	
	var exit_btn = _make_settings_button("退出")
	exit_btn.pressed.connect(_on_settings_exit_pressed)
	vbox.add_child(exit_btn)

func _make_settings_button(label: String) -> Button:
	var b = Button.new()
	b.text = label
	b.custom_minimum_size = Vector2(280, 70)
	b.add_theme_font_size_override("font_size", 26)
	b.add_theme_color_override("font_color", Color.WHITE)
	b.add_theme_stylebox_override("normal", create_style(Color("#339af0"), Color.TRANSPARENT, 0, 12, true))
	b.add_theme_stylebox_override("hover", create_style(Color("#228be6"), Color.TRANSPARENT, 0, 12, true))
	b.add_theme_stylebox_override("pressed", create_style(Color("#1c7ed6"), Color.TRANSPARENT, 0, 12))
	return b

func _on_settings_resume_pressed():
	_close_settings_panel()

func _on_settings_exit_pressed():
	get_tree().quit()

func _on_settings_btn_pressed():
	is_settings_open = true
	settings_overlay.move_to_front()
	settings_overlay.visible = true

func _on_settings_overlay_input(event):
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		# 点击到面板外的区域 → 关闭
		var mp = settings_overlay.get_local_mouse_position()
		if not settings_panel.get_rect().has_point(mp):
			_close_settings_panel()

func _close_settings_panel():
	is_settings_open = false
	settings_overlay.visible = false
