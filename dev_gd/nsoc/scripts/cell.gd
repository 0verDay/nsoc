extends Panel

# 棋盘格子。
# 重构后：
#   1. 不再通过 get_tree().current_scene 调用 main，改为发射信号供 PlayController 监听。
#   2. 样式由 ThemeFactory 统一构造。
#   3. 效果徽章由 EffectBadgeFactory 统一构造（去重 hand_card 的实现）。

signal long_press_requested(payload)
signal long_press_canceled
signal card_dropped(cell, drag_data)
signal cleared(cell)

var row: int = 0
var col: int = 0
var has_card: bool = false
var is_enemy: bool = false
var card_name: String = ""
var attack: int = 0
var health: Dictionary = {"top": 0, "bottom": 0, "left": 0, "right": 0}
var effects: Array = []
var has_attacked: bool = false
var is_phantom: bool = false

@onready var inner_panel = $InnerPanel
@onready var name_lbl = $InnerPanel/NameLbl
@onready var atk_lbl = $InnerPanel/AtkBg/AtkLbl

var hp_labels: Dictionary = {}
var active_tween = null
var is_drag_hovered: bool = false

func _ready() -> void:
	add_theme_stylebox_override("panel", ThemeFactory.cell_panel(Color.WHITE, Color("#d1d9e0"), 2, 20))
	$InnerPanel/AtkBg.add_theme_stylebox_override("panel", ThemeFactory.cell_panel(Color("#ff6b6b"), Color.TRANSPARENT, 0, 8))

	hp_labels["top"] = $InnerPanel/TopHp
	hp_labels["bottom"] = $InnerPanel/BottomHp
	hp_labels["left"] = $InnerPanel/LeftHp
	hp_labels["right"] = $InnerPanel/RightHp
	for d in hp_labels.values():
		d.add_theme_stylebox_override("normal", ThemeFactory.pill(Color("#51cf66"), 10))

	clear_card()
	inner_panel.pivot_offset = custom_minimum_size / 2.0
	gui_input.connect(_on_gui_input)
	mouse_exited.connect(_on_mouse_exit)

func _on_gui_input(event) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.is_pressed():
			_on_mouse_enter()
			if has_card:
				long_press_requested.emit({"name": card_name, "attack": attack, "health": health})
		else:
			_on_mouse_exit()

func _on_mouse_enter() -> void:
	if has_card and get_tree():
		var tween := create_tween()
		tween.tween_property(inner_panel, "scale", Vector2(1.08, 1.08), 0.1)

func _on_mouse_exit() -> void:
	long_press_canceled.emit()
	if (has_card or is_phantom) and get_tree():
		var tween := create_tween()
		tween.tween_property(inner_panel, "scale", Vector2.ONE, 0.1)

func set_phantom(cname, atk, hp, enemy: bool = false, effects_in: Array = []) -> void:
	set_card(cname, atk, hp, enemy, effects_in)
	has_card = false
	is_phantom = true
	inner_panel.modulate.a = 0.4

func set_card(cname, atk, hp, enemy: bool = false, effects_in: Array = []) -> void:
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
		inner_panel.add_theme_stylebox_override("panel", ThemeFactory.cell_panel(Color("#fff5f5"), Color("#ffc9c9"), 1, 20, true))
		name_lbl.add_theme_color_override("font_color", Color("#fa5252"))
	else:
		inner_panel.add_theme_stylebox_override("panel", ThemeFactory.cell_panel(Color.WHITE, Color("#e1e8ed"), 1, 20, true))
		name_lbl.add_theme_color_override("font_color", Color("#495057"))

	EffectBadgeFactory.refresh(inner_panel.get_node_or_null("EffectBadges"), effects)
	inner_panel.visible = true

func _update_hp_labels() -> void:
	for d in hp_labels.keys():
		hp_labels[d].text = str(health[d])

func clear_card() -> void:
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
	cleared.emit(self)

func play_damage_effect() -> void:
	if active_tween:
		active_tween.kill()
	inner_panel.self_modulate = Color("#ffc9c9") if is_enemy else Color("#ffe3e3")
	if get_tree():
		active_tween = get_tree().create_tween()
		active_tween.tween_property(inner_panel, "self_modulate", Color.WHITE, 0.4)

func play_attack_effect() -> void:
	if active_tween:
		active_tween.kill()
	inner_panel.self_modulate = Color("#ffe066")
	if get_tree():
		active_tween = get_tree().create_tween()
		active_tween.tween_property(inner_panel, "self_modulate", Color.WHITE, 0.4)

func play_death_effect() -> void:
	if active_tween:
		active_tween.kill()
	inner_panel.self_modulate = Color.WHITE
	if get_tree():
		active_tween = get_tree().create_tween()
		active_tween.tween_property(inner_panel, "self_modulate", Color(0.5, 0.5, 0.5), 0.4)

func receive_damage(dir, dmg, dying: bool = false) -> bool:
	health[dir] -= dmg
	_update_hp_labels()
	if dying:
		play_death_effect()
	else:
		play_damage_effect()
	return health[dir] <= 0

func set_drag_hover(hovered: bool) -> void:
	if is_drag_hovered == hovered:
		return
	is_drag_hovered = hovered

	if is_drag_hovered:
		var highlight_style := ThemeFactory.cell_panel(Color.WHITE, Color("#339af0"), 2, 20, true)
		if has_card:
			inner_panel.add_theme_stylebox_override("panel", highlight_style)
		else:
			add_theme_stylebox_override("panel", highlight_style)
	else:
		if has_card:
			if is_enemy:
				inner_panel.add_theme_stylebox_override("panel", ThemeFactory.cell_panel(Color("#fff5f5"), Color("#ffc9c9"), 1, 20, true))
			else:
				inner_panel.add_theme_stylebox_override("panel", ThemeFactory.cell_panel(Color.WHITE, Color("#e1e8ed"), 1, 20, true))
		add_theme_stylebox_override("panel", ThemeFactory.cell_panel(Color.WHITE, Color("#d1d9e0"), 2, 20))

func _notification(what) -> void:
	if what == NOTIFICATION_DRAG_END:
		set_drag_hover(false)

func _process(_delta) -> void:
	if is_drag_hovered:
		if not get_global_rect().has_point(get_global_mouse_position()):
			set_drag_hover(false)

func _can_drop_data(_pos, data) -> bool:
	if typeof(data) == TYPE_DICTIONARY and data.has("type"):
		# 法力检查交由 GameContext，避免对 main 的硬依赖
		if Game.mana.current < data.cost:
			return false
		var can_drop := false
		if data.type == "法术":
			can_drop = true
		elif has_card:
			can_drop = false
		elif data.type == "单位" and row <= 2:
			can_drop = false
		else:
			can_drop = true
		if can_drop:
			set_drag_hover(true)
			return true
	return false

func _drop_data(_pos, data) -> void:
	# 不在此处结算，统一发到 PlayController。
	card_dropped.emit(self, data)
