class_name EffectContext
extends RefCounted

# 传给 Effect.on_play / on_death 的轻量门面。
# 把"main_node 万能上帝对象"替换为受限接口，便于测试与替换实现。
#
# 旧代码中 effect 直接读写 main_node.banished / main_node.autophagy_counter，
# 现在改为通过 ctx 调用 banish_card() / get_counter() 等显式 API。

var game: Node                       # GameContext 引用

func _init(p_game: Node) -> void:
	game = p_game

# ---- 卡牌去向 ----
func banish_card(card_data) -> void:
	game.deck.banish(card_data)

func send_to_graveyard(card_data) -> void:
	game.deck.send_to_graveyard(card_data)

# ---- 英雄伤害 ----
func damage_player_hero(amount: int) -> void:
	game.hero.apply_damage(false, amount)

func damage_enemy_hero(amount: int) -> void:
	game.hero.apply_damage(true, amount)

# ---- 通用计数器（替代 main.autophagy_counter 这种零散字段） ----
func get_counter(key: String, default_value: int = 0) -> int:
	return game.counters.get(key, default_value)

func set_counter(key: String, value: int) -> void:
	game.counters[key] = value

func inc_counter(key: String, delta: int = 1) -> int:
	var v = get_counter(key, 0) + delta
	game.counters[key] = v
	return v
