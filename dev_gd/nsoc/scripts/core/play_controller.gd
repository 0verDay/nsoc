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
	# PVP：非当前行动玩家不能装备
	if Game.is_pvp and not Game.pvp_is_my_turn():
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
	# PVP：广播装备出牌
	if Game.is_pvp:
		_pvp_broadcast_play_equip(full.name)

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
	# PVP：非当前行动玩家不能出牌
	if Game.is_pvp and not Game.pvp_is_my_turn():
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
	var local_team: String = ""
	if Engine.get_main_loop() != null and Engine.get_main_loop().root.has_node("/root/Game"):
		local_team = Game.team_of_player(Game.local_player_id)
	match target:
		"":
			return true
		"friendly_unit":
			return cell != null and cell.has_card and cell.is_friendly_to(local_team)
		"enemy_unit":
			return cell != null and cell.has_card and cell.is_hostile_to(local_team)
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
		await _play_spell(full_data, cell)   # ← 必須 await 等效果執行完
		hand_consumed.emit(slot_index, src)
		if Game.is_pvp:
			_pvp_broadcast_play_card(cell, data)
		return

	# 单位：先播飞入动画并落子，落子后再触发 on_play。
	# on_play 时 cell 已写入数据，"突围"等需要查询自身相邻状态的效果可正确工作。
	hand_consumed.emit(slot_index, src)

	var effs := _get_effects(full_data)
	await _animate_drop(cell, data, drop_global_pos, effs)
	# origin = "hand"：玩家手牌部署，死亡入 Game.deck 而非所在盘 slot.graveyard
	cell.set_card(data.card_name, data.attack, data.health, false, effs, "", "hand")
	_trigger_unit_play_effects(full_data, cell)
	# PVP：广播出牌给对手（本端已执行，对手收到后镜像到 enemy_main）
	if Game.is_pvp:
		_pvp_broadcast_play_card(cell, data)

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

# ── PVP 出牌同步 ─────────────────────────────────────────────────────────
# 广播：本端出牌完成后通知对手。
# 协议约定：row/col 是本端 player_main 坐标，对手映射到 enemy_main 的对称位。
# card_type: "单位" / "法术" / "装备"
func _pvp_broadcast_play_card(cell, data) -> void:
	if not has_node("/root/Net"):
		return
	var payload: Dictionary = {
		"card_name": String(data.get("card_name", "")),
		"card_type": String(data.get("type", "单位")),
		"slot_id":   String(cell.slot_id),
	}
	# 多队伍 PVP 绝对坐标；1v1 旧坐标（接收方用镜像翻转）
	if Game.is_multi_team_pvp():
		payload["abs_row"] = cell.row
		payload["abs_col"] = cell.col
	else:
		payload["row"] = cell.row
		payload["col"] = cell.col
	if String(data.get("type", "")) == "法术":
		if cell.has_card:
			payload["result_atk"]    = cell.attack
			payload["result_health"] = cell.health.duplicate()
			print("[SPELL] cast at %s(%d,%d) result_atk=%d" % [cell.slot_id, cell.row, cell.col, cell.attack])
		else:
			var spell_effs: Array = _get_effects(data.get("full_data"))
			var is_return_to_hand: bool = false
			for eff_id in spell_effs:
				if String(eff_id) in _RETURN_TO_HAND_EFFECTS:
					is_return_to_hand = true
					break
			if is_return_to_hand:
				payload["result_cleared"] = true
	# 多队伍 PVP 广播给全房间；1v1 仍点对点发给对手，避免 echo 进入队列
	if Game.is_multi_team_pvp():
		Net.send_to_room("action/play_card", Game.pvp_room_id, payload, "all")
	else:
		var opp_id: String = _pvp_opponent_id()
		if opp_id != "":
			Net.send_to("action/play_card", Game.pvp_room_id, opp_id, payload)

# "放回手牌"类法术效果白名单：格子清空后对端只 clear_card，不重跑 effect。
# 与死亡类不同（死亡类需对端自跑 effect 完成动画 + 死亡流程），
# 放回手牌类不能跑 effect 否则对端会错误操作自己的牌库 / counter。
const _RETURN_TO_HAND_EFFECTS: Array = ["ming_jin"]

