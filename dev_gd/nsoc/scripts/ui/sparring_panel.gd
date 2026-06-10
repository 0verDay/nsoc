class_name SparringPanel
extends SecondaryPanel

# 演武切磋二级界面（res://scenes/SparringPanel.tscn）。
# 继承 SecondaryPanel 复用 BackBtn 风格 + 转场淡入淡出。
#
# 布局（.tscn 中静态节点）：
#   BackBtn                  : 右上 160×80
#   RightActionPnl/...       : 右侧 4 个模式按钮（ModeBtn0~3）
#   LeftContentPnl           : 左侧主内容区（脚本动态填充）
#
# 模式分工（点击右侧按钮切换）：
#   ModeBtn0「我的房间」: 视为创建房间 → 显示房号 / 玩家列表 / 开始战斗 / 离开房间
#   ModeBtn1「加入房间」: 显示房间列表 + 刷新按钮
#   ModeBtn2「随机匹配」: 占位（施工中）
#   ModeBtn3「随机排位」: 占位（施工中）
#
# 测试期默认配置（跳过昵称 / 服务器地址 / 端口设置）：
#   昵称="player", 服务器=127.0.0.1:8080
#
# ⚠️  父节点（RightSidePnl）由 MainMenu 以绝对 Tween size/position 控制，
#     不走 Container 路径，anchor 布局时序不可靠。
#     因此本脚本在 _notification(NOTIFICATION_RESIZED) 里手动计算并设置
#     RightActionPnl / LeftContentPnl 的 position + size，
#     完全绕开 anchor 系统，确保在任何 size 下都能正确布局。

const DEFAULT_MODE: int = 3  # 默认落在"随机排位"占位页

const MODE_NAMES: Array = [
	"我的房间",
	"加入房间",
	"随机匹配",
	"随机排位",
]

# ── 测试期网络默认值（跳过昵称 / 服务器配置环节） ─────────────────────────
const DEFAULT_NICKNAME: String = "player"
const DEFAULT_HOST:     String = "127.0.0.1"
const DEFAULT_PORT:     int    = 8080

# ── 房间列表刷新冷却 ────────────────────────────────────────────────────
const REFRESH_COOLDOWN: float = 3.0

# ── 字号 / 颜色 ─────────────────────────────────────────────────────────
const FONT_SIZE_TITLE: int   = 48
const FONT_SIZE_BODY: int    = 28
const FONT_SIZE_SMALL: int   = 22
const BTN_HEIGHT: float      = 72.0
const TEXT_DARK: Color       = Color("#212529")
const TEXT_MUTED: Color      = Color("#868e96")
const ACCENT: Color          = Color(0.109804, 0.494118, 0.839216, 1)

# ── 右侧面板布局参数（与 BackBtn 保持对齐） ───────────────────────────────
const RIGHT_MARGIN:   float = 20.0   # 距屏幕右边 / 上边 / 下边的留白
const RIGHT_WIDTH:    float = 160.0  # BackBtn 及 RightActionPnl 宽度
const BACKBTN_H:      float = 80.0   # BackBtn 高度
const GAP:            float = 20.0   # BackBtn 与 RightActionPnl 的间距
const LEFT_GAP:       float = 20.0   # LeftContentPnl 左边留白
const LR_GAP:         float = 20.0   # LeftContentPnl 与 RightActionPnl 之间的间距

# ── 样式 ─────────────────────────────────────────────────────────────────────
static func _selected_style() -> Dictionary:
	var normal := ThemeFactory.panel(Color("#1c7ed6"), Color.WHITE, 3, 12, true)
	var hover  := ThemeFactory.panel(Color("#1971c2"), Color.WHITE, 3, 12, true)
	return {"normal": normal, "hover": hover, "pressed": normal, "disabled": normal}

static func _unselected_style() -> Dictionary:
	return {
		"normal":   ThemeFactory.panel(Color("#adb5bd"), Color.TRANSPARENT, 0, 12),
		"hover":    ThemeFactory.panel(Color("#868e96"), Color.TRANSPARENT, 0, 12),
		"pressed":  ThemeFactory.panel(Color("#868e96"), Color.TRANSPARENT, 0, 12),
		"disabled": ThemeFactory.panel(Color("#ced4da"), Color.TRANSPARENT, 0, 12),
	}

# ── 节点引用 ─────────────────────────────────────────────────────────────────
@onready var right_action_pnl: Panel = $RightActionPnl
@onready var left_content_pnl: Panel = $LeftContentPnl
@onready var _btn0: Button = $RightActionPnl/Margin/VBox/ModeBtn0
@onready var _btn1: Button = $RightActionPnl/Margin/VBox/ModeBtn1
@onready var _btn2: Button = $RightActionPnl/Margin/VBox/ModeBtn2
@onready var _btn3: Button = $RightActionPnl/Margin/VBox/ModeBtn3

var _mode_btns: Array[Button] = []
var _selected_idx: int = DEFAULT_MODE

# ── 网络/房间运行时状态 ──────────────────────────────────────────────────────
var _conn_state: int = STATE_DISCONNECTED   # 镜像 Net 的连接状态
var _room_id: String = ""
var _host_uuid: String = ""
var _players: Array = []          # [{uuid, nickname, slot}, ...]
var _rooms: Array = []            # [{id, host_nickname, player_count}, ...]
var _last_refresh_time: float = -REFRESH_COOLDOWN
var _net_signals_bound: bool = false
var _auto_create_pending: bool = false   # 连上服务器后自动 room/create 标志

# 准备系统
var _player_ready: Dictionary = {}   # uuid → bool（所有玩家的准备状态）
var _is_local_ready: bool = false    # 本地玩家当前准备状态

# 游戏模式（仅房主可设置）
var _match_type: String = "1v1"     # "1v1" / "1v3"

# 各玩家已上报的牌组名列表（uuid/session_id → Array[String]）
# 由 room/deck_ready 消息填入；房主开始游戏时合并到 per_player_decks
var _player_decks: Dictionary = {}

# 各玩家已上报的英雄 key（uuid/session_id → String）
# 由 room/deck_ready 消息填入；房主开始游戏时合并到 per_player_heroes
var _player_heroes: Dictionary = {}

const STATE_DISCONNECTED: int = 0
const STATE_CONNECTING: int   = 1
const STATE_CONNECTED: int    = 2

# ── 初始化 ───────────────────────────────────────────────────────────────────
func _apply_styles() -> void:
	var pnl_style := ThemeFactory.panel(Color.WHITE, Color(1, 1, 1, 0.6), 1, 20, true)
	right_action_pnl.add_theme_stylebox_override("panel", pnl_style)
	left_content_pnl.add_theme_stylebox_override("panel", pnl_style)

	_mode_btns = [_btn0, _btn1, _btn2, _btn3]
	for i in _mode_btns.size():
		var btn := _mode_btns[i]
		btn.add_theme_color_override("font_color",         Color.WHITE)
		btn.add_theme_color_override("font_hover_color",   Color.WHITE)
		btn.add_theme_color_override("font_pressed_color", Color.WHITE)
		btn.pressed.connect(_on_mode_btn_pressed.bind(i))
	_apply_selection(DEFAULT_MODE)

	# BackBtn 退出：清理网络连接
	if back_btn and not back_btn.pressed.is_connected(_on_back_clicked):
		back_btn.pressed.connect(_on_back_clicked)

	# 接管 Net autoload 的镜像状态
	if has_node("/root/Net"):
		_conn_state = STATE_CONNECTED if Net.is_connected_to_server() else STATE_DISCONNECTED
	_bind_net_signals()

	_do_layout()
	# 默认落在 Mode3「随机排位」占位页，不触发联网
	_enter_mode(DEFAULT_MODE)


# ── 手动布局：完全绕开 anchor 系统 ───────────────────────────────────────────
func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		_do_layout()
	elif what == NOTIFICATION_PREDELETE:
		# 节点销毁前清理 Net 信号
		_unbind_net_signals()


