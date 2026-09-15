class_name AuthorityMain
extends Node

## 权威进程入口（Godot headless）——拓扑里"裁决者"那一端。
##
## 职责：连上 Go 中继（`role=authority`）→ 用密钥注册到指定房间 → 用
## `BattleServerSession` + `BattleSimHost` + `AuthorityBoard` 裁决该房间的全部意图，
## 并把 `auth/*` 发回中继（中继按 `to` 广播或定向给玩家）。
##
## 启动（headless）：
##   godot --headless --path dev_gd/nsoc res://server/AuthorityMain.tscn -- --room=12345
##
## 环境变量：
##   NSOC_RELAY_HOST    中继地址（默认 127.0.0.1）
##   NSOC_RELAY_PORT    中继端口（默认 8080）
##   NSOC_AUTHORITY_KEY 权威注册密钥（必须与中继的 NSOC_AUTHORITY_KEY 一致；未设置则注册必失败）
##   NSOC_ROOM_ID       要接管的房间号（也可用 --room=）
##   NSOC_MATCH_CONFIG  可选：对局配置 JSON 路径；缺省用内置 1v1 默认配置
##
## 分层：本文件在**运行时宿主层**（`dev_gd/nsoc/server/`，不进 SHARED_LAYERS），
## 允许碰场景树；`scripts/server/` 仍保持场景树无关。

signal match_created(match_id: String)
signal relay_message(msg: Dictionary)

const DEFAULT_HOST := "127.0.0.1"
const DEFAULT_PORT: int = 8080

## 断线重连退避（秒）：第一次 1s，逐次翻倍，封顶 30s。
const RECONNECT_DELAY_MIN: float = 1.0
const RECONNECT_DELAY_MAX: float = 30.0

var relay_host: String = DEFAULT_HOST
var relay_port: int = DEFAULT_PORT
var authority_key: String = ""
var room_id: String = ""
var match_config_path: String = ""

var session: BattleServerSession = null
var sim_host: BattleSimHost = null

## 是否在 `_ready` 里自动连中继。场景 AuthorityMain.tscn 打开它；
## 单元测试直接 `AuthorityMain.new()`（默认 false）→ 不会去连真实网络。
@export var auto_connect: bool = false

var _peer: WebSocketPeer = null
var _registered: bool = false
var _ticking: bool = false

## 当前 session 服务的房间号（用于重连回同一房间时**不重建**对局）。
var _session_room_id: String = ""

## 本局是否已经交还过房间（防止重复发 authority_release）。
var _released: bool = false

## 断线重连状态。
var _reconnect_at: float = 0.0
var _reconnect_delay: float = RECONNECT_DELAY_MIN

## 发送缝隙：默认走 WebSocketPeer；测试可替换为收集器（无需真实网络）。
var send_override: Callable = Callable()


func _ready() -> void:
	_read_env()
	Game._load_card_db()
	sim_host = BattleSimHost.new()
	sim_host.name = "AuthoritySimHost"
	add_child(sim_host)
	if auto_connect:
		connect_to_relay()


func _read_env() -> void:
	relay_host = _env("NSOC_RELAY_HOST", relay_host)
	relay_port = int(_env("NSOC_RELAY_PORT", str(relay_port)))
	authority_key = _env("NSOC_AUTHORITY_KEY", "")
	room_id = _env("NSOC_ROOM_ID", "")
	match_config_path = _env("NSOC_MATCH_CONFIG", "")
	_apply_cmdline()


func _env(key: String, fallback: String) -> String:
	var v := OS.get_environment(key)
	return fallback if v == "" else v


## 支持 --room=123 / --host=.. / --port=.. / --config=..（`godot ... -- 后面的参数`）。
func _apply_cmdline() -> void:
	for arg in OS.get_cmdline_user_args():
		var a := String(arg)
		if a.begins_with("--room="):
			room_id = a.substr(7)
		elif a.begins_with("--host="):
			relay_host = a.substr(7)
		elif a.begins_with("--port="):
			relay_port = int(a.substr(7))
		elif a.begins_with("--config="):
			match_config_path = a.substr(9)


# ══ 与中继的连接 ══════════════════════════════════════════════════════════

func authority_uuid() -> String:
	return "authority-%d" % OS.get_process_id()


