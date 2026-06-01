extends RefCounted

# damage_hero action：对指定 slot 的英雄造成伤害。
#
# params:
#   "slot"   : String  目标 slot_id（如 "enemy_main"）
#   "amount" : int     伤害量
#   "source" : String  伤害来源（默认 "triggered"，穿透死守）

func id() -> String:
	return "damage_hero"

func run(params: Dictionary, _ctx: Dictionary) -> void:
	if not _has_game():
		return
	var slot_id: String = String(params.get("slot", ""))
	var amount: int = int(params.get("amount", 0))
	var source: String = String(params.get("source", "triggered"))
	if slot_id == "" or amount == 0:
		return
	var slot: BoardSlot = Game.registry.get_by_id(slot_id)
	if slot != null:
		slot.damage_hero(amount, source)

static func _has_game() -> bool:
	var loop = Engine.get_main_loop()
	return loop != null and loop.root != null and loop.root.has_node("/root/Game")