func _do_layout() -> void:
	var W: float = size.x
	var H: float = size.y
	if W <= 0.0 or H <= 0.0:
		return

	# BackBtn
	if back_btn:
		back_btn.position = Vector2(W - RIGHT_MARGIN - RIGHT_WIDTH, RIGHT_MARGIN)
		back_btn.size     = Vector2(RIGHT_WIDTH, BACKBTN_H)

	# RightActionPnl：BackBtn 正下方，同宽，撑到底部留白
	var rap_top: float = RIGHT_MARGIN + BACKBTN_H + GAP
	if right_action_pnl:
		right_action_pnl.position = Vector2(W - RIGHT_MARGIN - RIGHT_WIDTH, rap_top)
		right_action_pnl.size     = Vector2(RIGHT_WIDTH, H - rap_top - RIGHT_MARGIN)

	# LeftContentPnl：左留白 ~ RightActionPnl 左边沿再留 LR_GAP
	var lcp_right: float = W - RIGHT_MARGIN - RIGHT_WIDTH - LR_GAP
	if left_content_pnl:
		left_content_pnl.position = Vector2(LEFT_GAP, RIGHT_MARGIN)
		left_content_pnl.size     = Vector2(lcp_right - LEFT_GAP, H - RIGHT_MARGIN * 2.0)


# ── 模式切换 ─────────────────────────────────────────────────────────────────
func _on_mode_btn_pressed(idx: int) -> void:
	if idx == _selected_idx:
		return  # 同 tab 重复点击：忽略

	# 离开「我的房间」时视为退出当前房间
	if _selected_idx == 0 and _room_id != "":
		if has_node("/root/Net") and Net.is_connected_to_server():
			Net.send({"type": "room/leave", "room_id": _room_id})
		_room_id = ""
		_players = []
		_host_uuid = ""

	_selected_idx = idx
	_apply_selection(idx)
	_enter_mode(idx)


func _apply_selection(idx: int) -> void:
	var sel   := _selected_style()
	var unsel := _unselected_style()
	for i in _mode_btns.size():
		ThemeFactory.apply_button_styles(_mode_btns[i], sel if i == idx else unsel)


# 进入指定模式：触发对应初始化（联网 / 拉房间列表）+ 刷新内容。
func _enter_mode(idx: int) -> void:
	match idx:
		0:
			# 我的房间 → 确保已连上服务器；未连接则发起连接，连上后自动 room/create
			_ensure_connected_then(true)
		1:
			# 加入房间 → 确保已连上服务器；连上后请求列表
			_ensure_connected_then(false)
		_:
			# 占位模式：无需联网
			pass
	_refresh_left_content()


# 确保 Net 连接到服务器；连接成功后视 auto_create 决定是否自动建房。
# auto_create=true → 进我的房间；auto_create=false → 进加入房间（后续拉列表）
func _ensure_connected_then(auto_create: bool) -> void:
	_auto_create_pending = auto_create
	if _conn_state == STATE_CONNECTED:
		_on_ready_after_connect()
		return
	if _conn_state == STATE_CONNECTING:
		return  # 等 Net.connected 信号
	# 未连接：读 ProfileManager 服务器配置（手机端需改为 PC 的局域网 IP）
	if has_node("/root/Net"):
		Net.set_nickname(DEFAULT_NICKNAME)
	_conn_state = STATE_CONNECTING
	if has_node("/root/Net"):
		var cfg := ProfileManager.get_server_config()
		Net.connect_to_server(cfg.host, int(cfg.port))


# 连接已就绪后的统一入口（首次连成功 / 已连接进入新模式时调用）。
func _on_ready_after_connect() -> void:
	if _selected_idx == 0:
		# 我的房间：若尚未在房间内，则发 room/create（附带当前 match_type）
		if _room_id == "" and _auto_create_pending:
			_auto_create_pending = false
			Net.send({"type": "room/create", "payload": {"match_type": _match_type}})
		_refresh_left_content()
	elif _selected_idx == 1:
		# 加入房间：拉一次房间列表（受冷却保护）
		_request_room_list(true)
		_refresh_left_content()


# ── 内容渲染：根据 selected_idx + 网络/房间状态构建 LeftContentPnl ─────────
func _refresh_left_content() -> void:
	if left_content_pnl == null:
		return
	# 清空旧内容（包括 .tscn 中的静态 Center/VBox）
	for child in left_content_pnl.get_children():
		child.queue_free()

	# 创建一个全填充的 MarginContainer 作为内容容器
	var holder := MarginContainer.new()
	holder.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	holder.add_theme_constant_override("margin_left",   24)
	holder.add_theme_constant_override("margin_right",  24)
	holder.add_theme_constant_override("margin_top",    24)
	holder.add_theme_constant_override("margin_bottom", 24)
	left_content_pnl.add_child(holder)

	match _selected_idx:
		0:
			print("[SparringPanel] _refresh_left_content → _build_my_room, _match_type=", _match_type)
			_build_my_room(holder)
		1: _build_join_room(holder)
		2: _build_placeholder(holder, MODE_NAMES[2])
		3: _build_placeholder(holder, MODE_NAMES[3])


