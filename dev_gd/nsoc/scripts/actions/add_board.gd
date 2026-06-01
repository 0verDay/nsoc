extends RefCounted

# add_board action：动态添加一个附盘（含滑入动画）。
#
# params:
#   "slot" : String  目标 board id（如 "enemy_left"）

func id() -> String:
	return "add_board"

func run(params: Dictionary, ctx: Dictionary) -> void:
	var slot_id: String = String(params.get("slot", ""))
	if slot_id == "":
		push_warning("add_board: missing 'slot' param")
		return
	var orch = ctx.get("orchestrator")
	if orch == null or not is_instance_valid(orch):
		push_warning("add_board: orchestrator not available in ctx")
		return
	if not orch.has_board(slot_id):
		await orch.add_board(slot_id)
