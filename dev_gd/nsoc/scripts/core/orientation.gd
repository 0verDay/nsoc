class_name Orientation
extends RefCounted

# 阵营领域 ↔ 屏幕绝对方向 的映射工具。
#
# 概念：
#   side（阵营领域）：单位自身视角的 front / back / left / right
#       - front = 朝向敌人那一面
#       - back  = 背向敌人那一面
#       - left  = 单位自身视角的左
#       - right = 单位自身视角的右
#   abs（屏幕绝对方向）：top / bottom / left / right （屏幕坐标系）
#
# 玩家朝上方向战斗（front=top, back=bottom, left=left, right=right）；
# 敌方朝下方向战斗（front=bottom, back=top, left=right, right=left）。
#
# 项目内规约：
#   - JSON 单位定义 health 仍以玩家视角 top/bottom/left/right 书写（作者直觉）。
#       DataLoader 读入后调 player_abs_to_side 转换为 side（front/back/left/right）。
#   - CardUnit.health / cell.health 一律以 side 存储。
#   - BoardModel.find_adjacent_enemies / TurnSystem / FrontRowSelector 等
#       面向"棋盘相对位置"的逻辑仍使用 abs（top/bottom/left/right）。
#       CombatSystem 在扣血 / 死亡判定时通过本工具转为 defender 的 side。

const SIDES := ["front", "back", "left", "right"]
const ABS_DIRS := ["top", "bottom", "left", "right"]

# side → abs，按阵营选取
static func side_to_abs(side: String, is_enemy: bool) -> String:
	if is_enemy:
		match side:
			"front": return "bottom"
			"back":  return "top"
			"left":  return "right"
			"right": return "left"
	else:
		match side:
			"front": return "top"
			"back":  return "bottom"
			"left":  return "left"
			"right": return "right"
	return side

# abs → side，按阵营选取
static func abs_to_side(abs_dir: String, is_enemy: bool) -> String:
	if is_enemy:
		match abs_dir:
			"top":    return "back"
			"bottom": return "front"
			"left":   return "right"
			"right":  return "left"
	else:
		match abs_dir:
			"top":    return "front"
			"bottom": return "back"
			"left":   return "left"
			"right":  return "right"
	return abs_dir

# 玩家视角 abs（top/bottom/left/right）→ side。
# 用于 JSON 读入：JSON 作者按玩家视角写 health。
# 等价于 abs_to_side(abs_dir, false)。
static func player_abs_to_side(abs_dir: String) -> String:
	return abs_to_side(abs_dir, false)

# 把以玩家视角 abs key 写的 health dict 转换为 side key。
# {top, bottom, left, right} → {front, back, left, right}
static func health_player_abs_to_side(hp: Dictionary) -> Dictionary:
	return {
		"front": int(hp.get("top", 0)),
		"back":  int(hp.get("bottom", 0)),
		"left":  int(hp.get("left", 0)),
		"right": int(hp.get("right", 0)),
	}

# 复制一份 side health dict（避免引用共享）
static func clone_side_health(hp: Dictionary) -> Dictionary:
	return {
		"front": int(hp.get("front", 0)),
		"back":  int(hp.get("back", 0)),
		"left":  int(hp.get("left", 0)),
		"right": int(hp.get("right", 0)),
	}
