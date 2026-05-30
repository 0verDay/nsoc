extends Objective

# 坚守 N 回合：玩家需经历 N 次完整回合结算。
# 计算方式：bootstrap 后 turn_number=0；每次 run() 开头 turn_number+=1，结尾发 turn_ended。
# 第 N 次 turn_ended 时（turn_number == N）即视为达成。
# 示例：turns=1 → 玩家第 1 次点结束回合 → run() 完毕 → turn_ended → 1 >= 1 → 胜利。

func id() -> String:
	return "survive_turns"

func description(params: Dictionary) -> String:
	return "坚守 %d 回合" % int(params.get("turns", 1))

func is_completed(params: Dictionary) -> bool:
	if Game == null or Game.turn == null:
		return false
	var n: int = int(params.get("turns", 1))
	# 第 N 次 turn_ended 时 turn_number == N
	return Game.turn.turn_number >= n

func progress_text(params: Dictionary) -> String:
	if Game == null or Game.turn == null:
		return ""
	var n: int = int(params.get("turns", 1))
	var current: int = mini(Game.turn.turn_number, n)
	return "%d / %d" % [current, n]
