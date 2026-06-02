extends Node

# EquipmentManager —— 玩家装备实例集合。autoload 单例 "Equipments"。
# 玩家从手牌打出装备 → equip(card_data) 创建 EquipmentInstance；
# 装备激活耐久归零 → unequip(inst) 自动入墓；
# 回合开始 → reset_turn_usage 清 once_per_turn 标记。

signal equipment_added(inst)
signal equipment_removed(inst)
signal equipment_changed(inst)

var _equipments: Array = []   # EquipmentInstance[]

func _ready() -> void:
	# 回合开始重置：Game.turn 在 game_context._ready() 已 add_child，但 autoload 加载顺序里
	# Equipments 与 Game 都是 autoload，连接放到 Game.turn 创建后由调用方触发。
	# 这里延后用 call_deferred 等 Game 子系统就绪再连。
	call_deferred("_connect_turn_signal")

func _connect_turn_signal() -> void:
	if has_node("/root/Game") and Game.turn != null:
		if not Game.turn.turn_started.is_connected(_on_turn_started):
			Game.turn.turn_started.connect(_on_turn_started)

func _on_turn_started() -> void:
	# turn_started 在 Game.turn.run() 时发出（行动阶段开始）。装备的"一回合"按
	# 玩家回合计 → 在玩家结束回合前重置最合适。但当前架构无 player_turn_began 信号，
	# 复用 turn_started + main.gd 在 end_turn 后调用 reset_turn_usage 双保险。
	pass

# 玩家结束回合后调用，清 once_per_turn 标记（与 HeroAbilities.reset_turn_usage 同节奏）。
func reset_turn_usage() -> void:
	for inst in _equipments:
		inst.reset_turn()

func equip(card_data: CardEquipment) -> EquipmentInstance:
	if card_data == null:
		return null
	var inst := EquipmentInstance.new(card_data)
	_equipments.append(inst)
	inst.changed.connect(func(): _on_inst_changed(inst))
	equipment_added.emit(inst)
	return inst

func unequip(inst: EquipmentInstance) -> void:
	if inst == null:
		return
	var idx := _equipments.find(inst)
	if idx < 0:
		return
	_equipments.remove_at(idx)
	equipment_removed.emit(inst)

func _on_inst_changed(inst: EquipmentInstance) -> void:
	equipment_changed.emit(inst)
	if inst.is_broken():
		# 入墓 + 移除按钮。
		if has_node("/root/Game") and Game.deck != null and inst.card_data != null:
			Game.deck.send_to_graveyard(inst.card_data)
		unequip(inst)

func all() -> Array:
	return _equipments

# 局结束 / 重新进入战斗时清理（game_context.bootstrap 调用）。
func clear_all() -> void:
	for inst in _equipments.duplicate():
		equipment_removed.emit(inst)
	_equipments.clear()

# ── 序列化（PVP 联机用）────────────────────────────────────────────
# 1v1 阶段：先做单玩家集合的序列化。多人扩展时 snapshot_io 按 player_id 分组。
func to_dict() -> Dictionary:
	var arr: Array = []
	for inst in _equipments:
		if inst == null:
			continue
		arr.append(inst.to_dict())
	return {"equipments": arr}

func from_dict(d: Dictionary) -> void:
	# 清空旧实例（发 removed 让 HeroActionBar 等 UI 同步）
	for old in _equipments.duplicate():
		equipment_removed.emit(old)
	_equipments.clear()
	var arr = d.get("equipments", [])
	if typeof(arr) != TYPE_ARRAY:
		arr = []
	for entry in arr:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		var inst := EquipmentInstance.from_dict(entry)
		if inst == null:
			continue
		_equipments.append(inst)
		inst.changed.connect(func(): _on_inst_changed(inst))
		equipment_added.emit(inst)
