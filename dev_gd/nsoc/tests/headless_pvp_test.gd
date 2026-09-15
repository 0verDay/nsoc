extends Node

## headless PVP 三路径冒烟（1v1 / 1v3 / 3v3）—— 重构文档.md §7 验收表「五条路径全流程冒烟」的 PVP 三条。
##
## 走的是**真实入口链**（不另写一套装配代码）：
##   大厅组装的 game/start 载荷
##     → `PvpStart.resolve()`（与 SparringPanel 同一份解析）
##     → `Game.bootstrap_pvp()`
##     → `res://scenes/TestMain.tscn`（真实战斗场景脚本）
## 远端玩家用"确定性替身"驱动：按协议格式把 `action/*` 消息喂进 `_handle_pvp_message()`，
## 因此覆盖：装配（盘/归属/队伍）、本端出牌、远端出牌镜像、单位行动与跨盘攻击、回合轮转、最终状态哈希。
##
## 运行：
##   godot --headless --path dev_gd/nsoc res://tests/HeadlessPvp.tscn -- --turns=2 --seed=20260101
##
## 输出：
##   PVP_CASE PASS|FAIL <案例> <说明>
##   PVP_TURN <案例> <轮次> active=<pid> hash=<hash>
##   PVP_HASH <案例> <hash>
##   PVP_RESULT PASS|FAIL passed=N failed=M

const DEFAULT_TURNS := 2
const DEFAULT_SEED := 20260101
const DEFAULT_WATCHDOG_SEC := 300
const BOOT_TIMEOUT_MSEC := 90000

const LOCAL_PID := "p1"
const UNIT_CARD := "填线宝宝"     # cost 1 / 1-1-1-1 / 无效果 —— 确定性最好的出牌素材
const DECK_SIZE := 12
const HERO_KEY := "A"

const CASES: Array = [
	{"name": "1v1", "match_type": "1v1", "pids": ["p1", "p2"]},
	{"name": "1v3", "match_type": "1v3", "pids": ["p1", "p2", "p3", "p4"]},
	{"name": "3v3", "match_type": "3v3", "pids": ["p1", "p2", "p3", "p4", "p5", "p6"]},
]

var _turns: int = DEFAULT_TURNS
var _seed: int = DEFAULT_SEED
var _watchdog_sec: int = DEFAULT_WATCHDOG_SEC
var _instant: bool = false
var _only: String = ""
var _passed: int = 0
var _failed: int = 0
var _front_row_resolved: int = 0
var _main: Node = null


func _ready() -> void:
	_parse_args()
	print("[headless-pvp] turns=%d seed=%d instant=%d" % [_turns, _seed, 1 if _instant else 0])
	_start_watchdog()
	for c in CASES:
		var cname: String = String(c["name"])
		if _only != "" and cname != _only:
			continue
		await _run_case(c)
	_finish()


func _parse_args() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--turns="):
			_turns = int(a.split("=")[1])
		elif a.begins_with("--seed="):
			_seed = int(a.split("=")[1])
		elif a.begins_with("--watchdog="):
			_watchdog_sec = int(a.split("=")[1])
		elif a.begins_with("--case="):
			_only = a.split("=")[1]
		elif a.begins_with("--instant"):
			_instant = true


func _start_watchdog() -> void:
	await get_tree().create_timer(float(_watchdog_sec)).timeout
	print("WATCHDOG_TIMEOUT %d" % _watchdog_sec)
	print("PVP_RESULT FAIL passed=%d failed=%d 看门狗强制退出" % [_passed, _failed])
	get_tree().quit(2)


# ── 单个案例 ──────────────────────────────────────────────────────────────

