class_name PlayController
extends Node

# 集中处理 cell.card_dropped 事件。
# 取代原 cell.gd:_drop_data 中扣 mana / 销毁手牌 / 触发出牌效果 / 动画飞入 / 入墓除外 等逻辑。
# 同时是出牌规则的唯一来源（can_play_at），cell 仅询问不裁决。

signal hand_consumed(slot_index: int, source_card)            # 通知 HandView 在指定槽位补手牌；source_card 为占位旧卡（HandView 负责 free）

var _root: Control                          # 用于挂载飞入动画 visual
var _cell_scene: PackedScene
# 供 discard_hand_card effect 访问，弃置动画由 HandView 执行。
var hand_view: HandView = null

func setup(root: Control, cell_scene: PackedScene) -> void:
	_root = root
	_cell_scene = cell_scene

# ============================================================================
# 装备：拖到玩家英雄面板触发。
# ============================================================================

# 是否允许把装备拖到英雄面板上释放。data 同 hand_card._get_drag_data 的 drag_dict。
func can_equip(data) -> bool:
	if typeof(data) != TYPE_DICTIONARY or not data.has("type"):
		return false
	if String(data.type) != "装备":
		return false
	if Game.turn != null and Game.turn.is_running:
		return false
	if not Game.mana.can_spend(int(data.cost)):
		return false
	return true

# 处理装备落地：扣费 → equip → 通知 HandView 补手牌。
# 装备本体卡不入墓不入除外，已转化为英雄身上的运行时实例。
func handle_equip(data) -> void:
	if not can_equip(data):
		return
	var full = data.get("full_data")
	if not (full is CardEquipment):
		return
	if not Game.mana.spend(int(data.cost)):
		return
	var src = data.get("source_card")
	var slot_index: int = -1
	if src and is_instance_valid(src):
		slot_index = src.get_index()
		src.modulate.a = 0.0
		src.mouse_filter = Control.MOUSE_FILTER_IGNORE
		src.set_meta("consumed", true)
	Equipments.equip(full)
	hand_consumed.emit(slot_index, src)

# 是否允许在 cell 上释放该卡。供 cell._can_drop_data 调用。
# 多盘语义：cell 必须属于一个 PLAYER 阵营盘且 slot.allow_player_deploy == true。
# data 形态约定见 hand_card._get_drag_data 构造的 drag_dict。
func can_play_at(cell, data) -> bool:
	if typeof(data) != TYPE_DICTIONARY or not data.has("type"):
		return false
	# 装备牌只能拖到玩家英雄面板（handle_equip），不允许放到棋盘格
	if String(data.get("type", "")) == "装备":
		return false
	if Game.turn.is_running:
		return false
	if not Game.mana.can_spend(data.cost):
		return false
	if data.type == "法术":
		var full = data.get("full_data")
		var target := ""
		if full is CardSpell:
			target = full.target
		return _spell_target_valid(cell, target)
	# 单位
	if cell.has_card:
		return false
	# 反查 cell 所属 slot
	var slot: BoardSlot = _resolve_slot(cell)
	if slot == null:
		return false
	if not slot.allow_player_deploy:
		return false
	return true

static func _resolve_slot(cell) -> BoardSlot:
	if cell == null:
		return null
	if Engine.get_main_loop() == null:
		return null
	var root: Node = Engine.get_main_loop().root
	if not root.has_node("/root/Game"):
		return null
	if cell.slot_id != "":
		return Game.registry.get_by_id(cell.slot_id)
	return null

# 法术目标过滤。
static func _spell_target_valid(cell, target: String) -> bool:
	match target:
		"":
			return true
		"friendly_unit":
			return cell != null and cell.has_card and not cell.is_enemy
		"enemy_unit":
			return cell != null and cell.has_card and cell.is_enemy
		"any_unit":
			return cell != null and cell.has_card
	return true

