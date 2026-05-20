class_name DetailPanelController
extends Node

# 长按详情面板。原 main.gd:60-200 全部迁移于此。
# 通过 register_long_press_source() 让 cell/hand_card/侧栏按钮注册长按目标。

var _parent: Control
var _hand_card_scene: PackedScene

var _clip: Control
var _panel: Panel
var _long_press_timer: Timer
var _long_press_target = null
var _long_press_kind: String = "card"  # "card" | "hero"
var _is_open: bool = false

const LONG_PRESS_TIME: float = 0.4
const PANEL_WIDTH: float = 320.0

func setup(parent: Control, hand_card_scene: PackedScene) -> void:
	_parent = parent
	_hand_card_scene = hand_card_scene
	_build_panel()
	_long_press_timer = Timer.new()
	_long_press_timer.wait_time = LONG_PRESS_TIME
	_long_press_timer.one_shot = true
	_long_press_timer.timeout.connect(_on_long_press_timeout)
	_parent.add_child(_long_press_timer)

func _build_panel() -> void:
	_clip = Control.new()
	_clip.name = "DetailPanelClip"
	_parent.add_child(_clip)
	_clip.set_anchors_preset(Control.PRESET_LEFT_WIDE, false)
	_clip.offset_left = 10
	_clip.offset_right = 330
	_clip.offset_top = 10
	_clip.offset_bottom = -10
	_clip.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_clip.clip_contents = true
	_clip.visible = false
	# 高 z_index 压住战斗动画 visual（visual.z_index = 100）。
	_clip.z_index = 200

	_panel = Panel.new()
	_panel.name = "DetailPanel"
	_clip.add_child(_panel)
	_panel.set_anchors_preset(Control.PRESET_LEFT_WIDE, false)
	_panel.offset_left = -PANEL_WIDTH
	_panel.offset_right = 0
	_panel.offset_top = 0
	_panel.offset_bottom = 0
	_panel.mouse_filter = Control.MOUSE_FILTER_STOP
	_panel.add_theme_stylebox_override("panel", ThemeFactory.panel(Color(0.94, 0.95, 0.96, 1.0), Color(1, 1, 1, 1.0), 1, 20))

	var vbox := VBoxContainer.new()
	vbox.name = "DetailVBox"
	vbox.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	vbox.offset_left = 20
	vbox.offset_right = -20
	vbox.offset_top = 30
	vbox.offset_bottom = -20
	vbox.add_theme_constant_override("separation", 20)
	_panel.add_child(vbox)

	var card_center := CenterContainer.new()
	card_center.name = "CardCenter"
	card_center.custom_minimum_size = Vector2(0, 240)
	vbox.add_child(card_center)

	var name_lbl := Label.new()
	name_lbl.name = "NameLbl"
	name_lbl.add_theme_font_size_override("font_size", 24)
	name_lbl.add_theme_color_override("font_color", Color(0.2, 0.2, 0.2, 1))
	name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(name_lbl)

	# 英雄专用：血量行（不随战斗扣减），插在名字与费用/技能行之间。
	var hp_lbl := Label.new()
	hp_lbl.name = "HpLbl"
	hp_lbl.add_theme_font_size_override("font_size", 20)
	hp_lbl.add_theme_color_override("font_color", Color(0.85, 0.3, 0.3, 1))
	hp_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	hp_lbl.visible = false
	vbox.add_child(hp_lbl)

	var cost_lbl := Label.new()
	cost_lbl.name = "CostLbl"
	cost_lbl.add_theme_font_size_override("font_size", 20)
	cost_lbl.add_theme_color_override("font_color", Color(0.3, 0.3, 0.3, 1))
	vbox.add_child(cost_lbl)

	var effect_lbl := Label.new()
	effect_lbl.name = "EffectLbl"
	effect_lbl.add_theme_font_size_override("font_size", 18)
	effect_lbl.add_theme_color_override("font_color", Color(0.4, 0.4, 0.4, 1))
	effect_lbl.autowrap_mode = TextServer.AUTOWRAP_ARBITRARY
	vbox.add_child(effect_lbl)

func start_long_press(target_data) -> void:
	_long_press_target = target_data
	_long_press_kind = "card"
	if _long_press_timer:
		_long_press_timer.start()

# 英雄长按。target 为字典 {name, ability_id, hp}。
func start_long_press_hero(hero_name: String, ability_id: String = "", display_hp: int = -1) -> void:
	_long_press_target = {"name": hero_name, "ability_id": ability_id, "hp": display_hp}
	_long_press_kind = "hero"
	if _long_press_timer:
		_long_press_timer.start()

