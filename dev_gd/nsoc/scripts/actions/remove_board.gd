extends RefCounted

# remove_board action：动态移除一个附盘（含滑出动画）。
#
# params:
#   "slot" : String  目标 board id（如 "enemy_left"）

func id() -> String:
	return "remove_board"

func run(params: Dictionary, ctx: Dictionary) -> void:
	var slot_id: String = String(params.get("slot", ""))
	if slot_id == "":
		push_warning("remove_board: missing 'slot' param")
		return
	var orch = ctx.get("orchestrator")
	if orch == null or not is_instance_valid(orch):
		push_warning("remove_board: orchestrator not available in ctx")
		return
	if orch.has_board(slot_id):
		await orch.remove_board(slot_id)
