extends RefCounted

# damage_hero action：对指定盘英雄造成固定伤害（走标准 BoardSlot.damage_hero 路径，
# 触发英雄面板闪红动画 + 扣血 + 死亡信号）。
#
# params 字段：
#   "slot"   : String  目标盘 id（如 "player_main"）
#   "amount" : int     伤害量（>0 生效）

func id() -> String:
	return "damage_hero"

func run(params: Dictionary, _ctx: Dictionary) -> void:
	if not _has_game():
		return

	var slot_id: String = String(params.get("slot", "player_main"))
	var amount: int     = int(params.get("amount", 0))

	if amount <= 0:
		return

	var slot: BoardSlot = Game.registry.get_by_id(slot_id)
	if slot == null:
		push_warning("damage_hero: slot not found: " + slot_id)
		return

	slot.damage_hero(amount)

static func _has_game() -> bool:
	var loop = Engine.get_main_loop()
	return loop != null and loop.root != null and loop.root.has_node("/root/Game")
