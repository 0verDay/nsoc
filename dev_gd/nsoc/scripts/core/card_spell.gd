class_name CardSpell
extends CardBase

# 目标过滤："" 无目标 / "friendly_unit" 任意己方单位 / "enemy_unit" 任意敌方单位 / "any_unit" 任意单位
var target: String = ""

func _init(n: String, c: int, e: Array = [], tgt: String = ""):
	super(n, "法术", c, e)
	target = tgt
