extends HeroAbility

# "义勇军" —— 长坂坡·刘备 专属技能。
# 消耗 2 费用：
#   1. 消灭"我方半场"（player_main 主盘）所有敌方单位（走标准死亡流程，触发 on_death）
#   2. 在所有空格召唤"乡勇"，并使其获得"灰烬"（死后除外）
#
# 召唤的乡勇：
#   - faction = PLAYER
#   - owner_slot_id = player_main
#   - origin = "ability"（非牌库来源；死后默认入 player_main 棋盘的墓地/除外）
#   - effects = 原型 effects + "ash"

const TARGET_BOARD_ID: String = "player_main"
const SUMMON_CARD_NAME: String = "乡勇"

func id() -> String:
	return "yi_yong_jun"

func display_name() -> String:
	return "义勇军"

func description() -> String:
	return "消耗 2 费用，消灭我方半场的所有敌人，随后在我方半场所有空格召唤「乡勇」，并使其获得「灰烬」（灰烬：死亡后从游戏中除外）。"

func cost() -> int:
	return 2

func once_per_turn() -> bool:
	return true

func on_activate(ctx) -> void:
	if ctx == null:
		return
	var slot: BoardSlot = Game.main_player_slot()
	if slot == null or slot.board == null:
		return
	var board: BoardModel = slot.board

	# ── 1. 收集"我方半场"所有敌方单位 ────────────────────────────
	var local_team: String = ctx.game.team_of_player(ctx.game.local_player_id)
	var enemies: Array = []
	for cell in board.grid_cells.values():
		if not is_instance_valid(cell):
			continue
		if cell.has_card and cell.is_hostile_to(local_team):
			enemies.append(cell)

	# ── 2. 消灭流程（仿 destroy_unit）──────────────────────────
	if enemies.size() > 0:
		for c in enemies:
			if is_instance_valid(c):
				c.play_damage_effect()
		await ctx.game.get_tree().create_timer(CombatSystem.DEATH_DELAY).timeout
		if Game.combat != null and Game.combat.aborted:
			return

		for c in enemies:
			if not is_instance_valid(c) or not c.has_card:
				continue
			c.play_death_effect()
		await ctx.game.get_tree().create_timer(CombatSystem.DEATH_DELAY).timeout
		if Game.combat != null and Game.combat.aborted:
			return

		for c in enemies:
			if not is_instance_valid(c) or not c.has_card:
				continue
			if Game.play != null and Game.play.has_method("handle_unit_death"):
				Game.play.handle_unit_death(c)
			if is_instance_valid(c) and c.has_card:
				c.clear_card()

	# ── 3. 在所有空格召唤"乡勇" + ash ─────────────────────────
	var villager = Game.get_card(SUMMON_CARD_NAME)
	if villager == null:
		push_warning("yi_yong_jun: 卡牌原型未找到: " + SUMMON_CARD_NAME)
		return
	var effs: Array = (villager.effects as Array).duplicate()
	if not effs.has("ash"):
		effs.append("ash")

	for cell in board.grid_cells.values():
		if not is_instance_valid(cell):
			continue
		# 跳过已有牌的格子（phantom 不算 has_card，会被覆盖）
		if cell.has_card:
			continue
		# faction = false（PLAYER 阵营），owner_slot_id = player_main，origin = "ability"
		cell.set_card(villager.name, villager.attack, villager.health,
			false, effs, slot.id, "ability")
