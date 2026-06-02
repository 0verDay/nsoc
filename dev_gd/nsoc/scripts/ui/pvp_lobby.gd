extends Control

# PvpLobby —— 联机大厅 UI（纯代码构建，无需 .tscn）。
#
# 页面流程：
#   [未连接]  → 服务器地址输入 + 连接按钮
#   [连接中]  → 加载提示
#   [已连接]  → 昵称显示 + 创建房间 / 房间列表（刷新）
#   [房间内]  → 玩家列表 + 开始按钮（仅房主）/ 等待提示 + 离开按钮
#
# 关闭方式：右上角 × 按钮，或 room/expired / disconnect 信号

signal closed   # 大厅关闭时发出，供 MainMenu 销毁节点

# ── 页面枚举 ──────────────────────────────────────────────────────────
enum Page { CONNECT, CONNECTING, LOBBY, ROOM }

# ── 样式常量 ──────────────────────────────────────────────────────────
const FONT_SIZE_TITLE: int  = 48
const FONT_SIZE_BODY: int   = 28
const FONT_SIZE_SMALL: int  = 22
const BTN_HEIGHT: float     = 72.0
const PANEL_BG: Color       = Color("#f8f9fa")
const ACCENT: Color         = Color("#339af0")
const DANGER: Color         = Color("#fa5252")
const TEXT_DARK: Color      = Color("#212529")
const TEXT_MUTED: Color     = Color("#868e96")

# ── 运行时状态 ────────────────────────────────────────────────────────
var _page: int = Page.CONNECT
var _room_id: String = ""
var _host_uuid: String = ""
var _players: Array = []        # RoomPlayer[]  {uuid, nickname, slot}
var _rooms: Array = []          # 房间列表缓存 [{id, host_nickname, player_count}]

# ── UI 节点引用 ───────────────────────────────────────────────────────
var _root_panel: Panel
var _title_lbl: Label
var _status_lbl: Label
var _page_container: Control    # 每次切页时重建子节点
var _close_btn: Button

func _ready() -> void:
	_build_frame()
	_connect_net_signals()
	# 若 Net 已连接（如二次打开大厅），直接进大厅页而不等信号
	if Net.is_connected_to_server():
		_go_page(Page.LOBBY)
	else:
		_go_page(Page.CONNECT)

# ── 帧骨架 ───────────────────────────────────────────────────────────
func _build_frame() -> void:
	# 1. 自身撑满 CanvasLayer 整个视口
	set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)

	# 2. 半透明遮罩底层
	var bg := ColorRect.new()
	bg.color = Color(0, 0, 0, 0.5)
	bg.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	bg.mouse_filter = Control.MOUSE_FILTER_STOP
	add_child(bg)

	# 3. 居中白色面板：用 CenterContainer 包裹，保证任何分辨率下都居中
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	add_child(center)

	_root_panel = Panel.new()
	_root_panel.custom_minimum_size = Vector2(720, 860)
	if has_node("/root/Game"):
		_root_panel.add_theme_stylebox_override("panel",
			ThemeFactory.panel(PANEL_BG, Color("#dee2e6"), 1, 24, true))
	center.add_child(_root_panel)

	# 4. 关闭按钮（右上角，相对 _root_panel）
	_close_btn = Button.new()
	_close_btn.text = "×"
	_close_btn.flat = true
	_close_btn.add_theme_font_size_override("font_size", 40)
	_close_btn.set_anchors_and_offsets_preset(Control.PRESET_TOP_RIGHT)
	_close_btn.offset_left   = -56
	_close_btn.offset_top    =   4
	_close_btn.offset_right  =  -4
	_close_btn.offset_bottom =  56
	_close_btn.pressed.connect(_on_close)
	_root_panel.add_child(_close_btn)

	# 5. 标题（相对 _root_panel）
	_title_lbl = Label.new()
	_title_lbl.text = "联机对战"
	_title_lbl.add_theme_font_size_override("font_size", FONT_SIZE_TITLE)
	_title_lbl.add_theme_color_override("font_color", TEXT_DARK)
	_title_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_title_lbl.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_title_lbl.offset_top    = 24
	_title_lbl.offset_bottom = 80
	_root_panel.add_child(_title_lbl)

	# 6. 状态提示行
	_status_lbl = Label.new()
	_status_lbl.text = ""
	_status_lbl.add_theme_font_size_override("font_size", FONT_SIZE_SMALL)
	_status_lbl.add_theme_color_override("font_color", TEXT_MUTED)
	_status_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_status_lbl.set_anchors_and_offsets_preset(Control.PRESET_TOP_WIDE)
	_status_lbl.offset_top    = 84
	_status_lbl.offset_bottom = 118
	_root_panel.add_child(_status_lbl)

	# 7. 内容区
	_page_container = MarginContainer.new()
	_page_container.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	_page_container.offset_top    = 128
	_page_container.offset_left   = 20
	_page_container.offset_right  = -20
	_page_container.offset_bottom = -12
	_root_panel.add_child(_page_container)

