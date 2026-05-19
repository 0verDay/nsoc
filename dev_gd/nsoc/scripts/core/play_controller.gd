class_name PlayController
extends Node

# 集中处理 cell.card_dropped 事件。
# 取代原 cell.gd:_drop_data 中扣 mana / 销毁手牌 / 触发出牌效果 / 动画飞入 / 入墓除外 等逻辑。
# 同时是出牌规则的唯一来源（can_play_at），cell 仅询问不裁决。

signal hand_consumed                       # 通知 HandView 补手牌

# 业务规则：单位最大可下行（row 索引）。row <= PLAYER_DEPLOY_MIN_ROW 视为敌方半场。
const PLAYER_DEPLOY_MIN_ROW: int = 2

var _root: Control                          # 用于挂载飞入动画 visual
var _cell_scene: PackedScene

func setup(root: Control, cell_scene: PackedScene) -> void:
	_root = root
	_cell_scene = cell_scene

# 是否允许在 cell 上释放该卡。供 cell._can_drop_data 调用。
# data 形态约定见 hand_card._get_drag_data 构造的 drag_dict。
func can_play_at(cell, data) -> bool:
	if typeof(data) != TYPE_DICTIONARY or not data.has("type"):
		return false
	if Game.turn.is_running:
		return false
	if not Game.mana.can_spend(data.cost):
		return false
	if data.type == "法术":
		return true
	# 单位
	if cell.has_card:
		return false
	if cell.row <= PLAYER_DEPLOY_MIN_ROW:
		return false
	return true

func handle_drop(cell, data) -> void:
	# 落地最后一次校验，避免拖拽期间状态变化
	if not can_play_at(cell, data):
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

	var effs := _get_effects(full_data)
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
	for eff in _get_effects(spell_data):
		var dest := Effects.resolve_destination(eff, spell_data, ctx)
		if dest != "":
			destination = dest
		Effects.trigger_play(eff, spell_data, ctx)

	match destination:
		"banish": Game.deck.banish(spell_data)
		_: Game.deck.send_to_graveyard(spell_data)

func _trigger_unit_play_effects(unit_data) -> void:
	if unit_data == null:
		return
	var ctx := Game.make_effect_context()
	for eff in _get_effects(unit_data):
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
	for eff in _get_effects(cdata):
		if Effects.trigger_death(eff, cdata, ctx):
			handled = true
	if not handled:
		Game.deck.send_to_graveyard(cdata)

# DataLoader 已统一输出 CardBase 对象。此函数只剩对 CardBase 的读取。
static func _get_effects(card_data) -> Array:
	if card_data == null:
		return []
	if card_data is CardBase:
		return card_data.effects
	# 兜底：若仍是字典则按 effects 字段读
	if typeof(card_data) == TYPE_DICTIONARY:
		var v = card_data.get("effects", [])
		return v if v != null else []
	return []
