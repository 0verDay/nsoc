extends RefCounted

# spawn_unit action：在指定棋盘的指定位置（或随机空格）召唤一个单位。
#
# params 字段：
#   "name"     : String  卡牌名（必须在 all_cards.json 中）
#   "board"    : String  目标盘 id（如 "enemy_main"）
#   "faction"  : int     0=玩家方，1=敌方（默认 1）
#   "strategy" : String  "any_empty"（随机空格）/ "fixed"（指定坐标，需 row/col）
#   "row","col": int     strategy=="fixed" 时生效

func id() -> String:
	return "spawn_unit"

func run(params: Dictionary, _ctx: Dictionary) -> void:
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
		_:
			target_cell = TargetResolver.resolve_cell(strategy, params)

	if target_cell == null:
		push_warning("spawn_unit: no valid cell found (board=%s strategy=%s)" % [board_id, strategy])
		return
	if target_cell.has_card:
		return  # 目标格已被占用，跳过

	var is_enemy: bool = faction == 1
	# origin = "spawner"：死亡时入该盘墓地而非玩家牌库
	target_cell.set_card(
		card_data.name, card_data.attack, card_data.health,
		is_enemy, card_data.effects,
		"",       # owner_slot_id 由 set_card 或盘注入（空串触发盘内默认赋值）
		"spawner"
	)
	# 补填 owner_slot_id（set_card 不自动写，需手动从 cell.slot_id 继承）
	if target_cell.owner_slot_id == "":
		target_cell.owner_slot_id = target_cell.slot_id

static func _has_game() -> bool:
	var loop = Engine.get_main_loop()
	return loop != null and loop.root != null and loop.root.has_node("/root/Game")