func connect_to_relay() -> bool:
	var url := "ws://%s:%d/ws?uuid=%s&nickname=%s&role=authority" % [
		relay_host, relay_port, authority_uuid(), "authority",
	]
	_peer = WebSocketPeer.new()
	var err := _peer.connect_to_url(url)
	if err != OK:
		push_error("AuthorityMain: connect_to_url failed: %d" % err)
		_peer = null
		return false
	return true


func _process(_delta: float) -> void:
	_poll_relay()
	if session != null and not _ticking:
		_ticking = true
		await tick_once()
		_ticking = false


func _poll_relay() -> void:
	if _peer == null:
		_try_reconnect()
		return
	_peer.poll()
	match _peer.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			_reconnect_delay = RECONNECT_DELAY_MIN
			if not _registered:
				_registered = true
				register_authority()
			while _peer.get_available_packet_count() > 0:
				var text: String = _peer.get_packet().get_string_from_utf8()
				handle_relay_text(text)
		WebSocketPeer.STATE_CLOSED:
			# 原来这里只是把 _peer 置空就完事 —— 权威进程会**永久失联**且不报错。
			# 现在改为退避重连，并在连上后重新注册（见 register_authority 的两种情形）。
			print("[authority] relay connection closed -> reconnect in %.1fs" % _reconnect_delay)
			_peer = null
			_registered = false
			_schedule_reconnect()


## 排下一次重连时刻，并把退避翻倍。
func _schedule_reconnect() -> void:
	_reconnect_at = Time.get_ticks_msec() / 1000.0 + _reconnect_delay
	_reconnect_delay = minf(_reconnect_delay * 2.0, RECONNECT_DELAY_MAX)


## 到点就重连；未到点或失败则继续等下一次。
func _try_reconnect() -> void:
	var now := Time.get_ticks_msec() / 1000.0
	if _reconnect_at <= 0.0:
		_schedule_reconnect()
		return
	if now < _reconnect_at:
		return
	_reconnect_at = 0.0
	if connect_to_relay():
		print("[authority] reconnecting to relay %s:%d (room=%s)" % [
			relay_host, relay_port, room_id])
	else:
		_schedule_reconnect()


## 注册。分两种情形（中继侧对应两种用法）：
##   无 room_id → **待命**：只校验密钥，等中继在有人建"权威模式房间"时派单；
##   有 room_id → 直接接管该房间（NSOC_ROOM_ID / --room，便于手工联调）。
func register_authority() -> void:
	_send_to_relay({
		"type": "room/authority_join",
		"payload": {"room_id": room_id, "key": authority_key},
	})


func _send_to_relay(msg: Dictionary) -> void:
	if send_override.is_valid():
		send_override.call(msg)
		return
	if _peer == null or _peer.get_ready_state() != WebSocketPeer.STATE_OPEN:
		push_warning("AuthorityMain: relay not connected, drop %s" % msg.get("type", "?"))
		return
	_peer.send_text(JSON.stringify(msg))


## 处理一条中继来的文本（公开以便无网络测试）。
func handle_relay_text(text: String) -> void:
	var d = JSON.parse_string(text)
	if typeof(d) != TYPE_DICTIONARY:
		push_warning("AuthorityMain: invalid JSON: %s" % text.left(120))
		return
	handle_relay_message(d)