# ── 页面切换 ─────────────────────────────────────────────────────────
func _go_page(p: int) -> void:
	_page = p
	for child in _page_container.get_children():
		child.queue_free()
	match p:
		Page.CONNECT:    _build_connect_page()
		Page.CONNECTING: _build_connecting_page()
		Page.LOBBY:      _build_lobby_page()
		Page.ROOM:       _build_room_page()

# ── 连接配置页 ───────────────────────────────────────────────────────
func _build_connect_page() -> void:
	_title_lbl.text = "联机对战"
	var cfg := ProfileManager.get_server_config()
	var vbox := _make_vbox(16)
	_page_container.add_child(vbox)

	# 昵称行
	vbox.add_child(_make_label("昵称", FONT_SIZE_SMALL, TEXT_MUTED))
	var nick_edit := _make_line_edit(ProfileManager.get_nickname(), "你的昵称")
	vbox.add_child(nick_edit)

	# 服务器地址行
	vbox.add_child(_make_label("服务器地址", FONT_SIZE_SMALL, TEXT_MUTED))
	var host_edit := _make_line_edit(cfg.host, "127.0.0.1")
	vbox.add_child(host_edit)

	# 端口行
	vbox.add_child(_make_label("端口", FONT_SIZE_SMALL, TEXT_MUTED))
	var port_edit := _make_line_edit(str(cfg.port), "8080")
	vbox.add_child(port_edit)

	vbox.add_child(_make_spacer(12))
	var connect_btn := _make_primary_btn("连接服务器")
	vbox.add_child(connect_btn)
	connect_btn.pressed.connect(func():
		var nick: String = nick_edit.text.strip_edges()
		if nick == "":
			nick = "玩家"
		Net.set_nickname(nick)
		var host: String = host_edit.text.strip_edges()
		var port: int = int(port_edit.text.strip_edges())
		if host == "":
			host = "127.0.0.1"
		if port <= 0:
			port = 8080
		ProfileManager.save_server_config(host, port)
		Net.connect_to_server(host, port)
		_go_page(Page.CONNECTING)
	)

# ── 连接中页 ─────────────────────────────────────────────────────────
func _build_connecting_page() -> void:
	_title_lbl.text = "连接中…"
	var lbl := _make_label("正在连接服务器，请稍候…", FONT_SIZE_BODY, TEXT_MUTED)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_page_container.add_child(lbl)

# ── 大厅页 ───────────────────────────────────────────────────────────
func _build_lobby_page() -> void:
	_title_lbl.text = "联机大厅"
	_status_lbl.text = "昵称：%s   UUID: …%s" % [Net.get_nickname(), Net.get_uuid().right(8)]
	var vbox := _make_vbox(12)
	_page_container.add_child(vbox)

	# 操作行
	var top_row := HBoxContainer.new()
	top_row.add_theme_constant_override("separation", 12)
	vbox.add_child(top_row)
	var create_btn := _make_primary_btn("创建房间")
	top_row.add_child(create_btn)
	var refresh_btn := _make_secondary_btn("刷新列表")
	top_row.add_child(refresh_btn)
	create_btn.pressed.connect(_on_create_room)
	refresh_btn.pressed.connect(_on_refresh_rooms)

	vbox.add_child(_make_label("可加入的房间：", FONT_SIZE_SMALL, TEXT_MUTED))

	# 房间列表滚动区
	var scroll := ScrollContainer.new()
	scroll.size_flags_vertical = Control.SIZE_EXPAND_FILL
	vbox.add_child(scroll)
	var list_vbox := VBoxContainer.new()
	list_vbox.name = "RoomListVBox"
	list_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_vbox.add_theme_constant_override("separation", 8)
	scroll.add_child(list_vbox)

	_refresh_room_list_ui()
	# 拉一次最新列表
	Net.send({"type": "room/list"})

func _refresh_room_list_ui() -> void:
	var container := _page_container.find_child("RoomListVBox", true, false)
	if container == null:
		return
	for c in container.get_children():
		c.queue_free()
	if _rooms.is_empty():
		container.add_child(_make_label("暂无可加入的房间", FONT_SIZE_SMALL, TEXT_MUTED))
		return
	for room in _rooms:
		var row := HBoxContainer.new()
		row.add_theme_constant_override("separation", 16)
		container.add_child(row)
		var info := _make_label(
			"房间 %s  房主: %s  人数: %d/6" % [room.id, room.host_nickname, room.player_count],
			FONT_SIZE_SMALL, TEXT_DARK
		)
		info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(info)
		var join_btn := _make_primary_btn("加入")
		join_btn.custom_minimum_size = Vector2(100, 48)
		row.add_child(join_btn)
		var rid: String = room.id
		join_btn.pressed.connect(func(): _on_join_room(rid))