# ── Mode 0「我的房间」内容 ─────────────────────────────────────────────────
func _build_my_room(holder: Control) -> void:
	var vbox := _make_vbox(16)
	holder.add_child(vbox)

	var title := _make_title(MODE_NAMES[0])
	vbox.add_child(title)

	# 状态：未连接（含连接失败）
	if _conn_state == STATE_DISCONNECTED:
		var cfg := ProfileManager.get_server_config()
		vbox.add_child(_make_hint("连接服务器失败"))
		vbox.add_child(_make_hint("%s:%d" % [cfg.host, cfg.port]))
		vbox.add_child(_make_spacer(8))
		var retry_btn := _make_primary_btn("重新连接")
		retry_btn.pressed.connect(func():
			_ensure_connected_then(_selected_idx == 0)
			_refresh_left_content())
		vbox.add_child(retry_btn)
		var edit_btn := _make_secondary_btn("修改服务器地址")
		edit_btn.pressed.connect(_open_server_config_dialog)
		vbox.add_child(edit_btn)
		return

	# 状态：连接中
	if _conn_state == STATE_CONNECTING:
		var cfg := ProfileManager.get_server_config()
		vbox.add_child(_make_hint("正在连接服务器…"))
		vbox.add_child(_make_hint("%s:%d" % [cfg.host, cfg.port]))
		return

	# 状态：已连接但还没建好房
	if _room_id == "":
		vbox.add_child(_make_hint("正在创建房间…"))
		return

	# 状态：已在房间内 — 左右分栏布局
	var body_row := HBoxContainer.new()
	body_row.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	body_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body_row.add_theme_constant_override("separation", 16)
	vbox.add_child(body_row)

	# ── 左：房间信息 + 操作 ──────────────────────────────────────────────
	var left_col := _make_vbox(16)
	left_col.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	left_col.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	body_row.add_child(left_col)

	var is_host: bool = (_host_uuid == Net.get_session_id())
	left_col.add_child(_make_label("房号：%s" % _room_id, FONT_SIZE_TITLE, ACCENT))
	left_col.add_child(_make_label("身份：%s" % ("房主" if is_host else "玩家"),
		FONT_SIZE_SMALL, TEXT_MUTED))
	left_col.add_child(_make_spacer(8))

	# ── 玩家格：2行×3列，按模式决定开放/锁定 ──────────────────────────────
	# 1v1：上中(flat=1)→slot 0，下中(flat=4)→slot 1，其余锁定
	# 1v3：上左(flat=0)→slot 1，上中(flat=1)→slot 2，上右(flat=2)→slot 3（攻方）
	#       下中(flat=4)→slot 0（守方/房主），下左(flat=3)下右(flat=5)仍锁定
	const CELL_MIN_H: float = 110.0

	var open_cells: Array
	var slot_map: Dictionary
	print("[SparringPanel] _build_my_room grid: _match_type=", _match_type, " _room_id=", _room_id, " is_host=", is_host)
	if _match_type == "1v3":
		open_cells = [0, 1, 2, 4]
		slot_map   = {0: 1, 1: 2, 2: 3, 4: 0}
	else:
		open_cells = [1, 4]
		slot_map   = {1: 0, 4: 1}

	var slot_to_player: Dictionary = {}
	for p in _players:
		slot_to_player[int(p.slot)] = p

	var grid := GridContainer.new()
	grid.columns = 3
	grid.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	grid.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	grid.add_theme_constant_override("h_separation", 10)
	grid.add_theme_constant_override("v_separation", 10)
	left_col.add_child(grid)

	for flat_idx in range(6):
		var cell_panel := PanelContainer.new()
		cell_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		cell_panel.size_flags_vertical   = Control.SIZE_EXPAND_FILL
		cell_panel.custom_minimum_size   = Vector2(0, CELL_MIN_H)

		var cell_margin := MarginContainer.new()
		cell_margin.add_theme_constant_override("margin_left",   8)
		cell_margin.add_theme_constant_override("margin_right",  8)
		cell_margin.add_theme_constant_override("margin_top",    8)
		cell_margin.add_theme_constant_override("margin_bottom", 8)
		cell_panel.add_child(cell_margin)

		var cell_center := CenterContainer.new()
		cell_center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
		cell_margin.add_child(cell_center)

		var cell_vbox := VBoxContainer.new()
		cell_vbox.add_theme_constant_override("separation", 4)
		cell_center.add_child(cell_vbox)

		if open_cells.has(flat_idx):
			var slot_id: int = slot_map[flat_idx]
			# 1v3 守方格（slot 0 / flat=4）：附加"守方"角色标注
			var role_tag: String = ""
			if _match_type == "1v3":
				role_tag = "〔守〕" if slot_id == 0 else "〔攻〕"
			if slot_to_player.has(slot_id):
				var p = slot_to_player[slot_id]
				var ready_mark: String = " ✓" if bool(_player_ready.get(p.uuid, false)) else ""
				var name_lbl := _make_label(p.nickname + ready_mark, FONT_SIZE_SMALL, TEXT_DARK)
				name_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				cell_vbox.add_child(name_lbl)
				if p.uuid == _host_uuid:
					var host_lbl := _make_label("【host】", FONT_SIZE_SMALL - 4, ACCENT)
					host_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
					cell_vbox.add_child(host_lbl)
				if role_tag != "":
					var role_lbl := _make_label(role_tag, FONT_SIZE_SMALL - 4,
						Color("#e67700") if slot_id == 0 else Color("#2b8a3e"))
					role_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
					cell_vbox.add_child(role_lbl)
				cell_panel.add_theme_stylebox_override("panel", ThemeFactory.panel(
					Color.WHITE, Color("#96c0f5"), 2, 12, false))
			else:
				var wait_lbl := _make_label(role_tag if role_tag != "" else "…", FONT_SIZE_BODY, TEXT_MUTED)
				wait_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
				cell_vbox.add_child(wait_lbl)
				cell_panel.add_theme_stylebox_override("panel", ThemeFactory.panel(
					Color("#edf2ff"), Color("#96c0f5"), 1, 12, false))
		else:
			var lock_lbl := _make_label("×", FONT_SIZE_TITLE, Color("#ced4da"))
			lock_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
			cell_vbox.add_child(lock_lbl)
			cell_panel.add_theme_stylebox_override("panel", ThemeFactory.panel(
				Color("#f1f3f5"), Color("#dee2e6"), 1, 12, false))

		grid.add_child(cell_panel)

	# ── 右：竖向撑满面板 + 底部按钮 ──────────────────────────────────────
	var right_panel := PanelContainer.new()
	right_panel.custom_minimum_size    = Vector2(NUMPAD_WIDTH, 0)
	right_panel.size_flags_vertical    = Control.SIZE_EXPAND_FILL
	right_panel.size_flags_horizontal  = Control.SIZE_SHRINK_END
	right_panel.add_theme_stylebox_override("panel", ThemeFactory.panel(
		Color("#f0f4ff"), Color("#96c0f5"), 2, 16, true))
	body_row.add_child(right_panel)

	var right_margin := MarginContainer.new()
	right_margin.add_theme_constant_override("margin_left",   16)
	right_margin.add_theme_constant_override("margin_right",  16)
	right_margin.add_theme_constant_override("margin_top",    16)
	right_margin.add_theme_constant_override("margin_bottom", 16)
	right_panel.add_child(right_margin)

	var right_vbox := VBoxContainer.new()
	right_vbox.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	right_vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	right_margin.add_child(right_vbox)

	# ── 当前游戏模式（所有人可见）────────────────────────────────────────
	var mode_tag_lbl := _make_label("游戏模式", FONT_SIZE_SMALL - 2, TEXT_MUTED)
	mode_tag_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	right_vbox.add_child(mode_tag_lbl)

	var mode_val_lbl := _make_label(_match_type, FONT_SIZE_BODY, ACCENT)
	mode_val_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	right_vbox.add_child(mode_val_lbl)

	right_vbox.add_child(_make_spacer(4))

	# 顶部弹性空白，把按钮推到底部
	var spacer_top := Control.new()
	spacer_top.size_flags_vertical = Control.SIZE_EXPAND_FILL
	right_vbox.add_child(spacer_top)

	if is_host:
		# ── 游戏模式选择（仅房主显示）─────────────────────────────────
		_build_match_type_row(right_vbox)
		# 房主：「开始」按钮（所有非房主玩家都准备后才启用）
		var all_ready := _all_non_host_ready()
		var min_players: int = 4 if _match_type == "1v3" else 2
		var can_start := _players.size() >= min_players and all_ready
		var start_btn := _make_primary_btn("开始")
		start_btn.custom_minimum_size = Vector2(0, BTN_HEIGHT + 24)
		start_btn.add_theme_font_size_override("font_size", FONT_SIZE_BODY + 6)
		start_btn.disabled = not can_start
		right_vbox.add_child(start_btn)
		start_btn.pressed.connect(_on_start_game)
	else:
		# 非房主：「准备」切换按钮
		var ready_btn: Button
		if _is_local_ready:
			ready_btn = _make_secondary_btn("已准备 ✓")
			# 已准备：深绿色样式
			var green_style := {
				"normal":   ThemeFactory.panel(Color("#2f9e44"), Color.TRANSPARENT, 0, 12, true),
				"hover":    ThemeFactory.panel(Color("#2b8a3e"), Color.TRANSPARENT, 0, 12, true),
				"pressed":  ThemeFactory.panel(Color("#237032"), Color.TRANSPARENT, 0, 12),
				"disabled": ThemeFactory.panel(Color("#adb5bd"), Color.TRANSPARENT, 0, 12),
			}
			ThemeFactory.apply_button_styles(ready_btn, green_style)
		else:
			ready_btn = _make_secondary_btn("准备")
		ready_btn.custom_minimum_size = Vector2(0, BTN_HEIGHT + 24)
		ready_btn.add_theme_font_size_override("font_size", FONT_SIZE_BODY + 6)
		right_vbox.add_child(ready_btn)
		ready_btn.pressed.connect(_on_toggle_ready)


# ── 游戏模式选择器（房主专用）────────────────────────────────────────────────
func _build_match_type_row(parent_vbox: VBoxContainer) -> void:
	var sep := _make_spacer(8)
	parent_vbox.add_child(sep)

	var mode_lbl := _make_label("游戏模式", FONT_SIZE_SMALL, TEXT_MUTED)
	mode_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	parent_vbox.add_child(mode_lbl)

	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 8)
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	parent_vbox.add_child(row)

	for mt in ["1v1", "1v3"]:
		var btn := Button.new()
		btn.text = mt
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.add_theme_font_size_override("font_size", FONT_SIZE_SMALL)
		btn.add_theme_color_override("font_color",         Color.WHITE)
		btn.add_theme_color_override("font_hover_color",   Color.WHITE)
		btn.add_theme_color_override("font_pressed_color", Color.WHITE)
		var is_sel: bool = (_match_type == mt)
		ThemeFactory.apply_button_styles(btn, _selected_style() if is_sel else _unselected_style())
		var captured_mt: String = mt
		btn.pressed.connect(func():
			_match_type = captured_mt
			# 通知服务端更新 MatchType / MaxPlayers，服务端再广播 room/config_updated
			if _room_id != "" and has_node("/root/Net"):
				Net.send_to_room("room/update_config", _room_id,
					{"match_type": _match_type})
			_refresh_left_content()
		)
		row.add_child(btn)

	var sep2 := _make_spacer(4)
	parent_vbox.add_child(sep2)


# ── 右侧固定面板：游戏模式选择器（始终可见，进房前就能选）────────────────────
# 插在 ModeBtn0「我的房间」与其他模式按钮之间。
var _right_mode_btns: Dictionary = {}  # mt → Button

