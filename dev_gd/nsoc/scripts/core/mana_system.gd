class_name ManaSystem
extends Node

signal mana_changed(current: int, maximum: int)

const MAX_MANA_CAP: int = 10

var current: int = 1
var maximum: int = 1

func setup(start_max: int = 1) -> void:
	maximum = start_max
	current = start_max
	mana_changed.emit(current, maximum)

func can_spend(amount: int) -> bool:
	return current >= amount

func spend(amount: int) -> bool:
	if not can_spend(amount):
		return false
	current -= amount
	mana_changed.emit(current, maximum)
	return true

# 进入新回合：上限 +1（不超过 cap），current 重置为 maximum。
func start_new_turn() -> void:
	if maximum < MAX_MANA_CAP:
		maximum += 1
	current = maximum
	mana_changed.emit(current, maximum)