# 广播装备出牌
func _pvp_broadcast_play_equip(card_name: String) -> void:
	if not has_node("/root/Net"):
		return
	if Game.is_multi_team_pvp():
		Net.send_to_room("action/play_equip", Game.pvp_room_id, {"card_name": card_name}, "all")
	else:
		var opp_id: String = _pvp_opponent_id()
		if opp_id != "":
			Net.send_to("action/play_equip", Game.pvp_room_id, opp_id, {"card_name": card_name})

# 装备激活影响对手的 effect 白名单（仅这些会改对端状态需要镜像）。
# 其他 effect（如 gain_mana_1 / discard_hand_card）只影响自家，不需广播。
const _PVP_BROADCAST_EQUIP_EFFECTS: Array = ["destroy_unit"]

# 广播装备激活：仅当装备的 effects 中含白名单内 effect 才发送。
# 由 hero_action_bar 在 inst.activate 成功后调用。
func _pvp_broadcast_activate_equip(equip_name: String, target_cell) -> void:
	if not has_node("/root/Net"):
		return
	if not Game.is_pvp:
		return
	var card = Game.get_card(equip_name)
	if not (card is CardEquipment):
		return
	# 检查 effect 白名单
	var need_broadcast: bool = false
	for eff_id in card.effects:
		if String(eff_id) in _PVP_BROADCAST_EQUIP_EFFECTS:
			need_broadcast = true
			break
	if not need_broadcast:
		return
	var payload: Dictionary = {"equip_name": equip_name}
	if target_cell != null:
		payload["slot_id"] = String(target_cell.slot_id)
		if Game.is_multi_team_pvp():
			payload["abs_row"] = int(target_cell.row)
			payload["abs_col"] = int(target_cell.col)
		else:
			payload["row"] = int(target_cell.row)
			payload["col"] = int(target_cell.col)
	if Game.is_multi_team_pvp():
		Net.send_to_room("action/activate_equip", Game.pvp_room_id, payload, "all")
	else:
		var opp_id: String = _pvp_opponent_id()
		if opp_id != "":
			Net.send_to("action/activate_equip", Game.pvp_room_id, opp_id, payload)

# 远端接收：对手激活了装备 → 在本端镜像执行 effect。
# 坐标 + slot_id 翻转规则同 handle_remote_play_card。
func handle_remote_activate_equip(payload: Dictionary) -> void:
	var equip_name: String = String(payload.get("equip_name", ""))
	if equip_name == "":
		return
	var card = Game.get_card(equip_name)
	if not (card is CardEquipment):
		push_warning("PlayController.handle_remote_activate_equip: card not found: " + equip_name)
		return

	var ctx := Game.make_effect_context()

	# 解析目标 cell（若装备 effect 需要目标）
	if payload.has("row") and payload.has("col"):
		var sender_slot: String = String(payload.get("slot_id", "player_main"))
		var t_slot_id: String
		var t_row: int
		var t_col: int
		if payload.has("abs_row"):
			# 1v3 绝对坐标
			t_slot_id = sender_slot
			t_row = int(payload.get("abs_row", 0))
			t_col = int(payload.get("abs_col", 0))
		else:
			# 1v1 镜像坐标
			var row_a: int = int(payload.get("row", 0))
			var col_a: int = int(payload.get("col", 0))
			t_row = (BoardModel.ROWS - 1) - row_a
			t_col = (BoardModel.COLS - 1) - col_a
			if sender_slot == "player_main":
				t_slot_id = "enemy_main"
			elif sender_slot == "enemy_main":
				t_slot_id = "player_main"
			else:
				t_slot_id = "enemy_main"
		var t_slot: BoardSlot = Game.registry.get_by_id(t_slot_id) if Game.registry != null else null
		if t_slot != null and t_slot.board != null:
			var cell = t_slot.board.get_cell(Vector2(t_row, t_col))
			if cell != null:
				ctx.target_cell = cell

	# 镜像执行 effect（与本端 inst.activate 走同一路径，保证动画/死亡流程一致）。
	# 不扣本端耐久（对手装备实例不在本端 Equipments 里）。
	for eff_id in card.effects:
		if not (String(eff_id) in _PVP_BROADCAST_EQUIP_EFFECTS):
			continue   # 白名单外的 effect 跳过（如 gain_mana_1 不应在对端执行）
		await Effects.trigger_play(String(eff_id), card, ctx)

