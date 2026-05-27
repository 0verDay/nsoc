extends Panel

# 手牌卡片。
# 重构后：
#   1. 长按交互改为信号 long_press_requested / long_press_canceled，由 HandView 转发。
#   2. is_action_running 改为读 Game.turn 状态，避免对 main 反向引用。
#   3. 样式 / 徽章使用 ThemeFactory + EffectBadgeFactory。

signal long_press_requested(card_data)
signal long_press_canceled

var card_data = {}
var card_id: int = 0

@onready var cost_lbl = $CostBg/CostLbl
@onready var name_lbl = $NameLbl
@onready var atk_lbl = $AtkBg/AtkLbl

var hp_labels_abs: Dictionary = {}

func _ready() -> void:
	add_theme_stylebox_override("panel", ThemeFactory.card_panel(Color.WHITE, Color("#e1e8ed"), 1, 15, true))
	$CostBg.add_theme_stylebox_override("panel", ThemeFactory.pill(Color("#339af0"), 12, true))
	$AtkBg.add_theme_stylebox_override("panel", ThemeFactory.pill(Color("#ff6b6b"), 12, true))

	# 手牌按玩家视角呈现：abs.top = 单位 front，abs.bottom = back，左右一致
	hp_labels_abs["top"] = $TopHp
	hp_labels_abs["bottom"] = $BottomHp
	hp_labels_abs["left"] = $LeftHp
	hp_labels_abs["right"] = $RightHp
	for d in hp_labels_abs.values():
		d.add_theme_stylebox_override("normal", ThemeFactory.pill(Color("#51cf66"), 10))

	pivot_offset = custom_minimum_size / 2.0
	gui_input.connect(_on_gui_input)
	mouse_exited.connect(_on_mouse_exit)

func _on_gui_input(event) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.is_pressed():
			_on_mouse_enter()
			long_press_requested.emit(card_data)
		else:
			_on_mouse_exit()

func _on_mouse_enter() -> void:
	if modulate.a < 1.0:
		return
	if get_tree():
		var tween := create_tween()
		tween.tween_property(self, "scale", Vector2(1.1, 1.1), 0.1)

func _on_mouse_exit() -> void:
	long_press_canceled.emit()
	if get_tree():
		var tween := create_tween()
		tween.tween_property(self, "scale", Vector2.ONE, 0.1)

func _process(_delta) -> void:
	var locked := _is_action_running()
	mouse_default_cursor_shape = Control.CURSOR_FORBIDDEN if locked else Control.CURSOR_ARROW

func _is_action_running() -> bool:
	return Game.turn.is_running

func setup(data, id: int) -> void:
	card_data = data
	card_id = id
	cost_lbl.text = str(data.cost)
	name_lbl.text = data.name

	var is_unit := false
	if typeof(data) == TYPE_DICTIONARY:
		is_unit = (data.type == "单位")
	else:
		is_unit = (data is CardUnit)

	if is_unit:
		atk_lbl.text = str(data.attack)
		# data.health 以单位视角 side 存储；手牌按玩家朝向展示，
		# 即 abs.top→front, abs.bottom→back, abs.left→left, abs.right→right。
		for abs_dir in hp_labels_abs.keys():
			var side := Orientation.abs_to_side(abs_dir, false)
			hp_labels_abs[abs_dir].text = str(data.health[side])
		atk_lbl.visible = true
		$AtkBg.visible = true
		for lbl in hp_labels_abs.values():
			lbl.visible = true
	else:
		atk_lbl.visible = false
		$AtkBg.visible = false
		for lbl in hp_labels_abs.values():
			lbl.visible = false

	var effs: Array = data.get("effects", []) if typeof(data) == TYPE_DICTIONARY else data.effects
	EffectBadgeFactory.refresh(get_node_or_null("EffectBadges"), effs)

func _get_drag_data(_pos):
	if _is_action_running():
		return null

	var root := Control.new()
	var preview := Panel.new()
	preview.size = self.size
	preview.position = -_pos
	preview.add_theme_stylebox_override("panel", ThemeFactory.card_panel(Color.WHITE, Color("#339af0"), 2, 15, true))
	var pl := Label.new()
	pl.text = name_lbl.text
	pl.add_theme_color_override("font_color", Color("#339af0"))
	pl.add_theme_font_size_override("font_size", 24)
	pl.set_anchors_preset(PRESET_FULL_RECT, false)
	pl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	pl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	preview.add_child(pl)
	root.add_child(preview)
	set_drag_preview(root)

	modulate.a = 0.5
	_on_mouse_exit()

	var drag_dict := {
		"type": card_data.type,
		"cost": card_data.cost,
		"card_name": card_data.name,
		"source_card": self,
		"full_data": card_data,
	}
	var is_unit := false
	if typeof(card_data) == TYPE_DICTIONARY:
		is_unit = (card_data.type == "单位")
	else:
		is_unit = (card_data is CardUnit)
	if is_unit:
		drag_dict["attack"] = card_data.attack
		# health 以 side 字典传递，落到 cell 时由 cell.set_card 直接消费
		drag_dict["health"] = Orientation.clone_side_health(card_data.health)
	return drag_dict

func _notification(what) -> void:
	if what == NOTIFICATION_DRAG_END:
		if get_meta("consumed", false):
			return
		modulate.a = 1.0