## 处理一条中继来的消息：注册回执 → 开局；其余视为玩家消息交给会话层。
func handle_relay_message(d: Dictionary) -> void:
	relay_message.emit(d)
	var type := String(d.get("type", ""))
	if type == "authority/ready":
		print("[authority] ready, waiting for room assignment")
		return
	if type == "authority/host_room":
		# 中继把房间派给我们：带房号再注册一次（密钥已校验过）
		var assign: Dictionary = d.get("payload", {})
		room_id = String(assign.get("room_id", ""))
		print("[authority] assigned room=%s" % room_id)
		register_authority()
		return
	if type == "authority/start_match":
		# 大厅给出的开局配置（牌组 / 英雄 / 关卡）：以它为准重建对局
		create_match_from_config(d.get("payload", {}))
		return
	if type == "authority/joined":
		# 断线重连回**同一个**房间时 session 还在：绝不能重建对局（会把权威盘面清空、
		# 手牌/血量全部回滚到开局）。只有换房间或首次开局才建。
		if session != null and room_id != "" and _session_room_id == room_id:
			print("[authority] rejoined room=%s with live session, board state kept" % room_id)
			return
		create_match_for(d.get("payload", {}))
		return
	if type == "authority/released":
		# 中继已把我们从房间摘下来（房间销毁，或我们自己刚交还）：回待命接下一局。
		var rel: Dictionary = d.get("payload", {})
		print("[authority] released room=%s reason=%s -> standby" % [
			String(rel.get("room_id", "")), String(rel.get("reason", ""))])
		reset_to_standby()
		return
	if type == "authority/rejected":
		push_error("AuthorityMain: 权威注册被拒: %s" % str(d.get("payload", {})))
		# 重连时房间可能已经不在了：不退回待命的话，这个权威进程再也接不到活。
		if String((d.get("payload", {}) as Dictionary).get("reason", "")) == "no_such_room" \
				and room_id != "":
			print("[authority] pinned room gone -> falling back to standby")
			reset_to_standby()
		return
	var from := String(d.get("from", ""))
	if from == "" or session == null:
		return
	var res: Dictionary = session.handle_client_message(from, d)
	print("[authority] %s from=%s accepted=%s reason=%s pending=%s" % [
		type, from, str(res.get("accepted", false)), String(res.get("reason", "")),
		str(session.authority().has_pending_work())])
	flush_outbound()


# ══ 对局 ══════════════════════════════════════════════════════════════════

## 用 `authority/joined` 的名单开局（配置来自 NSOC_MATCH_CONFIG，缺省用内置默认）。
##
## 注意：`authority/joined` 带的是**注册那一刻**的房间快照 —— 经常只有房主一个人
## （对手还没进来）。用它开出来的"单人局"会被 `_check_finished` 立刻判为结束
## （`alive.size() <= 1`），进而让本进程误以为"这局打完了"而提前交还房间。
## 因此名单不足两人时**不开局**，等大厅的 `authority/start_match` 交完整配置。
func create_match_for(joined: Dictionary) -> void:
	var roster: Array = joined.get("players", [])
	if roster.size() < 2:
		print("[authority] room=%s roster=%s <2, waiting for authority/start_match" % [
			room_id, str(roster)])
		return
	var config := _load_match_config()
	if config.is_empty():
		config = build_default_config(roster)
	_start_session(config)


## 用**大厅给出的配置**开局（权威模式下由房主通过 authority/start_match 交过来）。
## 缺失字段（card_costs / match_id / seed）在这里补齐，避免大厅漏发导致开局失败。
func create_match_from_config(cfg: Dictionary) -> void:
	if cfg.is_empty():
		push_warning("AuthorityMain: authority/start_match 载荷为空，忽略")
		return
	var config: Dictionary = cfg.duplicate(true)
	if not config.has("card_costs"):
		var costs: Dictionary = {}
		for key in Game.card_db.keys():
			var card = Game.card_db[key]
			if card != null:
				costs[String(key)] = int(card.cost)
		config["card_costs"] = costs
	if not config.has("match_id"):
		config["match_id"] = "auth_%d" % Time.get_ticks_msec()
	if not config.has("seed"):
		config["seed"] = 20260101
	if not config.has("hand_size"):
		config["hand_size"] = 3
	print("[authority] start_match players=%s" % str(config.get("players", [])))
	_start_session(config)


## 共用尾段：挂模拟宿主 → 建会话 → 下发 hello/state → 通知外部。
func _start_session(config: Dictionary) -> void:
	sim_host.setup_once()
	# 上一局的盘面还挂在 Game.registry 上（`BoardSlotFactory.create_headless` 会 add），
	# 不清掉的话第二局会带着上一局的 slot 一起结算 —— 这正是"一局一重启"时代被掩盖的问题。
	if Game.registry != null:
		Game.registry.clear()
	config["sim_host"] = sim_host
	session = BattleServerSession.new()
	session.configure(NetProtocol.VERSION, "")
	session.create_match(config)
	_session_room_id = room_id
	_released = false
	flush_outbound()
	match_created.emit(String(config.get("match_id", "")))


