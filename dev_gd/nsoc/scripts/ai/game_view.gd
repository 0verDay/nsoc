class_name AiGameView
extends RefCounted

var _ai_slot_id: String = ""
var _deck: DeckManager = null
var _mana: ManaSystem = null
var _hand: Array = []

func setup(ai_slot_id: String, deck: DeckManager, mana: ManaSystem) -> void:
	_ai_slot_id = ai_slot_id
	_deck = deck
	_mana = mana

func current_mana() -> int:
	return _mana.current if _mana != null else 0

func hand_cards() -> Array:
	return _hand

func set_hand(cards: Array) -> void:
	_hand = cards

func own_slot() -> BoardSlot:
	if not Engine.get_main_loop().root.has_node("/root/Game") or Game.registry == null:
		return null
	return Game.registry.get_by_id(_ai_slot_id)

func opponent_slots() -> Array:
	if not Engine.get_main_loop().root.has_node("/root/Game") or Game.registry == null:
		return []
	var own := own_slot()
	if own == null:
		return []
	var out: Array = []
	for s in Game.registry.slots:
		if s.faction != own.faction:
			out.append(s)
	return out

func empty_cells_of(slot: BoardSlot) -> Array:
	var out: Array = []
	if slot == null or slot.board == null:
		return out
	for c in slot.board.grid_cells.values():
		if is_instance_valid(c) and not c.has_card:
			out.append(c)
	return out

# 从本 AI 视角判断某格是否是"己方单位"（敌方 AI → is_enemy=true；友军 AI → is_enemy=false）
func is_own_unit(cell) -> bool:
	var own := own_slot()
	if own == null:
		return false
	return cell.is_enemy == (own.faction == BoardSlot.FACTION_ENEMY)

# 从本 AI 视角判断某格是否是"对方单位"
func is_target_unit(cell) -> bool:
	var own := own_slot()
	if own == null:
		return false
	return cell.is_enemy != (own.faction == BoardSlot.FACTION_ENEMY)

# 对手单位威胁评分（攻 + 关键词权重）
func threat_of(cell) -> float:
	if not is_instance_valid(cell) or not cell.has_card:
		return 0.0
	var score: float = float(cell.attack)
	for eff in cell.effects:
		match String(eff):
			"charge", "assault_charge", "breakout":
				score += 3.0
			"steadfast", "vigilance":
				score += 1.5
			"flood_strategy_unit", "awe":
				score += 4.0
	return score

