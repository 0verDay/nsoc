class_name LocalActionSink
extends AiActionSink

# 归属 AI 的 slot id，用于落子 + 路由墓地。
var _slot_id: String = ""
# 动画用：场景根节点（用于 add_child 创建飞牌 visual）和源节点（AI 英雄面板）。
var _root: Node = null
var _source_node: Node = null

const FLY_DURATION: float = 1.2

func setup(p_slot_id: String, p_root: Node = null, p_source_node: Node = null) -> void:
	_slot_id = p_slot_id
	_root = p_root
	_source_node = p_source_node

func apply(action: AiAction) -> bool:
	match action.kind:
		AiAction.Kind.PLAY_UNIT:
			return await _place_unit(action)
		AiAction.Kind.PLAY_SPELL:
			return await _cast_spell(action)
		AiAction.Kind.CROSS_BOARD:
			return _enqueue_cross(action)
		_:
			return true

func submit_cross_choice(slot_id: String, row: int, col: int, target_slot_id: String) -> void:
	if Engine.get_main_loop().root.has_node("/root/Game"):
		Game.turn.enqueue_cross_choice({
			"source_slot_id": slot_id, "row": row, "col": col,
			"target_slot_id": target_slot_id,
		})

# ── 内部实现 ────────────────────────────────────────────────────────────────

func _place_unit(action: AiAction) -> bool:
	if not Engine.get_main_loop().root.has_node("/root/Game") or Game.registry == null:
		return false
	var slot: BoardSlot = Game.registry.get_by_id(action.slot_id)
	if slot == null or slot.board == null:
		return false
	var cell = slot.board.get_cell(Vector2(action.row, action.col))
	if cell == null or cell.has_card:
		return false
	var card = Game.get_card(action.card_name)
	if card == null:
		return false
	await _animate_card_to_cell(action.card_name, cell)
	# is_enemy 取决于盘的阵营：敌方盘 = true，友军盘 = false
	var place_as_enemy: bool = (slot.faction == BoardSlot.FACTION_ENEMY)
	cell.set_card(action.card_name, card.attack, card.health, place_as_enemy, card.effects, "", "hand")
	cell.owner_slot_id = slot.id
	var ctx := Game.make_effect_context()
	ctx.target_cell = cell
	for eff in card.effects:
		await Effects.trigger_play(String(eff), card, ctx)
	return true

func _cast_spell(action: AiAction) -> bool:
	if not Engine.get_main_loop().root.has_node("/root/Game") or Game.registry == null:
		return false
	var card = Game.get_card(action.card_name)
	if card == null:
		return false
	var target_cell = null
	if action.row >= 0 and action.col >= 0:
		var t_slot: BoardSlot = Game.registry.get_by_id(action.slot_id)
		if t_slot != null and t_slot.board != null:
			target_cell = t_slot.board.get_cell(Vector2(action.row, action.col))
	await _animate_card_to_cell(action.card_name, target_cell)
	# 动画期间目标可能已死亡/移走；若格子已空则放弃施法，直接入墓
	if target_cell != null and not target_cell.has_card and String(card.target) != "":
		var ai_deck_early := _get_ai_deck()
		if ai_deck_early != null:
			ai_deck_early.send_to_graveyard(card)
		return true
	var ctx := Game.make_effect_context()
	ctx.target_cell = target_cell
	var caster_slot: BoardSlot = Game.registry.get_by_id(_slot_id)
	ctx.caster_is_enemy = (caster_slot != null and caster_slot.faction == BoardSlot.FACTION_ENEMY)
	var destination := "graveyard"
	for eff in card.effects:
		var dest := Effects.resolve_destination(String(eff), card, ctx)
		if dest != "":
			destination = dest
		await Effects.trigger_play(String(eff), card, ctx)
	var ai_deck := _get_ai_deck()
	if ai_deck != null:
		match destination:
			"banish":
				ai_deck.banish(card)
			_:
				ai_deck.send_to_graveyard(card)
	return true

func _enqueue_cross(action: AiAction) -> bool:
	if not Engine.get_main_loop().root.has_node("/root/Game"):
		return false
	Game.turn.enqueue_cross_choice({
		"source_slot_id": action.slot_id,
		"row": action.source_row,
		"col": action.source_col,
		"target_slot_id": action.target_slot_id,
	})
	return true

# ── 飞牌动画 ─────────────────────────────────────────────────────────────────
# 从 AI 英雄面板飞一张样式简单的牌到 target_cell；target_cell 为 null 时跳过动画。
func _animate_card_to_cell(card_name: String, target_cell) -> void:
	if _root == null or not is_instance_valid(_root):
		return
	if _source_node == null or not is_instance_valid(_source_node):
		return
	if target_cell == null or not is_instance_valid(target_cell):
		return

	const CARD_SIZE := Vector2(80, 56)

	# 用 Panel（不用 PanelContainer），显式 size 避免布局前 size=(0,0) 的问题
	var panel := Panel.new()
	panel.size = CARD_SIZE
	panel.z_index = 200
	panel.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var style := StyleBoxFlat.new()
	style.bg_color = Color("#fff5f5")
	style.border_color = Color("#fa5252")
	style.set_border_width_all(2)
	style.set_corner_radius_all(6)
	panel.add_theme_stylebox_override("panel", style)

	var lbl := Label.new()
	lbl.text = card_name
	lbl.position = Vector2(4, 4)
	lbl.size = CARD_SIZE - Vector2(8, 8)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.add_theme_font_size_override("font_size", 11)
	lbl.add_theme_color_override("font_color", Color("#333333"))
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	panel.add_child(lbl)

	_root.add_child(panel)

	# 用 CARD_SIZE（已知常量）算偏移，不依赖 panel.size
	var src_pos: Vector2 = _source_node.global_position \
		+ _source_node.size / 2.0 - CARD_SIZE / 2.0
	var dst_pos: Vector2 = target_cell.global_position \
		+ target_cell.size / 2.0 - CARD_SIZE / 2.0

	panel.global_position = src_pos
	panel.pivot_offset = CARD_SIZE / 2.0

	var tween := panel.get_tree().create_tween()
	tween.tween_property(panel, "global_position", dst_pos, FLY_DURATION) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN_OUT)
	tween.parallel().tween_property(panel, "modulate:a", 0.0, FLY_DURATION * 0.3) \
		.set_delay(FLY_DURATION * 0.7)
	await tween.finished
	if is_instance_valid(panel):
		panel.queue_free()

func _get_ai_deck() -> DeckManager:
	if not Engine.get_main_loop().root.has_node("/root/Game") or Game.registry == null:
		return null
	var slot: BoardSlot = Game.registry.get_by_id(_slot_id)
	if slot == null or slot.owner_player_id == "":
		return null
	return Game.get_deck(slot.owner_player_id)
