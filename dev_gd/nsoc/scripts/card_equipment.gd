class_name CardEquipment
extends CardBase

# 装备卡。玩家从手牌拖到英雄面板使用 → 转化为 EquipmentInstance 挂在英雄上。
# 每次激活按钮：扣费 → 触发 effects → 耐久 -1。耐久归零入墓。
# once_per_turn 由 EquipmentManager 按实例追踪。

var durability: int = 1
var once_per_turn: bool = false

func _init(n: String, c: int, dura: int, e: Array = [], opt: bool = false):
	super(n, "装备", c, e)
	durability = dura
	once_per_turn = opt
