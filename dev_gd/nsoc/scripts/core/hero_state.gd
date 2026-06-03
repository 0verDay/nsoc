class_name HeroState
extends Node

# 单方英雄状态。每个 BoardSlot 拥有一个独立实例。
# 旧 (player_/enemy_) 双套字段已合并为单方模型；阵营归属由所属 BoardSlot 提供，
# 本类仅承载该英雄自身的血量 / 名字 / 技能 / 死亡状态。

signal health_changed(new_value: int)
signal damaged(amount: int)
signal died     # health <= 0 时触发；同一英雄只触发一次

var health: int = 30
var max_health: int = 30          # 详情面板用，不随战斗扣减
var name_short: String = "Hero"   # 局内 HP 面板上的精简名
var name_full: String = "Hero"    # 长按详情用的完整名
var abilities: Array = []         # String[]，HeroAbility ID 列表
var is_dead: bool = false

# 通用 per-hero 计数器（如蓄水层数）。key=String, value=int。
var stacks: Dictionary = {}

# 英雄附加 effects 标志（如 die_hard 死守）。key=String, value=bool。
var flags: Dictionary = {}

func setup(p_hp: int, p_name_short: String = "Hero",
		p_name_full: String = "",
		p_abilities: Array = []) -> void:
	health = p_hp
	max_health = p_hp
	name_short = p_name_short
	name_full = p_name_full if p_name_full != "" else p_name_short
	abilities = p_abilities.duplicate()
	is_dead = false
	stacks.clear()
	flags.clear()
	health_changed.emit(health)

# 取首个技能 ID（保留向后兼容，HeroActionBar 仍用此）。
func ability_id() -> String:
	return String(abilities[0]) if abilities.size() > 0 else ""

# 取全部技能 ID 数组。
func all_ability_ids() -> Array:
	return abilities.duplicate()

func apply_damage(amount: int) -> void:
	health -= amount
	damaged.emit(amount)
	health_changed.emit(health)
	if not is_dead and health <= 0:
		is_dead = true
		died.emit()

# 治疗：恢复 amount 点，不超过 max_health。amount<=0 时无效。
func heal(amount: int) -> void:
	if amount <= 0:
		return
	health = min(health + amount, max_health)
	health_changed.emit(health)

# 回满血量。
func heal_full() -> void:
	health = max_health
	health_changed.emit(health)

# stacks 操作
func get_stack(key: String) -> int:
	return stacks.get(key, 0)

func add_stack(key: String, delta: int = 1) -> int:
	var v: int = stacks.get(key, 0) + delta
	stacks[key] = v
	return v

func set_stack(key: String, value: int) -> void:
	stacks[key] = value

# flags 操作
func has_flag(key: String) -> bool:
	return flags.get(key, false)

func set_flag(key: String, value: bool) -> void:
	flags[key] = value

# ── 序列化（PVP 联机用）────────────────────────────────────────────
# abilities 是 String 数组、stacks/flags 是基础类型字典，可直接序列化。
func to_dict() -> Dictionary:
	return {
		"health": health,
		"max_health": max_health,
		"name_short": name_short,
		"name_full": name_full,
		"abilities": abilities.duplicate(),
		"is_dead": is_dead,
		"stacks": stacks.duplicate(),
		"flags": flags.duplicate(),
	}

func from_dict(d: Dictionary) -> void:
	max_health = int(d.get("max_health", 30))
	health = int(d.get("health", max_health))
	name_short = String(d.get("name_short", "Hero"))
	name_full = String(d.get("name_full", name_short))
	var raw_ab = d.get("abilities", [])
	abilities.clear()
	if typeof(raw_ab) == TYPE_ARRAY:
		for a in raw_ab:
			abilities.append(String(a))
	is_dead = bool(d.get("is_dead", false))
	var raw_st = d.get("stacks", {})
	stacks = raw_st.duplicate() if typeof(raw_st) == TYPE_DICTIONARY else {}
	var raw_fl = d.get("flags", {})
	flags = raw_fl.duplicate() if typeof(raw_fl) == TYPE_DICTIONARY else {}
	health_changed.emit(health)
