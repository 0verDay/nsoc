class_name HeroState
extends Node

signal health_changed(is_enemy: bool, new_value: int)
signal damaged(is_enemy: bool, amount: int)
signal hero_died(is_enemy: bool)            # hp <= 0 时触发；同一英雄只触发一次

var player_health: int = 30
var enemy_health: int = 30
var _player_dead: bool = false
var _enemy_dead: bool = false

func setup(p_hp: int, e_hp: int) -> void:
	player_health = p_hp
	enemy_health = e_hp
	_player_dead = false
	_enemy_dead = false
	health_changed.emit(false, player_health)
	health_changed.emit(true, enemy_health)

func apply_damage(is_enemy: bool, amount: int) -> void:
	if is_enemy:
		enemy_health -= amount
	else:
		player_health -= amount
	damaged.emit(is_enemy, amount)
	health_changed.emit(is_enemy, enemy_health if is_enemy else player_health)
	# 死亡只发一次
	if is_enemy and not _enemy_dead and enemy_health <= 0:
		_enemy_dead = true
		hero_died.emit(true)
	elif not is_enemy and not _player_dead and player_health <= 0:
		_player_dead = true
		hero_died.emit(false)