func _run_case(c: Dictionary) -> void:
	var cname: String = String(c["name"])
	var match_type: String = String(c["match_type"])
	var pids: Array = c["pids"]
	print("PVP_BEGIN %s pids=%s" % [cname, str(pids)])

	await _teardown()
	_ensure_card_db()

	# 大厅组装的 game/start 载荷 → 真实解析入口
	var payload: Dictionary = _build_start_payload(match_type, pids)
	var cfg: Dictionary = PvpStart.resolve(payload, LOCAL_PID,
		[UNIT_CARD], HERO_KEY, Game.card_db, [])
	_check(cname, not bool(cfg["local_deck_fallback"]), "载荷带本端牌组（未走本地兜底）")
	_check(cname, int(cfg["rng_seed"]) == _seed, "随机种子取自载荷")
	_check(cname, String(cfg["match_type"]) == match_type, "对阵类型取自载荷")

	Game.is_pvp = true
	Game.instant_battle = _instant
	Game.pending_battle_seed = _seed
	Game.bootstrap_pvp(LOCAL_PID, cfg["order"], cfg["per_player_deck_cards"], [],
		int(cfg["rng_seed"]), cfg["per_player_heroes"], String(cfg["match_type"]), {},
		cfg["slot_layout"])

	var scene := load("res://scenes/TestMain.tscn") as PackedScene
	if scene == null:
		_check(cname, false, "无法加载 res://scenes/TestMain.tscn")
		return
	_main = scene.instantiate()
	add_child(_main)
	if not await _wait_booted():
		_check(cname, false, "装配超时（%d ms 内仍无 slot）" % BOOT_TIMEOUT_MSEC)
		return
	if not await _wait_intro_finished(_main):
		_check(cname, false, "入场动画超时")
		return

	_check_assembly(cname, match_type, pids)

	if not Game.turn.front_row_action_requested.is_connected(_on_front_row_requested):
		Game.turn.front_row_action_requested.connect(_on_front_row_requested)

	# ── 逐轮：本端出牌 → 结束回合 → 远端逐个出牌 + 结束回合 ──
	var turn_before: int = int(Game.turn.turn_number)
	for round_i in range(1, _turns + 1):
		if not Game.pvp_is_my_turn():
			_check(cname, false, "第 %d 轮开始时不是本端回合" % round_i)
			break
		var col: int = (round_i - 1) % BoardModel.COLS
		var remote_col: int = round_i % BoardModel.COLS
		await _local_play(cname, round_i, col)
		var btn: Button = _main.end_turn_btn
		_check(cname, not btn.disabled, "第 %d 轮本端结束回合按钮可点" % round_i)
		await _main._on_end_turn_pressed()

		var remotes: int = 0
		while not Game.pvp_is_my_turn() and remotes <= pids.size():
			var active: String = Game.pvp_active_player_id()
			await _remote_play(cname, active, remote_col)
			await _main._handle_pvp_message({
				"type": "action/end_turn", "from": active,
				"payload": {"player_id": active},
			})
			remotes += 1
		_check(cname, Game.pvp_is_my_turn(), "第 %d 轮远端全部结束后回到本端" % round_i)
		_check(cname, remotes == pids.size() - 1,
			"第 %d 轮远端玩家数 = %d" % [round_i, pids.size() - 1])
		print("PVP_TURN %s %d active=%s hash=%s" % [
			cname, round_i, Game.pvp_active_player_id(), StateHash.compute()])

	# 1v1 的 v1 锁步路径不推进 turn_number（只有多队伍分支在整轮结束时 +1）——
	# 这里如实固化现状，改动它会先让本冒烟失败。
	var want_turns: int = turn_before if match_type == "1v1" else turn_before + _turns
	_check(cname, int(Game.turn.turn_number) == want_turns,
		"回合计数 %d（期望 %d）" % [int(Game.turn.turn_number), want_turns])

	print("PVP_HASH %s %s" % [cname, StateHash.compute()])
	print("PVP_SUMMARY %s\n%s" % [cname, StateHash.summary()])


