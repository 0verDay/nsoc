class_name BattleAuthority
extends RefCounted

## 服务器权威核心（重构文档.md §4「确保无法作弊」的骨架实现）。
##
## 职责边界（阶段 1 骨架版）：
##   ✅ 服务器持有唯一真相：洗牌种子、抽牌堆顺序、手牌、费用、英雄血量、回合指针
##   ✅ 只接受"意图"，不接受任何客户端上报的结算结果
##   ✅ 身份 / 回合归属 / 序号单调 / 限速 四道校验
##   ✅ 按玩家过滤的私有视图（对手手牌只有数量，没有内容）
##   ✅ 权威事件流下发（客户端只据此渲染）
##   ✅ 棋盘战斗结算：通过可注入的 AuthorityBoard 适配器，用**同一套规则引擎**
##      （BoardModel / CellData / BoardSlotFactory）在纯数据盘面上落子与下发盘面视图
##
## 约束：本类不读文件、不碰场景树、不引用 UI，可在无 SceneTree 的环境构造与测试。
## 棋盘依赖（节点 / autoload）全部封装在适配器里，本类只调用 deploy_unit() / state()。

const DEFAULT_HAND_SIZE: int = 3
const DEFAULT_MANA_CAP: int = 10
const DEFAULT_RATE_LIMIT: int = 10   # 每秒最多接受的意图数；<0 表示不限速

# ── 对局配置 ──────────────────────────────────────────────────────────────
var match_id: String = ""
var seed_value: int = 0
var players: Array = []                # 按行动顺序的 pid
var card_costs: Dictionary = {}        # 卡名 -> 费用
var hand_size: int = DEFAULT_HAND_SIZE
var mana_cap: int = DEFAULT_MANA_CAP
var rate_limit_per_sec: int = DEFAULT_RATE_LIMIT

# ── 服务器唯一真相 ────────────────────────────────────────────────────────
var _rng := RandomNumberGenerator.new()
var _draw: Dictionary = {}             # pid -> Array[卡名]，index 0 为下一张
var _hand: Dictionary = {}
var _grave: Dictionary = {}
var _banish: Dictionary = {}
var _mana: Dictionary = {}             # pid -> {"current": int, "maximum": int}
var _hero_hp: Dictionary = {}
var _hero_max_hp: Dictionary = {}
var _active_idx: int = 0
var turn_number: int = 0
var _finished: bool = false
var _winner: String = ""
var _surrender_order: Array = []

# ── 反作弊状态 ────────────────────────────────────────────────────────────
var _last_seq: Dictionary = {}         # pid -> 已接受的最大 seq
var _intent_stamps: Dictionary = {}    # pid -> Array[int]（毫秒时间戳，用于限速）
var _stats: Dictionary = {             # 便于测试与运维观测
	"accepted": 0, "rejected": 0,
}

# ── 棋盘适配器（可选）─────────────────────────────────────────────────────
## 未接入（null）时只结算手牌 / 费用 / 回合（阶段 1 骨架模式，旧测试依赖此行为）；
## 接入后，`intent/play_card` 会先在权威盘面上校验并落子，再扣手牌与费用。
var board = null                       # AuthorityBoard

func attach_board(adapter) -> void:
	board = adapter

func has_board() -> bool:
	return board != null


# ── 事件流 ────────────────────────────────────────────────────────────────
var _events: Array = []                # [{"to": pid|"", "payload": {...}}]


# ══ 生命周期 ══════════════════════════════════════════════════════════════