## 回到待命：丢掉已结束/失效的对局上下文，以"无房号"身份重新注册，等中继派下一局。
##
## 由两条路径触发：中继的 `authority/released`（房间销毁或我们主动交还），
## 以及重连后 `authority/rejected{no_such_room}`（原房间已经不在了）。
## 注意 `--room=` / `NSOC_ROOM_ID` 的固定房号只服务那一次接管，之后转普通待命，
## 否则房间没了会陷入"注册 → 被拒 → 再注册"的死循环。
func reset_to_standby() -> void:
	if session != null:
		print("[authority] discarding session for room=%s" % _session_room_id)
	session = null
	_session_room_id = ""
	_released = false
	room_id = ""
	register_authority()


func _load_match_config() -> Dictionary:
	if match_config_path == "":
		return {}
	if not FileAccess.file_exists(match_config_path):
		push_warning("AuthorityMain: 配置不存在: %s" % match_config_path)
		return {}
	var text := FileAccess.get_file_as_string(match_config_path)
	var d = JSON.parse_string(text)
	if typeof(d) != TYPE_DICTIONARY:
		push_warning("AuthorityMain: 配置不是 JSON 对象: %s" % match_config_path)
		return {}
	return d


## 服务器主循环：结算待处理动作（法术/技能/装备/行动阶段）后下发结果。
func tick_once() -> void:
	if session == null:
		return
	var pending: bool = session.authority().has_pending_work()
	await session.tick()
	if pending:
		print("[authority] tick 结算完成 pending_was=%s" % str(pending))
	flush_outbound()
	_maybe_release_after_match()


## 对局结束后**主动**把房间交还中继，回到待命。
##
## 为什么必须主动交还：中继只在"房间销毁"时释放权威，而 v2 下 `game/end` 被当成
## 服务器专属消息丢弃，房间会一直留到玩家退房或 60 分钟过期。不主动交还的话，
## 一轮打完接着开下一局会静默退回 v1（中继回 authoritative=false）。
func _maybe_release_after_match() -> void:
	if _released or session == null:
		return
	var auth := session.authority()
	if auth == null or not auth.is_finished():
		return
	# 单人局（名单快照不完整导致的退化对局）不算"打完一局"，不能据此交还房间。
	if session.players().size() < 2:
		return
	_released = true
	print("[authority] match finished room=%s -> requesting release" % room_id)
	_send_to_relay({"type": "room/authority_release", "payload": {"room_id": room_id}})


## 把会话层给每个玩家排的消息发回中继（`to` 决定中继路由：定向或广播）。
func flush_outbound() -> void:
	if session == null:
		return
	for pid_raw in session.players():
		var pid := String(pid_raw)
		for msg in session.drain_outbound(pid):
			var out: Dictionary = (msg as Dictionary).duplicate()
			out["to"] = pid
			_send_to_relay(out)


# ══ 默认对局配置（本地联调可用；正式配置由大厅下发）══════════════════════

## 内置 1v1 默认配置：按名单两两分队，牌组取卡库里前若干张单位卡。
static func build_default_config(player_list: Array) -> Dictionary:
	var players: Array = []
	var teams: Dictionary = {}
	var hero_hp: Dictionary = {}
	var decks: Dictionary = {}
	var card_costs: Dictionary = {}
	var idx: int = 0
	for pid_raw in player_list:
		var pid := String(pid_raw)
		players.append(pid)
		teams[pid] = "defender" if idx % 2 == 0 else "attacker"
		hero_hp[pid] = 30
		decks[pid] = default_deck()
		idx += 1
	for key in Game.card_db.keys():
		var card = Game.card_db[key]
		if card != null:
			card_costs[String(key)] = int(card.cost)
	return {
		"match_id": "auth_%d" % Time.get_ticks_msec(),
		"seed": 20260101,
		"players": players,
		"teams": teams,
		"hero_hp": hero_hp,
		"decks": decks,
		"card_costs": card_costs,
		"hand_size": 3,
		"rate_limit_per_sec": 20,
		"board": {"players": players, "teams": teams, "hero_hp": hero_hp},
	}


## 默认牌组：卡库里前 10 张单位卡各 2 张（够开局手牌与数回合）。
static func default_deck() -> Array:
	var out: Array = []
	for key in Game.card_db.keys():
		var card = Game.card_db[key]
		if card is CardUnit:
			out.append(String(key))
			out.append(String(key))
		if out.size() >= 20:
			break
	return out
