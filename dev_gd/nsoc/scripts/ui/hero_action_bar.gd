class_name HeroActionBar
extends VBoxContainer

# 玩家英雄行动条。挂在 LeftSidePnl 内、居中，朝面板扩展方向生长。
# 顶部：英雄技能按钮；下方：每件已装备的装备按钮。
# 装备激活不消耗 mana（装备卡打出时已扣费）。
#
# ── 动画序列（扩展 & 收缩完全对称）────────────────────────────────────────────
# ① 面板全部按钮渐隐  → ② 面板 + VBox 扩展/收缩  → ③ 剩余按钮渐显
#
# ── 方向检测 ──────────────────────────────────────────────────────────────────
# 面板在屏幕下半：向上扩展（offset_top -=）；面板在屏幕上半：向下扩展（offset_bottom +=）。
#
# ── VBox 自动调整防护 ─────────────────────────────────────────────────────────
# VBoxContainer 在 add_child/queue_free 时可能因 minimum_size_changed 自动调整
# offset_top/bottom，导致动画起点错误。对策：在 add_child/free 前后记录并强制回写偏移。

# ── 信号 ──────────────────────────────────────────────────────────────────────
signal panel_expansion_started
signal panel_expansion_finished

# ── 布局常量 ──────────────────────────────────────────────────────────────────
const BTN_W:         float = 240.0
const BTN_H:         float = 56.0
const DUR_W:         float = 32.0   # 耐久指示器宽度
const BOTTOM_MARGIN: float = 30.0
const SEPARATION:    int   = 6

const EXPAND_DURATION:  float = 0.3
const FADE_IN_DURATION: float = 0.2
const SHRINK_DURATION:  float = 0.2

const COLOR_NORMAL_BORDER:    Color = Color(1, 1, 1, 0.6)
const COLOR_HIGHLIGHT_BORDER: Color = Color("#339af0")
# LeftSidePnl 的永久基础 z_index：高于棋盘/格子（默认 0），保证视觉和 drop 检测永远在棋盘之上
const PANEL_Z_INDEX_BASE: int  = 10
# 装备拖拽期间临时更高，防止附盘 UI 节点遮挡
const EQUIP_DRAG_Z_INDEX: int = 100

# ── 内部状态 ──────────────────────────────────────────────────────────────────
var _ability_btn: Button
var _equip_buttons: Dictionary    = {}   # inst → HBoxContainer（整行）
var _equip_dur_labels: Dictionary = {}   # inst → Label（耐久指示器）
var _detail_panel                 = null
var _hand_card_scene: PackedScene = null
var _ability_ctx_callable: Callable

var _parent_panel_node: Control = null
var _is_animating: bool         = false

# ── 初始化 ────────────────────────────────────────────────────────────────────
func setup(parent: Control, ability_ctx_callable: Callable,
		detail_panel = null, hand_card_scene: PackedScene = null) -> void:
	_ability_ctx_callable = ability_ctx_callable
	_detail_panel         = detail_panel
	_hand_card_scene      = hand_card_scene
	_parent_panel_node    = parent
	# 永远保持在棋盘之上（z 基础值），后续拖拽时临时再提升
	parent.z_index = PANEL_Z_INDEX_BASE

	parent.add_child(self)
	add_theme_constant_override("separation", SEPARATION)

	anchor_left   = 0.5; anchor_right  = 0.5
	anchor_top    = 1.0; anchor_bottom = 1.0
	offset_left   = -BTN_W * 0.5
	offset_right  =  BTN_W * 0.5
	# grow_vertical 不设置：offset_top/bottom 完全由本脚本控制，防止 VBox 自动调整

	_build_ability_button()
	_refresh_layout()
	_wire_signals()

# ── 信号连线 ──────────────────────────────────────────────────────────────────
func _wire_signals() -> void:
	if has_node("/root/Game") and Game.turn != null:
		Game.turn.turn_started.connect(_refresh_all)
		Game.turn.turn_ended.connect(_refresh_all)
	if has_node("/root/Game") and Game.mana != null:
		Game.mana.mana_changed.connect(func(_c, _m): _refresh_ability_button())
	if has_node("/root/HeroAbilities"):
		HeroAbilities.ability_used.connect(func(_id): _refresh_ability_button())
		HeroAbilities.turn_reset.connect(_refresh_ability_button)
	if has_node("/root/Equipments"):
		Equipments.equipment_added.connect(_on_equipment_added)
		Equipments.equipment_removed.connect(_on_equipment_removed)
		Equipments.equipment_changed.connect(_on_equipment_changed)

