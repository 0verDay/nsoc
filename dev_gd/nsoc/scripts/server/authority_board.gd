class_name AuthorityBoard
extends RefCounted

## 权威端棋盘适配器（重构文档.md §4「确保无法作弊」：棋盘结算也归服务器）。
##
## 为什么是"适配器"：`BattleAuthority` 刻意保持纯状态机（RefCounted、不碰场景树、
## 不引用 UI、可在无 SceneTree 环境构造），而棋盘规则引擎（BoardModel / BoardSlot /
## CellData / BoardSlotFactory）需要 Godot 的 autoload 与节点。两者用本类解耦：
##
##   BattleAuthority  ---- deploy_unit() / state() ---->  AuthorityBoard  ---->  规则引擎
##
## 于是"服务器裁决棋盘"用的是**同一套规则与同一份数据表示**（`CellData`），
## 不是第二份规则实现 —— 这正是阶段 2/3 做数据/表现分离的目的。
##
## 落子会带上 slot 的 team_id / owner_player_id，跨盘与友敌判定与客户端一致。

var _by_pid: Dictionary = {}        # pid -> Array[BoardSlot]（1v3/3v3 下一个玩家可有多盘）
var _by_slot_id: Dictionary = {}    # slot_id -> BoardSlot

# ── 模拟宿主（**注入**，本层不建节点）────────────────────────────────────
# 分层检查要求 scripts/server/ 与规则层同规：不得碰场景树。因此"用 TurnSystem 跑行动阶段"
# 的运行时宿主（BattleSimHost，见 dev_gd/nsoc/server/battle_sim_host.gd）由部署入口 /
# 测试建好并入树后注入这里；本类只持有引用并 await 它。
var _sim = null


## 注入模拟宿主（BattleSimHost）。服务器层因此保持场景树无关。
func attach_sim(host) -> void:
	_sim = host


func has_sim() -> bool:
	return _sim != null


## 建盘。config：
##   players: Array[pid]                 按行动顺序
##   teams:   {pid: team_id}             "defender" / "attacker" / "team_a" …（可选）
##   hero_hp: {pid: int}                 英雄血量（可选，默认 30）
##   abilities: {pid: [ability_id]}      该玩家英雄携带的技能（权威端据此校验归属，可选）
##   slot_ids:{pid: slot_id}             自定义盘 id（可选，默认 "main_<pid>"）
##   level:   {slot_id: {initial_units: [...]}}  初始铺盘（可选）
## 返回 {"ok": bool, "reason": String}。
func start(config: Dictionary) -> Dictionary:
	_by_pid.clear()
	_by_slot_id.clear()

	var players: Array = config.get("players", [])
	if players.is_empty():
		return {"ok": false, "reason": "no_players"}
	var teams: Dictionary = config.get("teams", {})
	var hero_hp: Dictionary = config.get("hero_hp", {})
	var slot_ids: Dictionary = config.get("slot_ids", {})
	var level: Dictionary = config.get("level", {})
	var abilities: Dictionary = config.get("abilities", {})

	for i in range(players.size()):
		var pid := String(players[i])
		# 默认盘 id：main_<pid>；阵营按行动顺序轮替（0 = 玩家侧 / 1 = 敌方侧），
		# 多队伍 PVP 的友敌判定由 team_id 决定（faction 只作 PVE 兜底）。
		var slot_id := String(slot_ids.get(pid, "main_%s" % pid))
		var faction: int = BoardSlot.FACTION_PLAYER if i % 2 == 0 else BoardSlot.FACTION_ENEMY
		var role: int = BoardSlot.ROLE_MAIN_PLAYER if faction == BoardSlot.FACTION_PLAYER \
			else BoardSlot.ROLE_MAIN_ENEMY
		var section: Dictionary = level.get(slot_id, {})
		var hero_spec := {"hp": int(hero_hp.get(pid, 30)), "name_short": pid, "name_full": pid,
			"abilities": (abilities.get(pid, []) as Array).duplicate()}
		var team := String(teams.get(pid, ""))

		var slot: BoardSlot = BoardSlotFactory.create_headless(
			slot_id, faction, role, hero_spec, section, team, pid)
		if slot == null:
			return {"ok": false, "reason": "board_setup_failed"}
		var list: Array = _by_pid.get(pid, [])
		list.append(slot)
		_by_pid[pid] = list
		_by_slot_id[slot_id] = slot

	return {"ok": true, "reason": ""}


func is_empty() -> bool:
	return _by_slot_id.is_empty()


func slots_of(pid: String) -> Array:
	return _by_pid.get(pid, [])