func cancel_long_press() -> void:
	if _long_press_timer:
		_long_press_timer.stop()
	_long_press_target = null

func _on_long_press_timeout() -> void:
	if _long_press_kind == "hero":
		var t = _long_press_target
		if typeof(t) == TYPE_DICTIONARY:
			show_hero(String(t.get("name", "")), String(t.get("ability_id", "")), int(t.get("hp", -1)))
		else:
			show_hero(String(t))
	else:
		show_for(_long_press_target)

func show_for(data) -> void:
	if data == null:
		return
	var vbox := _panel.get_node_or_null("DetailVBox")
	if vbox == null:
		return
	var card_center := vbox.get_node("CardCenter") as Control
	var name_lbl := vbox.get_node("NameLbl") as Label
	var hp_lbl := vbox.get_node("HpLbl") as Label
	var cost_lbl := vbox.get_node("CostLbl") as Label
	var effect_lbl := vbox.get_node("EffectLbl") as Label

	# 卡牌模式：恢复 CardCenter 占位，隐藏英雄专用血量行。
	card_center.visible = true
	card_center.custom_minimum_size = Vector2(0, 240)
	hp_lbl.visible = false

	for c in card_center.get_children():
		c.queue_free()

	var cname: String = ""
	if typeof(data) == TYPE_DICTIONARY:
		cname = String(data.get("name", ""))
	else:
		cname = data.name

	var cdata = Game.get_card(cname)
	if not cdata and typeof(data) != TYPE_DICTIONARY:
		cdata = data

	if cdata:
		var visual = _hand_card_scene.instantiate()
		card_center.add_child(visual)
		visual.setup(cdata, 0)
		visual.mouse_filter = Control.MOUSE_FILTER_IGNORE
		visual.scale = Vector2.ONE

		name_lbl.text = cname
		cost_lbl.text = "费用: " + str(cdata.cost)

		var effect_texts: Array = []
		for eff in cdata.effects:
			effect_texts.append(Effects.get_description(eff))
		effect_lbl.text = "\n".join(effect_texts) if effect_texts.size() > 0 else "无附加效果"

	if _is_open:
		return
	_is_open = true
	_clip.visible = true
	_panel.offset_left = -PANEL_WIDTH
	_panel.offset_right = 0
	var tween := get_tree().create_tween()
	tween.tween_property(_panel, "offset_left", 0.0, 0.2).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(_panel, "offset_right", PANEL_WIDTH, 0.2).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

# 英雄详情：显示名字 + 血量 + 技能名/描述，复用同一弹出动画。
# 不显示费用括号；CardCenter 隐藏让文字整体上移。血量传 -1 表示走默认从 Game.hero 取初始 max。
func show_hero(hero_name: String, ability_id: String = "", display_hp: int = -1) -> void:
	if hero_name == "":
		return
	var vbox := _panel.get_node_or_null("DetailVBox")
	if vbox == null:
		return
	var card_center := vbox.get_node("CardCenter") as Control
	var name_lbl := vbox.get_node("NameLbl") as Label
	var hp_lbl := vbox.get_node("HpLbl") as Label
	var cost_lbl := vbox.get_node("CostLbl") as Label
	var effect_lbl := vbox.get_node("EffectLbl") as Label

	for c in card_center.get_children():
		c.queue_free()
	# 英雄模式：CardCenter 隐藏并清零占位，让 Name/Hp/Skill 整体上移。
	card_center.visible = false
	card_center.custom_minimum_size = Vector2.ZERO

	name_lbl.text = hero_name
	hp_lbl.visible = true
	hp_lbl.text = "血量：%d" % display_hp

	if ability_id != "" and HeroAbilities.has(ability_id):
		cost_lbl.text = "技能：%s" % HeroAbilities.get_display_name(ability_id)
		effect_lbl.text = HeroAbilities.get_description(ability_id)
	else:
		cost_lbl.text = ""
		effect_lbl.text = ""

	if _is_open:
		return
	_is_open = true
	_clip.visible = true
	_panel.offset_left = -PANEL_WIDTH
	_panel.offset_right = 0
	var tween := get_tree().create_tween()
	tween.tween_property(_panel, "offset_left", 0.0, 0.2).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(_panel, "offset_right", PANEL_WIDTH, 0.2).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

func hide_panel() -> void:
	if not _is_open:
		return
	_is_open = false
	var tween := get_tree().create_tween()
	tween.tween_property(_panel, "offset_left", -PANEL_WIDTH, 0.2).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.parallel().tween_property(_panel, "offset_right", 0.0, 0.2).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_callback(func(): _clip.visible = false)

func get_clip() -> Control:
	return _clip