func handle_drop(cell, data) -> void:
	# 落地最后一次校验，避免拖拽期间状态变化
	if not can_play_at(cell, data):
		return
	Game.mana.spend(data.cost)

	var drop_global_pos: Vector2 = cell.global_position + cell.size / 2.0
	# 拖拽源：先记录位置 + 隐藏（保留 Container 占位），由 HandView 在新卡到位后 free
	var src = data.get("source_card")
	var slot_index: int = -1
	if src and is_instance_valid(src):
		slot_index = src.get_index()
		src.modulate.a = 0.0
		src.mouse_filter = Control.MOUSE_FILTER_IGNORE
		# 标记为已消耗，避免 HandCard._notification(DRAG_END) 把 modulate.a 改回 1
		src.set_meta("consumed", true)

	var full_data = data.get("full_data")

	if data.type == "法术":
		_play_spell(full_data, cell)
		hand_consumed.emit(slot_index, src)
		return

	# 单位：先播飞入动画并落子，落子后再触发 on_play。
	# on_play 时 cell 已写入数据，"突围"等需要查询自身相邻状态的效果可正确工作。
	hand_consumed.emit(slot_index, src)

	var effs := _get_effects(full_data)
	await _animate_drop(cell, data, drop_global_pos, effs)
	# origin = "hand"：玩家手牌部署，死亡入 Game.deck 而非所在盘 slot.graveyard
	cell.set_card(data.card_name, data.attack, data.health, false, effs, "", "hand")
	_trigger_unit_play_effects(full_data, cell)

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

func _play_spell(spell_data, target_cell) -> void:
	if spell_data == null:
		return
	var ctx := Game.make_effect_context()
	ctx.target_cell = target_cell
	var destination := "graveyard"
	for eff in _get_effects(spell_data):
		var dest := Effects.resolve_destination(eff, spell_data, ctx)
		if dest != "":
			destination = dest
		await Effects.trigger_play(eff, spell_data, ctx)

	match destination:
		"banish": Game.deck.banish(spell_data)
		_: Game.deck.send_to_graveyard(spell_data)

func _trigger_unit_play_effects(unit_data, target_cell = null) -> void:
	if unit_data == null:
		return
	var ctx := Game.make_effect_context()
	ctx.target_cell = target_cell
	for eff in _get_effects(unit_data):
		await Effects.trigger_play(eff, unit_data, ctx)

func handle_unit_death(cell) -> void:
	# 死亡去向按 cell.origin 路由：
	#   "hand"    = 玩家手牌部署 → Game.deck.graveyard（不论部署到主盘还是 ally 盘）
	#   "spawner" / "initial" / 其他 = 入"原属盘"slot.graveyard
	# 跨盘冲锋后 cell.slot_id 会变，但 owner_slot_id / origin 不变，保证定向准确。
	# 原属盘已销毁（registry 找不到）则静默丢弃，与缩盘语义一致。
	var cdata = Game.get_card(cell.card_name)
	if cdata == null:
		return
	var ctx := Game.make_effect_context()
	ctx.dying_is_enemy = cell.is_enemy
	# 把 cell 所属 slot 也注入 ctx，effect.trigger_death 可按需读取
	ctx.target_cell = cell
	var handled := false
	for eff in _get_effects(cdata):
		if Effects.trigger_death(eff, cdata, ctx):
			handled = true
	if handled:
		return
	if cell.origin == "hand":
		Game.deck.send_to_graveyard(cdata)
	else:
		var slot: BoardSlot = _resolve_owner_slot(cell)
		if slot != null:
			slot.send_to_graveyard(cdata)
		# slot==null：原属盘已销毁，单位连同资源一起丢弃

# 取单位"原属盘"。优先用 cell.owner_slot_id，未注入时回退到 cell.slot_id（旧逻辑兜底）。
static func _resolve_owner_slot(cell) -> BoardSlot:
	if cell == null:
		return null
	if Engine.get_main_loop() == null:
		return null
	var root: Node = Engine.get_main_loop().root
	if not root.has_node("/root/Game"):
		return null
	var owner_id: String = cell.owner_slot_id if cell.owner_slot_id != "" else cell.slot_id
	if owner_id == "":
		return null
	return Game.registry.get_by_id(owner_id)

# 攻击者完成一次击杀后调用。victim_cells 已 clear_card。
# 仅在 attacker 仍存活时触发其 on_kill 效果（如"冲阵"）。
func handle_kills(attacker_cell, victim_cells: Array) -> void:
	if attacker_cell == null or not attacker_cell.has_card:
		return
	if victim_cells.is_empty():
		return
	var cdata = Game.get_card(attacker_cell.card_name)
	if cdata == null:
		return
	var ctx := Game.make_effect_context()
	ctx.target_cell = attacker_cell
	for eff in _get_effects(cdata):
		await Effects.trigger_kill(eff, attacker_cell, victim_cells, ctx)

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