## 开局。config 见文件头说明；decks 由调用方从内容数据构造（本类不做 I/O）。
func start(config: Dictionary) -> void:
	match_id = String(config.get("match_id", ""))
	seed_value = int(config.get("seed", 0))
	players = (config.get("players", []) as Array).duplicate()
	card_costs = (config.get("card_costs", {}) as Dictionary).duplicate()
	hand_size = int(config.get("hand_size", DEFAULT_HAND_SIZE))
	mana_cap = int(config.get("mana_cap", DEFAULT_MANA_CAP))
	rate_limit_per_sec = int(config.get("rate_limit_per_sec", DEFAULT_RATE_LIMIT))

	_rng.seed = seed_value
	_draw.clear()
	_hand.clear()
	_grave.clear()
	_banish.clear()
	_mana.clear()
	_hero_hp.clear()
	_hero_max_hp.clear()
	_last_seq.clear()
	_intent_stamps.clear()
	_events.clear()
	_stats = {"accepted": 0, "rejected": 0}
	_finished = false
	_winner = ""
	_surrender_order.clear()
	_active_idx = 0
	turn_number = 1

	var decks: Dictionary = config.get("decks", {})
	var hero_hp: Dictionary = config.get("hero_hp", {})
	for pid_raw in players:
		var pid := String(pid_raw)
		var pile: Array = (decks.get(pid, []) as Array).duplicate()
		_shuffle(pile)
		_draw[pid] = pile
		_hand[pid] = []
		_grave[pid] = []
		_banish[pid] = []
		_mana[pid] = {"current": 0, "maximum": 0}
		_hero_hp[pid] = int(hero_hp.get(pid, 30))
		_hero_max_hp[pid] = int(hero_hp.get(pid, 30))
		_last_seq[pid] = -1
		_intent_stamps[pid] = []
		# 起始费用与客户端一致：1/1
		_mana[pid] = {"current": 1, "maximum": 1}
		for _i in range(hand_size):
			_draw_one(pid)

	_emit("", {"event": "match_started", "match_id": match_id, "players": players.duplicate(),
		"seed_committed": true})
	# 开局回合不额外抽牌、不加费：开局手牌即首回合的抽牌，起始费用保持 1/1
	# （与游戏内 mana.setup(1) 一致；先手首回合 1 费，后手首回合 2 费 + 摸一张）
	_begin_turn(false)


# ══ 意图入口 ══════════════════════════════════════════════════════════════

## 处理一条客户端意图。返回 {"ok": bool, "reason": String}。
## 无论接受还是拒绝，都会给该玩家排入相应的事件（auth/event 或 auth/reject）。
func submit_intent(pid: String, type: String, payload: Dictionary) -> Dictionary:
	if not players.has(pid):
		return _reject(pid, NetProtocol.REJECT_UNKNOWN_PLAYER, type, -1)
	if _finished:
		return _reject(pid, NetProtocol.REJECT_MATCH_FINISHED, type, _seq_of(payload))
	var struct_err := NetProtocol.validate_intent(type, payload)
	if struct_err != "":
		return _reject(pid, struct_err, type, _seq_of(payload))

	var seq: int = _seq_of(payload)
	if seq <= int(_last_seq.get(pid, -1)):
		return _reject(pid, NetProtocol.REJECT_STALE_SEQ, type, seq)
	if _rate_limited(pid):
		return _reject(pid, NetProtocol.REJECT_RATE_LIMITED, type, seq)

	# 除投降外，只有当前行动玩家可以行动（服务器判定，不看 payload 里的身份字段）
	if type != NetProtocol.INTENT_SURRENDER and pid != active_player():
		return _reject(pid, NetProtocol.REJECT_NOT_YOUR_TURN, type, seq)

	var result: Dictionary
	match type:
		NetProtocol.INTENT_END_TURN:
			result = _accept(pid, seq, type, _on_end_turn(pid))
		NetProtocol.INTENT_PLAY_CARD:
			result = _on_play_card(pid, seq, payload)
		NetProtocol.INTENT_SURRENDER:
			result = _accept(pid, seq, type, _on_surrender(pid))
		_:
			# 骨架阶段：装备 / 英雄技能 / 跨盘 / 选择 的规则结算待阶段 2/3 接入规则引擎
			result = _reject(pid, NetProtocol.REJECT_NOT_ALLOWED, type, seq)
	return result


# ══ 视图 ══════════════════════════════════════════════════════════════════