func _build_right_mode_selector(vbox: VBoxContainer) -> void:
	# 分隔线
	var sep := HSeparator.new()
	sep.add_theme_color_override("color", Color("#dee2e6"))
	vbox.add_child(sep)
	vbox.move_child(sep, 1)   # 插在 ModeBtn0 (index=0) 后面

	# 标题
	var lbl := Label.new()
	lbl.text = "对战模式"
	lbl.add_theme_font_size_override("font_size", FONT_SIZE_SMALL - 2)
	lbl.add_theme_color_override("font_color", Color.WHITE)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	vbox.add_child(lbl)
	vbox.move_child(lbl, 2)

	# 1v1 / 1v3 按钮行
	var row := HBoxContainer.new()
	row.add_theme_constant_override("separation", 6)
	vbox.add_child(row)
	vbox.move_child(row, 3)

	for mt in ["1v1", "1v3"]:
		var btn := Button.new()
		btn.text = mt
		btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
		btn.add_theme_font_size_override("font_size", FONT_SIZE_SMALL - 2)
		btn.add_theme_color_override("font_color",         Color.WHITE)
		btn.add_theme_color_override("font_hover_color",   Color.WHITE)
		btn.add_theme_color_override("font_pressed_color", Color.WHITE)
		_right_mode_btns[mt] = btn
		var captured_mt: String = mt
		btn.pressed.connect(func():
			_match_type = captured_mt
			_refresh_right_mode_selector()
			if _room_id != "" and has_node("/root/Net"):
				var is_h: bool = (_host_uuid == Net.get_session_id())
				if is_h:
					# 同步更新服务端房间配置（MaxPlayers 随之变化）
					Net.send_to_room("room/update_config", _room_id,
						{"match_type": _match_type})
			if _selected_idx == 0:
				_refresh_left_content()
		)
		row.add_child(btn)

	_refresh_right_mode_selector()

func _refresh_right_mode_selector() -> void:
	for mt in _right_mode_btns.keys():
		var btn: Button = _right_mode_btns[mt]
		if not is_instance_valid(btn):
			continue
		if mt == _match_type:
			ThemeFactory.apply_button_styles(btn, _selected_style())
		else:
			ThemeFactory.apply_button_styles(btn, _unselected_style())


# ── 房间号输入状态（数字键盘面板） ──────────────────────────────────────────
var _room_input: String = ""       # 当前已输入的房间号（最多 5 位）
const MAX_ROOM_INPUT_LEN: int = 5
const NUMPAD_WIDTH: float     = 340.0  # 数字键盘面板总宽（内宽 312，3列正方形每格≈99）
const NUMPAD_BTN_H: float     = 99.0   # 每个数字按键高度（= 内宽/3 ≈ 正方形）
const NUMPAD_SEP: int         = 8      # 按键间距

# 刷新按钮引用（跨帧持久，用于更新倒计时文字）
var _refresh_btn_ref: Button = null
var _refresh_countdown_active: bool = false


# ── Mode 1「加入房间」内容 ─────────────────────────────────────────────────
func _build_join_room(holder: Control) -> void:
	var vbox := _make_vbox(12)
	holder.add_child(vbox)

	vbox.add_child(_make_title(MODE_NAMES[1]))

	if _conn_state != STATE_CONNECTED:
		var cfg := ProfileManager.get_server_config()
		var msg: String = "正在连接服务器…\n%s:%d" % [cfg.host, cfg.port] \
			if _conn_state == STATE_CONNECTING else "连接服务器失败\n%s:%d" % [cfg.host, cfg.port]
		vbox.add_child(_make_hint(msg))
		if _conn_state == STATE_DISCONNECTED:
			vbox.add_child(_make_spacer(8))
			var retry_btn := _make_primary_btn("重新连接")
			retry_btn.pressed.connect(func():
				_ensure_connected_then(false)
				_refresh_left_content())
			vbox.add_child(retry_btn)
			var edit_btn := _make_secondary_btn("修改服务器地址")
			edit_btn.pressed.connect(_open_server_config_dialog)
			vbox.add_child(edit_btn)
		return

	# ── 刷新行（刷新按钮 + 状态提示） ────────────────────────────────────
	var refresh_row := HBoxContainer.new()
	refresh_row.add_theme_constant_override("separation", 12)
	vbox.add_child(refresh_row)

	var refresh_btn := _make_secondary_btn("刷新列表")
	refresh_btn.custom_minimum_size = Vector2(160, BTN_HEIGHT)
	refresh_btn.size_flags_horizontal = 0
	refresh_row.add_child(refresh_btn)
	_refresh_btn_ref = refresh_btn
	_update_refresh_btn_label()   # 若倒计时进行中恢复文字

	var status_lbl := _make_label("可加入的房间（未开战）  若房主切换了模式，点刷新查看最新", FONT_SIZE_SMALL, TEXT_MUTED)
	status_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	status_lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	refresh_row.add_child(status_lbl)
	refresh_btn.pressed.connect(_on_refresh_btn)

	vbox.add_child(_make_spacer(4))

	# ── 主体：左侧列表 + 右侧数字键盘（HBox） ──────────────────────────
	var body_row := HBoxContainer.new()
	body_row.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	body_row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	body_row.add_theme_constant_override("separation", 16)
	vbox.add_child(body_row)

	# ── 左：房间列表底板 ──────────────────────────────────────────────────
	var list_panel := PanelContainer.new()
	list_panel.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	list_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_panel.add_theme_stylebox_override("panel", ThemeFactory.panel(
		Color("#f0f4ff"), Color("#96c0f5"), 2, 16, true))
	body_row.add_child(list_panel)

	var list_margin := MarginContainer.new()
	list_margin.add_theme_constant_override("margin_left",   12)
	list_margin.add_theme_constant_override("margin_right",  12)
	list_margin.add_theme_constant_override("margin_top",    12)
	list_margin.add_theme_constant_override("margin_bottom", 12)
	list_panel.add_child(list_margin)

	var elastic := ElasticScrollList.new()
	elastic.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	elastic.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	list_margin.add_child(elastic)

	var list_vbox: VBoxContainer = elastic.get_content_box()

	if _rooms.is_empty():
		list_vbox.add_child(_make_hint("暂无可加入的房间，请稍后刷新"))
	else:
		for room in _rooms:
			var row_panel := PanelContainer.new()
			row_panel.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			row_panel.add_theme_stylebox_override("panel", ThemeFactory.panel(
				Color.WHITE, Color("#dee2e6"), 1, 10, false))
			list_vbox.add_child(row_panel)

			var row_margin := MarginContainer.new()
			row_margin.add_theme_constant_override("margin_left",   16)
			row_margin.add_theme_constant_override("margin_right",  12)
			row_margin.add_theme_constant_override("margin_top",    10)
			row_margin.add_theme_constant_override("margin_bottom", 10)
			row_panel.add_child(row_margin)

			var row := HBoxContainer.new()
			row.add_theme_constant_override("separation", 16)
			row_margin.add_child(row)

			var mt_str: String = String(room.get("match_type", "1v1"))
			var max_p: int = int(room.get("max_players", 2))
			var info := _make_label(
				"房间 %s  [%s]  房主: %s  人数: %d/%d" % [
					room.id, mt_str, room.host_nickname, room.player_count, max_p],
				FONT_SIZE_BODY, TEXT_DARK)
			info.size_flags_horizontal = Control.SIZE_EXPAND_FILL
			info.vertical_alignment    = VERTICAL_ALIGNMENT_CENTER
			row.add_child(info)

			var join_btn := _make_primary_btn("加入")
			join_btn.custom_minimum_size = Vector2(120, 56)
			row.add_child(join_btn)
			var rid: String = room.id
			join_btn.pressed.connect(func(): _on_join_room(rid))

	# ── 右：直接输入房间号面板 ────────────────────────────────────────────
	body_row.add_child(_build_numpad_panel())