## 装配断言：盘数 / 归属 / 队伍 / 本端盘可部署。
func _check_assembly(cname: String, match_type: String, pids: Array) -> void:
	_check(cname, Game.registry != null and Game.registry.slots.size() == pids.size(),
		"盘数 = 玩家数（%d）" % pids.size())
	var local_slot: BoardSlot = Game.registry.by_owner(LOCAL_PID)
	_check(cname, local_slot != null and local_slot.allow_player_deploy, "本端盘存在且可部署")
	if match_type == "1v1":
		_check(cname, Game.registry.get_by_id("player_main") != null \
			and Game.registry.get_by_id("enemy_main") != null, "1v1 双主盘装配")
	for pid_raw in pids:
		var pid: String = String(pid_raw)
		var slot: BoardSlot = Game.registry.by_owner(pid)
		if slot == null:
			_check(cname, false, "玩家 %s 没有对应盘" % pid)
			continue
		if match_type == "1v3":
			var want: String = "defender" if pid == LOCAL_PID else "attacker"
			_check(cname, slot.team_id == want, "%s 队伍 = %s" % [pid, want])
		elif match_type == "3v3":
			var want2: String = "team_a" if pids.find(pid) < 3 else "team_b"
			_check(cname, slot.team_id == want2, "%s 队伍 = %s" % [pid, want2])
	_check(cname, Game.hero_specs.size() == pids.size(),
		"英雄规格 = 玩家数（%d）" % pids.size())


# ── 出牌（本端走真实拖拽字典；远端走协议消息）──────────────────────────────

func _local_play(cname: String, round_i: int, _col: int) -> void:
	var hand_card: Node = _find_unit_hand_card(_main)
	_check(cname, hand_card != null, "第 %d 轮手牌里有可出单位" % round_i)
	if hand_card == null:
		return
	var card = hand_card.card_data
	var local_slot: BoardSlot = Game.registry.by_owner(LOCAL_PID)
	# 前排优先（朝向对手）：1v1 玩家盘与多队伍盘的前排都是 row 0；前排被占就往后排找
	var spot: Vector2 = _pick_local_cell(local_slot)
	_check(cname, spot.x >= 0, "第 %d 轮本端有空格可部署" % round_i)
	if spot.x < 0:
		return
	var target = local_slot.board.get_cell(spot)
	_check(cname, target != null and not target.has_card,
		"第 %d 轮本端落点 (%d,%d) 为空" % [round_i, int(spot.x), int(spot.y)])
	if target == null or target.has_card:
		return
	var mana_before: int = int(Game.mana.current)
	var cost: int = int(card.cost)
	await _main.play_controller.handle_drop(target, {
		"type": card.type, "cost": cost, "card_name": card.name,
		"source_card": hand_card, "full_data": card,
		"attack": card.attack, "health": Orientation.clone_side_health(card.health),
	})
	_check(cname, target.has_card and String(target.card_name) == String(card.name),
		"第 %d 轮本端单位落子到 (%d,%d)" % [round_i, int(spot.x), int(spot.y)])
	_check(cname, int(Game.mana.current) == mana_before - cost,
		"第 %d 轮本端费用按牌面扣除（%d → %d）" % [round_i, mana_before, int(Game.mana.current)])