# ── 方向检测 ──────────────────────────────────────────────────────────────────
# 返回 true = 面板在屏幕上半（向下扩展，animate offset_bottom）
# 返回 false = 面板在屏幕下半（向上扩展，animate offset_top）
func _is_panel_in_upper_half() -> bool:
	if _parent_panel_node == null or not is_inside_tree():
		return false
	var vp_h: float = get_viewport().get_visible_rect().size.y
	return _parent_panel_node.get_global_rect().get_center().y < vp_h * 0.5

# ── 英雄技能按钮 ──────────────────────────────────────────────────────────────
func _build_ability_button() -> void:
	_ability_btn = Button.new()
	_ability_btn.name = "HeroAbilityBtn"
	_ability_btn.custom_minimum_size = Vector2(BTN_W, BTN_H)
	_ability_btn.text = _get_player_ability_label()
	_ability_btn.add_theme_font_size_override("font_size", 22)
	_ability_btn.add_theme_color_override("font_color",         Color.WHITE)
	_ability_btn.add_theme_color_override("font_hover_color",   Color.WHITE)
	_ability_btn.add_theme_color_override("font_pressed_color", Color.WHITE)
	add_child(_ability_btn)
	ThemeFactory.apply_button_styles(_ability_btn, ThemeFactory.primary_button_styles())
	_ability_btn.pressed.connect(_on_ability_pressed)
	_refresh_ability_button()

func _get_player_ability_label() -> String:
	var hero: HeroState = Game.player_hero() if has_node("/root/Game") else null
	if hero == null: return "英雄能力"
	var ability_id: String = hero.ability_id()
	if ability_id != "" and HeroAbilities.has(ability_id):
		return HeroAbilities.get_display_name(ability_id)
	return "英雄能力"

func _on_ability_pressed() -> void:
	# PVP：非当前行动玩家不能用英雄技能
	if Game.is_pvp and not Game.pvp_is_my_turn():
		return
	var hero: HeroState = Game.player_hero()
	if hero == null: return
	var ability_id: String = hero.ability_id()
	if ability_id == "" or not HeroAbilities.has(ability_id): return
	var ctx = _make_ctx()
	if not HeroAbilities.can_activate(ability_id, ctx): return
	# PVP 同步前快照：restart 需要把弃牌入对端的 enemy_main slot.graveyard，
	# 必须在 activate 之前记录当前手牌（discard_all_and_refill 之后再取就是新抽的牌了）。
	var pre_snapshot: Dictionary = _pvp_snapshot_for_ability(ability_id)
	await HeroAbilities.activate(ability_id, ctx)
	# 激活成功后广播给对手
	if Game.is_pvp:
		_pvp_broadcast_activate_hero(ability_id, pre_snapshot)

# 不同 ability 需要的"前置快照"。activate 是 async，必须在 await 前记录。
# - restart：当前手牌名单（用于对端把弃牌入 enemy_main.graveyard）
func _pvp_snapshot_for_ability(ability_id: String) -> Dictionary:
	var snap: Dictionary = {}
	if ability_id == "restart":
		var names: Array = []
		var hv: HandView = Game.play.hand_view if Game.play != null else null
		if hv != null:
			var container: Container = hv.get_hand_container()
			if container != null:
				for c in container.get_children():
					var data = c.card_data if "card_data" in c else null
					if data != null and data is CardBase and String(data.name) != "虚空":
						names.append(String(data.name))
		snap["discarded"] = names
	return snap

# 广播 action/activate_hero 给对手。
func _pvp_broadcast_activate_hero(ability_id: String, snapshot: Dictionary) -> void:
	if not has_node("/root/Net"):
		return
	if Game.play == null:
		return
	var opp_id: String = ""
	if Game.play.has_method("_pvp_opponent_id"):
		opp_id = Game.play._pvp_opponent_id()
	if opp_id == "":
		return
	var payload: Dictionary = {"ability_id": ability_id}
	# 合并 snapshot 字段
	for k in snapshot.keys():
		payload[String(k)] = snapshot[k]
	Net.send_to("action/activate_hero", Game.pvp_room_id, opp_id, payload)

