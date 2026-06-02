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

var row: int = 0
var col: int = 0
var has_card: bool = false
## 阵营标识：0 = 玩家方（FACTION_PLAYER），1 = 敌方（FACTION_ENEMY）。
## 与 BoardSlot.FACTION_* 常量对齐，作为单位阵营的唯一可信来源。
var faction: int = 0
## 向后兼容别名。所有对 is_enemy 的读 / 写均自动同步到 faction，现有代码无需改动。
var is_enemy: bool:
	get: return faction == 1
	set(value): faction = 1 if value else 0
# 该 cell 所属的 BoardSlot id。由 BoardSlotFactory / setup 注入。
# 用于 PlayController / TurnSystem 反查 slot.faction / slot.allow_player_deploy 等。
var slot_id: String = ""
# 该 cell 上当前单位的"原属盘"id（即单位最初被生成/部署的盘）。
# 与 slot_id 区别：slot_id 是格子物理位置所属盘；owner_slot_id 是单位归属。
# 跨盘冲锋 / 玩家跨盘移动 时，slot_id 会被更新为新盘，owner_slot_id 保持不变，
# 保证单位死亡时入"原属盘"墓地，而非当前位置盘墓地（详见 PlayController.handle_unit_death）。
# 空串表示尚未注入归属（如 phantom / 初始空格）。
var owner_slot_id: String = ""

# 单位"出处"枚举：决定死亡时去向。
#   "hand"    = 玩家手牌部署 → Game.deck.graveyard（不论部署到主盘还是 ally 盘）
#   "spawner" = 该盘 spawner 生成 → owner slot 的 graveyard
#   "initial" = 关卡初始铺盘（json initial_units）→ owner slot 的 graveyard
#   ""        = 未设置（phantom / 空格）
const ORIGIN_HAND: String = "hand"
const ORIGIN_SPAWNER: String = "spawner"
const ORIGIN_INITIAL: String = "initial"
var origin: String = ""
var card_name: String = ""
var attack: int = 0
# 以单位视角 side 存储：{front, back, left, right}
# 渲染时再按 faction 翻转到屏幕绝对方向标签上。
var health: Dictionary = {"front": 0, "back": 0, "left": 0, "right": 0}
var effects: Array = []
var has_attacked: bool = false
var has_charged: bool = false
var is_phantom: bool = false
# 单位初始四维：set_card 时记录，受降等全恢复效果用。
var max_health: Dictionary = {"front": 0, "back": 0, "left": 0, "right": 0}

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

func set_phantom(cname, atk, hp, enemy: bool = false, effects_in: Array = []) -> void:
	set_card(cname, atk, hp, enemy, effects_in)
	has_card = false
	is_phantom = true
	inner_panel.modulate.a = 0.4

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
	has_card = true
	is_phantom = false
	inner_panel.modulate.a = 1.0
	card_name = cname
	attack = atk
	# hp 入参是单位视角 side dict（front/back/left/right），整盘统一 side 存储
	health = Orientation.clone_side_health(hp)
	# 记录初始四维，供受降等全恢复效果使用
	max_health = Orientation.clone_side_health(hp)
	effects = effects_in.duplicate()
	is_enemy = enemy
	# 归属盘：显式传入则用之（跨盘 move 透传），否则取格子当前所在盘 = 单位起源盘
	owner_slot_id = owner_id if owner_id != "" else slot_id
	# 出处：显式传入用之；不传则保留旧值（兼容旧调用，避免覆盖已有 origin）
	if p_origin != "":
		origin = p_origin
	name_lbl.text = cname
	atk_lbl.text = str(attack)
	_update_hp_labels()

	if is_enemy:
		inner_panel.add_theme_stylebox_override("panel", ThemeFactory.cell_panel(Color("#fff5f5"), Color("#ffc9c9"), 1, 20, true))
		name_lbl.add_theme_color_override("font_color", Color("#fa5252"))
	else:
		inner_panel.add_theme_stylebox_override("panel", ThemeFactory.cell_panel(Color.WHITE, Color("#e1e8ed"), 1, 20, true))
		name_lbl.add_theme_color_override("font_color", Color("#495057"))

	EffectBadgeFactory.refresh(inner_panel.get_node_or_null("EffectBadges"), effects)
	inner_panel.visible = true

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
	if active_tween:
		active_tween.kill()
		active_tween = null
	has_card = false
	card_name = ""
	is_enemy = false
	is_phantom = false
	has_charged = false
	owner_slot_id = ""
	origin = ""
	inner_panel.visible = false
	inner_panel.scale = Vector2.ONE
	inner_panel.modulate.a = 1.0
	inner_panel.self_modulate = Color.WHITE

func play_damage_effect() -> void:
	if active_tween:
		active_tween.kill()
	inner_panel.self_modulate = Color("#ffc9c9") if is_enemy else Color("#ffe3e3")
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