## 按玩家过滤的对局视图：自己的手牌明文，对手只有数量（修复"没有暗牌"的问题）。
func view_for(pid: String) -> Dictionary:
	var others: Array = []
	for other_raw in players:
		var other := String(other_raw)
		if other == pid:
			continue
		others.append({
			"pid": other,
			"hand_count": (_hand.get(other, []) as Array).size(),
			"draw_count": (_draw.get(other, []) as Array).size(),
			"graveyard": (_grave.get(other, []) as Array).duplicate(),
			"banished": (_banish.get(other, []) as Array).duplicate(),
			"mana": (_mana.get(other, {}) as Dictionary).duplicate(),
			"hero": {"hp": int(_hero_hp.get(other, 0)), "max_hp": int(_hero_max_hp.get(other, 0))},
		})
	return {
		"type": NetProtocol.AUTH_STATE,
		"protocol": NetProtocol.VERSION,
		"turn": turn_number,
		"active": active_player(),
		"you": {
			"pid": pid,
			"hand": (_hand.get(pid, []) as Array).duplicate(),
			"draw_count": (_draw.get(pid, []) as Array).size(),
			"graveyard": (_grave.get(pid, []) as Array).duplicate(),
			"banished": (_banish.get(pid, []) as Array).duplicate(),
			"mana": (_mana.get(pid, {}) as Dictionary).duplicate(),
			"hero": {"hp": int(_hero_hp.get(pid, 0)), "max_hp": int(_hero_max_hp.get(pid, 0))},
			"seq_ack": int(_last_seq.get(pid, -1)),
		},
		"others": others,
		# 盘面是公开信息（战棋单位位置本就可见）；隐藏信息只有手牌，见上 you/others
		"board": board.state() if board != null else {},
		"finished": _finished,
		"winner": _winner,
	}


func active_player() -> String:
	if players.is_empty():
		return ""
	return String(players[_active_idx])


func is_finished() -> bool:
	return _finished


func verdict() -> Dictionary:
	return {
		"type": NetProtocol.AUTH_VERDICT,
		"finished": _finished,
		"winner": _winner,
		"surrender_order": _surrender_order.duplicate(),
	}


func stats() -> Dictionary:
	return _stats.duplicate()


## 取出（并清空）**全部**事件，元素形如 {"to": pid|"", "payload": {...}}。
## 由服务器会话层负责路由：to == "" 为公共事件（广播给所有人），否则只发给该玩家。
## 与 drain_events_for 的区别：后者只取"发给某个人"的事件，公共事件会留在队列里。
func drain_all_events() -> Array:
	var out: Array = _events.duplicate()
	_events = []
	return out


## 取出（并清空）发给指定玩家的事件；pid == "" 时取公共事件。
func drain_events_for(pid: String) -> Array:
	var out: Array = []
	var rest: Array = []
	for entry in _events:
		var to := String((entry as Dictionary).get("to", ""))
		if to == pid:
			out.append((entry as Dictionary).get("payload", {}))
		else:
			rest.append(entry)
	_events = rest
	return out


# ══ 内部：规则（骨架级，只覆盖费用/手牌/回合/投降）═════════════════════════

func _on_play_card(pid: String, seq: int, payload: Dictionary) -> Dictionary:
	var card := String(payload.get("card_name", ""))
	var hand: Array = _hand.get(pid, [])
	if not hand.has(card):
		return _reject(pid, NetProtocol.REJECT_CARD_NOT_IN_HAND, NetProtocol.INTENT_PLAY_CARD, seq)
	var cost: int = int(card_costs.get(card, 0))
	var mana: Dictionary = _mana.get(pid, {})
	if int(mana.get("current", 0)) < cost:
		return _reject(pid, NetProtocol.REJECT_NOT_ENOUGH_MANA, NetProtocol.INTENT_PLAY_CARD, seq)

	# 接入棋盘后：先在权威盘面上校验并落子；失败则**不消耗手牌与费用**（原子性）
	var deployed: Dictionary = {}
	if board != null:
		deployed = board.deploy_unit(pid, card, payload)
		if not bool(deployed.get("ok", false)):
			return _reject(pid, String(deployed.get("reason", NetProtocol.REJECT_ILLEGAL_TARGET)),
				NetProtocol.INTENT_PLAY_CARD, seq)

	hand.erase(card)
	mana["current"] = int(mana["current"]) - cost

	var events: Array = [{
		"event": "card_played", "pid": pid, "card": card, "mana_left": int(mana["current"]),
		# 结算结果由服务器给出；客户端不再计算，也不再接受客户端上报的结果字段
		"authoritative": true,
	}]
	if board != null:
		# 单位已落到权威盘面：下发落点与盘面单位属性（客户端只据此渲染）
		var unit: Dictionary = (deployed.get("unit", {}) as Dictionary).duplicate()
		unit["event"] = "unit_deployed"
		unit["pid"] = pid
		events.append(unit)
	else:
		# 骨架模式（无棋盘）：只记录"已打出"
		_grave[pid].append(card)
	return _accept(pid, seq, NetProtocol.INTENT_PLAY_CARD, events)


