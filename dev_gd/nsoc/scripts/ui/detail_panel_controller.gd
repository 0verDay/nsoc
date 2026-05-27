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
# 详情面板默认宽度（游玩界面用）。备战界面通过 attach_to_rect(HeroPnl) 改为
# 跟随 HeroPnl 实时尺寸，确保任意分辨率下都能完全遮住英雄卡片。
const PANEL_WIDTH: float = 464.0
const PANEL_LEFT_INSET: float = 10.0

# 跟随目标：非空时 clip 的位置/尺寸每帧锁定到 target 的全局矩形上，
# 这样 detail panel 完全覆盖 target，不受设计分辨率与实际屏幕比例差异影响。
var _follow_target: Control = null
# 跟随模式下，true 时 _sync_to_target 不改 panel 的 offset_left/right，
# 让弹出/收回 tween 完整播放，避免每帧把 panel 拉回关闭态导致动画消失。
var _animating: bool = false

func setup(parent: Control, hand_card_scene: PackedScene) -> void:
	_parent = parent
	_hand_card_scene = hand_card_scene
	_build_panel()
	_long_press_timer = Timer.new()
	_long_press_timer.wait_time = LONG_PRESS_TIME
	_long_press_timer.one_shot = true
	_long_press_timer.timeout.connect(_on_long_press_timeout)
	_parent.add_child(_long_press_timer)
	# 默认无跟随目标，省一份 _process 开销。
	set_process(false)

# 让 clip 锁到 target 的矩形。备战界面把 HeroPnl 传入即可。
# 调用一次即可：之后每帧 _process 同步 global_position/size，自动跟随屏宽变化。
func attach_to_rect(target: Control) -> void:
	_follow_target = target
	if _clip == null or target == null:
		set_process(false)
		return
	# 切到 TOP_LEFT 锚点 + 手动尺寸控制，避免 anchor 与 set_global_* 互相打架。
	_clip.set_anchors_preset(Control.PRESET_TOP_LEFT, false)
	set_process(true)
	_sync_to_target()

func _process(_delta: float) -> void:
	if _follow_target != null and is_instance_valid(_follow_target):
		_sync_to_target()

func _sync_to_target() -> void:
	if _clip == null or _follow_target == null:
		return
	_clip.global_position = _follow_target.global_position
	_clip.size = _follow_target.size
	# panel 始终铺满 clip。仅在"非动画 + 关闭态"时同步 offset，否则会盖掉 tween。
	if _panel != null and not _is_open and not _animating:
		_panel.offset_left = -_clip.size.x
		_panel.offset_right = 0

# 当前面板宽。跟随模式下取 clip 实时宽，否则回落到 PANEL_WIDTH。
func _current_width() -> float:
	if _follow_target != null and _clip != null:
		return _clip.size.x
	return PANEL_WIDTH

func _build_panel() -> void:
	_clip = Control.new()
	_clip.name = "DetailPanelClip"
	_parent.add_child(_clip)
	_clip.set_anchors_preset(Control.PRESET_LEFT_WIDE, false)
	_clip.offset_left = PANEL_LEFT_INSET
	_clip.offset_right = PANEL_LEFT_INSET + PANEL_WIDTH
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
	var w: float = _current_width()
	_panel.offset_left = -w
	_panel.offset_right = 0
	_animating = true
	var tween := get_tree().create_tween()
	tween.tween_property(_panel, "offset_left", 0.0, 0.2).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(_panel, "offset_right", w, 0.2).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_callback(func(): _animating = false)

# 英雄详情：显示名字 + 血量 + 技能名/描述，复用同一弹出动画。
# 不显示费用括号；CardCenter 隐藏让文字整体上移。display_hp 由调用方传入，
# 通常为 hero.max_health（不随战斗扣减的初始值）。
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
	var w: float = _current_width()
	_panel.offset_left = -w
	_panel.offset_right = 0
	_animating = true
	var tween := get_tree().create_tween()
	tween.tween_property(_panel, "offset_left", 0.0, 0.2).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(_panel, "offset_right", w, 0.2).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_callback(func(): _animating = false)

func hide_panel() -> void:
	if not _is_open:
		return
	_is_open = false
	var w: float = _current_width()
	_animating = true
	var tween := get_tree().create_tween()
	tween.tween_property(_panel, "offset_left", -w, 0.2).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.parallel().tween_property(_panel, "offset_right", 0.0, 0.2).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.tween_callback(func():
		_animating = false
		_clip.visible = false)

func get_clip() -> Control:
	return _clip
