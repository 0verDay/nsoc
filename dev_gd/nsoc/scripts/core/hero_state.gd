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

func setup(p_hp: int, p_name_short: String = "Hero",
		p_name_full: String = "",
		p_abilities: Array = []) -> void:
	health = p_hp
	max_health = p_hp
	name_short = p_name_short
	name_full = p_name_full if p_name_full != "" else p_name_short
	abilities = p_abilities.duplicate()
	is_dead = false
	health_changed.emit(health)

# 取首个技能 ID（当前每英雄至多一个）。
func ability_id() -> String:
	return String(abilities[0]) if abilities.size() > 0 else ""

func apply_damage(amount: int) -> void:
	health -= amount
	damaged.emit(amount)
	health_changed.emit(health)
	if not is_dead and health <= 0:
		is_dead = true
		died.emit()
