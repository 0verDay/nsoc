extends Panel

# 棋盘格子。
# 重构后：
#   1. 不再通过 get_tree().current_scene 调用 main，改为发射信号供 PlayController 监听。
#   2. 样式由 ThemeFactory 统一构造。
#   3. 效果徽章由 EffectBadgeFactory 统一构造（去重 hand_card 的实现）。

signal long_press_requested(payload)
signal long_press_canceled
signal card_dropped(cell, drag_data)
signal cleared(cell)
# 效果列表变化（浸水/冲锋等运行时追加）：只刷新已开详情面板，不触发弹出。
signal effects_changed(payload)

## 状态全部存放在纯数据对象里（重构文档.md §3.4-6）。
## 本类的 `row/col/has_card/health/...` 都是**转发属性**：读写语义与旧实现逐条相同，
## 因此规则层（TurnSystem / CombatSystem / 效果 / AI）的调用点**零改动**，
## 而状态已经与 UI 节点解耦 —— 服务器可以用同一套规则跑 `CellData` 棋盘
## （见 tests/HeadlessBoardTest.tscn 与 scripts/core/cell_data.gd）。
var data: CellData = CellData.new()

var row: int:
	get: return data.row
	set(value): data.row = value
var col: int:
	get: return data.col
	set(value): data.col = value
var has_card: bool:
	get: return data.has_card
	set(value): data.has_card = value
## 阵营标识：0 = 玩家方（FACTION_PLAYER），1 = 敌方（FACTION_ENEMY）。
## 与 BoardSlot.FACTION_* 常量对齐，作为单位阵营的唯一可信来源。
var faction: int:
	get: return data.faction
	set(value): data.faction = value
## 向后兼容别名。所有对 is_enemy 的读 / 写均自动同步到 faction，现有代码无需改动。
var is_enemy: bool:
	get: return data.is_enemy
	set(value): data.is_enemy = value
# 该 cell 所属的 BoardSlot id。由 BoardSlotFactory / setup 注入。
# 用于 PlayController / TurnSystem 反查 slot.faction / slot.allow_player_deploy 等。
var slot_id: String:
	get: return data.slot_id
	set(value): data.slot_id = value
# 该 cell 上当前单位的"原属盘"id（即单位最初被生成/部署的盘）。
# 与 slot_id 区别：slot_id 是格子物理位置所属盘；owner_slot_id 是单位归属。
# 跨盘冲锋 / 玩家跨盘移动 时，slot_id 会被更新为新盘，owner_slot_id 保持不变，
# 保证单位死亡时入"原属盘"墓地，而非当前位置盘墓地（详见 PlayController.handle_unit_death）。
# 空串表示尚未注入归属（如 phantom / 初始空格）。
var owner_slot_id: String:
	get: return data.owner_slot_id
	set(value): data.owner_slot_id = value
# PVP 队伍标识，继承自所在 slot.team_id："defender" / "attacker"，PVE 为空串。
# 用于 is_hostile_to / is_friendly_to，效果/目标选择以此判断敌友，不再依赖 is_enemy 二分。
var team_id: String:
	get: return data.team_id
	set(value): data.team_id = value

# 返回本单位对 viewer_team 是否为敌方。PVE（team_id==""）降级到 is_enemy 判定。
func is_hostile_to(viewer_team_id: String) -> bool:
	return data.is_hostile_to(viewer_team_id)

func is_friendly_to(viewer_team_id: String) -> bool:
	return data.is_friendly_to(viewer_team_id)

var origin: String:
	get: return data.origin
	set(value): data.origin = value
var card_name: String:
	get: return data.card_name
	set(value): data.card_name = value
var attack: int:
	get: return data.attack
	set(value): data.attack = value
# 以单位视角 side 存储：{front, back, left, right}
# 渲染时再按 faction 翻转到屏幕绝对方向标签上。
# 注意：getter 返回的是 CellData 里的同一个 Dictionary 引用，
# 因此 `cell.health["front"] -= dmg` 这类原地修改照旧生效。
var health: Dictionary:
	get: return data.health
	set(value): data.health = value
