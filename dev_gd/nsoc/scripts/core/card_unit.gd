class_name CardUnit
extends CardBase

# health 以单位视角的 side 存储：{front, back, left, right}
# - front = 面向敌人那一面（玩家:top / 敌方:bottom）
# - back  = 背向敌人那一面
# - left / right = 单位自身视角的左右
# JSON 中仍以玩家视角 top/bottom/left/right 书写，DataLoader 入库时转换。
var attack: int = 0
var health: Dictionary = {"front": 0, "back": 0, "left": 0, "right": 0}

func _init(n: String, c: int, atk: int, hp: Dictionary, e: Array = []):
	super(n, "单位", c, e)
	attack = atk
	health = hp
