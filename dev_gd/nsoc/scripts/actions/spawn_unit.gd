extends RefCounted

# spawn_unit action：在指定棋盘的指定位置（或随机空格）召唤一个单位。
#
# params 字段：
#   "name"     : String  卡牌名（必须在 all_cards.json 中）
#   "board"    : String  目标盘 id（如 "enemy_main"）
#   "faction"  : int     0=玩家方，1=敌方（默认 1）
#   "strategy" : String
#     "any_empty"   随机空格
#     "fixed"       指定坐标（params.row / params.col）
#     "snap_origin" 用上游事件 snap 中的死亡盘 + 死亡格坐标
#                   （盘 = snap.slot_id 即死亡时所在盘，不读 action.board；
#                   保证跨盘死亡后仍生成在视觉死亡位置）
#   "row","col": int     strategy=="fixed" 时生效

func id() -> String:
	return "spawn_unit"

func run(params: Dictionary, ctx: Dictionary) -> void:
	if not _has_game():
		return

	var card_name: String = String(params.get("name", ""))
	var board_id: String  = String(params.get("board", ""))
	var faction: int      = int(params.get("faction", 1))
	var strategy: String  = String(params.get("strategy", "fixed"))

	if card_name == "" or board_id == "":
		push_warning("spawn_unit: missing 'name' or 'board' param")
		return

	var card_data = Game.get_card(card_name)
	if card_data == null:
		push_warning("spawn_unit: card not found: " + card_name)
		return

	# 解析目标格
	var target_cell = null
	match strategy:
		"any_empty":
			target_cell = TargetResolver.resolve_empty_cell(board_id)
		"fixed":
			target_cell = TargetResolver.resolve_cell("fixed_cell", params)
		"snap_origin":
			# 用上游事件 snap 中的死亡盘 + 死亡格定位。
			# 关键：用 snap.slot_id（死亡瞬间所在盘）而非 action.board，
			# 这样跨盘死亡后疑兵生成在视觉死亡位置（如 player_main 上死的单位
			# 召唤出的疑兵也站在 player_main 同格），与"原位"语义一致。
			var snap: Dictionary = ctx.get("snap", {})
			if snap.is_empty():
				push_warning("spawn_unit[snap_origin]: ctx.snap missing")
				return
			var death_slot: String = String(snap.get("slot_id", ""))
			if death_slot == "":
				push_warning("spawn_unit[snap_origin]: snap.slot_id empty")
				return
			var origin_params := {
				"board": death_slot,
				"row":   int(snap.get("row", -1)),
				"col":   int(snap.get("col", -1)),
			}
			target_cell = TargetResolver.resolve_cell("fixed_cell", origin_params)
		_:
			target_cell = TargetResolver.resolve_cell(strategy, params)

	if target_cell == null:
		push_warning("spawn_unit: no valid cell found (board=%s strategy=%s)" % [board_id, strategy])
		return
	if target_cell.has_card:
		return  # 目标格已被占用，跳过

	var is_enemy: bool = faction == 1
	# owner_slot_id：用 action.board 显式指定，保证跨盘 spawn（snap_origin 落在
	# 对方盘）时 ownership 仍归属"召唤者所在盘"，死亡时 graveyard 路由正确。
	# 空 board_id 兜底 = target_cell.slot_id（旧行为）。
	var owner_id: String = board_id if board_id != "" else target_cell.slot_id
	# origin = "spawner"：死亡时入该盘墓地而非玩家牌库
	target_cell.set_card(
		card_data.name, card_data.attack, card_data.health,
		is_enemy, card_data.effects,
		owner_id,
		"spawner"
	)
	# 兜底：set_card 收到空 owner 仍允许盘内默认赋值，对齐到目标格 slot_id。
	if target_cell.owner_slot_id == "":
		target_cell.owner_slot_id = target_cell.slot_id

static func _has_game() -> bool:
	var loop = Engine.get_main_loop()
	return loop != null and loop.root != null and loop.root.has_node("/root/Game")