# ── 房间内页 ─────────────────────────────────────────────────────────
func _build_room_page() -> void:
	_title_lbl.text = "房间 " + _room_id
	var is_host: bool = (_host_uuid == Net.get_uuid())
	_status_lbl.text = "身份：%s" % ("房主" if is_host else "玩家")
	var vbox := _make_vbox(16)
	_page_container.add_child(vbox)

	vbox.add_child(_make_label("当前玩家（%d 人）：" % _players.size(), FONT_SIZE_SMALL, TEXT_MUTED))
	for p in _players:
		var row := HBoxContainer.new()
		vbox.add_child(row)
		var tag: String = " 【房主】" if p.uuid == _host_uuid else ""
		var lbl := _make_label("  Slot%d  %s%s" % [p.slot, p.nickname, tag], FONT_SIZE_BODY, TEXT_DARK)
		lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		row.add_child(lbl)

	vbox.add_child(_make_spacer(20))

	if is_host:
		var start_btn := _make_primary_btn("开始战斗")
		vbox.add_child(start_btn)
		start_btn.disabled = (_players.size() < 2)
		if _players.size() < 2:
			vbox.add_child(_make_label("等待其他玩家加入…（至少 2 人）",
				FONT_SIZE_SMALL, TEXT_MUTED))
		start_btn.pressed.connect(_on_start_game)
	else:
		vbox.add_child(_make_label("等待房主开始…", FONT_SIZE_BODY, TEXT_MUTED))

	vbox.add_child(_make_spacer(12))
	var leave_btn := _make_secondary_btn("离开房间")
	vbox.add_child(leave_btn)
	leave_btn.pressed.connect(_on_leave_room)

# ── 网络事件处理 ─────────────────────────────────────────────────────
func _connect_net_signals() -> void:
	Net.connected.connect(_on_net_connected)
	Net.connection_failed.connect(_on_net_failed)
	Net.disconnected.connect(_on_net_disconnected)
	Net.message_received.connect(_on_message)

func _on_net_connected() -> void:
	_go_page(Page.LOBBY)

func _on_net_failed(reason: String) -> void:
	_title_lbl.text = "连接失败"
	_status_lbl.text = reason
	_go_page(Page.CONNECT)

func _on_net_disconnected() -> void:
	_room_id = ""
	_players = []
	_go_page(Page.CONNECT)
	_status_lbl.text = "已断线，请重新连接"

func _on_message(msg: Dictionary) -> void:
	var type: String = String(msg.get("type", ""))
	var payload = msg.get("payload", {})
	if typeof(payload) != TYPE_DICTIONARY:
		payload = {}
	match type:
		"room/create_ok":
			_room_id   = String(msg.get("room_id", ""))
			_host_uuid = String(payload.get("host_uuid", ""))
			_players   = _parse_players(payload.get("players", []))
			_go_page(Page.ROOM)
		"room/create_failed":
			_status_lbl.text = "创建失败：" + String(payload.get("reason", ""))
		"room/joined":
			_room_id   = String(msg.get("room_id", ""))
			_host_uuid = String(payload.get("host_uuid", ""))
			_players   = _parse_players(payload.get("players", []))
			if _page != Page.ROOM:
				_go_page(Page.ROOM)
			else:
				_rebuild_room_player_list()
		"room/join_rejected":
			_status_lbl.text = "加入失败：" + String(payload.get("reason", ""))
		"room/left":
			# 有人离开，刷新玩家列表（等 room/joined 带最新列表会被下一条覆盖）
			var leaver: String = String(payload.get("uuid", ""))
			_players = _players.filter(func(p): return p.uuid != leaver)
			if _page == Page.ROOM:
				_rebuild_room_player_list()
		"room/list_response":
			var raw = payload.get("rooms", [])
			_rooms = []
			if typeof(raw) == TYPE_ARRAY:
				for r in raw:
					if typeof(r) == TYPE_DICTIONARY:
						_rooms.append({
							"id": String(r.get("id", "")),
							"host_nickname": String(r.get("host_nickname", "")),
							"player_count": int(r.get("player_count", 0)),
						})
			if _page == Page.LOBBY:
				_refresh_room_list_ui()
		"room/expired", "room/destroy":
			_room_id = ""
			_players = []
			_go_page(Page.LOBBY)
			_status_lbl.text = "房间已过期或被销毁"
		"disconnect/notify":
			if _page == Page.ROOM:
				var leaver: String = String(payload.get("nickname", "未知玩家"))
				_status_lbl.text = leaver + " 已断线"
				var uuid_gone: String = String(payload.get("uuid", ""))
				_players = _players.filter(func(p): return p.uuid != uuid_gone)
				_rebuild_room_player_list()
		"game/start":
			# 服务器转发房主发出的 game/start，其他玩家切到战斗场景
			_disconnect_net_signals()
			_on_close()
			# game_context.bootstrap_pvp 留待 Step 5 补全
			# 目前打印提示，后续接战斗场景
			print("PvpLobby: received game/start, TODO: load PvpMain scene")

