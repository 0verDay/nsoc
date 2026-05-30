extends RefCounted

# cast_spell action：由脚本化事件系统驱动，向目标施放一张法术卡的所有效果。
# 与玩家出牌路径不同：目标由 target_strategy 自动解析，无需玩家点选。
#
# params 字段：
#   "spell"           : String  卡牌名（必须在 all_cards.json 中）
#   "target_strategy" : String  见 TargetResolver.resolve_cell

func id() -> String:
	return "cast_spell"

func run(params: Dictionary, _ctx: Dictionary) -> void:
	if not _has_game():
		return

	var spell_name: String      = String(params.get("spell", ""))
	var target_strategy: String = String(params.get("target_strategy", ""))

	if spell_name == "":
		push_warning("cast_spell: missing 'spell' param")
		return

	var card_data = Game.get_card(spell_name)
	if card_data == null:
		push_warning("cast_spell: spell not found: " + spell_name)
		return

	var target_cell = TargetResolver.resolve_cell(target_strategy, params)
	if target_cell == null:
		return  # 无目标，跳过

	var ctx = Game.make_effect_context_with_selectors()
	ctx.target_cell = target_cell

	for eff in card_data.effects:
		if Game.combat != null and Game.combat.aborted:
			return
		await Effects.trigger_play(eff, card_data, ctx)

static func _has_game() -> bool:
	var loop = Engine.get_main_loop()
	return loop != null and loop.root != null and loop.root.has_node("/root/Game")
