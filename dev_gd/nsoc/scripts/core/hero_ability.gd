class_name HeroAbility
extends RefCounted

# 英雄技能基类。仿 Effect 设计，子类放 res://scripts/abilities/，文件名即 ID。
# 由 HeroAbilityRegistry 启动期扫描自动注册。

# 唯一 ID（默认取脚本文件名 stem）。
func id() -> String:
	return ""

# UI 显示名。
func display_name() -> String:
	return id()

# 详情面板描述。
func description() -> String:
	return ""

# 费用。
func cost() -> int:
	return 0

# 是否每回合限用一次。注册表激活成功后会写计数器。
func once_per_turn() -> bool:
	return false

# 是否可激活：默认禁止回合运行中、检查费用与每回合次数限制。
func can_activate(ctx) -> bool:
	if Game.turn != null and Game.turn.is_running:
		return false
	if not Game.mana.can_spend(cost()):
		return false
	if once_per_turn() and HeroAbilities.is_used_this_turn(id()):
		return false
	return true

# 激活逻辑。子类重写。
func on_activate(ctx) -> void:
	pass