func _disconnect_net_signals() -> void:
	if Net.connected.is_connected(_on_net_connected):
		Net.connected.disconnect(_on_net_connected)
	if Net.connection_failed.is_connected(_on_net_failed):
		Net.connection_failed.disconnect(_on_net_failed)
	if Net.disconnected.is_connected(_on_net_disconnected):
		Net.disconnected.disconnect(_on_net_disconnected)
	if Net.message_received.is_connected(_on_message):
		Net.message_received.disconnect(_on_message)

# ── 按钮动作 ─────────────────────────────────────────────────────────
func _on_create_room() -> void:
	Net.send({"type": "room/create"})

func _on_join_room(room_id: String) -> void:
	Net.send({"type": "room/join", "room_id": room_id, "payload": {"room_id": room_id}})

func _on_refresh_rooms() -> void:
	Net.send({"type": "room/list"})

func _on_leave_room() -> void:
	Net.send({"type": "room/leave", "room_id": _room_id})
	_room_id = ""
	_players = []
	_go_page(Page.LOBBY)

func _on_start_game() -> void:
	Net.send_to_room("game/start", _room_id)
	# 房主端：TODO Step 5 调用 bootstrap_pvp 后切战斗场景

func _on_close() -> void:
	_disconnect_net_signals()
	queue_free()
	closed.emit()

# ── 辅助：玩家列表解析 ───────────────────────────────────────────────
static func _parse_players(raw) -> Array:
	var out: Array = []
	if typeof(raw) != TYPE_ARRAY:
		return out
	for entry in raw:
		if typeof(entry) != TYPE_DICTIONARY:
			continue
		out.append({
			"uuid":     String(entry.get("uuid", "")),
			"nickname": String(entry.get("nickname", "")),
			"slot":     int(entry.get("slot", 0)),
		})
	return out

# 仅重建房间页玩家列表（不整页重建，减少闪烁）
func _rebuild_room_player_list() -> void:
	if _page != Page.ROOM:
		return
	_go_page(Page.ROOM)

# ── UI 工厂辅助 ───────────────────────────────────────────────────────
func _make_vbox(sep: int) -> VBoxContainer:
	var vb := VBoxContainer.new()
	vb.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vb.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	vb.add_theme_constant_override("separation", sep)
	return vb

func _make_label(text: String, font_size: int, color: Color) -> Label:
	var lbl := Label.new()
	lbl.text = text
	lbl.add_theme_font_size_override("font_size", font_size)
	lbl.add_theme_color_override("font_color", color)
	lbl.autowrap_mode = TextServer.AUTOWRAP_WORD
	return lbl

func _make_line_edit(default_text: String, placeholder: String) -> LineEdit:
	var le := LineEdit.new()
	le.text = default_text
	le.placeholder_text = placeholder
	le.add_theme_font_size_override("font_size", FONT_SIZE_BODY)
	le.custom_minimum_size = Vector2(0, BTN_HEIGHT)
	return le

func _make_primary_btn(text: String) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.add_theme_font_size_override("font_size", FONT_SIZE_BODY)
	btn.custom_minimum_size = Vector2(0, BTN_HEIGHT)
	if has_node("/root/Game"):
		ThemeFactory.apply_button_styles(btn, ThemeFactory.primary_button_styles())
		btn.add_theme_color_override("font_color", Color.WHITE)
		btn.add_theme_color_override("font_hover_color", Color.WHITE)
		btn.add_theme_color_override("font_pressed_color", Color.WHITE)
	return btn

func _make_secondary_btn(text: String) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.add_theme_font_size_override("font_size", FONT_SIZE_BODY)
	btn.custom_minimum_size = Vector2(0, BTN_HEIGHT)
	if has_node("/root/Game"):
		ThemeFactory.apply_button_styles(btn, ThemeFactory.settings_button_styles())
	return btn

func _make_spacer(h: int) -> Control:
	var sp := Control.new()
	sp.custom_minimum_size = Vector2(0, h)
	return sp