static func _pvp_opponent_id() -> String:
	if Engine.get_main_loop() == null or not Engine.get_main_loop().root.has_node("/root/Game"):
		return ""
	for id in Game.pvp_action_order:
		if id != Game.local_player_id:
			return id
	return ""

# 远端接收：对手打出了一张牌，在本端镜像执行。
#
# 1v1 旧路径（slot_id = "player_main" / "enemy_main"，坐标镜像）：
#   row_b = (ROWS-1) - row_a,  col_b = (COLS-1) - col_a
#   player_main → enemy_main；enemy_main → player_main
#
# 多队伍 PVP 新路径（slot_id = "slot_<uuid>"，abs_row / abs_col = 绝对坐标，无需镜像）：
#   payload 中带 "abs_row" / "abs_col" 字段时走新路径；否则回退旧逻辑。
#   1v3 / 3v3 均走此路径。
func handle_remote_play_card(payload: Dictionary, caster_pid: String = "") -> void:
	var card_name: String = String(payload.get("card_name", ""))
	var card_type: String = String(payload.get("card_type", "单位"))
	var sender_slot: String = String(payload.get("slot_id", "player_main"))
	var card = Game.get_card(card_name)
	if card == null:
		push_warning("PlayController.handle_remote_play_card: card not found: " + card_name)
		return

	var target_slot_id: String
	var target_row: int
	var target_col: int

	if payload.has("abs_row"):
		# ── 1v3 绝对坐标路径 ──────────────────────────────────────────
		# sender_slot_id 即为目标 slot_id（接收端按 slot_id 直查）
		target_slot_id = sender_slot
		target_row = int(payload.get("abs_row", 0))
		target_col = int(payload.get("abs_col", 0))
	else:
		# ── 1v1 镜像坐标路径（向后兼容）─────────────────────────────
		var row_a: int = int(payload.get("row", 0))
		var col_a: int = int(payload.get("col", 0))
		target_row = (BoardModel.ROWS - 1) - row_a
		target_col = (BoardModel.COLS - 1) - col_a
		if sender_slot == "player_main":
			target_slot_id = "enemy_main"
		elif sender_slot == "enemy_main":
			target_slot_id = "player_main"
		else:
			target_slot_id = "enemy_main"

	var t_slot: BoardSlot = Game.registry.get_by_id(target_slot_id) if Game.registry != null else null
	if t_slot == null or t_slot.board == null:
		return
	var cell = t_slot.board.get_cell(Vector2(target_row, target_col))
	if cell == null:
		return
	# 确定放置时的 is_enemy 标志（PVE/1v1 兼容）：视觉已由 _is_visual_enemy 接管，
	# 此处仍需传 faction=1 给 spawner / effect 用；1v3 中 team_id 会在 set_card 里从 slot 取。
	var place_as_enemy: bool
	# 多队伍 PVP 中按 team_id 判断是否为"本端敌方"；1v1 按 slot 名判断
	if Game.is_multi_team_pvp():
		var local_team: String = Game.team_of_player(Game.local_player_id)
		place_as_enemy = t_slot.team_id != "" and t_slot.team_id != local_team
	else:
		place_as_enemy = (target_slot_id == "enemy_main")

	match card_type:
		"单位":
			var effs: Array = _get_effects(card)
			cell.set_card(card_name, card.attack, card.health, place_as_enemy, effs, "", "hand")
			cell.owner_slot_id = t_slot.id
			_trigger_unit_play_effects(card, cell)
		"法术":
			print("[SPELL] recv at %s(%d,%d) has_card=%s result_atk=%s" % [
				target_slot_id, target_row, target_col, str(cell.has_card), str(payload.get("result_atk", "N/A"))])
			# 法术 destination 由 effect.resolve_destination 决定（默认 graveyard，
			# 个别 effect 如 jue_di / exhaust 会覆盖为 banish）。在跑 effect 前先解析，
			# 避免 unit 已死亡分支后再访问 cell 失败。
			var spell_destination: String = "graveyard"
			for eff in _get_effects(card):
				var ctx_for_dest := Game.make_effect_context()
				ctx_for_dest.target_cell = cell
				var dest := Effects.resolve_destination(eff, card, ctx_for_dest)
				if dest != "":
					spell_destination = dest
			if payload.has("result_atk") and cell.has_card:
				# 法术执行后单位仍存活：直接写终态数值（绕过 is_enemy 等 effect 内部检查）
				cell.attack = int(payload.get("result_atk", cell.attack))
				var rh = payload.get("result_health", {})
				if typeof(rh) == TYPE_DICTIONARY and not rh.is_empty():
					# JSON 往返后数值变浮点，显式转 int 避免显示 "2.0"
					var clean: Dictionary = {}
					for k in rh.keys():
						clean[String(k)] = int(rh[k])
					cell.health = clean
				if cell.has_method("_update_atk_label"):
					cell._update_atk_label()
				if cell.has_method("_update_hp_labels"):
					cell._update_hp_labels()
			elif payload.get("result_cleared", false):
				# 法术让单位"放回手牌"（ming_jin 等）：只清格子，不跑 effect。
				# 不能重跑 effect，否则对端会错误操作自己的牌库 / counter。
				if cell.has_card:
					cell.clear_card()
			else:
				# 法术执行后格子被清空（单位死亡，如 weaken）：对端自跑 effect 完成死亡动画+流程
				var ctx := Game.make_effect_context()
				ctx.target_cell = cell
				for eff in _get_effects(card):
					await Effects.trigger_play(eff, card, ctx)
			# 跨端入墓：法术卡同步到 caster 的代理 deck，让远端 viewer 的合并墓地面板可见。
			# 与 _play_spell 末尾的本地落库语义一致（caster 端走 Game.deck，远端走 Game.decks[caster]）。
			var caster_deck: DeckManager = null
			if caster_pid != "":
				caster_deck = Game.get_deck(caster_pid)
			if caster_deck == null:
				caster_deck = Game.deck
			if caster_deck != null:
				match spell_destination:
					"banish": caster_deck.banish(card)
					_: caster_deck.send_to_graveyard(card)
		"装备":
			# 对手装备由对手自己的 Equipments 管理，本端不添加。
			# Step 5-D：若需展示对手装备 UI，在此补充视觉逻辑。
			pass