# ── 数字键盘面板 ─────────────────────────────────────────────────────────────
func _build_numpad_panel() -> Control:
	# 外层底板
	var panel := PanelContainer.new()
	panel.custom_minimum_size = Vector2(NUMPAD_WIDTH, 0)
	panel.size_flags_vertical = Control.SIZE_EXPAND_FILL
	panel.add_theme_stylebox_override("panel", ThemeFactory.panel(
		Color("#f0f4ff"), Color("#96c0f5"), 2, 16, true))

	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left",   14)
	margin.add_theme_constant_override("margin_right",  14)
	margin.add_theme_constant_override("margin_top",    14)
	margin.add_theme_constant_override("margin_bottom", 14)
	panel.add_child(margin)

	# VBox 竖向填充整个面板
	var vbox := VBoxContainer.new()
	vbox.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", NUMPAD_SEP)
	margin.add_child(vbox)

	# ── 输入显示栏 ────────────────────────────────────────────────────────
	var display_panel := PanelContainer.new()
	display_panel.add_theme_stylebox_override("panel", ThemeFactory.panel(
		Color.WHITE, Color("#96c0f5"), 2, 10, false))
	vbox.add_child(display_panel)

	var display_margin := MarginContainer.new()
	display_margin.add_theme_constant_override("margin_left",   12)
	display_margin.add_theme_constant_override("margin_right",  12)
	display_margin.add_theme_constant_override("margin_top",    8)
	display_margin.add_theme_constant_override("margin_bottom", 8)
	display_panel.add_child(display_margin)

	var disp_row := HBoxContainer.new()
	disp_row.add_theme_constant_override("separation", 8)
	display_margin.add_child(disp_row)

	# 房间号显示 Label
	var disp_lbl := Label.new()
	disp_lbl.name = "_NumpadDisplay"
	disp_lbl.text = _room_input   # 空字符串时什么也不显示
	disp_lbl.add_theme_font_size_override("font_size", 36)
	disp_lbl.add_theme_color_override("font_color", TEXT_DARK)
	disp_lbl.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	disp_lbl.horizontal_alignment  = HORIZONTAL_ALIGNMENT_CENTER
	disp_lbl.vertical_alignment    = VERTICAL_ALIGNMENT_CENTER
	disp_row.add_child(disp_lbl)

	# × 清空键
	var clear_btn := Button.new()
	clear_btn.text = "×"
	clear_btn.add_theme_font_size_override("font_size", 28)
	clear_btn.custom_minimum_size = Vector2(52, 52)
	var clear_normal := ThemeFactory.panel(Color("#339af0"), Color.TRANSPARENT, 0, 12, true)
	var clear_pressed := ThemeFactory.panel(Color("#1c7ed6"), Color.TRANSPARENT, 0, 12)
	clear_btn.add_theme_stylebox_override("normal",  clear_normal)
	clear_btn.add_theme_stylebox_override("hover",   clear_normal)  # 无悬浮动效
	clear_btn.add_theme_stylebox_override("pressed", clear_pressed)
	clear_btn.pressed.connect(func():
		_room_input = ""
		_refresh_numpad_display(disp_lbl))
	disp_row.add_child(clear_btn)

	# ── 数字键 1-9（3×3，每行竖向 EXPAND_FILL） ──────────────────────────
	for row_idx in range(3):
		var btn_row := _make_numpad_row()
		vbox.add_child(btn_row)
		for col_idx in range(3):
			var digit: int = row_idx * 3 + col_idx + 1   # 1..9
			var btn := _make_numpad_digit_btn(str(digit))
			btn.pressed.connect(func():
				if _room_input.length() < MAX_ROOM_INPUT_LEN:
					_room_input += str(digit)
					_refresh_numpad_display(disp_lbl))
			btn_row.add_child(btn)

	# ── 最后一行：[0] + [加入房间（2倍宽）] ─────────────────────────────
	var last_row := _make_numpad_row()
	vbox.add_child(last_row)

	var btn0 := _make_numpad_digit_btn("0")
	btn0.pressed.connect(func():
		if _room_input.length() < MAX_ROOM_INPUT_LEN:
			_room_input += "0"
			_refresh_numpad_display(disp_lbl))
	last_row.add_child(btn0)

	var join_btn := _make_primary_btn("加入房间")
	join_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	join_btn.size_flags_stretch_ratio = 2.0        # 占 2 格宽（0 占 1 格）
	join_btn.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	join_btn.add_theme_font_size_override("font_size", FONT_SIZE_SMALL)
	join_btn.pressed.connect(func():
		if _room_input.length() > 0:
			_on_join_room(_room_input)
			_room_input = "")
	last_row.add_child(join_btn)

	return panel


# 更新数字键盘显示 Label。
func _refresh_numpad_display(lbl: Label) -> void:
	if not is_instance_valid(lbl):
		return
	lbl.text = _room_input   # 空时显示空白，不再用占位符


# 工厂：数字按键行（HBoxContainer，竖向 EXPAND_FILL）。
func _make_numpad_row() -> HBoxContainer:
	var row := HBoxContainer.new()
	row.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	row.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.custom_minimum_size   = Vector2(0, NUMPAD_BTN_H)
	row.add_theme_constant_override("separation", NUMPAD_SEP)
	return row


# 工厂：单个数字按键（水平+竖向均 EXPAND_FILL，自动平分空间）。
func _make_numpad_digit_btn(digit: String) -> Button:
	var btn := Button.new()
	btn.text = digit
	btn.add_theme_font_size_override("font_size", FONT_SIZE_BODY)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	btn.size_flags_vertical   = Control.SIZE_EXPAND_FILL
	# hover 与 normal 同色，去除悬浮变色动效
	var normal_style := ThemeFactory.panel(Color("#339af0"), Color.TRANSPARENT, 0, 12, true)
	var pressed_style := ThemeFactory.panel(Color("#1c7ed6"), Color.TRANSPARENT, 0, 12)
	var disabled_style := ThemeFactory.panel(Color("#adb5bd"), Color.TRANSPARENT, 0, 12)
	btn.add_theme_stylebox_override("normal",   normal_style)
	btn.add_theme_stylebox_override("hover",    normal_style)   # 同 normal，无悬浮动效
	btn.add_theme_stylebox_override("pressed",  pressed_style)
	btn.add_theme_stylebox_override("disabled", disabled_style)
	return btn


# ── 占位模式（随机匹配 / 随机排位） ─────────────────────────────────────────
func _build_placeholder(holder: Control, title: String) -> void:
	var center := CenterContainer.new()
	center.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	holder.add_child(center)
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 20)
	center.add_child(vbox)
	vbox.add_child(_make_title(title))
	vbox.add_child(_make_hint("（施工中）"))


# ── 网络信号处理 ────────────────────────────────────────────────────────────
func _bind_net_signals() -> void:
	if _net_signals_bound or not has_node("/root/Net"):
		return
	Net.connected.connect(_on_net_connected)
	Net.connection_failed.connect(_on_net_failed)
	Net.disconnected.connect(_on_net_disconnected)
	Net.message_received.connect(_on_net_message)
	_net_signals_bound = true


func _unbind_net_signals() -> void:
	if not _net_signals_bound or not has_node("/root/Net"):
		return
	if Net.connected.is_connected(_on_net_connected):
		Net.connected.disconnect(_on_net_connected)
	if Net.connection_failed.is_connected(_on_net_failed):
		Net.connection_failed.disconnect(_on_net_failed)
	if Net.disconnected.is_connected(_on_net_disconnected):
		Net.disconnected.disconnect(_on_net_disconnected)
	if Net.message_received.is_connected(_on_net_message):
		Net.message_received.disconnect(_on_net_message)
	_net_signals_bound = false


func _on_net_connected() -> void:
	_conn_state = STATE_CONNECTED
	_on_ready_after_connect()


func _on_net_failed(_reason: String) -> void:
	_conn_state = STATE_DISCONNECTED
	_refresh_left_content()


func _on_net_disconnected() -> void:
	_conn_state = STATE_DISCONNECTED
	_room_id = ""
	_host_uuid = ""
	_players = []
	_refresh_left_content()