var effects: Array:
	get: return data.effects
	set(value): data.effects = value
var has_attacked: bool:
	get: return data.has_attacked
	set(value): data.has_attacked = value
var has_charged: bool:
	get: return data.has_charged
	set(value): data.has_charged = value
var is_phantom: bool:
	get: return data.is_phantom
	set(value): data.is_phantom = value
# 单位初始四维：set_card 时记录，受降等全恢复效果用。
var max_health: Dictionary:
	get: return data.max_health
	set(value): data.max_health = value

@onready var inner_panel = $InnerPanel
@onready var name_lbl = $InnerPanel/NameLbl
@onready var atk_lbl = $InnerPanel/AtkBg/AtkLbl

# 屏幕绝对方向 → Label 节点（位置由 .tscn 锚定）
var hp_labels_abs: Dictionary = {}
var active_tween = null
var is_drag_hovered: bool = false

func _ready() -> void:
	add_theme_stylebox_override("panel", ThemeFactory.cell_panel(Color.WHITE, Color("#d1d9e0"), 2, 20))
	$InnerPanel/AtkBg.add_theme_stylebox_override("panel", ThemeFactory.cell_panel(Color("#ff6b6b"), Color.TRANSPARENT, 0, 8))

	hp_labels_abs["top"] = $InnerPanel/TopHp
	hp_labels_abs["bottom"] = $InnerPanel/BottomHp
	hp_labels_abs["left"] = $InnerPanel/LeftHp
	hp_labels_abs["right"] = $InnerPanel/RightHp
	for d in hp_labels_abs.values():
		d.add_theme_stylebox_override("normal", ThemeFactory.pill(Color("#51cf66"), 10))
		# 相对 z_index = 2（继承 InnerPanel z=1），实际 z=3，高于 _SelectionBorder(z=2)
		d.z_index = 2
	# InnerPanel z=1，渲染在 cell 背景之上；_SelectionBorder z=2 将浮在其上显示描边
	inner_panel.z_index = 1

	# 初始化期不发 cleared（无监听者，且语义错误）
	_do_clear()
	inner_panel.pivot_offset = custom_minimum_size / 2.0
	gui_input.connect(_on_gui_input)
	mouse_exited.connect(_on_mouse_exit)

func _on_gui_input(event) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT:
		if event.is_pressed():
			_on_mouse_enter()
			if has_card:
				long_press_requested.emit({
					"name": card_name,
					"attack": attack,
					"health": health,
					"effects": effects,
				})
		else:
			_on_mouse_exit()

func _on_mouse_enter() -> void:
	if has_card and is_inside_tree():
		var tween := create_tween()
		tween.tween_property(inner_panel, "scale", Vector2(1.08, 1.08), 0.1)

func _on_mouse_exit() -> void:
	long_press_canceled.emit()
	if (has_card or is_phantom) and is_inside_tree():
		var tween := create_tween()
		tween.tween_property(inner_panel, "scale", Vector2.ONE, 0.1)

# 选中等待状态高亮：在 cell 顶层叠一个透明背景 + 蓝色描边的 Panel。
# 四维指示器已设置绝对 z_index = 10，始终渲染在描边之上，不被遮挡。
const _HIGHLIGHT_BORDER: float = 3.0

func set_selection_highlight(enabled: bool, color: Color = Color("#339af0")) -> void:
	var existing := get_node_or_null("_SelectionBorder")
	if not enabled:
		if existing != null:
			existing.queue_free()
		return
	if existing != null:
		# 颜色可能变了，更新描边颜色
		existing.add_theme_stylebox_override("panel",
			ThemeFactory.cell_panel(Color(0, 0, 0, 0), color,
				int(_HIGHLIGHT_BORDER), 20))
		return
	var frame := Panel.new()
	frame.name = "_SelectionBorder"
	frame.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	frame.mouse_filter = Control.MOUSE_FILTER_IGNORE
	# z_index=2：浮在 InnerPanel(z=1) 之上，低于 HP labels(InnerPanel z=1 + label z=2 = 3)
	frame.z_index = 2
	frame.add_theme_stylebox_override("panel",
		ThemeFactory.cell_panel(Color(0, 0, 0, 0), color,
			int(_HIGHLIGHT_BORDER), 20))
	add_child(frame)

