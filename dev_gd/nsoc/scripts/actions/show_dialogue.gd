extends RefCounted

# show_dialogue action：将一条对话台词推入 Dialogue 队列（非阻塞）。
#
# params 字段：
#   "speaker" : String  说话者名称（显示在气泡左上）
#   "text"    : String  台词内容（支持 MarkupParser 标签）
#   "side"    : String  气泡所在半场："enemy"（默认）/ "player"（玩家半场）
#   "board"   : String  指定棋盘 slot_id（如 "enemy_left"）；非空时气泡锚定在该盘位置

func id() -> String:
	return "show_dialogue"

func run(params: Dictionary, _ctx: Dictionary) -> void:
	var speaker: String = String(params.get("speaker", ""))
	var text: String    = String(params.get("text", ""))
	var side: String    = String(params.get("side", "enemy"))
	var board: String   = String(params.get("board", ""))

	if text.is_empty():
		return

	var loop = Engine.get_main_loop()
	if loop == null or loop.root == null:
		return
	if not loop.root.has_node("/root/Dialogue"):
		return

	Dialogue.push(speaker, text, side, board)