func _remote_play(cname: String, pid: String, _col: int) -> void:
	if pid == "" or pid == LOCAL_PID:
		return
	var slot: BoardSlot = Game.registry.by_owner(pid)
	if slot == null:
		_check(cname, false, "远端 %s 无对应盘" % pid)
		return
	var multi: bool = Game.is_multi_team_pvp()
	# 在**发送方视角**里前排优先找空格（1v1 下本端读同一格要按镜像索引）
	var spot: Vector2 = _pick_sender_cell(slot, multi)
	_check(cname, spot.x >= 0, "远端 %s 有空格可出牌" % pid)
	if spot.x < 0:
		return
	var payload: Dictionary = {"card_name": UNIT_CARD, "card_type": "单位"}
	var expect_row: int
	var expect_col: int
	if multi:
		# 多队伍：绝对坐标 + 接收端 registry 里同名的 slot_id（所有盘前排 = row 0）
		payload["slot_id"] = String(slot.id)
		payload["abs_row"] = int(spot.x)
		payload["abs_col"] = int(spot.y)
		expect_row = int(spot.x)
		expect_col = int(spot.y)
	else:
		# 1v1：载荷用发送方视角（对方看自己也是 player_main），接收端按镜像翻转
		payload["slot_id"] = "player_main"
		payload["row"] = int(spot.x)
		payload["col"] = int(spot.y)
		expect_row = (BoardModel.ROWS - 1) - int(spot.x)
		expect_col = (BoardModel.COLS - 1) - int(spot.y)
	await _main._handle_pvp_message({
		"type": "action/play_card", "from": pid, "payload": payload,
	})
	var cell = slot.board.get_cell(Vector2(expect_row, expect_col))
	_check(cname, cell != null and cell.has_card,
		"远端 %s 单位镜像到其盘 (%d,%d)" % [pid, expect_row, expect_col])
	if cell == null or not cell.has_card:
		_dump_slot(cname, slot)


## 本端视角：前排优先找一个空格（row = front_row_of_slot，再依次往后排）。
func _pick_local_cell(slot: BoardSlot) -> Vector2:
	var front: int = BoardModel.front_row_of_slot(slot)
	var rows: Array = [front]
	for r in range(BoardModel.ROWS):
		if r != front:
			rows.append(r)
	for r in rows:
		for c in range(BoardModel.COLS):
			var cell = slot.board.get_cell(Vector2(r, c))
			if cell != null and not cell.has_card:
				return Vector2(r, c)
	return Vector2(-1, -1)


## 发送方视角：前排优先找一个空格。multi=多队伍（绝对坐标，无需镜像）。
func _pick_sender_cell(slot: BoardSlot, multi: bool) -> Vector2:
	for r in range(BoardModel.ROWS):
		for c in range(BoardModel.COLS):
			var rr: int = r if multi else (BoardModel.ROWS - 1) - r
			var cc: int = c if multi else (BoardModel.COLS - 1) - c
			var cell = slot.board.get_cell(Vector2(rr, cc))
			if cell != null and not cell.has_card:
				return Vector2(r, c)
	return Vector2(-1, -1)


## 排障用：打印某盘的逐格内容（断言失败时才知道镜像到底落哪了）。
func _dump_slot(cname: String, slot: BoardSlot) -> void:
	for r in range(BoardModel.ROWS):
		var row_txt: Array = []
		for c in range(BoardModel.COLS):
			var cell = slot.board.get_cell(Vector2(r, c))
			if cell == null:
				row_txt.append("(null)")
			elif cell.has_card:
				row_txt.append("[%s@%s]" % [String(cell.card_name), String(cell.owner_slot_id)])
			else:
				row_txt.append(".")
		print("PVP_DUMP %s %s row%d %s" % [cname, String(slot.id), r, " ".join(row_txt)])


# ── 载荷 / 环境 ───────────────────────────────────────────────────────────

