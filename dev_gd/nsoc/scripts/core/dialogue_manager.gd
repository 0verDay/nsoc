extends Node

# DialogueManager —— 对话气泡队列管理器。作为 autoload 单例"Dialogue"。
#
# 职责：
#   - 维护对话队列（FIFO），每次只显示一个气泡
#   - 自动定位到敌方棋盘区域的上半部分
#   - 通过 CanvasLayer(z=92) 叠加于战斗 UI 之上，结算面板(z=100)之下
#
# 外部调用：
#   Dialogue.push("曹操", "台词内容")
#
# 无需外部注入任何节点引用；定位时从 Game.registry 查 enemy_main 槽的 bg_panel。

const BUBBLE_WIDTH_RATIO: float = 0.88   # 气泡宽度 = 敌方盘宽度 × 此比例
const BUBBLE_OFFSET_Y: float    = 12.0   # 距敌方盘顶边的偏移

const _BubbleScript = preload("res://scripts/ui/dialogue_bubble.gd")

var _queue: Array          = []   # [{speaker, text}]
var _current: DialogueBubble = null
var _canvas_layer: CanvasLayer = null

func _ready() -> void:
	_canvas_layer = CanvasLayer.new()
	_canvas_layer.layer = 92
	_canvas_layer.name = "DialogueCanvas"
	add_child(_canvas_layer)

# ── 公开 API ──────────────────────────────────────────────────────────────

# 将一条对话加入队列。非阻塞：立即返回，气泡在下一帧显示。
func push(speaker: String, text: String) -> void:
	if speaker.is_empty() and text.is_empty():
		return
	_queue.append({"speaker": speaker, "text": text})
	if _current == null:
		_show_next.call_deferred()

# 清空队列（退出战斗时调用，防止残留气泡在菜单场景出现）。
func clear_queue() -> void:
	_queue.clear()
	if _current != null and is_instance_valid(_current):
		_current.queue_free()
	_current = null

# ── 私有 ─────────────────────────────────────────────────────────────────

func _show_next() -> void:
	if _queue.is_empty():
		_current = null
		return

	var item: Dictionary = _queue.pop_front()

	var bubble: DialogueBubble = _BubbleScript.new()
	bubble.name = "DialogueBubble"
	_canvas_layer.add_child(bubble)
	bubble.dismissed.connect(_on_bubble_dismissed.bind(bubble))

	# 先定位再 setup（setup 触发淡入，位置应已就绪）
	_position_bubble(bubble, item["speaker"], item["text"])

	_current = bubble

func _on_bubble_dismissed(_bubble: DialogueBubble) -> void:
	_current = null
	if not _queue.is_empty():
		# 稍微延迟再显示下一条，避免连续气泡"闪烁"
		get_tree().create_timer(0.15).timeout.connect(_show_next, CONNECT_ONE_SHOT)
	# else: 队列已空，等待下次 push

# 定位 + 初始化气泡内容。
func _position_bubble(bubble: DialogueBubble, speaker: String, text: String) -> void:
	var anchor_rect: Rect2 = _get_enemy_board_rect()

	var bw: float = anchor_rect.size.x * BUBBLE_WIDTH_RATIO
	var bx: float = anchor_rect.position.x + (anchor_rect.size.x - bw) * 0.5
	var by_: float = anchor_rect.position.y + BUBBLE_OFFSET_Y

	# 设置最小宽度约束（高度自适应内容）
	bubble.custom_minimum_size = Vector2(bw, 0)
	bubble.position = Vector2(bx, by_)

	# 内容初始化（触发淡入 + 计时）
	bubble.setup(speaker, text)

# 获取敌方棋盘的屏幕绝对 Rect。
# 优先从 Game.registry 的 enemy_main slot 获取 bg_panel 坐标；
# 无法获取时返回 1920×1080 基准下的合理后备值。
func _get_enemy_board_rect() -> Rect2:
	if has_node("/root/Game") and Game.registry != null:
		var slot = Game.enemy_main_slot()
		if slot != null and is_instance_valid(slot):
			# 优先使用 bg_panel（背景面板有完整尺寸）
			if slot.bg_panel != null and is_instance_valid(slot.bg_panel):
				return slot.bg_panel.get_global_rect()
			# 次选 grid_node
			if slot.grid_node != null and is_instance_valid(slot.grid_node):
				return slot.grid_node.get_global_rect()
	# 后备：1920×1080 基准，敌方盘大致区域
	return Rect2(190, 30, 830, 480)
