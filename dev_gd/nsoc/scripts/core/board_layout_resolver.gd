class_name BoardLayoutResolver
extends RefCounted

# PVP 棋盘布局解析器（1v1 / 1v3）。
#
# 输入：viewer_pid（本端玩家 uuid）+ slot_layout（来自 bootstrap_pvp）
# 输出：
#   main_ui_slots  : Array of slot_id —— 这些盘应使用现有场景树 UI 节点（bottom/top）
#   side_slot_ids  : Array of slot_id —— 其余盘使用动态 side board UI
#   local_slot_id  : 本端玩家的盘 id
#   top_slot_id    : 顶部主对手盘 id（1v1 唯一对手；1v3 守方→第一个攻方盘，攻方→守方盘）
#   extra_top_ids  : 1v3 守方时额外的 2 个攻方盘（side board，位于 top 区域左右）
#
# 1v3 布局规则：
#   守方视角：bottom = 自己，top_center = 攻方中，top_left/top_right = 攻方左/右
#   攻方视角：bottom = 自己，top_center = 守方，side_left/side_right = 队友左/右

var local_slot_id:   String = ""
var top_slot_id:     String = ""
var extra_top_ids:   Array  = []   # 1v3 守方额外的 2 个攻方盘（按大厅顺序：左/右）
var side_slot_ids:   Array  = []   # 动态 side board 盘 id

func resolve(viewer_pid: String, slot_layout: Array) -> void:
	local_slot_id = ""
	top_slot_id   = ""
	extra_top_ids = []
	side_slot_ids = []

	if slot_layout.is_empty():
		return

	# 找本端 slot
	var my_entry: Dictionary = {}
	for entry in slot_layout:
		if String(entry.get("owner_pid", "")) == viewer_pid:
			my_entry = entry
			break
	if my_entry.is_empty():
		return

	local_slot_id = String(my_entry.get("slot_id", ""))
	var my_team: String = String(my_entry.get("team_id", ""))

	# 收集对手盘（按 slot_index 排序）
	var opponent_entries: Array = []
	for entry in slot_layout:
		var pid: String = String(entry.get("owner_pid", ""))
		if pid == viewer_pid:
			continue
		var tid: String = String(entry.get("team_id", ""))
		if tid != my_team:
			opponent_entries.append(entry)
	opponent_entries.sort_custom(func(a, b): return int(a.get("slot_index", 0)) < int(b.get("slot_index", 0)))

	# 1v3 守方 (defender)：3 个对手盘
	#   top_slot_id   = 攻方中（slot_index 居中，或取第二个，即 index=2）
	#   extra_top_ids = 攻方左（index=1）和右（index=3），作为附盘
	if my_team == "defender" and opponent_entries.size() >= 3:
		# slot_index: 1=攻左, 2=攻中, 3=攻右；按 slot_index 排列
		top_slot_id = String(opponent_entries[1].get("slot_id", ""))  # 中间（index=2）
		extra_top_ids = [
			String(opponent_entries[0].get("slot_id", "")),  # 左（index=1）
			String(opponent_entries[2].get("slot_id", "")),  # 右（index=3）
		]
	elif opponent_entries.size() >= 1:
		# 1v1 或 攻方视角（1 个守方 + 2 个队友，队友不互为对手）
		# 1v3 攻方：对手只有守方 1 盘
		top_slot_id = String(opponent_entries[0].get("slot_id", ""))
		# 1v3 攻方的队友盘（same team）作为 side boards
		for entry in slot_layout:
			var pid: String = String(entry.get("owner_pid", ""))
			if pid == viewer_pid:
				continue
			var tid: String = String(entry.get("team_id", ""))
			if tid == my_team:   # 同队友
				side_slot_ids.append(String(entry.get("slot_id", "")))