func _on_net_message(msg: Dictionary) -> void:
	var type: String = String(msg.get("type", ""))
	var from: String = String(msg.get("from", ""))
	var payload = msg.get("payload", {})
	if typeof(payload) != TYPE_DICTIONARY:
		payload = {}
	# 过滤自己发的消息 echo（服务端中继会把 to=all 消息发回给自己）
	var my_sid: String = Net.get_session_id() if has_node("/root/Net") else ""
	if from != "" and from == my_sid:
		return
	match type:
		"room/create_ok":
			_room_id   = String(msg.get("room_id", ""))
			_host_uuid = String(payload.get("host_uuid", ""))
			_players   = _parse_players(payload.get("players", []))
			_player_ready.clear()
			_player_decks.clear()
			_player_heroes.clear()
			_is_local_ready = false
			# 服务端返回 match_type 时以服务端为准；否则保留房主本地选择的 _match_type
			var confirmed_mt: String = String(payload.get("match_type", ""))
			if confirmed_mt != "":
				_match_type = confirmed_mt
			# 房主创建房间成功，立刻广播当前模式给任何后续加入者
			# （服务端未传 match_type 时，靠此消息让非房主同步）
			_refresh_left_content()
		"room/config_updated":
			# 服务端确认房间配置更新（MatchType / MaxPlayers 已在服务端修改）
			var cfg_mt: String = String(payload.get("match_type", ""))
			if cfg_mt != "" and cfg_mt != _match_type:
				_match_type = cfg_mt
				_refresh_right_mode_selector()
			if _selected_idx == 0:
				_refresh_left_content()
		"room/match_type_changed":
			var new_mt: String = String(payload.get("match_type", ""))
			print("[SparringPanel] room/match_type_changed recv: new_mt=", new_mt, " cur=", _match_type, " from=", from)
			if new_mt != "" and new_mt != _match_type:
				_match_type = new_mt
				print("[SparringPanel] _match_type updated to ", _match_type)
				_refresh_right_mode_selector()
				if _selected_idx == 0:
					_refresh_left_content()
		"room/joined":
			_room_id   = String(msg.get("room_id", ""))
			_host_uuid = String(payload.get("host_uuid", ""))
			_players   = _parse_players(payload.get("players", []))
			_player_ready.clear()
			_player_decks.clear()
			_player_heroes.clear()
			_is_local_ready = false
			# 同步房间的 match_type（服务端下发为准；旧服务端无此字段时保留本地值）
			var jmt: String = String(payload.get("match_type", ""))
			print("[SparringPanel] room/joined: jmt=", jmt, " cur _match_type=", _match_type, " from=", from, " my_sid=", my_sid)
			if jmt != "":
				_match_type = jmt
				print("[SparringPanel] _match_type updated from room/joined to ", _match_type)
			# 房主：向最新加入的那个玩家点对点发送当前模式（不走广播避免 echo）
			if my_sid != "" and my_sid == _host_uuid and _room_id != "":
				# 找到最新加入的玩家（列表末位，且不是自己）
				for p in _players:
					if p.uuid != my_sid:
						Net.send_to("room/match_type_changed", _room_id, p.uuid,
							{"match_type": _match_type})
			# 强制切回 Mode 0 显示房间内容
			if _selected_idx != 0:
				_selected_idx = 0
				_apply_selection(0)
			_refresh_left_content()
		"room/join_rejected":
			# 加入失败：仅刷新列表标签提示（简化）
			_refresh_left_content()
		"room/left":
			var leaver: String = String(payload.get("uuid", ""))
			_players = _players.filter(func(p): return p.uuid != leaver)
			_player_ready.erase(leaver)
			_player_decks.erase(leaver)
			_player_heroes.erase(leaver)
			var new_host: String = String(payload.get("new_host_uuid", ""))
			if new_host != "":
				_host_uuid = new_host
			if _selected_idx == 0:
				_refresh_left_content()
		"room/list_response":
			var raw = payload.get("rooms", [])
			_rooms = []
			if typeof(raw) == TYPE_ARRAY:
				for r in raw:
					if typeof(r) == TYPE_DICTIONARY:
						# 过滤已开战的房间
						if bool(r.get("started", false)):
							continue
						_rooms.append({
							"id": String(r.get("id", "")),
							"host_nickname": String(r.get("host_nickname", "")),
							"player_count": int(r.get("player_count", 0)),
							"match_type": String(r.get("match_type", "1v1")),
							"max_players": int(r.get("max_players", 2)),
						})
			if _selected_idx == 1:
				_refresh_left_content()
		"room/expired", "room/destroy":
			_room_id = ""
			_players = []
			_host_uuid = ""
			_refresh_left_content()
		"disconnect/notify":
			var uuid_gone: String = String(payload.get("uuid", ""))
			_players = _players.filter(func(p): return p.uuid != uuid_gone)
			_player_ready.erase(uuid_gone)
			_player_decks.erase(uuid_gone)
			_player_heroes.erase(uuid_gone)
			var new_host: String = String(payload.get("new_host_uuid", ""))
			if new_host != "":
				_host_uuid = new_host
			if _selected_idx == 0:
				_refresh_left_content()
		"room/ready_update":
			var who: String = String(payload.get("uuid", ""))
			var ready: bool  = bool(payload.get("ready", false))
			if who != "":
				_player_ready[who] = ready
			if _selected_idx == 0:
				_refresh_left_content()
		"room/deck_ready":
			# 非房主玩家上报自己的牌组和英雄：{ uuid, deck_names: [name, ...], hero_key: "A"/"B"/... }
			var who: String = String(payload.get("uuid", ""))
			var raw_names = payload.get("deck_names", [])
			if who != "" and typeof(raw_names) == TYPE_ARRAY:
				var names: Array = []
				for n in raw_names:
					names.append(String(n))
				_player_decks[who] = names
			var hkey: String = String(payload.get("hero_key", ""))
			if who != "" and hkey != "":
				_player_heroes[who] = hkey
		"game/start":
			_handle_game_start(msg, payload)


# ── room/create / join / leave / list / start 操作 ───────────────────────────
func _request_room_list(force: bool = false) -> void:
	if not has_node("/root/Net") or not Net.is_connected_to_server():
		return
	var now: float = Time.get_ticks_msec() / 1000.0
	if not force and now - _last_refresh_time < REFRESH_COOLDOWN:
		return
	_last_refresh_time = now
	Net.send({"type": "room/list"})
	# 无论是自动触发还是手动触发，均启动倒计时
	_start_refresh_countdown()


# 刷新按钮点击：检查冷却，通过则发请求 + 启动倒计时文字更新。
func _on_refresh_btn() -> void:
	var now: float = Time.get_ticks_msec() / 1000.0
	if now - _last_refresh_time < REFRESH_COOLDOWN:
		return  # 倒计时正在跑，按钮已被 disabled，此分支不应触发
	_last_refresh_time = now
	Net.send({"type": "room/list"})
	_start_refresh_countdown()


# 启动刷新冷却倒计时（幂等：已在跑则只刷新引用，不重启协程）。
func _start_refresh_countdown() -> void:
	if _refresh_countdown_active:
		# 协程已在运行，只需确保新按钮引用正确；协程会自动更新新引用
		_update_refresh_btn_label()
		return
	_refresh_countdown_active = true
	_update_refresh_btn_label()
	_run_refresh_countdown()


func _run_refresh_countdown() -> void:
	while _refresh_countdown_active:
		var elapsed: float = (Time.get_ticks_msec() / 1000.0) - _last_refresh_time
		var remaining: float = REFRESH_COOLDOWN - elapsed
		if remaining <= 0.0:
			_refresh_countdown_active = false
			if is_instance_valid(_refresh_btn_ref):
				_refresh_btn_ref.text     = "刷新列表"
				_refresh_btn_ref.disabled = false
			break
		if is_instance_valid(_refresh_btn_ref):
			_refresh_btn_ref.text     = "%d 秒" % int(ceil(remaining))
			_refresh_btn_ref.disabled = true
		await get_tree().create_timer(0.25).timeout


# 重建 UI 时同步按钮文字与冷却状态。若仍在冷却且协程未运行，重启协程。
func _update_refresh_btn_label() -> void:
	if not is_instance_valid(_refresh_btn_ref):
		return
	var elapsed: float = (Time.get_ticks_msec() / 1000.0) - _last_refresh_time
	var remaining: float = REFRESH_COOLDOWN - elapsed
	if remaining > 0.0:
		_refresh_btn_ref.text     = "%d 秒" % int(ceil(remaining))
		_refresh_btn_ref.disabled = true
		# UI 重建后协程可能已结束，若按钮仍需冷却则重启
		if not _refresh_countdown_active:
			_refresh_countdown_active = true
			_run_refresh_countdown()
	else:
		_refresh_btn_ref.text     = "刷新列表"
		_refresh_btn_ref.disabled = false


