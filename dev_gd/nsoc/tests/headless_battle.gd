extends Node

## headless 对局冒烟 + 状态哈希（重构文档.md §7 阶段 0「安全网」）。
##
## 运行方式：
##   godot --headless --path dev_gd/nsoc res://tests/HeadlessBattle.tscn \
##         -- --turns=3 --chapter=res://data/chapters/smoke_test.json --seed=20260101
##
## 输出（stdout，便于 CI 解析）：
##   BOOT slots=N
##   TURN_HASH <回合> <hash>
##   STATE_HASH <hash>
##   STATE_SUMMARY <多行摘要>
##   SMOKE_RESULT PASS|FAIL <说明>
##
## 设计说明：
##   - 复用真实的 Main.tscn 装配流程（即服务器将来要跑的同一套代码），不另写一套装配
##   - 用 pending_chapter_config 走"章节固定牌堆"路径，避免读取 user:// 玩家牌组导致不可复现
##   - 固定全局 RNG 种子：PVE 路径仍有裸 randi()/Array.shuffle()，靠种子保证可复现
##   - 等装配与入场动画都结束后再开始跑回合，避免与动画协程交错
##
## 踩坑记录（重构文档.md 附录会收录）：
##   1. 全新副本必须先跑一次 `--import` 建立 .godot/global_script_class_cache.cfg，
##      否则所有 class_name 类型解析失败，一大串 "Could not find type" 假报错。
##   2. 协程 run() 是 `-> void`：`_state = Game.turn.run()` 会直接解析失败
##      （"Cannot get return value of call to run()"）。必须 `await Game.turn.run()`。
##   3. 脚本解析失败时场景根节点无脚本，Godot 会空转且永不退出 —— 因此外层 runner
##      必须有进程级超时兜底，不能只依赖脚本内的看门狗。

const DEFAULT_CHAPTER := "res://data/chapters/smoke_test.json"
const DEFAULT_TURNS := 3
const DEFAULT_SEED := 20260101
const BOOT_TIMEOUT_MSEC := 60000      # 装配 + 入场动画的总超时
const DEFAULT_WATCHDOG_SEC := 300     # 全局看门狗：无论如何 N 秒后强制退出

var _turns: int = DEFAULT_TURNS
var _chapter: String = DEFAULT_CHAPTER
var _seed: int = DEFAULT_SEED
var _watchdog_sec: int = DEFAULT_WATCHDOG_SEC
var _turn_active: bool = false
var _turn_start_ms: int = 0
var _fail: String = ""


func _ready() -> void:
	_parse_args()
	print("[headless] chapter=%s turns=%d seed=%d" % [_chapter, _turns, _seed])
	seed(_seed)
	_start_watchdog()
	_start_heartbeat()
	await _run()
	_finish()


func _parse_args() -> void:
	for a in OS.get_cmdline_user_args():
		if a.begins_with("--turns="):
			_turns = int(a.split("=")[1])
		elif a.begins_with("--chapter="):
			_chapter = a.split("=", true, 1)[1]
		elif a.begins_with("--seed="):
			_seed = int(a.split("=")[1])
		elif a.begins_with("--watchdog="):
			_watchdog_sec = int(a.split("=")[1])


## 看门狗（独立协程，与回合循环并发）：保证进程一定退出。
func _start_watchdog() -> void:
	await get_tree().create_timer(float(_watchdog_sec)).timeout
	print("WATCHDOG_TIMEOUT %d" % _watchdog_sec)
	print("SMOKE_RESULT FAIL 看门狗强制退出（%d 秒）" % _watchdog_sec)
	get_tree().quit(2)


## 心跳（独立协程）：卡住时用于定位等待点（headless 下没有栈，只能靠状态推断）。
func _start_heartbeat() -> void:
	while true:
		await get_tree().create_timer(2.0).timeout
		if _turn_active:
			_heartbeat(Time.get_ticks_msec() - _turn_start_ms)


func _heartbeat(elapsed_msec: int) -> void:
	var turn: Object = Game.turn
	print("[hb] %5.1fs turn_number=%s is_running=%s front_resolved=%s front_result='%s' aborted=%s" % [
		float(elapsed_msec) / 1000.0,
		str(turn.get("turn_number")),
		str(turn.get("is_running")),
		str(turn.get("_front_row_resolved")),
		str(turn.get("_front_row_result")),
		str(Game.combat.aborted if Game.combat != null else "n/a"),
	])


func _run() -> void:
	# 进入 PVE 战役装配路径（固定牌堆 + 不接 AI），保证可复现
	Game.is_pvp = false
	Game.pending_level_path = ""
	Game.pending_chapter_config = _chapter
	if Game.get("pending_empire_battle") != null:
		Game.pending_empire_battle = {}
	if Game.get("empire_state") != null:
		Game.empire_state = {}

	var main_scene: PackedScene = load("res://scenes/Main.tscn")
	if main_scene == null:
		_fail = "无法加载 res://scenes/Main.tscn"
		return
	var main: Node = main_scene.instantiate()
	add_child(main)

	if not await _wait_booted():
		_fail = "装配超时（%d ms 内 Game.registry 仍无 slot）" % BOOT_TIMEOUT_MSEC
		return
	print("BOOT slots=%d" % Game.registry.slots.size())
	print("BATTLE_MODE %s" % BattleMode.name_of(Game.battle_mode))
	if Game.battle_mode != BattleMode.Kind.CAMPAIGN:
		_fail = "冒烟章节应判定为 CAMPAIGN 模式，实际 %s" % BattleMode.name_of(Game.battle_mode)
		return

	if not await _wait_intro_finished(main):
		_fail = "入场动画超时（IntroInputBlocker 未被释放）"
		return

	print("TURN_HASH 0 %s" % StateHash.compute())
	for i in range(1, _turns + 1):
		if Game.turn == null:
			_fail = "Game.turn 为空"
			return
		_turn_start_ms = Time.get_ticks_msec()
		_turn_active = true
		await Game.turn.run()          # 协程必须 await（见文件头踩坑记录 2）
		_turn_active = false
		print("TURN_HASH %d %s" % [i, StateHash.compute()])

	print("STATE_HASH %s" % StateHash.compute())
	print("STATE_SUMMARY\n%s" % StateHash.summary())


func _wait_booted() -> bool:
	var deadline: int = Time.get_ticks_msec() + BOOT_TIMEOUT_MSEC
	while Time.get_ticks_msec() < deadline:
		if Game.registry != null and Game.registry.slots.size() > 0 and Game.turn != null:
			return true
		await get_tree().process_frame
	return false


## 等入场动画结束：main.gd 在动画开始时加 IntroInputBlocker，结束时 queue_free。
func _wait_intro_finished(main: Node) -> bool:
	var deadline: int = Time.get_ticks_msec() + BOOT_TIMEOUT_MSEC
	# 先确保动画已开始（避免"还没开始就判定已结束"）
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
		print("SMOKE_RESULT PASS")
		get_tree().quit(0)
	else:
		print("SMOKE_RESULT FAIL %s" % _fail)
		get_tree().quit(1)
