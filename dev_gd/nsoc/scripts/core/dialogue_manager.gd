extends Node

# DialogueManager —— 对话气泡队列管理器。作为 autoload 单例"Dialogue"。
#
# 职责：
#   - 维护对话队列（FIFO），每次只显示一个气泡
#   - 支持 side = "enemy"（敌方半场顶部）/ "player"（玩家半场顶部）两种定位
#   - 通过 CanvasLayer(z=92) 叠加于战斗 UI 之上，结算面板(z=100)之下
#
# 外部调用：
#   Dialogue.push("曹操", "台词内容")               # 默认 enemy 侧
#   Dialogue.push("刘备", "台词内容", "player")      # 玩家侧

const BUBBLE_WIDTH_RATIO: float = 0.88   # 气泡宽度 = 棋盘宽度 × 此比例
const BUBBLE_OFFSET_Y: float    = 12.0   # 距棋盘顶边的偏移

const _BubbleScript = preload("res://scripts/ui/dialogue_bubble.gd")

var _queue: Array          = []     # [{speaker, text, side}]
var _current: DialogueBubble = null
# call_deferred 防重入标志：同帧内多次 push 时，只排队一次 _show_next。
# 若缺此标志，_current 仍为 null 时连续两次 push 会调度两次 _show_next，
# 导致两个气泡同时弹出并相互覆盖。
var _show_scheduled: bool  = false
var _canvas_layer: CanvasLayer = null

func _ready() -> void:
	_canvas_layer = CanvasLayer.new()
	_canvas_layer.layer = 92
	_canvas_layer.name = "DialogueCanvas"
	add_child(_canvas_layer)

# ── 公开 API ──────────────────────────────────────────────────────────────

# 将一条对话加入队列。非阻塞：立即返回，气泡在下一帧显示。
# side: "enemy"（默认）或 "player"。
# board: 指定 slot_id（如 "enemy_left"）；非空时气泡锚定到该盘而非 side 推断的主盘。
func push(speaker: String, text: String, side: String = "enemy", board: String = "") -> void:
	if speaker.is_empty() and text.is_empty():
		return
	_queue.append({"speaker": speaker, "text": text, "side": side, "board": board})
	if _current == null and not _show_scheduled:
		_show_scheduled = true
		_show_next.call_deferred()

# 清空队列（退出战斗时调用，防止残留气泡在菜单场景出现）。
func clear_queue() -> void:
	_queue.clear()
	_show_scheduled = false
	if _current != null and is_instance_valid(_current):
		_current.queue_free()
	_current = null

# ── 私有 ─────────────────────────────────────────────────────────────────

func _show_next() -> void:
	_show_scheduled = false
	if _queue.is_empty():
		_current = null
		return

	var item: Dictionary = _queue.pop_front()

	var bubble: DialogueBubble = _BubbleScript.new()
	bubble.name = "DialogueBubble"
	_canvas_layer.add_child(bubble)
	bubble.dismissed.connect(_on_bubble_dismissed.bind(bubble))

	# 先定位再 setup（setup 触发淡入，位置应已就绪）
	_position_bubble(bubble, item)

	_current = bubble

func _on_bubble_dismissed(_bubble: DialogueBubble) -> void:
	_current = null
	if not _queue.is_empty():
		# 稍微延迟再显示下一条，避免连续气泡"闪烁"
		get_tree().create_timer(0.15).timeout.connect(_show_next, CONNECT_ONE_SHOT)
	# else: 队列已空，等待下次 push

# 根据 item.side / item.board 定位气泡并初始化内容。
func _position_bubble(bubble: DialogueBubble, item: Dictionary) -> void:
	var side: String  = String(item.get("side", "enemy"))
	var board: String = String(item.get("board", ""))

	# 优先按指定 board slot 获取 Rect；退回 side 推断。
	var anchor_rect: Rect2
	if board != "" and has_node("/root/Game") and Game.registry != null:
		var slot: BoardSlot = Game.registry.get_by_id(board)
		if slot != null:
			if slot.bg_panel != null and is_instance_valid(slot.bg_panel):
				anchor_rect = slot.bg_panel.get_global_rect()
			elif slot.grid_node != null and is_instance_valid(slot.grid_node):
				anchor_rect = slot.grid_node.get_global_rect()
	if anchor_rect == Rect2():
		anchor_rect = _get_player_board_rect() if side == "player" \
		              else _get_enemy_board_rect()

	var bw: float  = anchor_rect.size.x * BUBBLE_WIDTH_RATIO
	var bx: float  = anchor_rect.position.x + (anchor_rect.size.x - bw) * 0.5

	const PLAYER_BUBBLE_HEIGHT: float = 107.0
	var by_: float
	var slide_from_below: bool
	if side == "player":
		by_ = anchor_rect.position.y + anchor_rect.size.y - PLAYER_BUBBLE_HEIGHT - BUBBLE_OFFSET_Y
		slide_from_below = true
	else:
		by_ = anchor_rect.position.y + BUBBLE_OFFSET_Y
		slide_from_below = false

	bubble.custom_minimum_size = Vector2(bw, 0)
	bubble.position = Vector2(bx, by_)
	bubble.setup(item["speaker"], item["text"], slide_from_below)

# 获取敌方棋盘的屏幕绝对 Rect。
# 优先从 Game.registry 的 enemy_main slot 获取 bg_panel 坐标；
# 无法获取时返回 1920×1080 基准下的合理后备值。
func _get_enemy_board_rect() -> Rect2:
	if has_node("/root/Game") and Game.registry != null:
		var slot = Game.enemy_main_slot()
		if slot != null and is_instance_valid(slot):
			if slot.bg_panel != null and is_instance_valid(slot.bg_panel):
				return slot.bg_panel.get_global_rect()
			if slot.grid_node != null and is_instance_valid(slot.grid_node):
				return slot.grid_node.get_global_rect()
	# 后备：1920×1080 基准，敌方盘大致区域
	return Rect2(190, 30, 830, 480)

# 获取玩家棋盘的屏幕绝对 Rect。
# 优先从 Game.registry 的 player_main slot 获取 bg_panel 坐标；
# 无法获取时返回 1920×1080 基准下的合理后备值。
func _get_player_board_rect() -> Rect2:
	if has_node("/root/Game") and Game.registry != null:
		var slot = Game.main_player_slot()
		if slot != null and is_instance_valid(slot):
			if slot.bg_panel != null and is_instance_valid(slot.bg_panel):
				return slot.bg_panel.get_global_rect()
			if slot.grid_node != null and is_instance_valid(slot.grid_node):
				return slot.grid_node.get_global_rect()
	# 后备：1920×1080 基准，玩家盘大致区域（下半场）
	return Rect2(190, 570, 830, 480)