func _refresh_ability_button() -> void:
	if _ability_btn == null: return
	var hero: HeroState = Game.player_hero()
	if hero == null:
		_ability_btn.disabled = true; return
	var ability_id: String = hero.ability_id()
	if ability_id == "" or not HeroAbilities.has(ability_id):
		_ability_btn.disabled = true; return
	# 每次刷新时同步更新按钮文字，确保 setup() 时序问题不导致永久显示 fallback 文字
	_ability_btn.text = HeroAbilities.get_display_name(ability_id)
	var can_use: bool = HeroAbilities.can_activate(ability_id, _make_ctx())
	# PVP：非当前行动玩家时禁用
	if Game.is_pvp and not Game.pvp_is_my_turn():
		can_use = false
	_ability_btn.disabled = not can_use

# ── 装备按钮 ──────────────────────────────────────────────────────────────────
func _on_equipment_added(inst: EquipmentInstance) -> void:
	var upper: bool = _is_panel_in_upper_half()

	# add_child 前记录偏移（防 VBox 自动调整跳帧）
	# 上半：面板向下扩展（panel.offset_bottom 变大），VBox 顶边保持不动（offset_top 变小）
	# 下半：面板向上扩展（panel.offset_top 变小），VBox 顶边随之上移（offset_top 变小）
	var pre_vbox_top: float  = offset_top
	var pre_panel_bottom: float = _parent_panel_node.offset_bottom if upper else 0.0
	var pre_panel_top: float    = _parent_panel_node.offset_top    if not upper else 0.0

	var row := _build_equipment_row(inst)
	row.modulate.a = 0.0
	add_child(row)
	_equip_buttons[inst] = row
	_refresh_equipment_button(inst)

	# 强制回写，抵消 VBox 可能的自动调整
	offset_top = pre_vbox_top
	if upper:
		_parent_panel_node.offset_bottom = pre_panel_bottom
	else:
		_parent_panel_node.offset_top = pre_panel_top

	_animate_equip_expand(inst, upper, pre_vbox_top, pre_panel_bottom, pre_panel_top)

func _on_equipment_removed(inst: EquipmentInstance) -> void:
	if not _equip_buttons.has(inst): return
	var row: Control = _equip_buttons[inst]
	_equip_buttons.erase(inst)
	_equip_dur_labels.erase(inst)
	_animate_equip_shrink(row)

func _on_equipment_changed(inst: EquipmentInstance) -> void:
	_refresh_equipment_button(inst)

func _build_equipment_row(inst: EquipmentInstance) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.name = "EquipRow"
	row.custom_minimum_size = Vector2(BTN_W, BTN_H)
	row.add_theme_constant_override("separation", 4)
	row.alignment = BoxContainer.ALIGNMENT_CENTER

	# 耐久指示器：黄色 pill Label（与卡牌手牌样式一致）
	var dur_lbl := Label.new()
	dur_lbl.name = "DurLbl"
	dur_lbl.text = str(inst.durability_left)
	dur_lbl.add_theme_stylebox_override("normal", ThemeFactory.pill(Color("#fcc419"), 10))
	dur_lbl.add_theme_font_size_override("font_size", 16)
	dur_lbl.add_theme_color_override("font_color", Color("#495057"))
	dur_lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	dur_lbl.vertical_alignment   = VERTICAL_ALIGNMENT_CENTER
	dur_lbl.custom_minimum_size  = Vector2(DUR_W, BTN_H - 8)
	dur_lbl.size_flags_vertical  = Control.SIZE_SHRINK_CENTER
	row.add_child(dur_lbl)
	_equip_dur_labels[inst] = dur_lbl

	# 主按钮（填充剩余宽度，文字只显示装备名称）
	var b := Button.new()
	b.name = "EquipBtn"
	b.text = inst.display_name()
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	b.custom_minimum_size   = Vector2(BTN_W - DUR_W - 8, BTN_H)
	b.add_theme_font_size_override("font_size", 20)
	b.add_theme_color_override("font_color",         Color.WHITE)
	b.add_theme_color_override("font_hover_color",   Color.WHITE)
	b.add_theme_color_override("font_pressed_color", Color.WHITE)
	ThemeFactory.apply_button_styles(b, ThemeFactory.primary_button_styles())
	b.pressed.connect(func(): _on_equip_btn_pressed(inst))
	b.button_down.connect(func(): _on_equip_btn_down(inst))
	b.button_up.connect(_on_equip_btn_up)
	b.mouse_exited.connect(_on_equip_btn_up)
	row.add_child(b)
	return row

