extends RefCounted

# set_counter action：设置 Game.counters 中指定 key 的值。
#
# params:
#   "key"   : String  计数器键名
#   "value" : int     目标值（默认 1）

func id() -> String:
	return "set_counter"

func run(params: Dictionary, _ctx: Dictionary) -> void:
	if not _has_game():
		return
	var key: String = String(params.get("key", ""))
	var value: int  = int(params.get("value", 1))
	if key == "":
		return
	Game.counters[key] = value

static func _has_game() -> bool:
	var loop = Engine.get_main_loop()
	return loop != null and loop.root != null and loop.root.has_node("/root/Game")
