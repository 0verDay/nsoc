class_name ManaSystem
extends Node

signal mana_changed(current: int, maximum: int)

const MAX_MANA_CAP: int = 10

var current: int = 1
var maximum: int = 1
# 本局费用上限硬封顶。默认 = MAX_MANA_CAP（10）；
# 战役章节可通过 level.mana_max_cap 覆写（如街亭·王平协防 = 5）。
var cap: int = MAX_MANA_CAP

func setup(start_max: int = 1, p_cap: int = MAX_MANA_CAP) -> void:
	cap = clampi(p_cap, 1, MAX_MANA_CAP)
	maximum = mini(start_max, cap)
	current = maximum
	mana_changed.emit(current, maximum)

func can_spend(amount: int) -> bool:
	return current >= amount

func spend(amount: int) -> bool:
	if not can_spend(amount):
		return false
	current -= amount
	mana_changed.emit(current, maximum)
	return true

# 增加当前法力，仅受硬上限 cap 约束，可超过本回合 maximum（临时超费）。
func gain(amount: int) -> void:
	if amount <= 0:
		return
	current = min(current + amount, cap)
	mana_changed.emit(current, maximum)

# 进入新回合：上限 +1（不超过 cap），current 重置为 maximum。
# cap < MAX_MANA_CAP 时（如协防 cap=5）maximum 升到 cap 后即停止增长。
func start_new_turn() -> void:
	if maximum < cap:
		maximum += 1
	current = maximum
	mana_changed.emit(current, maximum)

# ── 序列化（PVP 联机用）────────────────────────────────────────────
# 状态对外只有 current / maximum 两个标量。
func to_dict() -> Dictionary:
	return {
		"current": current,
		"maximum": maximum,
	}

func from_dict(d: Dictionary) -> void:
	current = int(d.get("current", 1))
	maximum = int(d.get("maximum", 1))
	mana_changed.emit(current, maximum)
