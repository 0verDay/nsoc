class_name PlayController
extends Node

# 集中处理 cell.card_dropped 事件。
# 取代原 cell.gd:_drop_data 中扣 mana / 销毁手牌 / 触发出牌效果 / 动画飞入 / 入墓除外 等逻辑。

signal hand_consumed                       # 通知 HandView 补手牌

var _root: Control                          # 用于挂载飞入动画 visual
var _cell_scene: PackedScene

func setup(root: Control, cell_scene: PackedScene) -> void:
	_root = root
	_cell_scene = cell_scene

func handle_drop(cell, data) -> void:
	if not Game.mana.can_spend(data.cost):
		return
	Game.mana.spend(data.cost)

	var drop_global_pos: Vector2 = cell.global_position + cell.size / 2.0
	# 销毁拖拽源（手牌）
	var src = data.get("source_card")
	if src and is_instance_valid(src):
		if src.get_parent():
			src.get_parent().remove_child(src)
		src.queue_free()

	var full_data = data.get("full_data")

	if data.type == "法术":
		_play_spell(full_data, cell)
		hand_consumed.emit()
		return

	# 单位：先触发 on_play，再播飞入动画并落子
	_trigger_unit_play_effects(full_data)
	hand_consumed.emit()

	var effs := _extract_effects(full_data)
	await _animate_drop(cell, data, drop_global_pos, effs)
	cell.set_card(data.card_name, data.attack, data.health, false, effs)

func _animate_drop(cell, data, drop_global_pos: Vector2, effs: Array) -> void:
	var visual = _cell_scene.instantiate()
	_root.add_child(visual)
	visual.global_position = drop_global_pos - (visual.custom_minimum_size / 2.0)
	visual.z_index = 100
	visual.pivot_offset = visual.custom_minimum_size / 2.0
	visual.set_card(data.card_name, data.attack, data.health, false, effs)

	var tween := get_tree().create_tween()
	var mid_pos: Vector2 = (visual.global_position + cell.global_position) / 2.0
	var offset := Vector2(0, -70)
	tween.tween_property(visual, "global_position", mid_pos + offset, 0.15).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(visual, "scale", Vector2(1.08, 1.08), 0.15).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(visual, "global_position", cell.global_position, 0.15).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.parallel().tween_property(visual, "scale", Vector2(1.0, 1.0), 0.15).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	await tween.finished
	if is_instance_valid(visual):
		visual.queue_free()

func _play_spell(spell_data, _target_cell) -> void:
	if spell_data == null:
		return
	var ctx := Game.make_effect_context()
	var destination := "graveyard"
	for eff in _extract_effects(spell_data):
		# 询问该效果是否决定卡的去向
		var dest := Effects.resolve_destination(eff, spell_data, ctx)
		if dest != "":
			destination = dest
		Effects.trigger_play(eff, spell_data, ctx)

	match destination:
		"banish": Game.deck.banish(spell_data)
		"graveyard": Game.deck.send_to_graveyard(spell_data)
		_: Game.deck.send_to_graveyard(spell_data)

func _trigger_unit_play_effects(unit_data) -> void:
	if unit_data == null:
		return
	var ctx := Game.make_effect_context()
	for eff in _extract_effects(unit_data):
		Effects.trigger_play(eff, unit_data, ctx)

func handle_unit_death(cell) -> void:
	# 玩家阵亡才有"卡牌去向"概念；敌方阵亡不入任何牌堆。
	if cell.is_enemy:
		return
	var cdata = Game.get_card(cell.card_name)
	if cdata == null:
		return
	var ctx := Game.make_effect_context()
	var handled := false
	for eff in _extract_effects(cdata):
		if Effects.trigger_death(eff, cdata, ctx):
			handled = true
	if not handled:
		Game.deck.send_to_graveyard(cdata)

static func _extract_effects(card_data) -> Array:
	if card_data == null:
		return []
	if typeof(card_data) == TYPE_DICTIONARY:
		var v = card_data.get("effects", [])
		return v if v != null else []
	if "effects" in card_data and card_data.effects != null:
		return card_data.effects
	return []