func _on_equip_btn_pressed(inst: EquipmentInstance) -> void:
	if inst == null or not inst.can_activate(): return
	# PVP：非当前行动玩家不能激活装备
	if Game.is_pvp and not Game.pvp_is_my_turn():
		return
	var ctx = _make_ctx()
	# 需要目标：锁 UI → 进入选择模式 → 等待选择 → 解锁
	var req_target: String = inst.required_target()
	if req_target != "":
		# pick_target_async 需要 ctx._target_selector 已注入
		if typeof(ctx) == TYPE_DICTIONARY:
			push_warning("HeroActionBar: ctx 为字典，无法调用 pick_target_async")
			return
		# 锁回合运行，禁用结束回合/出牌
		if Game.turn != null:
			Game.turn.is_running = true
		var chosen_cell = await ctx.pick_target_async(req_target)
		if chosen_cell == null:
			# 取消：解锁，不激活
			if Game.turn != null:
				Game.turn.is_running = false
			return
		ctx.target_cell = chosen_cell
		# 装备激活属于"回合外"操作；选完目标后先解锁 is_running，
		# 否则 inst.activate 内部的 can_activate() 会因 is_running=true 而拒绝执行。
		if Game.turn != null:
			Game.turn.is_running = false
		var success: bool = await inst.activate(ctx)
		if Game.turn != null:
			Game.turn.is_running = false
		if success:
			_refresh_equipment_button(inst)
			# PVP：激活成功后广播给对手（仅白名单 effect 实际发包）
			_pvp_broadcast_equip_activation(inst, chosen_cell)
		return
	# 无目标：直接激活
	var success_no_target: bool = await inst.activate(ctx)
	if success_no_target:
		_pvp_broadcast_equip_activation(inst, null)

# PVP 广播包装：仅 PVP 模式 + Game.play 存在时调用。
# play_controller 内部按 effect 白名单决定是否实际发包。
func _pvp_broadcast_equip_activation(inst: EquipmentInstance, target_cell) -> void:
	if not Game.is_pvp:
		return
	if inst == null or inst.card_data == null:
		return
	if Game.play == null:
		return
	if Game.play.has_method("_pvp_broadcast_activate_equip"):
		Game.play._pvp_broadcast_activate_equip(inst.card_data.name, target_cell)

func _on_equip_btn_down(inst: EquipmentInstance) -> void:
	if _detail_panel != null and _detail_panel.has_method("start_long_press_equipment"):
		_detail_panel.start_long_press_equipment(inst)

func _on_equip_btn_up() -> void:
	if _detail_panel != null and _detail_panel.has_method("cancel_long_press"):
		_detail_panel.cancel_long_press()

func _refresh_equipment_button(inst: EquipmentInstance) -> void:
	if not _equip_buttons.has(inst): return
	var row: Control = _equip_buttons[inst]
	if not is_instance_valid(row): return
	# 刷新耐久指示器数字
	if _equip_dur_labels.has(inst):
		var lbl: Label = _equip_dur_labels[inst]
		if is_instance_valid(lbl):
			lbl.text = str(inst.durability_left)
	# 刷新按钮禁用状态
	var inner_btn: Button = row.get_node_or_null("EquipBtn")
	if inner_btn != null:
		var can_use: bool = inst.can_activate()
		# PVP：非当前行动玩家时禁用
		if Game.is_pvp and not Game.pvp_is_my_turn():
			can_use = false
		inner_btn.disabled = not can_use

# ── 全量刷新 ──────────────────────────────────────────────────────────────────
func _refresh_all() -> void:
	_refresh_ability_button()
	for inst in _equip_buttons.keys():
		_refresh_equipment_button(inst)

func _make_ctx():
	if _ability_ctx_callable.is_valid(): return _ability_ctx_callable.call()
	return {"hero": Game.player_hero()}

# ── VBox 布局刷新（仅 setup 时调用） ──────────────────────────────────────────
func _refresh_layout() -> void:
	var n: int = get_child_count()
	var total_h: float = float(n) * BTN_H + float(max(n - 1, 0)) * float(SEPARATION)
	offset_top    = -total_h - BOTTOM_MARGIN
	offset_bottom = -BOTTOM_MARGIN

