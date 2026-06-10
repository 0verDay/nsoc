class_name TurnOrderIndicator
extends Control

# 单棋盘的行动顺序徽章 + 转圈光环。
# 由 BoardOrchestrator 在每个 slot 的 bg_panel 内部创建。
#
# 位置锚点：
#   FACTION_PLAYER（玩家盘，视觉在下方）→ bg_panel 上沿中点
#   FACTION_ENEMY （敌方盘，视觉在上方）→ bg_panel 下沿中点
#
# 光环驱动规则（「场上始终有一个光环在转」）：
#   PVE：
#     phase_started(PLAYER) → 所有 PLAYER 盘亮，ENEMY 盘灭
#     phase_started(ENEMY)  → 所有 ENEMY 盘亮，PLAYER 盘灭
#     turn_ended            → 回到 PLAYER 盘亮（玩家出牌 / 等待结束回合）
#     初始默认              → PLAYER 盘亮
#   PVP：
#     由 BoardOrchestrator.preview_active_pvp_slots() 全程维护，
#     phase_started / turn_ended 信号在 PVP 下被跳过，避免冲突。

const BADGE_SIZE: float = 32.0
const RING_RADIUS: float = 22.0

var _slot: BoardSlot = null
var _badge: Panel = null
var _label: Label = null
var _ring: _Ring = null

func setup(p_slot: BoardSlot) -> void:
	_slot = p_slot
	mouse_filter = Control.MOUSE_FILTER_IGNORE
	z_index = 10

	# 光环（在徽章下层）
	_ring = _Ring.new()
	_ring.name = "Ring"
	_ring.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_ring.visible = false
	add_child(_ring)

	# 徽章面板
	_badge = Panel.new()
	_badge.name = "Badge"
	_badge.size = Vector2(BADGE_SIZE, BADGE_SIZE)
	_badge.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_badge.z_index = 1
	var sb := StyleBoxFlat.new()
	sb.bg_color = Color("#dee2e6")
	sb.set_corner_radius_all(int(BADGE_SIZE / 2.0))
	sb.border_width_bottom = 2
	sb.border_width_top    = 2
	sb.border_width_left   = 2
	sb.border_width_right  = 2
	sb.border_color = Color("#adb5bd")
	_badge.add_theme_stylebox_override("panel", sb)
	add_child(_badge)

	# 数字标签
	_label = Label.new()
	_label.name = "Num"
	_label.add_theme_font_size_override("font_size", 18)
	_label.add_theme_color_override("font_color", Color("#495057"))
	_label.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	_label.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	_label.size = Vector2(BADGE_SIZE, BADGE_SIZE)
	_label.mouse_filter = Control.MOUSE_FILTER_IGNORE
	_badge.add_child(_label)

	_apply_ring_color()
	_connect_signals()

	if is_instance_valid(p_slot.bg_panel):
		p_slot.bg_panel.resized.connect(_reposition)
	# 等待一帧布局就绪后定位，同时设初始激活状态
	await get_tree().process_frame
	if is_instance_valid(self):
		_reposition()
		_set_initial_active()

# ── 外部 API ──────────────────────────────────────────────────────────

func set_order(num: int) -> void:
	if is_instance_valid(_label):
		_label.text = str(num) if num >= 1 else "?"

func set_active(active: bool) -> void:
	if is_instance_valid(_ring):
		_ring.visible = active
	if is_instance_valid(_badge):
		_badge.self_modulate = Color.WHITE if active else Color(1.0, 1.0, 1.0, 0.75)

func refresh_color() -> void:
	_apply_ring_color()

# ── 内部 ──────────────────────────────────────────────────────────────

# PVE 初始状态：玩家盘默认亮（等待玩家出牌）
func _set_initial_active() -> void:
	if not has_node("/root/Game") or Game.is_pvp:
		return
	if _slot != null:
		set_active(_slot.faction == BoardSlot.FACTION_PLAYER)

