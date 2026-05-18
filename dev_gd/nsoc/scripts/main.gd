extends Control

const MIN_HAND_SIZE = 5
const MAX_MANA_CAP = 10
var max_mana = 1
var current_mana = 1
var card_counter = 1

var player_health = 30
var enemy_health = 30
var is_action_running = false

var testCards = [
	{ "name": "blanket", "type": "单位", "cost": 1, "health": 1, "attack": 1, "count": 5 },
	{ "name": "pro", "type": "单位", "cost": 2, "health": 2, "attack": 2, "count": 3 }
]
var draw_pile = []
var unit_config = []
var spawners = []

var grid_cells = {}
@onready var hand_container = $BottomBar/HandClip/HandContainer
@onready var enemy_health_label = $EnemyHpPnl/EnemyHealthLabel
@onready var player_health_label = $BottomBar/PHpPnl/PlayerHealthLabel
@onready var mana_label = $BottomBar/ManaPnl/ManaLabel
@onready var end_turn_btn = $BottomBar/EndTurnBtn

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

func _ready():
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
				var new_card = card.duplicate()
				if new_card.has("cost"): new_card["cost"] = int(new_card["cost"])
				if new_card.has("health"): new_card["health"] = int(new_card["health"])
				if new_card.has("attack"): new_card["attack"] = int(new_card["attack"])
				if new_card.has("count"): new_card["count"] = int(new_card["count"])
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
	
	_reshuffle_deck()

func _reshuffle_deck():
	draw_pile.clear()
	for card in testCards:
		var count = 1
		if card.has("count"):
			count = int(card["count"])
		for i in range(count):
			draw_pile.append(card)
	draw_pile.shuffle()

func _apply_styles():
	$Bg.add_theme_stylebox_override("panel", create_style(Color.WHITE, Color("#e1e8ed"), 1, 0))
	$EnemyHpPnl.add_theme_stylebox_override("panel", create_style(Color.WHITE, Color("#ff6b6b"), 2, 20, true))
	
	var grid_bg_style = create_style(Color("#f0f3f5"), Color("#e1e8ed"), 1, 16)
	$TopGridBg.add_theme_stylebox_override("panel", grid_bg_style)
	$BottomGridBg.add_theme_stylebox_override("panel", grid_bg_style)
	
	var bb_style = create_style(Color(0.94, 0.95, 0.96, 0.85), Color(1, 1, 1, 0.6), 1, 20)
	$BottomBar.add_theme_stylebox_override("panel", bb_style)
	
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
				cell.set_card(cdata.name, cdata.attack, cdata.health, cfg.faction == 1)

func _get_card_data(name_str):
	for c in testCards:
		if c.name == name_str: return c
	return null

func get_random_card():
	if draw_pile.size() == 0:
		_reshuffle_deck()
	return draw_pile.pop_back()

func ensure_min_hand_size():
	while hand_container.get_child_count() < MIN_HAND_SIZE:
		var c = hand_card_scene.instantiate()
		hand_container.add_child(c)
		var data = get_random_card()
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
				var enemy = find_adjacent_enemy(cell, false)
				if enemy:
					attack_cell(cell, enemy)
					cell.has_attacked = true
					await get_tree().create_timer(0.5).timeout
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
					target_cell.set_card(cdata.name, cdata.attack, cdata.health, sp.faction == 1)
					sp.timer = 0
					spawned_any = true
	if spawned_any:
		await get_tree().create_timer(0.5).timeout

	for r in range(5, -1, -1):
		for c in range(2, -1, -1):
			var cell = grid_cells[Vector2(r, c)]
			if cell.has_card and cell.is_enemy and not cell.has_attacked:
				var enemy = find_adjacent_enemy(cell, true)
				if enemy:
					attack_cell(cell, enemy)
					cell.has_attacked = true
					await get_tree().create_timer(0.5).timeout
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
					target_cell.set_phantom(cdata.name, cdata.attack, cdata.health, sp.faction == 1)

func find_adjacent_enemy(cell, for_enemy):
	var r = cell.row
	var c = cell.col
	var checks = []
	if for_enemy:
		checks = [Vector2(r+1,c), Vector2(r,c-1), Vector2(r,c+1), Vector2(r-1,c)]
	else:
		checks = [Vector2(r-1,c), Vector2(r,c-1), Vector2(r,c+1), Vector2(r+1,c)]
	for pos in checks:
		if grid_cells.has(pos):
			var tgt = grid_cells[pos]
			if tgt.has_card:
				if for_enemy and not tgt.is_enemy: return tgt
				if not for_enemy and tgt.is_enemy: return tgt
	return null

func attack_cell(attacker, defender):
	var a_atk = attacker.attack
	var d_atk = defender.attack
	var a_dead = attacker.receive_damage(d_atk)
	var d_dead = defender.receive_damage(a_atk)
	if a_dead: 
		attacker.play_death_effect()
		attacker.clear_card()
	if d_dead: 
		defender.play_death_effect()
		defender.clear_card()

func move_card(start, end):
	var cname = start.card_name
	var atk = start.attack
	var hp = start.health
	var is_e = start.is_enemy
	start.clear_card()
	
	var visual = Panel.new()
	if is_e:
		visual.add_theme_stylebox_override("panel", create_style(Color("#fff5f5"), Color("#ffc9c9"), 1, 12, true))
	else:
		visual.add_theme_stylebox_override("panel", create_style(Color.WHITE, Color("#e1e8ed"), 1, 12, true))
	
	visual.size = start.size
	visual.position = start.global_position
	var lbl = Label.new()
	lbl.text = cname
	if is_e:
		lbl.add_theme_color_override("font_color", Color("#fa5252"))
	else:
		lbl.add_theme_color_override("font_color", Color("#495057"))
	lbl.set_anchors_preset(PRESET_FULL_RECT)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	visual.add_child(lbl)
	add_child(visual)
	
	var tween = get_tree().create_tween()
	tween.tween_property(visual, "global_position", end.global_position, 0.4).set_trans(Tween.TRANS_CUBIC)
	await tween.finished
	visual.queue_free()
	
	end.set_card(cname, atk, hp, is_e)