## 组装大厅 `_on_start_game()` 会发出的那份 game/start 载荷（顺序/布局确定化）。
func _build_start_payload(match_type: String, pids: Array) -> Dictionary:
	var decks: Dictionary = {}
	var heroes: Dictionary = {}
	for pid_raw in pids:
		var names: Array = []
		for _i in range(DECK_SIZE):
			names.append(UNIT_CARD)
		decks[String(pid_raw)] = names
		heroes[String(pid_raw)] = HERO_KEY

	var order: Array = []
	var layout: Array = []
	if match_type == "1v3":
		# 房主 = defender（首位），其余 3 人 attacker
		for pid_raw in pids:
			order.append(String(pid_raw))
		for i in range(order.size()):
			layout.append({
				"slot_id": "slot_" + String(order[i]), "owner_pid": String(order[i]),
				"team_id": "defender" if i == 0 else "attacker", "slot_index": i,
			})
	elif match_type == "3v3":
		# 前 3 人 team_a、后 3 人 team_b；行动顺序 A1→B1→A2→B2→A3→B3
		var team_a: Array = [pids[0], pids[1], pids[2]]
		var team_b: Array = [pids[3], pids[4], pids[5]]
		for i in range(3):
			order.append(String(team_a[i]))
			order.append(String(team_b[i]))
		for i in range(3):
			layout.append({
				"slot_id": "slot_" + String(team_a[i]), "owner_pid": String(team_a[i]),
				"team_id": "team_a", "slot_index": i,
			})
		for i in range(3):
			layout.append({
				"slot_id": "slot_" + String(team_b[i]), "owner_pid": String(team_b[i]),
				"team_id": "team_b", "slot_index": 3 + i,
			})
	else:
		for pid_raw in pids:
			order.append(String(pid_raw))

	return {
		"match_type": match_type,
		"action_order": order,
		"per_player_decks": decks,
		"per_player_heroes": heroes,
		"rng_seed": _seed,
		"slot_layout": layout,
		"authoritative": false,
	}


func _ensure_card_db() -> void:
	if not Game.card_db.is_empty():
		return
	for card in DataLoader.load_cards(DataLoader.ALL_CARDS_JSON):
		Game.card_db[card.name] = card


func _teardown() -> void:
	if _main != null and is_instance_valid(_main):
		_main.queue_free()
		await get_tree().process_frame
		await get_tree().process_frame
	_main = null
	Game.is_pvp = false
	Game.v2_authority = false
	if has_node("/root/Net"):
		Net.use_v2 = false
	if has_node("/root/AiManager"):
		AiManager.clear()
	_front_row_resolved = 0


func _find_unit_hand_card(main_node: Node) -> Node:
	var container: Node = main_node.hand_container
	if container == null:
		return null
	for child in container.get_children():
		if child == null or not ("card_data" in child):
			continue
		var cd = child.card_data
		if cd == null:
			continue
		var ctype: String = String(cd.get("type", "") if typeof(cd) == TYPE_DICTIONARY else cd.type)
		if ctype == "单位":
			return child
	return null


## 确定性选盘（与 FrontRowSelector 在只有一个候选盘时一致）。
func _on_front_row_requested(_cell) -> void:
	_front_row_resolved += 1
	var enemy_slots: Array = Game.registry.enemy_targets() if Game.registry != null else []
	if enemy_slots.is_empty():
		Game.turn.resolve_front_row_selection("")
	else:
		Game.turn.resolve_front_row_selection(String(enemy_slots[0].id))


func _wait_booted() -> bool:
	var deadline: int = Time.get_ticks_msec() + BOOT_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		if Game.registry != null and Game.registry.slots.size() > 0 and Game.turn != null:
			return true
		await get_tree().process_frame
	return false


func _wait_intro_finished(main_node: Node) -> bool:
	var deadline: int = Time.get_ticks_msec() + BOOT_TIMEOUT_MSEC
	for _i in range(5):
		await get_tree().process_frame
	while Time.get_ticks_msec() < deadline:
		if main_node.get_node_or_null("IntroInputBlocker") == null and main_node.visible:
			await get_tree().process_frame
			await get_tree().process_frame
			return true
		await get_tree().process_frame
	return false


func _check(cname: String, ok: bool, what: String) -> void:
	if ok:
		_passed += 1
		print("PVP_CASE PASS %s | %s" % [cname, what])
	else:
		_failed += 1
		print("PVP_CASE FAIL %s | %s" % [cname, what])


func _finish() -> void:
	print("PVP_RESULT %s passed=%d failed=%d front_row_resolved=%d" % [
		"PASS" if _failed == 0 else "FAIL", _passed, _failed, _front_row_resolved])
	get_tree().quit(0 if _failed == 0 else 1)
