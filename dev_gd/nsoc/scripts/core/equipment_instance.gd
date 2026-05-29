class_name EquipmentInstance
extends RefCounted

# 装备运行时实例。EquipmentManager 持有数组。
# card_data 指向 CardEquipment（不可变模板），durability_left / used_this_turn 为运行时态。
#
# 费用说明：
#   "装备"牌打出时在 PlayController.handle_equip 中一次性扣费（装备费用）。
#   之后每次激活效果不再扣费——效果本身是免费的（除非效果自行操作 mana）。

signal changed   # 任意运行时字段变更，UI 监听刷新

var card_data: CardEquipment
var durability_left: int = 0
var used_this_turn: bool = false

func _init(card: CardEquipment) -> void:
	card_data = card
	durability_left = card.durability
	used_this_turn = false

func display_name() -> String:
	return card_data.name if card_data != null else ""

func is_broken() -> bool:
	return durability_left <= 0

# 是否可激活：非回合运行中 + once_per_turn 未触发 + 耐久未归零。
# 注意：激活效果不扣费，无需检查 mana。
func can_activate() -> bool:
	if Game == null:
		return false
	if Game.turn != null and Game.turn.is_running:
		return false
	if card_data == null:
		return false
	if card_data.once_per_turn and used_this_turn:
		return false
	if is_broken():
		return false
	return true

# 聚合所有 effects 声明的目标类型。返回第一个非空的 target，无则返回 ""。
func required_target() -> String:
	if card_data == null:
		return ""
	for eff_id in card_data.effects:
		var t: String = Effects.get_target(String(eff_id))
		if t != "":
			return t
	return ""

# 激活：触发每个 effect 的 on_play → durability -= 1 → 标记本回合已用。
# 不扣费（装备卡打出时已扣）。
# 返回 true = 成功激活并扣耐久；false = 玩家主动取消，耐久不扣。
func activate(ctx) -> bool:
	if not can_activate():
		return false
	for eff in card_data.effects:
		var success: bool = await Effects.trigger_play(String(eff), card_data, ctx)
		if not success:
			changed.emit()   # 刷新按钮状态
			return false
	durability_left -= 1
	if card_data.once_per_turn:
		used_this_turn = true
	changed.emit()
	return true

func reset_turn() -> void:
	if used_this_turn:
		used_this_turn = false
		changed.emit()
