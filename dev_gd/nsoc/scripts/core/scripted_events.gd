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

# PlayController.handle_unit_death 调用：通知单位死亡，检查 unit_died 类 trigger。
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

# ── 回合信号处理 ──────────────────────────────────────────────────────────

func _on_turn_started() -> void:
	if not has_node("/root/Game") or Game.turn == null:
		return
	var current_turn: int = Game.turn.turn_number

	# 1. 回合型 board_events.actions
	for ev in _board_event_actions:
		if int(ev["turn"]) == current_turn:
			_run_actions_async(ev["actions"])

	# 2. 回合型 trigger：turn_eq / turn_gte
	for trig in _triggers:
		if trig["fired"] and trig["once"]:
			continue
		var when: Dictionary = trig["when"]
		match String(when.get("type", "")):
			"turn_eq":
				if current_turn == int(when.get("n", -1)):
					_fire_trigger(trig)
			"turn_gte":
				if current_turn >= int(when.get("n", -1)):
					_fire_trigger(trig)
			"hero_hp_below":
				_check_hero_hp_trigger(trig, when, current_turn)

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

func _fire_trigger(trig: Dictionary) -> void:
	trig["fired"] = true
	if has_node("/root/Game") and Game.turn != null:
		trig["last_fired_turn"] = Game.turn.turn_number
	_run_actions_async(trig["actions"])

# 启动 actions 协程（fire-and-forget）：_run_actions 是协程，
# 不 await 即以"后台"方式运行，不阻塞当前信号处理路径。
func _run_actions_async(actions: Array) -> void:
	if actions.is_empty():
		return
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
