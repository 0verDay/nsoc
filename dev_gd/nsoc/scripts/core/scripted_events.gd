extends Node

# ScriptedEvents —— 战役剧情事件调度器。作为 autoload 单例"Events"。
#
# 处理两类战场事件：
#   1. 回合触发（level_data.board_events[i].actions）
#      在对应回合开始时执行 actions 数组。
#   2. 条件触发（level_data.triggers）
#      满足 when 条件时执行 actions。
#
# Actions 委托给 ActionRegistry（Actions autoload）执行。
# BoardOrchestrator 在 boot() 后调用 Events.set_orchestrator(self)，
# 供 add_board / remove_board action 使用。
#
# 生命周期：
#   Game.bootstrap() 末尾 → Events.setup_for_battle(level_data)
#   每局开始清空旧数据，重新解析，重新接信号。

# ── 状态 ─────────────────────────────────────────────────────────────────

# 从 board_events 提取的"动作型"事件（仅含 actions 字段的条目）
var _board_event_actions: Array = []
# [{turn: int, actions: Array}]

# 触发器列表
var _triggers: Array = []
# [{id, when, once, cooldown, fired, last_fired_turn, actions}]

# BoardOrchestrator 引用，供 add_board / remove_board action 使用
var _orchestrator: Node = null

# ── 公开 API ──────────────────────────────────────────────────────────────

# 战斗启动时调用（Game.bootstrap 末尾）。
# 清空上一局状态，解析本局 level_data，连接 turn_started 信号。
func setup_for_battle(level_data: Dictionary) -> void:
	_board_event_actions.clear()
	_triggers.clear()

	# 解析 board_events.actions
	for ev in level_data.get("board_events", []):
		if typeof(ev) != TYPE_DICTIONARY:
			continue
		var actions = ev.get("actions", [])
		if typeof(actions) != TYPE_ARRAY or (actions as Array).is_empty():
			continue
		_board_event_actions.append({
			"turn":    int(ev.get("turn", -1)),
			"actions": (actions as Array).duplicate(true),
		})

	# 解析 triggers
	for trig in level_data.get("triggers", []):
		if typeof(trig) != TYPE_DICTIONARY:
			continue
		_triggers.append({
			"id":              String(trig.get("id", "")),
			"when":            (trig.get("when", {}) as Dictionary).duplicate(true),
			"once":            bool(trig.get("once", false)),
			"cooldown":        int(trig.get("cooldown", 0)),
			"fired":           false,
			"last_fired_turn": -999,
			"actions":         (trig.get("actions", []) as Array).duplicate(true),
		})

	# 接 turn_started 信号（幂等：已连接则不重复）
	if has_node("/root/Game") and Game.turn != null:
		if not Game.turn.turn_started.is_connected(_on_turn_started):
			Game.turn.turn_started.connect(_on_turn_started)

# BoardOrchestrator 在 boot() 后注入自身引用。
func set_orchestrator(orch: Node) -> void:
	_orchestrator = orch

# main.gd intro 动画完成后调用：触发 game_started 类 trigger。
func notify_game_started() -> void:
	for trig in _triggers:
		if trig["fired"] and trig["once"]:
			continue
		var when: Dictionary = trig["when"]
		if String(when.get("type", "")) == "game_started":
			_fire_trigger(trig)
func notify_unit_died(snap: Dictionary) -> void:
	for trig in _triggers:
		if trig["fired"] and trig["once"]:
			continue
		var when: Dictionary = trig["when"]
		if String(when.get("type", "")) != "unit_died":
			continue
		if not _match_unit_died(when, snap):
			continue
		_fire_trigger(trig)

# BoardSlot.hero died 信号调用：通知英雄死亡，检查 hero_died 类 trigger。
# snap 结构：{"slot_id": String, "hero_name": String}
func notify_hero_died(snap: Dictionary) -> void:
	for trig in _triggers:
		if trig["fired"] and trig["once"]:
			continue
		var when: Dictionary = trig["when"]
		if String(when.get("type", "")) != "hero_died":
			continue
		# "slot" 条件：slot_id 匹配
		if when.has("slot"):
			if String(when["slot"]) != String(snap.get("slot_id", "")):
				continue
		# "name" 条件：hero_name 匹配
		if when.has("name"):
			if String(when["name"]) != String(snap.get("hero_name", "")):
				continue
		_fire_trigger(trig)

# ── 回合信号处理 ──────────────────────────────────────────────────────────

func _on_turn_started() -> void:
	if not has_node("/root/Game") or Game.turn == null:
		return
	# board_events 和 triggers 现在由 TurnSystem 在 run() 里 await 执行，
	# 此处不再重复执行，防止双跑。
	pass

