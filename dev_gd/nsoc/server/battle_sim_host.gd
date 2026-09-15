class_name BattleSimHost
extends Node

## 权威模拟宿主（**运行时层**，刻意不在 `scripts/server/` 里）。
##
## 为什么单独一层：分层检查（tools/ci/check_layers.py §3.2）要求 `scripts/server/` 与
## 规则层同规 —— **不得碰场景树**（`add_child` / `get_tree` / Tween 全禁），因为它必须在
## 无头环境可运行。而"用 `TurnSystem` 跑一个 slot 的行动阶段"必须把节点挂进场景树，
## 于是把这段纯运行时职责放在本类里：
##
##   部署入口 / 测试  ── 建宿主并入树 ──▶  BattleSimHost  ──▶  CombatSystem / PlayController / TurnSystem
##                                            ▲
##                       AuthorityBoard（纯会话层）只持有引用并 await 它
##
## 用的仍然是**客户端同一套规则类**（不是第二份实现），差别只有：
##   `CombatSystem.presentation_enabled = false`（不表演）+ `Game.instant_battle = true`（不等待）。

var _combat: CombatSystem = null
var _pc: PlayController = null
var _turn: TurnSystem = null

## 动作事件接收器（由 AuthorityBoard 设置）：每次攻击/阵亡/移动各回调一次，
## 用来把"细粒度逐动作事件"转成 auth/event 下发给客户端。
var action_sink: Callable = Callable()


## 幂等装配。宿主自身必须已入场景树（`TurnSystem` 内部会 `_combat.get_tree()`）。
func setup_once() -> void:
	if _turn != null:
		return
	_combat = CombatSystem.new()
	_combat.name = "AuthorityCombat"
	_combat.presentation_enabled = false
	add_child(_combat)

	_pc = PlayController.new()
	_pc.name = "AuthorityPlayController"
	add_child(_pc)
	# 不 setup：死亡清算（handle_unit_death）本身不依赖 UI 容器
	_combat.setup(null, null, _pc)

	_turn = TurnSystem.new()
	_turn.name = "AuthorityTurnSystem"
	add_child(_turn)
	_turn.setup(_combat, Callable(Game, "get_card"))
	# 细粒度动作事件：CombatSystem 的三个信号 → action_sink
	if not _combat.damage_dealt.is_connected(_on_combat_action):
		_combat.damage_dealt.connect(_on_combat_action)
	if not _combat.units_died.is_connected(_on_combat_action):
		_combat.units_died.connect(_on_combat_action)
	if not _combat.move_resolved.is_connected(_on_combat_action):
		_combat.move_resolved.connect(_on_combat_action)
	# 前排跨盘选择：无头环境没人点 UI（`_run_front_row_selection` 会一直等）。
	# 先用**确定性兜底**（第一个敌队盘，与 tests/headless_test_battle.gd 同款）；
	# 待会话层接入 auth/request_choice 后改为询问玩家本人。
	if not _turn.front_row_action_requested.is_connected(_on_front_row_requested):
		_turn.front_row_action_requested.connect(_on_front_row_requested)


## 跑某个 slot 的自动行动阶段（攻击 / 推进 / 冲锋 / 死亡入墓）。
func resolve_slot_actions(slot_id: String) -> void:
	setup_once()
	var saved_instant: bool = Game.instant_battle
	Game.instant_battle = true
	await _turn.run_pvp_phase_for_slot(slot_id)
	Game.instant_battle = saved_instant


func _on_front_row_requested(_cell) -> void:
	var targets: Array = Game.registry.enemy_targets() if Game.registry != null else []
	_turn.resolve_front_row_selection(String(targets[0].id) if not targets.is_empty() else "")


## CombatSystem 的细粒度动作 → action_sink（权威端据此下发 auth/event）。
func _on_combat_action(payload: Dictionary) -> void:
	if action_sink.is_valid():
		action_sink.call(payload)


func combat() -> CombatSystem:
	return _combat


func turn_system() -> TurnSystem:
	return _turn
