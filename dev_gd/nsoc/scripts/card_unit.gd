class_name CardUnit
extends CardBase

var attack: int = 0
var health: Dictionary = {"top": 0, "bottom": 0, "left": 0, "right": 0}

func _init(n: String, c: int, atk: int, hp: Dictionary, e: Array = []):
	super(n, "单位", c, e)
	attack = atk
	health = hp