# TurnSystem 在 turn_started.emit() 后、_run_phase 前调用并 await。
# 顺序执行当前回合的 board_events.actions 和所有符合条件的 triggers。
func run_turn_events_and_wait(current_turn: int) -> void:
	# 1. 回合型 board_events.actions（顺序 await，确保 add_board 动画完成后再继续）
	for ev in _board_event_actions:
		if int(ev["turn"]) == current_turn:
			await _run_actions(ev["actions"])

	# 2. 回合型 trigger：turn_eq / turn_gte / counters 等
	for trig in _triggers:
		if trig["fired"] and trig["once"]:
			continue
		var when: Dictionary = trig["when"]
		match String(when.get("type", "")):
			"turn_eq":
				if current_turn == int(when.get("n", -1)):
					await _fire_trigger_and_wait(trig)
			"turn_gte":
				if current_turn >= int(when.get("n", -1)):
					await _fire_trigger_and_wait(trig)
			"hero_hp_below":
				_check_hero_hp_trigger(trig, when, current_turn)
			"counters_all_set":
				_check_counters_all_set_trigger(trig, when, current_turn)

# ── 内部工具 ──────────────────────────────────────────────────────────────

func _match_unit_died(cond: Dictionary, snap: Dictionary) -> bool:
	# "name" 条件：不填则不限制
	if cond.has("name"):
		if String(cond["name"]) != String(snap.get("card_name", "")):
			return false
	# "faction" 条件：0=玩家方，1=敌方
	if cond.has("faction"):
		var expected_enemy: bool = int(cond["faction"]) == 1
		if expected_enemy != bool(snap.get("is_enemy", false)):
			return false
	# "board" 条件：owner_slot_id 匹配
	if cond.has("board"):
		if String(cond["board"]) != String(snap.get("owner_slot_id", "")):
			return false
	return true

func _check_hero_hp_trigger(trig: Dictionary, cond: Dictionary, current_turn: int) -> void:
	if not has_node("/root/Game") or Game.registry == null:
		return
	# cooldown 检查
	var cooldown: int = trig["cooldown"]
	if cooldown > 0 and current_turn - trig["last_fired_turn"] < cooldown:
		return
	var slot_id: String = String(cond.get("slot", ""))
	var threshold: int  = int(cond.get("threshold", 0))
	var slot: BoardSlot = Game.registry.get_by_id(slot_id)
	if slot == null or slot.hero == null:
		return
	if slot.hero.health <= threshold:
		_fire_trigger(trig)

# counters_all_set：检查 Game.counters 中指定 keys 是否全部 >= 1
func _check_counters_all_set_trigger(trig: Dictionary, cond: Dictionary, _current_turn: int) -> void:
	if not has_node("/root/Game"):
		return
	var keys = cond.get("keys", [])
	if typeof(keys) != TYPE_ARRAY:
		return
	for k in keys:
		if int(Game.counters.get(String(k), 0)) < 1:
			return
	_fire_trigger(trig)

func _fire_trigger(trig: Dictionary) -> void:
	trig["fired"] = true
	if has_node("/root/Game") and Game.turn != null:
		trig["last_fired_turn"] = Game.turn.turn_number
	_run_actions_async(trig["actions"])

# 可 await 版本：执行完所有 actions 后才返回。
func _fire_trigger_and_wait(trig: Dictionary) -> void:
	trig["fired"] = true
	if has_node("/root/Game") and Game.turn != null:
		trig["last_fired_turn"] = Game.turn.turn_number
	await _run_actions(trig["actions"])

# 启动 actions 协程（fire-and-forget）：_run_actions 是协程，
# 不 await 即以"后台"方式运行，不阻塞当前信号处理路径。
func _run_actions_async(actions: Array) -> void:
	if actions.is_empty():
		return
	# fire-and-forget：不 await，后台运行
	_run_actions(actions)

# 顺序执行 actions 数组（协程，含 await）。
func _run_actions(actions: Array) -> void:
	for action in actions:
		if typeof(action) != TYPE_DICTIONARY:
			continue
		if has_node("/root/Game") and Game.combat != null and Game.combat.aborted:
			return
		var type_str: String = String(action.get("type", ""))
		if not Actions.has(type_str):
			push_warning("Events: unknown action type: " + type_str)
			continue
		var ctx := _make_action_ctx()
		await Actions.run(type_str, action, ctx)

func _make_action_ctx() -> Dictionary:
	return {
		"tree":         Engine.get_main_loop(),
		"orchestrator": _orchestrator,
	}
