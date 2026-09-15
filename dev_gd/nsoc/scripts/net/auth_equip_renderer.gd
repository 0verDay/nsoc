class_name AuthEquipRenderer
extends RefCounted

## 权威装备渲染件（对应"手牌/装备按 auth/state 渲染"的装备那一半）。
##
## 与 `AuthBoardRenderer` 同一套路：把 `auth/state` 里的权威数据落到本地视图，
## 且**逐字段比较、无变化不写入** —— 否则每次 state 都会重发
## `Equipments.equipment_removed` / `equipment_added`，让英雄装备栏的按钮
## 反复重建 / 重播动画。
##
## 之所以单独成类（而不是写进场景脚本）：它对"有 UI 的战斗场景"与"无头"是同一套
## 鸭子类型调用（只依赖 `Equipments` 单例的 `to_dict()` / `from_dict()`），
## 因此可以无 UI 测试。
##
## 数据形状：`auth/state.you.equipments` = `[ {card_name, durability_left, used_this_turn}, ... ]`
## （`BattleAuthority._equip_list()` 输出、`EquipmentInstance.to_dict()` 生成）。
## 注意 JSON 往返会把整数变成浮点，比较时必须归一化。

## 把权威装备列表写进 `Equipments` 单例。返回是否真的写入了。
## `equip_dicts` 非数组时视为"权威没给这个字段"，直接不动本地状态。
static func apply(equip_dicts) -> bool:
	if typeof(equip_dicts) != TYPE_ARRAY:
		return false
	var incoming: Array = equip_dicts
	if _same(_current(), incoming):
		return false
	Equipments.from_dict({"equipments": incoming})
	return true


## 当前本地装备列表（`[{card_name, durability_left, used_this_turn}, ...]`）。
static func _current() -> Array:
	if not _has_equipments():
		return []
	var raw: Dictionary = Equipments.to_dict()
	var arr = raw.get("equipments", [])
	return arr if typeof(arr) == TYPE_ARRAY else []


## 两个装备列表是否等价（忽略 JSON 的 int/float 差异）。
static func _same(a: Array, b: Array) -> bool:
	if a.size() != b.size():
		return false
	for i in range(a.size()):
		var x = a[i]
		var y = b[i]
		if typeof(x) != TYPE_DICTIONARY or typeof(y) != TYPE_DICTIONARY:
			return false
		if String((x as Dictionary).get("card_name", "")) != String((y as Dictionary).get("card_name", "")):
			return false
		if int((x as Dictionary).get("durability_left", 0)) != int((y as Dictionary).get("durability_left", 0)):
			return false
		if bool((x as Dictionary).get("used_this_turn", false)) != bool((y as Dictionary).get("used_this_turn", false)):
			return false
	return true


static func _has_equipments() -> bool:
	if Engine.get_main_loop() == null:
		return false
	var root: Node = Engine.get_main_loop().root
	return root != null and root.has_node("/root/Equipments")