# ── 英雄面板高亮 ──────────────────────────────────────────────────────────────
func show_equip_drag_highlight() -> void:
	if _parent_panel_node == null: return
	# 拖拽期间进一步提升，超过附盘 UI 节点
	_parent_panel_node.z_index = EQUIP_DRAG_Z_INDEX
	_parent_panel_node.add_theme_stylebox_override("panel",
		ThemeFactory.panel(Color.WHITE, COLOR_HIGHLIGHT_BORDER, 3, 20, true))

func hide_equip_drag_highlight() -> void:
	if _parent_panel_node == null: return
	# 恢复到基础值（非 0），保证始终在棋盘之上
	_parent_panel_node.z_index = PANEL_Z_INDEX_BASE
	_parent_panel_node.add_theme_stylebox_override("panel",
		ThemeFactory.panel(Color.WHITE, COLOR_NORMAL_BORDER, 1, 20, true))

# ── 公用：构建三阶段 tween ────────────────────────────────────────────────────
# btns_all      : 参与渐隐/渐显的按钮列表
# btns_fadein   : 最终渐显的按钮（收缩时排除被销毁的那个）
# panel_prop    : 面板要动画的属性名（"offset_top" 或 "offset_bottom"）
# panel_tgt     : 面板属性目标值
# vbox_prop     : VBox 要动画的属性名
# vbox_tgt      : VBox 属性目标值
# duration      : 第②阶段时长
# on_done       : 完成回调（可选）
func _build_3phase_tween(
		btns_all: Array, btns_fadein: Array,
		panel_prop: String, panel_tgt: float,
		vbox_prop: String,  vbox_tgt: float,
		duration: float, on_done: Callable = Callable()) -> void:

	var master := create_tween()

	# ── ① 全部按钮渐隐 ───────────────────────────────────────────────────
	if btns_all.size() > 0:
		master.tween_property(btns_all[0], "modulate:a", 0.0, FADE_IN_DURATION) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		for i in range(1, btns_all.size()):
			master.parallel().tween_property(btns_all[i], "modulate:a", 0.0, FADE_IN_DURATION) \
				.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	else:
		master.tween_interval(FADE_IN_DURATION)

	# ── ② 面板 + VBox 同时扩展/收缩 ────────────────────────────────────
	master.tween_property(_parent_panel_node, panel_prop, panel_tgt, duration) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	master.parallel().tween_property(self, vbox_prop, vbox_tgt, duration) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)

	# ── ③ 剩余按钮渐显 ───────────────────────────────────────────────────
	if btns_fadein.size() > 0:
		master.tween_property(btns_fadein[0], "modulate:a", 1.0, FADE_IN_DURATION) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		for i in range(1, btns_fadein.size()):
			master.parallel().tween_property(btns_fadein[i], "modulate:a", 1.0, FADE_IN_DURATION) \
				.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	else:
		master.tween_interval(FADE_IN_DURATION)

	if on_done.is_valid():
		master.finished.connect(on_done)

# ── 面板扩展动画 ──────────────────────────────────────────────────────────────
# upper=false（面板在下半）：panel.offset_top 减小（顶边上移），VBox.offset_top 同步减小
# upper=true（面板在上半）：panel.offset_bottom 增大（底边下移），VBox.offset_top 减小
#   → VBox 顶边在屏幕上保持不动，VBox 底边随 panel 底边下移，VBox 向下增高
func _animate_equip_expand(inst: EquipmentInstance,
		upper: bool, pre_vbox_top: float,
		pre_panel_bottom: float, pre_panel_top: float) -> void:
	if _parent_panel_node == null: return
	var row: Control = _equip_buttons.get(inst)
	if not is_instance_valid(row): return

	# 动画锁：另一段动画正在运行时，直接应用终态，跳过过渡动画。
	# 保证按钮可见、面板/VBox 尺寸正确，不产生悬空不可见按钮。
	var expand_h: float = BTN_H + float(SEPARATION)
	if _is_animating:
		row.modulate.a = 1.0
		offset_top = pre_vbox_top - expand_h
		if upper:
			_parent_panel_node.offset_bottom = pre_panel_bottom + expand_h
		else:
			_parent_panel_node.offset_top = pre_panel_top - expand_h
		return

	var panel_prop: String
	var panel_tgt: float
	var vbox_tgt: float = pre_vbox_top - expand_h   # offset_top 始终减小（向上扩）

	if upper:
		# 面板底边下移
		panel_prop = "offset_bottom"
		panel_tgt  = pre_panel_bottom + expand_h
	else:
		# 面板顶边上移
		panel_prop = "offset_top"
		panel_tgt  = pre_panel_top - expand_h

	panel_expansion_started.emit()
	_is_animating = true

	var rows: Array = []
	for child in get_children():
		if is_instance_valid(child) and (child is Button or child is HBoxContainer):
			rows.append(child)

	_build_3phase_tween(rows, rows, panel_prop, panel_tgt, "offset_top", vbox_tgt,
		EXPAND_DURATION,
		func():
			_is_animating = false
			panel_expansion_finished.emit()
	)

