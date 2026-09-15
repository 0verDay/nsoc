extends Node

## headless 多棋盘 PVE 冒烟（重构文档.md §7 的"第二条黄金路径"）。
##
## 与 HeadlessBattle 的区别：
##   - HeadlessBattle 跑 Main.tscn（单盘战役路径，不接 AI）
##   - 本场景跑 TestMain.tscn 的**非 PVP** 分支（多棋盘测试关卡 + AI 敌人），
##     覆盖跨棋盘阶段、附盘、AI 出牌 —— 也就是 main/test_main 合一时最容易踩坏的那部分
##
## 运行：
##   godot --headless --path dev_gd/nsoc res://tests/HeadlessTestBattle.tscn \
##         -- --turns=2 --seed=20260101 --watchdog=180
##
## 输出：
##   BOOT_TESTBATTLE slots=N
##   TESTBATTLE_TURN <回合> <hash>
##   STATE_HASH <hash>
##   TESTBATTLE_RESULT PASS|FAIL <说明>
##
## headless 决策器：多棋盘下玩家单位到达前排会弹"选目标盘"界面并 await 玩家点击
## （turn_system._run_front_row_selection）。无头环境没人点，因此本 harness 订阅
## front_row_action_requested 并**确定性地**选第一个敌队盘 —— 这正是服务器权威
## 将来要用 auth/request_choice 做的事（此处先建立可复现的替身）。

const DEFAULT_TURNS := 2
const DEFAULT_SEED := 20260101
const BOOT_TIMEOUT_MSEC := 90000
const DEFAULT_WATCHDOG_SEC := 300

var _turns: int = DEFAULT_TURNS
var _seed: int = DEFAULT_SEED
var _watchdog_sec: int = DEFAULT_WATCHDOG_SEC
var _instant: bool = false   # --instant：跳过动画等待（服务器模式）
var _front_row_resolved_count: int = 0
var _fail: String = ""


func _ready() -> void:
	_parse_args()
	print("[headless-testbattle] turns=%d seed=%d" % [_turns, _seed])
	seed(_seed)
	_start_watchdog()
	await _run()
	_finish()


func _parse_args() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--turns="):
			_turns = int(a.split("=")[1])
		elif a.begins_with("--seed="):
			_seed = int(a.split("=")[1])
		elif a.begins_with("--watchdog="):
			_watchdog_sec = int(a.split("=")[1])
		elif a.begins_with("--instant"):
			_instant = true


func _start_watchdog() -> void:
	await get_tree().create_timer(float(_watchdog_sec)).timeout
	print("WATCHDOG_TIMEOUT %d" % _watchdog_sec)
	print("TESTBATTLE_RESULT FAIL 看门狗强制退出（%d 秒）" % _watchdog_sec)
	get_tree().quit(2)


func _run() -> void:
	# TestMain 的非 PVP 分支：is_pvp=false 时它会自行装载多棋盘测试关卡
	Game.is_pvp = false
	Game.pending_chapter_config = ""
	Game.pending_level_path = ""
	Game.pending_battle_seed = _seed
	Game.instant_battle = _instant
	print("INSTANT %d" % (1 if _instant else 0))
	if Game.get("pending_empire_battle") != null:
		Game.pending_empire_battle = {}
	if Game.get("empire_state") != null:
		Game.empire_state = {}

	var scene: PackedScene = load("res://scenes/TestMain.tscn")
	if scene == null:
		_fail = "无法加载 res://scenes/TestMain.tscn"
		return
	var main: Node = scene.instantiate()
	add_child(main)

	if not await _wait_booted():
		_fail = "装配超时（%d ms 内仍无 slot）" % BOOT_TIMEOUT_MSEC
		return
	print("BOOT_TESTBATTLE slots=%d" % Game.registry.slots.size())
	if Game.registry.slots.size() < 2:
		_fail = "多棋盘路径应装配出多个盘，实际 %d" % Game.registry.slots.size()
		return

	if not await _wait_intro_finished(main):
		_fail = "入场动画超时"
		return

	# headless 决策器（多棋盘选盘）
	if not Game.turn.front_row_action_requested.is_connected(_on_front_row_requested):
		Game.turn.front_row_action_requested.connect(_on_front_row_requested)

	print("TESTBATTLE_TURN 0 %s" % StateHash.compute())
	for i in range(1, _turns + 1):
		await Game.turn.run()
		print("TESTBATTLE_TURN %d %s" % [i, StateHash.compute()])

	print("STATE_HASH %s" % StateHash.compute())
	print("FRONT_ROW_RESOLVED %d" % _front_row_resolved_count)
	print("STATE_SUMMARY\n%s" % StateHash.summary())


## 确定性选盘：第一个敌队盘（与 FrontRowSelector 在"只有一个候选"时的行为一致）。
func _on_front_row_requested(_cell) -> void:
	_front_row_resolved_count += 1
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


func _wait_intro_finished(main: Node) -> bool:
	var deadline: int = Time.get_ticks_msec() + BOOT_TIMEOUT_MSEC
	for _i in range(5):
		await get_tree().process_frame
	while Time.get_ticks_msec() < deadline:
		if main.get_node_or_null("IntroInputBlocker") == null and main.visible:
			await get_tree().process_frame
			await get_tree().process_frame
			return true
		await get_tree().process_frame
	return false


func _finish() -> void:
	if _fail == "":
		print("TESTBATTLE_RESULT PASS")
		get_tree().quit(0)
	else:
		print("TESTBATTLE_RESULT FAIL %s" % _fail)
		get_tree().quit(1)
