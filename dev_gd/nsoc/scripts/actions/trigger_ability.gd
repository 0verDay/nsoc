extends RefCounted

# trigger_ability action：调用指定静态能力方法（援樊/受降/屯扎/先射/直入/蓄水）。
#
# params:
#   "ability" : String  能力脚本 stem（如 "aid_fancheng_ability"）
#   "method"  : String  静态方法名（如 "trigger", "trigger_start", "trigger_end", "add_charge", "release"）

func id() -> String:
	return "trigger_ability"

func run(params: Dictionary, _ctx: Dictionary) -> void:
	if not _has_game():
		return
	var ability_stem: String = String(params.get("ability", ""))
	var method_name: String = String(params.get("method", "trigger"))
	if ability_stem == "":
		return
	var path: String = "res://scripts/abilities/" + ability_stem + ".gd"
	var script = load(path)
	if script == null:
		push_warning("trigger_ability: script not found: " + path)
		return
	if not script.has_method(method_name):
		push_warning("trigger_ability: method not found: " + method_name + " in " + path)
		return
	script.call(method_name, Game)

static func _has_game() -> bool:
	var loop = Engine.get_main_loop()
	return loop != null and loop.root != null and loop.root.has_node("/root/Game")