func set_card(cname, atk, hp, enemy: bool = false, effects_in: Array = [], owner_id: String = "", p_origin: String = "") -> void:
	# ① 状态写进纯数据层
	data.set_card(cname, atk, hp, enemy, effects_in, owner_id, p_origin)
	# ② 归属队伍的解析留在视图侧：客户端有 Game.registry 可查，服务器侧显式注入
	var owner_slot_ref: BoardSlot = null
	if Game.registry != null:
		owner_slot_ref = Game.registry.get_by_id(data.owner_slot_id)
	data.team_id = owner_slot_ref.team_id if owner_slot_ref != null else ""
	# ③ 按数据刷视图
	_apply_card_view()

# 按 data 重建"有单位"的视图表现（原 set_card 的 UI 部分）。
func _apply_card_view() -> void:
	is_phantom = data.is_phantom
	inner_panel.modulate.a = 0.4 if is_phantom else 1.0
	name_lbl.text = card_name
	atk_lbl.text = str(attack)
	_update_hp_labels()

	# 颜色：PVP 模式按本端视角 is_hostile_to 决定；PVE 仍靠 is_enemy。
	var show_as_enemy: bool = _is_visual_enemy()
	if show_as_enemy:
		inner_panel.add_theme_stylebox_override("panel", ThemeFactory.cell_panel(Color("#fff5f5"), Color("#ffc9c9"), 1, 20, true))
		name_lbl.add_theme_color_override("font_color", Color("#fa5252"))
	else:
		inner_panel.add_theme_stylebox_override("panel", ThemeFactory.cell_panel(Color.WHITE, Color("#e1e8ed"), 1, 20, true))
		name_lbl.add_theme_color_override("font_color", Color("#495057"))

	EffectBadgeFactory.refresh(inner_panel.get_node_or_null("EffectBadges"), effects)
	inner_panel.visible = true

func set_phantom(cname, atk, hp, enemy: bool = false, effects_in: Array = []) -> void:
	set_card(cname, atk, hp, enemy, effects_in)
	has_card = false        # phantom 不算"真有牌"
	is_phantom = true
	inner_panel.modulate.a = 0.4

# 视觉上是否显示为"敌方"色。
# PVP：按本端队伍 is_hostile_to 判断；PVE：直接用 is_enemy。
func _is_visual_enemy() -> bool:
	if Game.is_pvp and team_id != "":
		var local_team: String = Game.team_of_player(Game.local_player_id) if Game.registry != null else ""
		if local_team != "":
			return is_hostile_to(local_team)
	return is_enemy

func _update_hp_labels() -> void:
	# health 以 side 存储；标签按屏幕绝对方向放置。
	# 取 abs label，找到对应单位视角 side，回填数值。
	for abs_dir in hp_labels_abs.keys():
		var side := Orientation.abs_to_side(abs_dir, is_enemy)
		hp_labels_abs[abs_dir].text = str(health[side])

func _update_atk_label() -> void:
	atk_lbl.text = str(attack)

# 清除实卡（敌/我方死亡 或 棋子被替换）。
# 会 emit cleared 通知外部"格子空了"，触发 phantom 重算等副作用。
func clear_card() -> void:
	_do_clear()
	cleared.emit(self)

# 清除 phantom 预告。不发 cleared 信号，避免与 SpawnerSystem.refresh_phantoms 形成循环回调。
func clear_phantom() -> void:
	if not is_phantom:
		return
	_do_clear()