func slot_at(slot_id: String) -> BoardSlot:
	return _by_slot_id.get(slot_id)


func cell_at(slot_id: String, row: int, col: int):
	var slot: BoardSlot = _by_slot_id.get(slot_id)
	if slot == null or slot.board == null:
		return null
	return slot.board.get_cell(Vector2(row, col))


## 校验并落子。**只做校验与状态写入**，不碰手牌/费用（那是 BattleAuthority 的职责）：
## 失败时调用方不应消耗任何资源。
## 返回 {"ok": bool, "reason": String(NetProtocol.REJECT_*), "unit": {...}}。
func deploy_unit(pid: String, card_name: String, payload: Dictionary) -> Dictionary:
	var row := int(payload.get("row", -1))
	var col := int(payload.get("col", -1))
	if row < 0 or col < 0:
		return {"ok": false, "reason": NetProtocol.REJECT_BAD_PAYLOAD}
	if not _by_pid.has(pid):
		return {"ok": false, "reason": NetProtocol.REJECT_UNKNOWN_PLAYER}

	var slot: BoardSlot = _resolve_slot(pid, String(payload.get("target_slot_id", "")))
	if slot == null:
		# 指定了他人的盘 / 不存在的盘：一律非法目标（防"把单位放到对手盘上"）
		return {"ok": false, "reason": NetProtocol.REJECT_ILLEGAL_TARGET}

	var cdata = Game.get_card(card_name)
	if cdata == null:
		return {"ok": false, "reason": NetProtocol.REJECT_BAD_PAYLOAD}
	if not (cdata is CardUnit):
		# 法术 / 装备 / 英雄技能的权威结算待后续切片；现在明确拒绝而不是静默放行
		return {"ok": false, "reason": NetProtocol.REJECT_NOT_ALLOWED}

	var cell = slot.board.get_cell(Vector2(row, col))
	if cell == null:
		return {"ok": false, "reason": NetProtocol.REJECT_ILLEGAL_TARGET}
	if cell.has_card or cell.is_phantom:
		return {"ok": false, "reason": NetProtocol.REJECT_ILLEGAL_TARGET}

	cell.set_card(cdata.name, cdata.attack, cdata.health,
		slot.faction == BoardSlot.FACTION_ENEMY, cdata.effects,
		slot.id, "hand", slot.team_id)
	return {"ok": true, "reason": "", "unit": {
		"slot_id": slot.id, "row": row, "col": col, "card": cdata.name,
		"attack": cdata.attack, "health": cell.health.duplicate(),
		"team_id": slot.team_id, "owner": pid, "origin": "hand",
	}}


## 出牌总入口（**同步校验 + 落子**）：单位 → 落子；法术 → 只校验目标，效果排队到 tick 执行；
## 装备 / 英雄技能暂未接入 → not_allowed（明确拒绝而不是静默放行）。
## 返回值统一为 {"ok", "reason", "kind", ...}；`kind` ∈ {"unit", "spell"}。
func validate_play(pid: String, card_name: String, payload: Dictionary) -> Dictionary:
	var cdata = Game.get_card(card_name)
	if cdata == null:
		return {"ok": false, "reason": NetProtocol.REJECT_BAD_PAYLOAD}
	if cdata is CardUnit:
		var deployed: Dictionary = deploy_unit(pid, card_name, payload)
		if bool(deployed.get("ok", false)):
			deployed["kind"] = "unit"
		return deployed
	if cdata is CardSpell:
		return _validate_spell(pid, cdata, payload)
	return {"ok": false, "reason": NetProtocol.REJECT_NOT_ALLOWED}


## 法术目标校验（同步）。effect 执行是协程，放在 cast_spell 里由 tick 驱动。
func _validate_spell(pid: String, cdata, payload: Dictionary) -> Dictionary:
	if not _by_pid.has(pid):
		return {"ok": false, "reason": NetProtocol.REJECT_UNKNOWN_PLAYER}
	var row := int(payload.get("row", -1))
	var col := int(payload.get("col", -1))
	var slot: BoardSlot = _by_slot_id.get(String(payload.get("target_slot_id", "")))
	var target = null
	if row >= 0 and col >= 0 and slot != null:
		target = slot.board.get_cell(Vector2(row, col))
	# 有目标策略的法术（friendly_unit / any_unit / enemy_unit）：目标格必须真有单位
	var needs_target: bool = String(cdata.target) != ""
	if needs_target and (target == null or not target.has_card):
		return {"ok": false, "reason": NetProtocol.REJECT_ILLEGAL_TARGET}
	return {"ok": true, "reason": "", "kind": "spell", "spell": {
		"card": String(cdata.name),
		"slot_id": slot.id if slot != null else "",
		"row": row, "col": col,
	}}


