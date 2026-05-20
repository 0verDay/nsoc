class_name HandView
extends Node

# 手牌渲染。原 main.ensure_min_hand_size 迁移于此。
# 新增：draw_into_slot(idx) 带飞入动画的单卡补位。

signal hand_card_long_press_requested(card_data)
signal hand_card_long_press_canceled

const MIN_HAND_SIZE: int = 5
const DRAW_ANIM_DURATION: float = 0.35
const DRAW_ENTRY_OFFSET: Vector2 = Vector2(900, 0)   # 屏外右侧起点偏移

var _container: Container
var _hand_card_scene: PackedScene
var _animation_root: Control                          # 飞入动画 visual 的挂载点（屏内但脱离 Container 布局）
var _card_counter: int = 1

func setup(container: Container, hand_card_scene: PackedScene, animation_root: Control = null) -> void:
	_container = container
	_hand_card_scene = hand_card_scene
	_animation_root = animation_root if animation_root != null else container

# 启动初始填充：无动画一次补足。
func ensure_min_hand_size() -> void:
	while _container.get_child_count() < MIN_HAND_SIZE:
		_spawn_card_at(-1)

# 出牌后单张补位，带飞入动画。
# placeholder 为消耗后保留占位的旧卡节点（modulate=0），新卡到位后由本方法 free。
# slot_index < 0 时直接走无动画补位。
func draw_into_slot(slot_index: int, placeholder = null) -> void:
	if slot_index < 0 or placeholder == null or not is_instance_valid(placeholder):
		# 兜底：旧逻辑（无占位时直接补足）
		_free_placeholder(placeholder)
		while _container.get_child_count() < MIN_HAND_SIZE:
			_spawn_card_at(-1)
		return
	_play_draw_animation(slot_index, placeholder)

# 无动画的卡节点创建（启动初始化用）。
func _spawn_card_at(slot_index: int) -> void:
	var data = Game.deck.draw_card()
	if data == null:
		data = CardSpell.new("虚空", 1, ["autophagy"])
	var c = _hand_card_scene.instantiate()
	_container.add_child(c)
	c.setup(data, _card_counter)
	_card_counter += 1
	if c.has_signal("long_press_requested"):
		c.long_press_requested.connect(_on_card_long_press_requested)
	if c.has_signal("long_press_canceled"):
		c.long_press_canceled.connect(_on_card_long_press_canceled)
	if slot_index >= 0 and slot_index < _container.get_child_count():
		_container.move_child(c, slot_index)

# 飞入动画：visual 从屏外右侧滑到占位卡位置，结束时一次性替换占位卡为真卡。
# 期间 Container 始终保持 5 张子（占位卡顶位），不发生 reflow。
func _play_draw_animation(slot_index: int, placeholder) -> void:
	var data = Game.deck.draw_card()
	if data == null:
		data = CardSpell.new("虚空", 1, ["autophagy"])
	# 等一帧让占位状态稳定再读 global_position
	await placeholder.get_tree().process_frame
	if not is_instance_valid(placeholder):
		# 占位丢失，退化为直接补位
		_spawn_card_at(slot_index)
		return
	var target_pos: Vector2 = placeholder.global_position
	var visual = _hand_card_scene.instantiate()
	_animation_root.add_child(visual)
	visual.setup(data, _card_counter)
	visual.global_position = target_pos + DRAW_ENTRY_OFFSET
	visual.z_index = 50
	var tween := visual.create_tween()
	tween.tween_property(visual, "global_position", target_pos, DRAW_ANIM_DURATION).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	await tween.finished
	# 飞入完成：插入真卡到原 idx，free 占位卡，free visual。
	var ph_idx: int = slot_index
	if is_instance_valid(placeholder):
		ph_idx = placeholder.get_index()
	var c = _hand_card_scene.instantiate()
	_container.add_child(c)
	c.setup(data, _card_counter)
	_card_counter += 1
	if c.has_signal("long_press_requested"):
		c.long_press_requested.connect(_on_card_long_press_requested)
	if c.has_signal("long_press_canceled"):
		c.long_press_canceled.connect(_on_card_long_press_canceled)
	# 移到占位卡之前，free 占位卡后位置即正确
	if ph_idx < _container.get_child_count() - 1:
		_container.move_child(c, ph_idx)
	_free_placeholder(placeholder)
	if is_instance_valid(visual):
		visual.queue_free()

func _free_placeholder(placeholder) -> void:
	if placeholder == null:
		return
	if not is_instance_valid(placeholder):
		return
	if placeholder.get_parent():
		placeholder.get_parent().remove_child(placeholder)
	placeholder.queue_free()

const DISCARD_FADE_DURATION: float = 0.35

# 弃置全部手牌进墓地，再补齐至 MIN_HAND_SIZE。
# 动画：逐张 modulate.a 1→0 + 入墓 → 飞入新卡补位 → 下一张。
# "虚空" 占位卡（CardSpell 临时实例）不入墓，直接释放。
func discard_all_and_refill() -> void:
	if _container == null:
		return
	# 拍快照，避免遍历期间 container 子集变化。
	var cards: Array = []
	for c in _container.get_children():
		cards.append(c)

	for c in cards:
		if not is_instance_valid(c):
			continue
		var data = c.card_data if "card_data" in c else null
		var slot_index: int = c.get_index()

		# fade out
		c.set_meta("consumed", true)            # 防 DRAG_END 把 modulate 改回 1
		c.mouse_filter = Control.MOUSE_FILTER_IGNORE
		var t1: Tween = c.create_tween()
		t1.tween_property(c, "modulate:a", 0.0, DISCARD_FADE_DURATION)
		await t1.finished
		if not is_instance_valid(c):
			continue

		# 入墓（虚空占位卡跳过）
		if data != null and data is CardBase and String(data.name) != "虚空":
			Game.deck.send_to_graveyard(data)

		# 复用出牌后补位的飞入动画：c 此时 modulate.a=0 充当 placeholder。
		await _play_draw_animation(slot_index, c)

	# 兜底：若有空槽（弃置过程中牌堆完全空导致 _spawn 没触发等极端情况）。
	while _container.get_child_count() < MIN_HAND_SIZE:
		_spawn_card_at(-1)

func _on_card_long_press_requested(data) -> void:
	hand_card_long_press_requested.emit(data)

func _on_card_long_press_canceled() -> void:
	hand_card_long_press_canceled.emit()