func _get_ring_color() -> Color:
	if _slot == null:
		return Color("#adb5bd")
	match _slot.team_id:
		"team_a":   return Color("#339af0")
		"team_b":   return Color("#f03e3e")
		"defender": return Color("#fab005")
		"attacker": return Color("#f76707")
	return Color("#4dabf7") if _slot.faction == BoardSlot.FACTION_PLAYER \
		else Color("#fa5252")

func _apply_ring_color() -> void:
	if is_instance_valid(_ring):
		_ring.ring_color = _get_ring_color()

func _reposition() -> void:
	if _slot == null or not is_instance_valid(_slot.bg_panel):
		return
	var bg: Panel = _slot.bg_panel
	var bw: float = bg.size.x
	var bh: float = bg.size.y
	var cx: float = bw / 2.0
	# 几何判断：bg_panel 中心在视口上半 → 板子在上方 → 徽章贴下沿（朝中线）
	#                              下半 → 板子在下方 → 徽章贴上沿（朝中线）
	# 不依赖 faction，兼容 3v3 友军盘（视觉在下但 faction=ENEMY）等特殊情形。
	var screen_h: float = bg.get_viewport_rect().size.y
	var board_mid_y: float = bg.global_position.y + bh * 0.5
	var at_top_half: bool = board_mid_y < screen_h * 0.5
	var cy: float = bh if at_top_half else 0.0
	_badge.position = Vector2(cx - BADGE_SIZE / 2.0, cy - BADGE_SIZE / 2.0)
	# 光环略大，圆心与徽章一致
	var rh: float = RING_RADIUS + 3.0
	if is_instance_valid(_ring):
		_ring.position = Vector2(cx - rh, cy - rh)
		_ring.size     = Vector2(rh * 2.0, rh * 2.0)

func _connect_signals() -> void:
	if not has_node("/root/Game") or Game.turn == null:
		return
	var t: TurnSystem = Game.turn
	if not t.phase_started.is_connected(_on_phase_started):
		t.phase_started.connect(_on_phase_started)
	if not t.turn_ended.is_connected(_on_turn_ended):
		t.turn_ended.connect(_on_turn_ended)

func _disconnect_signals() -> void:
	if not has_node("/root/Game") or Game.turn == null:
		return
	var t: TurnSystem = Game.turn
	if t.phase_started.is_connected(_on_phase_started):
		t.phase_started.disconnect(_on_phase_started)
	if t.turn_ended.is_connected(_on_turn_ended):
		t.turn_ended.disconnect(_on_turn_ended)

# PVE：按阶段阵营点亮；PVP：跳过（由 preview_active_pvp_slots 管理）
func _on_phase_started(faction: int) -> void:
	if has_node("/root/Game") and Game.is_pvp:
		return
	if _slot != null:
		set_active(_slot.faction == faction)

# PVE：turn_ended 回到玩家盘亮（玩家出牌阶段）；PVP：跳过
func _on_turn_ended() -> void:
	if has_node("/root/Game") and Game.is_pvp:
		return
	if _slot != null:
		set_active(_slot.faction == BoardSlot.FACTION_PLAYER)

func _exit_tree() -> void:
	_disconnect_signals()

# ── 转圈光环子节点 ────────────────────────────────────────────────────

class _Ring extends Control:
	const ARC_SPAN: float = TAU * 0.75   # 270° 弧段
	const RING_W: float = 3.0

	var ring_color: Color = Color("#4dabf7")
	var _angle: float = 0.0

	func _process(delta: float) -> void:
		if not visible:
			return
		_angle += delta * 2.0
		if _angle > TAU:
			_angle -= TAU
		queue_redraw()

	func _draw() -> void:
		var center: Vector2 = size / 2.0
		var r: float = size.x / 2.0 - RING_W / 2.0
		draw_arc(center, r, _angle, _angle + ARC_SPAN, 48, ring_color, RING_W, true)