## 执行法术效果（**协程**，由服务器 tick 调用；此前必须已通过 _validate_spell）。
## 与客户端 PlayController._play_spell 同一套：Effects.resolve_destination + trigger_play。
func cast_spell(pid: String, card_name: String, payload: Dictionary) -> Dictionary:
	var cdata = Game.get_card(card_name)
	if cdata == null or not (cdata is CardSpell):
		return {"ok": false, "reason": NetProtocol.REJECT_BAD_PAYLOAD}
	var check: Dictionary = _validate_spell(pid, cdata, payload)
	if not bool(check.get("ok", false)):
		return check
	var slot: BoardSlot = _by_slot_id.get(String(payload.get("target_slot_id", "")))
	var target = null
	var row := int(payload.get("row", -1))
	var col := int(payload.get("col", -1))
	if slot != null and row >= 0 and col >= 0:
		target = slot.board.get_cell(Vector2(row, col))

	var ctx := Game.make_effect_context()
	ctx.target_cell = target
	var destination := "graveyard"
	for eff in cdata.effects:
		var dest := Effects.resolve_destination(eff, cdata, ctx)
		if dest != "":
			destination = dest
		await Effects.trigger_play(eff, cdata, ctx)
	var spell: Dictionary = check.get("spell", {})
	spell["destination"] = destination
	return {"ok": true, "reason": "", "kind": "spell", "spell": spell}


## 英雄技能：同步校验。技能必须在显式注册表里、必须属于该玩家盘上的英雄、
## 且 `can_activate(ctx)` 通过（ctx 注入权威端自己的费用/回合/已用状态）。
## 返回 {"ok", "reason", "cost", "once_per_turn", "spell"/"ability"}。
func validate_hero_ability(pid: String, ability_id: String,
		mana_current: int, mana_maximum: int, used_this_turn: bool,
		payload: Dictionary) -> Dictionary:
	var slot: BoardSlot = _resolve_slot(pid, String(payload.get("target_slot_id", "")))
	if slot == null:
		return {"ok": false, "reason": NetProtocol.REJECT_ILLEGAL_TARGET}
	if not HeroAbilities.has(ability_id):
		return {"ok": false, "reason": NetProtocol.REJECT_BAD_PAYLOAD}
	# 归属校验：只有英雄自己带的技能可激活（客户端无法凭空用一个别人的技能）
	if slot.hero == null or not (slot.hero.abilities as Array).has(ability_id):
		return {"ok": false, "reason": NetProtocol.REJECT_NOT_ALLOWED}

	var ctx := _make_ctx(slot, payload, mana_current, mana_maximum, used_this_turn)
	var inst = HeroAbilities.get_instance(ability_id)
	if inst == null:
		return {"ok": false, "reason": NetProtocol.REJECT_BAD_PAYLOAD}
	if not bool(inst.can_activate(ctx)):
		return {"ok": false, "reason": NetProtocol.REJECT_NOT_ALLOWED}
	return {"ok": true, "reason": "",
		"ability": {"ability_id": ability_id, "slot_id": String(slot.id)},
		"cost": int(inst.cost()),
		"once_per_turn": bool(inst.once_per_turn())}


## 执行英雄技能（**协程**，由服务器 tick 调用；此前必须已通过 validate_hero_ability）。
func run_hero_ability(pid: String, ability_id: String,
		mana_current: int, mana_maximum: int, used_this_turn: bool,
		payload: Dictionary) -> Dictionary:
	var slot: BoardSlot = _resolve_slot(pid, String(payload.get("target_slot_id", "")))
	if slot == null:
		return {"ok": false, "reason": NetProtocol.REJECT_ILLEGAL_TARGET}
	var inst = HeroAbilities.get_instance(ability_id)
	if inst == null:
		return {"ok": false, "reason": NetProtocol.REJECT_BAD_PAYLOAD}
	await inst.on_activate(_make_ctx(slot, payload, mana_current, mana_maximum, used_this_turn))
	return {"ok": true, "reason": "",
		"ability": {"ability_id": ability_id, "slot_id": String(slot.id)}}


