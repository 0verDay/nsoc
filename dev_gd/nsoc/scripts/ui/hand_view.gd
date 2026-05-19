class_name HandView
extends Node

# 手牌渲染。原 main.ensure_min_hand_size 迁移于此。

signal hand_card_long_press_requested(card_data)
signal hand_card_long_press_canceled

const MIN_HAND_SIZE: int = 5

var _container: Container
var _hand_card_scene: PackedScene
var _card_counter: int = 1

func setup(container: Container, hand_card_scene: PackedScene) -> void:
	_container = container
	_hand_card_scene = hand_card_scene

func ensure_min_hand_size() -> void:
	while _container.get_child_count() < MIN_HAND_SIZE:
		var data = Game.deck.draw_card()
		if data == null:
			# 牌库 + 墓地都空：补虚空卡（带 autophagy）
			data = CardSpell.new("虚空", 1, ["autophagy"])
		var c = _hand_card_scene.instantiate()
		_container.add_child(c)
		c.setup(data, _card_counter)
		# cell/hand_card 通过信号上报长按
		if c.has_signal("long_press_requested"):
			c.long_press_requested.connect(func(d): hand_card_long_press_requested.emit(d))
		if c.has_signal("long_press_canceled"):
			c.long_press_canceled.connect(func(): hand_card_long_press_canceled.emit())
		_card_counter += 1
