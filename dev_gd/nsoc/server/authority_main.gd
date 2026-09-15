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

var relay_host: String = DEFAULT_HOST
var relay_port: int = DEFAULT_PORT
var authority_key: String = ""
var room_id: String = ""
var match_config_path: String = ""

var session: BattleServerSession = null
var sim_host: BattleSimHost = null

var _peer: WebSocketPeer = null
var _registered: bool = false
var _ticking: bool = false

## 发送缝隙：默认走 WebSocketPeer；测试可替换为收集器（无需真实网络）。
var send_override: Callable = Callable()


func _ready() -> void:
	_read_env()
	Game._load_card_db()
	sim_host = BattleSimHost.new()
	sim_host.name = "AuthoritySimHost"
	add_child(sim_host)


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
		return
	_peer.poll()
	match _peer.get_ready_state():
		WebSocketPeer.STATE_OPEN:
			if not _registered:
				_registered = true
				register_authority()
			while _peer.get_available_packet_count() > 0:
				var text: String = _peer.get_packet().get_string_from_utf8()
				handle_relay_text(text)
		WebSocketPeer.STATE_CLOSED:
			_peer = null
			_registered = false


## 用密钥向中继注册为房间的权威（未配置 room_id 时只告警，等外部指定）。
func register_authority() -> void:
	if room_id == "":
		push_warning("AuthorityMain: room_id 未提供（NSOC_ROOM_ID / --room），暂不注册")
		return
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
	if type == "authority/joined":
		create_match_for(d.get("payload", {}))
		return
	if type == "authority/rejected":
		push_error("AuthorityMain: 权威注册被拒: %s" % str(d.get("payload", {})))
		return
	var from := String(d.get("from", ""))
	if from == "" or session == null:
		return
	session.handle_client_message(from, d)
	flush_outbound()


# ══ 对局 ══════════════════════════════════════════════════════════════════

## 用 `authority/joined` 的名单开局（配置来自 NSOC_MATCH_CONFIG，缺省用内置默认）。
func create_match_for(joined: Dictionary) -> void:
	var config := _load_match_config()
	if config.is_empty():
		config = build_default_config(joined.get("players", []))
	sim_host.setup_once()
	config["sim_host"] = sim_host
	session = BattleServerSession.new()
	session.configure(NetProtocol.VERSION, "")
	session.create_match(config)
	flush_outbound()
	match_created.emit(String(config.get("match_id", "")))


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
	await session.tick()
	flush_outbound()


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
