class_name NetActionSink
extends AiActionSink

# PVP 人机托管（AI 扮演某 pid 广播行动）。P5 阶段实现。
var pid: String = ""

func apply(action: AiAction) -> bool:
	match action.kind:
		AiAction.Kind.PLAY_UNIT, AiAction.Kind.PLAY_SPELL:
			var payload := {
				"card_name": action.card_name,
				"card_type": "单位" if action.kind == AiAction.Kind.PLAY_UNIT else "法术",
				"slot_id": action.slot_id,
				"abs_row": action.row,
				"abs_col": action.col,
			}
			Net.send_to_room("action/play_card", Game.pvp_room_id, payload, "all")
			return true
		AiAction.Kind.CROSS_BOARD:
			Net.send_to_room("action/cross_board", Game.pvp_room_id, {
				"source_slot_id": action.slot_id,
				"row": action.source_row,
				"col": action.source_col,
				"target_slot_id": action.target_slot_id,
			}, "all")
			return true
		AiAction.Kind.END_TURN:
			Net.send_to_room("action/end_turn", Game.pvp_room_id, {
				"player_id": pid,
				"turn_number": Game.turn.turn_number,
			}, "all")
			return true
	return false