func _on_join_room(room_id: String) -> void:
	Net.send({"type": "room/join", "room_id": room_id, "payload": {"room_id": room_id}})


func _on_leave_room() -> void:
	if _room_id != "":
		Net.send({"type": "room/leave", "room_id": _room_id})
	_room_id = ""
	_players = []
	_host_uuid = ""
	_player_ready.clear()
	_is_local_ready = false
	# 离开后切到「加入房间」视图，避免停留 Mode 0 显示空状态
	_selected_idx = 1
	_apply_selection(1)
	_enter_mode(1)


# 非房主玩家切换准备状态，广播给房间所有人。
# 同时上报自己的牌组和英雄 key（room/deck_ready），供房主在 game/start 时收集。
func _on_toggle_ready() -> void:
	_is_local_ready = not _is_local_ready
	_player_ready[Net.get_session_id()] = _is_local_ready
	Net.send({
		"type":    "room/ready_update",
		"room_id": _room_id,
		"to":      "all",
		"payload": {"uuid": Net.get_session_id(), "ready": _is_local_ready},
	})
	# 每次切换准备状态时上报自己的最新牌组和英雄
	var my_deck_names: Array = _collect_deck_names()
	Net.send({
		"type":    "room/deck_ready",
		"room_id": _room_id,
		"to":      "host",
		"payload": {
			"uuid":       Net.get_session_id(),
			"deck_names": my_deck_names,
			"hero_key":   DeckStorage.get_selected_hero(),
		},
	})
	_refresh_left_content()


# 检查所有非房主玩家是否全部准备完毕。
func _all_non_host_ready() -> bool:
	for p in _players:
		if p.uuid == _host_uuid:
			continue   # 房主不需要准备
		if not bool(_player_ready.get(p.uuid, false)):
			return false
	return _players.size() >= 2   # 至少 2 人才有意义


func _on_back_clicked() -> void:
	# 返回主菜单：先退当前房间（若在房中），保持 Net 连接活跃方便下次再进。
	# 战斗场景在退出时才会主动 disconnect。
	if _room_id != "" and has_node("/root/Net") and Net.is_connected_to_server():
		Net.send({"type": "room/leave", "room_id": _room_id})
	_room_id = ""
	_players = []
	_host_uuid = ""


# ── 服务器地址配置对话框 ─────────────────────────────────────────────────────
# 在全屏 CanvasLayer(200) 弹出输入框让用户填 host + port，保存到 ProfileManager。
func _open_server_config_dialog() -> void:
	var cfg := ProfileManager.get_server_config()

	var canvas := CanvasLayer.new()
	canvas.layer = 200
	get_tree().current_scene.add_child(canvas)

	# 半透明蒙层
	var overlay := ColorRect.new()
	overlay.color = Color(0, 0, 0, 0.5)
	overlay.set_anchors_and_offsets_preset(Control.PRESET_FULL_RECT)
	canvas.add_child(overlay)

	# 居中对话框
	var dialog := PanelContainer.new()
	dialog.custom_minimum_size = Vector2(520, 0)
	dialog.set_anchors_preset(Control.PRESET_CENTER)
	dialog.add_theme_stylebox_override("panel", ThemeFactory.panel(
		Color.WHITE, Color("#96c0f5"), 2, 20, true))
	canvas.add_child(dialog)

	var dlg_margin := MarginContainer.new()
	for side in ["margin_left", "margin_right", "margin_top", "margin_bottom"]:
		dlg_margin.add_theme_constant_override(side, 24)
	dialog.add_child(dlg_margin)

	var dlg_vbox := VBoxContainer.new()
	dlg_vbox.add_theme_constant_override("separation", 16)
	dlg_margin.add_child(dlg_vbox)

	dlg_vbox.add_child(_make_label("修改服务器地址", FONT_SIZE_BODY, TEXT_DARK))
	dlg_vbox.add_child(_make_label("手机测试时请填 PC 的局域网 IP（如 192.168.x.x）",
		FONT_SIZE_SMALL, TEXT_MUTED))

	# Host 输入
	dlg_vbox.add_child(_make_label("服务器 IP：", FONT_SIZE_SMALL, TEXT_MUTED))
	var host_edit := LineEdit.new()
	host_edit.text = cfg.host
	host_edit.placeholder_text = "127.0.0.1"
	host_edit.add_theme_font_size_override("font_size", FONT_SIZE_BODY)
	host_edit.custom_minimum_size = Vector2(0, 64)
	dlg_vbox.add_child(host_edit)

	# Port 输入
	dlg_vbox.add_child(_make_label("端口：", FONT_SIZE_SMALL, TEXT_MUTED))
	var port_edit := LineEdit.new()
	port_edit.text = str(cfg.port)
	port_edit.placeholder_text = "8080"
	port_edit.add_theme_font_size_override("font_size", FONT_SIZE_BODY)
	port_edit.custom_minimum_size = Vector2(0, 64)
	dlg_vbox.add_child(port_edit)

	# 按钮行
	var btn_row := HBoxContainer.new()
	btn_row.add_theme_constant_override("separation", 12)
	dlg_vbox.add_child(btn_row)

	var cancel_btn := _make_secondary_btn("取消")
	cancel_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	cancel_btn.pressed.connect(canvas.queue_free)
	btn_row.add_child(cancel_btn)

	var confirm_btn := _make_primary_btn("保存并重连")
	confirm_btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	confirm_btn.pressed.connect(func():
		var new_host: String = host_edit.text.strip_edges()
		var new_port: int    = int(port_edit.text.strip_edges())
		if new_host == "":
			new_host = "127.0.0.1"
		if new_port <= 0 or new_port > 65535:
			new_port = 8080
		ProfileManager.save_server_config(new_host, new_port)
		canvas.queue_free()
		# 断开旧连接，重新发起
		if has_node("/root/Net"):
			Net.disconnect_from_server()
		_conn_state = STATE_DISCONNECTED
		_ensure_connected_then(_selected_idx == 0)
		_refresh_left_content())
	btn_row.add_child(confirm_btn)


func _on_start_game() -> void:
	# 房主负责：生成行动顺序 + RNG 种子；广播 game/start。
	var my_sid: String = Net.get_session_id()

	# 1v3：房主固定为 defender（index=0），其余 3 人随机排序为 attacker
	# 1v1：随机打乱（不区分队伍）
	var order: Array = []
	if _match_type == "1v3":
		order.append(my_sid)   # 房主 = defender（1 方），排在首位
		var others: Array = []
		for p in _players:
			if p.uuid != my_sid:
				others.append(p.uuid)
		others.shuffle()
		order.append_array(others)
	else:
		for p in _players:
			order.append(p.uuid)
		order.shuffle()

	var rng := RandomNumberGenerator.new()
	rng.randomize()
	var seed_value: int = rng.randi()

	# 把所有已收集的牌组 + 自己的牌组合并为 per_player_decks
	var per_player_decks: Dictionary = {}
	for pid in _player_decks.keys():
		per_player_decks[pid] = _player_decks[pid]
	per_player_decks[my_sid] = _collect_deck_names()

	# 把所有已收集的英雄 key + 自己的英雄合并为 per_player_heroes
	var per_player_heroes: Dictionary = {}
	for pid in _player_heroes.keys():
		per_player_heroes[pid] = _player_heroes[pid]
	per_player_heroes[my_sid] = DeckStorage.get_selected_hero()

	# 1v3：构建 slot_layout（服务端纯中继，由房主生成下发）
	var slot_layout: Array = []
	if _match_type == "1v3":
		for i in range(order.size()):
			var pid: String = String(order[i])
			slot_layout.append({
				"slot_id":    "slot_" + pid,
				"owner_pid":  pid,
				"team_id":    "defender" if i == 0 else "attacker",
				"slot_index": i,
			})

	var start_payload: Dictionary = {
		"match_type":        _match_type,
		"action_order":      order,
		"per_player_decks":  per_player_decks,
		"per_player_heroes": per_player_heroes,
		"rng_seed":          seed_value,
		"slot_layout":       slot_layout,
	}
	Net.send_to_room("game/start", _room_id, start_payload)
	# 房主自己直接处理进入游戏（不等服务端 echo，echo 会被 from==my_sid 过滤）
	var fake_msg: Dictionary = {"type": "game/start", "room_id": _room_id, "payload": start_payload}
	_handle_game_start(fake_msg, start_payload)


