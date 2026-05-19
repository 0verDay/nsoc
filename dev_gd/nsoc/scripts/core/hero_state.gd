class_name HeroState
extends Node

signal health_changed(is_enemy: bool, new_value: int)
signal damaged(is_enemy: bool, amount: int)

var player_health: int = 30
var enemy_health: int = 30

func setup(p_hp: int, e_hp: int) -> void:
	player_health = p_hp
	enemy_health = e_hp
	health_changed.emit(false, player_health)
	health_changed.emit(true, enemy_health)

func apply_damage(is_enemy: bool, amount: int) -> void:
	if is_enemy:
		enemy_health -= amount
	else:
		player_health -= amount
	damaged.emit(is_enemy, amount)
	health_changed.emit(is_enemy, enemy_health if is_enemy else player_health)