# ── 面板收缩动画 ──────────────────────────────────────────────────────────────
# upper=false：panel.offset_top 增大（顶边下移），VBox.offset_top 增大（收缩）
# upper=true ：panel.offset_bottom 减小（底边上移），VBox.offset_top 增大（收缩）
func _animate_equip_shrink(row: Control) -> void:
	if _parent_panel_node == null: return

	var upper: bool = _is_panel_in_upper_half()
	var expand_h: float = BTN_H + float(SEPARATION)

	# 动画锁：另一段动画正在运行时，直接清理，跳过过渡动画。
	if _is_animating:
		if is_instance_valid(row):
			row.queue_free()
		if upper:
			_parent_panel_node.offset_bottom -= expand_h
		else:
			_parent_panel_node.offset_top += expand_h
		offset_top += expand_h
		return

	var pre_vbox_top: float = offset_top
	var panel_prop: String
	var pre_panel_val: float
	var panel_tgt: float

	if upper:
		panel_prop    = "offset_bottom"
		pre_panel_val = _parent_panel_node.offset_bottom
		panel_tgt     = pre_panel_val - expand_h
	else:
		panel_prop    = "offset_top"
		pre_panel_val = _parent_panel_node.offset_top
		panel_tgt     = pre_panel_val + expand_h

	var vbox_tgt: float = pre_vbox_top + expand_h

	var remaining: Array = []
	for child in get_children():
		if is_instance_valid(child) \
				and (child is Button or child is HBoxContainer) \
				and child != row:
			remaining.append(child)

	var all_rows: Array = []
	for child in get_children():
		if is_instance_valid(child) and (child is Button or child is HBoxContainer):
			all_rows.append(child)

	# 与 expand 对称：lock + 发出信号，保证 drag_blocked 在动画结束后一定解除
	panel_expansion_started.emit()
	_is_animating = true

	var master := create_tween()

	# ── ① 全部行渐隐 ─────────────────────────────────────────────────────
	if all_rows.size() > 0:
		master.tween_property(all_rows[0], "modulate:a", 0.0, FADE_IN_DURATION) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
		for i in range(1, all_rows.size()):
			master.parallel().tween_property(all_rows[i], "modulate:a", 0.0, FADE_IN_DURATION) \
				.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	else:
		master.tween_interval(FADE_IN_DURATION)

	# free 死亡行，重置偏移防止 VBox 自动收缩抢跑
	master.tween_callback(func():
		if is_instance_valid(row):
			row.queue_free()
		offset_top = pre_vbox_top
		if upper:
			_parent_panel_node.offset_bottom = pre_panel_val
		else:
			_parent_panel_node.offset_top = pre_panel_val
	)

	# ── ② 面板 + VBox 同时收缩 ───────────────────────────────────────────
	master.tween_property(_parent_panel_node, panel_prop, panel_tgt, SHRINK_DURATION) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	master.parallel().tween_property(self, "offset_top", vbox_tgt, SHRINK_DURATION) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)

	# ── ③ 剩余行渐显 ─────────────────────────────────────────────────────
	if remaining.size() > 0:
		master.tween_property(remaining[0], "modulate:a", 1.0, FADE_IN_DURATION) \
			.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
		for i in range(1, remaining.size()):
			master.parallel().tween_property(remaining[i], "modulate:a", 1.0, FADE_IN_DURATION) \
				.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	else:
		master.tween_interval(FADE_IN_DURATION)

	# 解锁：与 expand 对称，保证 drag_blocked 最终一定被解除
	master.finished.connect(func():
		_is_animating = false
		panel_expansion_finished.emit()
	)
