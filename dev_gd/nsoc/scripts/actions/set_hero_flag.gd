extends RefCounted

# set_hero_flag action：设置指定 slot 英雄的 flag。
#
# params:
#   "slot"  : String  目标 slot_id
#   "flag"  : String  flag 键名（如 "die_hard"）
#   "value" : bool    目标值（默认 true）

func id() -> String:
	return "set_hero_flag"

func run(params: Dictionary, _ctx: Dictionary) -> void:
	if not _has_game():
		return
	var slot_id: String = String(params.get("slot", ""))
	var flag_key: String = String(params.get("flag", ""))
	var value: bool = bool(params.get("value", true))
	if slot_id == "" or flag_key == "":
		return
	var slot: BoardSlot = Game.registry.get_by_id(slot_id)
	if slot != null and slot.hero != null:
		slot.hero.set_flag(flag_key, value)

static func _has_game() -> bool:
	var loop = Engine.get_main_loop()
	return loop != null and loop.root != null and loop.root.has_node("/root/Game")
