class_name SpellCasterSystem
extends Node

# 敌方（或任意盘）自动法术施放系统。挂在 BoardSlot 上，与 SpawnerSystem 同级。
#
# setup(configs)  —— 解析 JSON 配置（level_data.boards.<id>.spell_casters）
# advance()       —— 推进一轮施法（每回合敌方阶段开始时由 TurnSystem 调用）
#
# JSON 配置格式：
#   {
#     "spell": "放箭",                     卡牌名（从 Game.card_db 查效果）
#     "interval": 1,                       每 N 回合施放一次
#     "target_strategy": "frontmost_player_unit"  目标策略（见 TargetResolver）
#   }

var _casters: Array = []  # [{spell_name, interval, target_strategy, timer}]

func setup(configs: Array) -> void:
	_casters.clear()
	for cfg in configs:
		if typeof(cfg) != TYPE_DICTIONARY:
			continue
		_casters.append({
			"spell_name":      String(cfg.get("spell", "")),
			"interval":        int(cfg.get("interval", 1)),
			"target_strategy": String(cfg.get("target_strategy", "")),
			"timer":           0,
		})

# 推进一轮施法。含动画 await，调用方须 await。
func advance() -> void:
	for caster in _casters:
		if not _can_continue():
			return
		caster["timer"] += 1
		if caster["timer"] < caster["interval"]:
			continue
		caster["timer"] = 0
		await _cast(caster)

# ── 私有 ──────────────────────────────────────────────────────────────────

func _cast(caster: Dictionary) -> void:
	if not _can_continue():
		return

	var spell_name: String      = caster["spell_name"]
	var target_strategy: String = caster["target_strategy"]

	if not has_node("/root/Game"):
		return

	# 从 card_db 取卡牌原型（all_cards.json 已全量装入）
	var card_data = Game.get_card(spell_name)
	if card_data == null:
		push_warning("SpellCasterSystem: spell not found in card_db: " + spell_name)
		return

	# 解析目标格
	var target_cell = TargetResolver.resolve_cell(target_strategy)
	if target_cell == null:
		return  # 无有效目标，本轮跳过

	# 视觉反馈：目标格闪红
	target_cell.play_damage_effect()
	await get_tree().create_timer(0.3).timeout

	if not _can_continue():
		return
	if not is_instance_valid(target_cell) or not target_cell.has_card:
		return

	# 构建 EffectContext 并指定目标，依次触发卡牌所有效果
	var ctx = Game.make_effect_context_with_selectors()
	ctx.target_cell = target_cell

	for eff in card_data.effects:
		if not _can_continue():
			return
		await Effects.trigger_play(eff, card_data, ctx)

func _can_continue() -> bool:
	if not is_instance_valid(self):
		return false
	if not has_node("/root/Game"):
		return false
	if Game.combat != null and Game.combat.aborted:
		return false
	return true