## 结束回合：返回事件数组（_accept 同时接受单条事件与事件数组）。
func _on_end_turn(pid: String) -> Array:
	var events: Array = [{"event": "turn_ended", "pid": pid}]
	_advance_active()
	_begin_turn()
	events.append({"event": "turn_started", "pid": active_player(), "turn": turn_number,
		"mana": (_mana.get(active_player(), {}) as Dictionary).duplicate()})
	return events


func _on_surrender(pid: String) -> Dictionary:
	if not _surrender_order.has(pid):
		_surrender_order.append(pid)
	_hero_hp[pid] = 0
	_check_finished()
	return {"event": "surrendered", "pid": pid}


## 回合开始。with_effects = false 仅用于开局回合（不抽牌、不加费）。
func _begin_turn(with_effects: bool = true) -> void:
	var pid := active_player()
	if pid == "":
		return
	var mana: Dictionary = _mana.get(pid, {})
	if with_effects:
		var maximum: int = mini(int(mana.get("maximum", 1)) + 1, mana_cap)
		mana["maximum"] = maximum
		mana["current"] = maximum
		_draw_one(pid)
	_emit("", {"event": "turn_started", "pid": pid, "turn": turn_number,
		"mana": mana.duplicate()})


func _advance_active() -> void:
	if players.is_empty():
		return
	var n: int = players.size()
	for step in range(1, n + 1):
		var idx: int = (_active_idx + step) % n
		var pid := String(players[idx])
		if int(_hero_hp.get(pid, 0)) > 0:
			if idx <= _active_idx:
				turn_number += 1
			_active_idx = idx
			return


func _draw_one(pid: String) -> void:
	var pile: Array = _draw.get(pid, [])
	if pile.is_empty():
		# 牌堆耗尽：把墓地洗回抽牌堆（服务器侧决定，客户端无从干预）
		var grave: Array = _grave.get(pid, [])
		if grave.is_empty():
			_emit(pid, {"event": "draw_failed", "pid": pid, "reason": "deck_empty"})
			return
		_shuffle(grave)
		_draw[pid] = grave
		_grave[pid] = []
		pile = _draw[pid]
	var card := String(pile.pop_front())
	_hand[pid].append(card)
	# 抽牌事件只发给本人：对手只能看到数量变化（暗牌）
	_emit(pid, {"event": "card_drawn", "pid": pid, "card": card,
		"hand_count": (_hand[pid] as Array).size()})


func _check_finished() -> void:
	var alive: Array = []
	for pid_raw in players:
		var pid := String(pid_raw)
		if int(_hero_hp.get(pid, 0)) > 0:
			alive.append(pid)
	if alive.size() <= 1:
		_finished = true
		_winner = String(alive[0]) if alive.size() == 1 else ""
		_emit("", {"event": "match_finished", "winner": _winner})


# ══ 内部：校验与工具 ══════════════════════════════════════════════════════

func _seq_of(payload: Dictionary) -> int:
	return int(payload.get("seq", -1))


func _rate_limited(pid: String) -> bool:
	if rate_limit_per_sec < 0:
		return false
	var now: int = Time.get_ticks_msec()
	var stamps: Array = _intent_stamps.get(pid, [])
	var fresh: Array = []
	for t in stamps:
		if now - int(t) < 1000:
			fresh.append(int(t))
	fresh.append(now)
	_intent_stamps[pid] = fresh
	return fresh.size() > rate_limit_per_sec


func _accept(pid: String, seq: int, type: String, events) -> Dictionary:
	_last_seq[pid] = seq
	_stats["accepted"] = int(_stats["accepted"]) + 1
	var list: Array = events if typeof(events) == TYPE_ARRAY else [events]
	for ev in list:
		_emit("", ev)
	_emit(pid, {"event": "intent_accepted", "intent": type, "seq": seq})
	return {"ok": true, "reason": ""}


func _reject(pid: String, reason: String, type: String, seq: int) -> Dictionary:
	_stats["rejected"] = int(_stats["rejected"]) + 1
	_emit(pid, {"type": NetProtocol.AUTH_REJECT, "intent": type, "reason": reason, "seq": seq})
	return {"ok": false, "reason": reason}


## to == "" 表示公共事件；否则只发给该玩家。
func _emit(to: String, payload: Dictionary) -> void:
	_events.append({"to": to, "payload": payload})


func _shuffle(arr: Array) -> void:
	for i in range(arr.size() - 1, 0, -1):
		var j: int = _rng.randi_range(0, i)
		var tmp = arr[i]
		arr[i] = arr[j]
		arr[j] = tmp