# 共用清理逻辑。不触发信号。
func _do_clear() -> void:
	# ① 清状态（与 CellData.clear_card 同一份语义）
	data.clear_card()
	# ② 复位视图
	if active_tween:
		active_tween.kill()
		active_tween = null
	inner_panel.visible = false
	inner_panel.scale = Vector2.ONE
	inner_panel.modulate.a = 1.0
	inner_panel.self_modulate = Color.WHITE

func play_damage_effect() -> void:
	if active_tween:
		active_tween.kill()
	inner_panel.self_modulate = Color("#ffc9c9") if _is_visual_enemy() else Color("#ffe3e3")
	if is_inside_tree():
		active_tween = get_tree().create_tween()
		active_tween.tween_property(inner_panel, "self_modulate", Color.WHITE, 0.4)

func play_attack_effect() -> void:
	if active_tween:
		active_tween.kill()
	inner_panel.self_modulate = Color("#ffe066")
	if is_inside_tree():
		active_tween = get_tree().create_tween()
		active_tween.tween_property(inner_panel, "self_modulate", Color.WHITE, 0.4)

func play_death_effect() -> void:
	if active_tween:
		active_tween.kill()
	inner_panel.self_modulate = Color.WHITE
	if is_inside_tree():
		active_tween = get_tree().create_tween()
		active_tween.tween_property(inner_panel, "self_modulate", Color(0.5, 0.5, 0.5), 0.4)


func set_drag_hover(hovered: bool) -> void:
	if is_drag_hovered == hovered:
		return
	is_drag_hovered = hovered

	if is_drag_hovered:
		var highlight_style := ThemeFactory.cell_panel(Color.WHITE, Color("#339af0"), 2, 20, true)
		if has_card:
			inner_panel.add_theme_stylebox_override("panel", highlight_style)
		else:
			add_theme_stylebox_override("panel", highlight_style)
	else:
		if has_card:
			if _is_visual_enemy():
				inner_panel.add_theme_stylebox_override("panel", ThemeFactory.cell_panel(Color("#fff5f5"), Color("#ffc9c9"), 1, 20, true))
			else:
				inner_panel.add_theme_stylebox_override("panel", ThemeFactory.cell_panel(Color.WHITE, Color("#e1e8ed"), 1, 20, true))
		add_theme_stylebox_override("panel", ThemeFactory.cell_panel(Color.WHITE, Color("#d1d9e0"), 2, 20))

func _notification(what) -> void:
	if what == NOTIFICATION_DRAG_END:
		set_drag_hover(false)

func _process(_delta) -> void:
	if is_drag_hovered:
		if not get_global_rect().has_point(get_global_mouse_position()):
			set_drag_hover(false)

func _can_drop_data(_pos, drag_data) -> bool:
	# 业务规则由 PlayController 统一裁决，cell 仅询问并响应视觉。
	# 形参名用 drag_data：`data` 已是本类的 CellData 成员，避免遮蔽。
	if Game.play == null:
		return false
	if Game.play.can_play_at(self, drag_data):
		set_drag_hover(true)
		return true
	return false

func _drop_data(_pos, drag_data) -> void:
	# 不在此处结算，统一发到 PlayController。
	card_dropped.emit(self, drag_data)

# ── 序列化（PVP 联机用）────────────────────────────────────────────
# 状态全在 CellData 中，序列化直接转发（键与 CellData.to_dict 完全一致）。
# health / max_health 以 side 视角存储，序列化保留 side 键。
# row/col 不参与 grid_cells 键的推导（由 BoardModel 决定，反序时已正确）。
func to_dict() -> Dictionary:
	return data.to_dict()

# 在已存在的 Cell 节点上原地还原：先还原数据，再按数据刷视图。
# 调用前 Cell._ready 必须已跑完（hp_labels_abs 已构建）。
func from_dict(d: Dictionary) -> void:
	# row/col 假定已由 BoardSlotFactory 设好，不覆盖（避免与 grid_cells 键不一致）。
	data.from_dict(d)
	if not data.has_card and not data.is_phantom:
		# 空格：清状态 + 复位视图（与旧实现的 _do_clear 路径等价）
		_do_clear()
		return
	_apply_card_view()