# 收到 game/start：bootstrap_pvp + 切战斗场景
func _handle_game_start(msg: Dictionary, payload: Dictionary) -> void:
	var order: Array = []
	var raw_order = payload.get("action_order", [])
	if typeof(raw_order) == TYPE_ARRAY:
		for v in raw_order:
			order.append(String(v))
	if order.is_empty():
		for p in _players:
			order.append(p.uuid)

	var rng_seed: int = int(payload.get("rng_seed", 0))

	# 确保 card_db 已装载（bootstrap_pvp 内部会兜底，但提前装载可减少重复 IO）
	if Game.card_db.size() == 0:
		var all := DataLoader.load_cards(DataLoader.ALL_CARDS_JSON)
		for c in all:
			Game.card_db[c.name] = c

	# 读取 per_player_decks（格式：{ uuid: [card_name, ...] }）
	# 取本地玩家自己的牌组；若字段缺失（旧服务端），回退到 deck_names 共用牌组（向后兼容）
	var my_sid: String = Net.get_session_id()
	var per_player_deck_cards: Dictionary = {}

	var raw_ppd = payload.get("per_player_decks", {})
	if typeof(raw_ppd) == TYPE_DICTIONARY and not raw_ppd.is_empty():
		# 新协议：每位玩家独立牌组
		for pid_raw in raw_ppd.keys():
			var pid: String = String(pid_raw)
			var names_raw = raw_ppd[pid_raw]
			var cards: Array = []
			if typeof(names_raw) == TYPE_ARRAY:
				for n in names_raw:
					var c = Game.get_card(String(n))
					if c != null:
						cards.append(c)
			per_player_deck_cards[pid] = cards
	else:
		# 旧协议回退：deck_names 为所有人共用
		var deck_names: Array = []
		var raw_names = payload.get("deck_names", [])
		if typeof(raw_names) == TYPE_ARRAY:
			for v in raw_names:
				deck_names.append(String(v))
		var shared_cards: Array = []
		for n in deck_names:
			var c = Game.get_card(n)
			if c != null:
				shared_cards.append(c)
		for pid_raw in order:
			per_player_deck_cards[String(pid_raw)] = shared_cards.duplicate()

	# 本地玩家的牌组缺失时，用本地 DeckStorage 自补（离线兜底）
	if not per_player_deck_cards.has(my_sid) or per_player_deck_cards[my_sid].is_empty():
		var local_names: Array = _collect_deck_names()
		var local_cards: Array = []
		for n in local_names:
			var c = Game.get_card(n)
			if c != null:
				local_cards.append(c)
		per_player_deck_cards[my_sid] = local_cards

	# 解析 per_player_heroes（格式：{ uuid: hero_key }）
	# 本地玩家 hero_key 缺失时回退到 DeckStorage.get_selected_hero()
	var per_player_heroes: Dictionary = {}
	var raw_pph = payload.get("per_player_heroes", {})
	if typeof(raw_pph) == TYPE_DICTIONARY:
		for pid_raw in raw_pph.keys():
			var hkey: String = String(raw_pph[pid_raw])
			if hkey != "":
				per_player_heroes[String(pid_raw)] = hkey
	# 本地玩家英雄兜底
	if not per_player_heroes.has(my_sid) or per_player_heroes[my_sid] == "":
		per_player_heroes[my_sid] = DeckStorage.get_selected_hero()

	_unbind_net_signals()
	Net.set_current_room_id(msg.get("room_id", _room_id))

	# 解析 match_type 和 slot_layout
	var match_type: String = String(payload.get("match_type", "1v1"))
	var slot_layout: Array = []
	var raw_sl = payload.get("slot_layout", [])
	if typeof(raw_sl) == TYPE_ARRAY:
		for entry in raw_sl:
			if typeof(entry) == TYPE_DICTIONARY:
				slot_layout.append(entry)

	# 用 session_id 作本地玩家标识，确保同机两实例 ID 不同
	Game.bootstrap_pvp(my_sid, order, per_player_deck_cards, [], rng_seed,
		per_player_heroes, match_type, {}, slot_layout)
	get_tree().change_scene_to_file("res://scenes/TestMain.tscn")


# ── 牌组读取：从 DeckStorage 读取当前英雄「A」的备战卡组 ─────────────────────
# 优先走 DeckStorage（备战界面保存的卡组）；
# 若卡组为空（玩家尚未编辑），回退到 test_multiplayer_deck.json 或 battle_cards.json。
const TEST_MP_DECK_PATH: String = "res://data/test_multiplayer_deck.json"

func _collect_deck_names() -> Array:
	# 读当前携带的英雄 key（备战界面退出时保存）
	var hero_key: String = DeckStorage.get_selected_hero()
	var saved: Dictionary = DeckStorage.load_deck(hero_key)
	var cards_map: Dictionary = saved.get("cards", {})
	var order: Array = saved.get("order", [])

	if not cards_map.is_empty():
		var names: Array = []
		# 按 order 顺序展开（每张卡按 count 重复）
		for cname in order:
			var count: int = int(cards_map.get(String(cname), 0))
			for _i in range(count):
				names.append(String(cname))
		# order 里没收录的条目兜底追加
		for cname in cards_map.keys():
			if not order.has(cname):
				var count: int = int(cards_map[cname])
				for _i in range(count):
					names.append(String(cname))
		if not names.is_empty():
			return names

	# 回退：test_multiplayer_deck.json
	var path: String
	if FileAccess.file_exists(TEST_MP_DECK_PATH):
		path = TEST_MP_DECK_PATH
	else:
		path = DataLoader.BATTLE_CARDS_JSON
		if not FileAccess.file_exists(path):
			DataLoader.generate_battle_cards(hero_key)
	var f := FileAccess.open(path, FileAccess.READ)
	if f == null:
		return []
	var parsed = JSON.parse_string(f.get_as_text())
	f.close()
	var names: Array = []
	if typeof(parsed) == TYPE_ARRAY:
		for entry in parsed:
			if typeof(entry) == TYPE_DICTIONARY and entry.has("name"):
				var count: int = int(entry.get("count", 1))
				for _i in range(count):
					names.append(String(entry["name"]))
	elif typeof(parsed) == TYPE_DICTIONARY and parsed.has("cards"):
		var arr = parsed["cards"]
		if typeof(arr) == TYPE_ARRAY:
			for entry in arr:
				if typeof(entry) == TYPE_DICTIONARY and entry.has("name"):
					var count: int = int(entry.get("count", 1))
					for _i in range(count):
						names.append(String(entry["name"]))
	return names


# ── 辅助：玩家列表解析 ──────────────────────────────────────────────────────
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


# ── UI 工厂 ──────────────────────────────────────────────────────────────────
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


func _make_title(text: String) -> Label:
	var lbl := _make_label(text, FONT_SIZE_TITLE, ACCENT)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return lbl


func _make_hint(text: String) -> Label:
	var lbl := _make_label(text, FONT_SIZE_SMALL, TEXT_MUTED)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	return lbl


func _make_primary_btn(text: String) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.add_theme_font_size_override("font_size", FONT_SIZE_BODY)
	btn.custom_minimum_size = Vector2(0, BTN_HEIGHT)
	ThemeFactory.apply_button_styles(btn, ThemeFactory.primary_button_styles())
	btn.add_theme_color_override("font_color",         Color.WHITE)
	btn.add_theme_color_override("font_hover_color",   Color.WHITE)
	btn.add_theme_color_override("font_pressed_color", Color.WHITE)
	return btn


func _make_secondary_btn(text: String) -> Button:
	var btn := Button.new()
	btn.text = text
	btn.add_theme_font_size_override("font_size", FONT_SIZE_BODY)
	btn.custom_minimum_size = Vector2(0, BTN_HEIGHT)
	ThemeFactory.apply_button_styles(btn, ThemeFactory.settings_button_styles())
	return btn


func _make_spacer(h: int) -> Control:
	var sp := Control.new()
	sp.custom_minimum_size = Vector2(0, h)
	return sp