func receive_damage(dir_abs, dmg, dying: bool = false) -> bool:
	# dir_abs: 屏幕绝对方向（top/bottom/left/right），通常由 BoardModel 邻接判定给出
	var side := Orientation.abs_to_side(dir_abs, is_enemy)
	health[side] -= dmg
	_update_hp_labels()
	if dying:
		play_death_effect()
	else:
		play_damage_effect()
	# 任意一面 <=0 即阵亡
	for s in Orientation.SIDES:
		if health[s] <= 0:
			return true
	return false

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
			if is_enemy:
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

func _can_drop_data(_pos, data) -> bool:
	# 业务规则由 PlayController 统一裁决，cell 仅询问并响应视觉。
	if Game.play == null:
		return false
	if Game.play.can_play_at(self, data):
		set_drag_hover(true)
		return true
	return false

func _drop_data(_pos, data) -> void:
	# 不在此处结算，统一发到 PlayController。
	card_dropped.emit(self, data)

# JSON 往返后整数变浮点的工具函数：把 dict 所有 value 转为 int。
static func _int_dict(d: Dictionary) -> Dictionary:
	var out: Dictionary = {}
	for k in d.keys():
		out[k] = int(d[k])
	return out

# ── 序列化（PVP 联机用）────────────────────────────────────────────
# Cell 是场景节点，序列化只导出业务数据（不含视觉/动画/UI 层）。
# from_dict 在已存在的空 Cell 上原地还原；不创建新节点。
# health / max_health 以 side 视角存储，序列化保留 side 键。
# row/col 不序列化（由 BoardModel 的 grid_cells 键决定，反序时已正确）。
func to_dict() -> Dictionary:
	return {
		"row":            row,
		"col":            col,
		"has_card":       has_card,
		"is_phantom":     is_phantom,
		"faction":        faction,
		"slot_id":        slot_id,
		"owner_slot_id":  owner_slot_id,
		"origin":         origin,
		"card_name":      card_name,
		"attack":         attack,
		"health":         health.duplicate(),
		"max_health":     max_health.duplicate(),
		"effects":        effects.duplicate(),
		"has_attacked":   has_attacked,
		"has_charged":    has_charged,
	}

# 在已存在的 Cell 节点上原地还原。
# 调用前 Cell._ready 必须已跑完（hp_labels_abs 已构建）。
func from_dict(d: Dictionary) -> void:
	# row/col 假定已由 BoardSlotFactory 设好，不覆盖（避免与 grid_cells 键不一致）。
	var p_has_card:   bool   = bool(d.get("has_card", false))
	var p_is_phantom: bool   = bool(d.get("is_phantom", false))
	var p_faction:    int    = int(d.get("faction", 0))
	slot_id        = String(d.get("slot_id", ""))
	owner_slot_id  = String(d.get("owner_slot_id", ""))
	origin         = String(d.get("origin", ""))
	has_attacked   = bool(d.get("has_attacked", false))
	has_charged    = bool(d.get("has_charged", false))

	if not p_has_card and not p_is_phantom:
		_do_clear()
		return

	var p_card_name:  String = String(d.get("card_name", ""))
	var p_attack:     int    = int(d.get("attack", 0))
	var raw_hp                = d.get("health", {})
	# JSON 往返后数值变浮点，显式转 int 避免显示 "2.0"
	var p_health:     Dictionary = _int_dict(raw_hp) if typeof(raw_hp) == TYPE_DICTIONARY \
		else {"front": 0, "back": 0, "left": 0, "right": 0}
	var raw_mh                = d.get("max_health", p_health)
	var p_max_health: Dictionary = _int_dict(raw_mh) if typeof(raw_mh) == TYPE_DICTIONARY else p_health
	var raw_eff               = d.get("effects", [])
	var p_effects: Array      = raw_eff.duplicate() if typeof(raw_eff) == TYPE_ARRAY else []

	# set_card 会按"玩家视角 abs"格式处理 hp，但我们存的是 side 视角；
	# 直接用底层赋值再调样式，避免再走 Orientation 转换。
	has_card     = true
	is_phantom   = p_is_phantom
	inner_panel.modulate.a = 0.4 if p_is_phantom else 1.0
	card_name    = p_card_name
	attack       = p_attack
	health       = Orientation.clone_side_health(p_health)
	max_health   = Orientation.clone_side_health(p_max_health)
	effects      = p_effects
	is_enemy     = (p_faction == 1)
	name_lbl.text = p_card_name
	atk_lbl.text  = str(p_attack)
	_update_hp_labels()
	if is_enemy:
		inner_panel.add_theme_stylebox_override("panel",
			ThemeFactory.cell_panel(Color("#fff5f5"), Color("#ffc9c9"), 1, 20, true))
		name_lbl.add_theme_color_override("font_color", Color("#fa5252"))
	else:
		inner_panel.add_theme_stylebox_override("panel",
			ThemeFactory.cell_panel(Color.WHITE, Color("#e1e8ed"), 1, 20, true))
		name_lbl.add_theme_color_override("font_color", Color("#495057"))
	EffectBadgeFactory.refresh(inner_panel.get_node_or_null("EffectBadges"), effects)
	inner_panel.visible = true
	if p_is_phantom:
		# phantom 不算"真有牌"
		has_card = false