## 构造效果上下文：把**权威端的**费用 / 回合 / 已用状态与目标注入，让技能复用客户端同一份
## 逻辑。注意这些值来自服务器参数，**绝不从客户端 payload 读取**（否则可伪造费用）。
func _make_ctx(slot: BoardSlot, payload: Dictionary,
		mana_current: int, mana_maximum: int, used_this_turn: bool) -> EffectContext:
	var ctx := Game.make_effect_context()
	ctx.hero = slot.hero
	var row := int(payload.get("row", -1))
	var col := int(payload.get("col", -1))
	var target_slot: BoardSlot = _by_slot_id.get(String(payload.get("target_slot_id", slot.id)))
	if target_slot != null and row >= 0 and col >= 0:
		ctx.target_cell = target_slot.board.get_cell(Vector2(row, col))
	var mirror := ManaSystem.new()
	mirror.current = mana_current
	mirror.maximum = mana_maximum
	ctx.mana_system = mirror
	ctx.turn_running = false
	ctx.ability_used_this_turn = used_this_turn
	return ctx


## 取卡牌原型（权威核心不直接依赖 Game；卡库查询统一走这里）。
func card_info(card_name: String):
	return Game.get_card(card_name)


## 激活装备效果（**协程**）。`inst` 由权威核心持有（每个玩家一套），本方法只负责用
## 同一套效果机制执行：`EquipmentInstance.activate(ctx, turn_running=false)`。
## 返回 {"ok", "durability", "broken"}。
func run_equip_activation(inst, payload: Dictionary) -> Dictionary:
	if inst == null:
		return {"ok": false, "reason": NetProtocol.REJECT_NOT_ALLOWED}
	var ctx := Game.make_effect_context()
	var row := int(payload.get("row", -1))
	var col := int(payload.get("col", -1))
	var slot: BoardSlot = _by_slot_id.get(String(payload.get("target_slot_id", "")))
	if slot != null and row >= 0 and col >= 0:
		ctx.target_cell = slot.board.get_cell(Vector2(row, col))
	var ok: bool = await inst.activate(ctx, false)
	return {
		"ok": ok,
		"reason": "" if ok else NetProtocol.REJECT_NOT_ALLOWED,
		"durability": int(inst.durability_left),
		"broken": bool(inst.is_broken()),
	}


## 盘面公开状态（战棋里单位位置本就公开；隐藏信息只有手牌，由 view_for 处理）。
func state() -> Dictionary:
	var out: Dictionary = {}
	for slot_id in _by_slot_id.keys():
		var slot: BoardSlot = _by_slot_id[slot_id]
		var cells: Dictionary = {}
		for key in slot.board.grid_cells.keys():
			var cell = slot.board.grid_cells[key]
			cells["%d,%d" % [int(key.x), int(key.y)]] = cell.to_dict()
		out[slot_id] = {
			"owner": slot.owner_player_id,
			"team_id": slot.team_id,
			"faction": slot.faction,
			"hero": {"hp": slot.hero.health if slot.hero != null else 0},
			"cells": cells,
			"graveyard": slot.graveyard.size(),
			"banished": slot.banished.size(),
		}
	return out


## 该玩家名下盘的英雄血量（1v3/3v3 下一个玩家一块盘；多盘取最大，即"还有一盘的英雄活着"）。
## 棋盘是权威模拟的真相来源，权威核心据此同步 _hero_hp 与终局判定。
func hero_hp(pid: String) -> int:
	var owned: Array = _by_pid.get(pid, [])
	var best: int = 0
	var found: bool = false
	for slot in owned:
		if slot.hero == null:
			continue
		if not found or int(slot.hero.health) > best:
			best = int(slot.hero.health)
		found = true
	return best


## 解析目标盘：显式 slot_id 必须在 pid 名下；未指定则取 pid 的第一块盘。
func _resolve_slot(pid: String, slot_id: String) -> BoardSlot:
	var owned: Array = _by_pid.get(pid, [])
	if slot_id == "":
		return owned[0] if owned.size() > 0 else null
	for slot in owned:
		if slot.id == slot_id:
			return slot
	return null


# ══ 权威端回合结算（委托给注入的 BattleSimHost；规则仍是客户端同一套）══════

## 结算某个 slot 的自动行动阶段（该盘单位的攻击 / 推进 / 冲锋 / 死亡清算）。
## 返回 {"ok": bool, "reason": String}。
func resolve_slot_actions(slot_id: String) -> Dictionary:
	if not _by_slot_id.has(slot_id):
		return {"ok": false, "reason": NetProtocol.REJECT_ILLEGAL_TARGET}
	if _sim == null:
		# 没注入宿主（例如只做落子校验的场景）：如实报告而不是假装结算过
		return {"ok": false, "reason": "no_sim"}
	await _sim.resolve_slot_actions(slot_id)
	return {"ok": true, "reason": ""}
