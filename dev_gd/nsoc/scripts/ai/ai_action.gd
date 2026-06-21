class_name AiAction
extends RefCounted

enum Kind { PLAY_UNIT, PLAY_SPELL, CROSS_BOARD, END_TURN }

var kind: int = Kind.END_TURN
var card_name: String = ""
var slot_id: String = ""
var row: int = -1
var col: int = -1
var target_slot_id: String = ""
var source_row: int = -1
var source_col: int = -1

static func play_unit(p_card: String, p_slot: String, p_row: int, p_col: int) -> AiAction:
	var a := AiAction.new()
	a.kind = Kind.PLAY_UNIT
	a.card_name = p_card
	a.slot_id = p_slot
	a.row = p_row
	a.col = p_col
	return a

static func play_spell(p_card: String, p_slot: String, p_row: int, p_col: int) -> AiAction:
	var a := AiAction.new()
	a.kind = Kind.PLAY_SPELL
	a.card_name = p_card
	a.slot_id = p_slot
	a.row = p_row
	a.col = p_col
	return a

static func cross_board(p_slot: String, p_row: int, p_col: int, p_target: String) -> AiAction:
	var a := AiAction.new()
	a.kind = Kind.CROSS_BOARD
	a.slot_id = p_slot
	a.source_row = p_row
	a.source_col = p_col
	a.target_slot_id = p_target
	return a

static func end_turn() -> AiAction:
	var a := AiAction.new()
	a.kind = Kind.END_TURN
	return a