# 远端接收：对手结束回合后，本端跑 ENEMY phase（锁步模型）。
# 对手单位从本端视角是 enemy_main（faction=1），所以跑 ENEMY phase。
# 1v1 专用；1v3 由 test_main._on_remote_end_turn 直接调 run_pvp_phase_for_slot。
func handle_remote_end_turn() -> void:
	await Game.turn.run_pvp_phase(TurnSystem.ENEMY)
	var opp_mana: ManaSystem = Game.get_mana(Game.pvp_active_player_id())
	if opp_mana != null:
		opp_mana.start_new_turn()
	HeroAbilities.reset_turn_usage()
	Equipments.reset_turn_usage()

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

	# 提前捕获死亡快照（cell 数据在死亡处理后可能被清空）
	var snap := {
		"card_name":    cell.card_name,
		"is_enemy":     cell.is_enemy,
		"owner_slot_id": cell.owner_slot_id,
		"slot_id":      cell.slot_id,
	}

	var cdata = Game.get_card(cell.card_name)
	if cdata == null:
		_notify_events_unit_died(snap)
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
		_notify_events_unit_died(snap)
		return
	if cell.origin == "hand":
		# "hand" 来源：入单位归属玩家的 deck.graveyard
		# 按 owner_slot_id 找到归属盘 → 取其 owner_player_id 反查 deck
		var owner_slot: BoardSlot = _resolve_owner_slot(cell)
		if owner_slot != null and owner_slot.owner_player_id != "":
			var d: DeckManager = Game.decks.get(owner_slot.owner_player_id)
			if d != null:
				d.send_to_graveyard(cdata)
				_notify_events_unit_died(snap)
				return
		# 兜底：无归属或 PVE → 本地玩家 deck
		Game.deck.send_to_graveyard(cdata)
	else:
		var slot: BoardSlot = _resolve_owner_slot(cell)
		if slot != null:
			slot.send_to_graveyard(cdata)
		# slot==null：原属盘已销毁，单位连同资源一起丢弃
	_notify_events_unit_died(snap)

# 通知 Events 系统单位已死亡（Events 存在时才调用，否则静默）。
func _notify_events_unit_died(snap: Dictionary) -> void:
	if has_node("/root/Events"):
		Events.notify_unit_died(snap)

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
