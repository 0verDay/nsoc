class_name CardBase
extends RefCounted

var name: String = ""
var type: String = ""
var cost: int = 0
var effects: Array = []
var count: int = 1

func _init(n: String, t: String, c: int, e: Array = []):
	name = n
	type = t
	cost = c
	effects = e
