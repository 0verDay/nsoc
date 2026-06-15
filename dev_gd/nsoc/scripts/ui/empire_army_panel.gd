class_name EmpireArmyPanel
extends SecondaryPanel

# 帝国"军队"二级界面（res://scenes/EmpireArmyPanel.tscn）。
# 结构与逻辑均仿照 PreparePanel，差异：
#   - 将领数据：empire_hero.json（A/B/C 占位）
#   - 卡数据：  empire_cards.json（仅"填线宝宝"一种）
#   - 存档：    EmpireDeckStorage（user://empire_decks.json，与备战面板隔离）
#   - Review 区按"剩余库存"动态铺卡：每种卡总量 TOTAL_PER_CARD=10，
#     muster 拿走一张则 review 少一张，放回则多一张（实体堆，互补总和=10）。

const HAND_CARD_SCENE: PackedScene = preload("res://scenes/HandCard.tscn")

const REVIEW_CARD_JSON: String = "res://data/empire_cards.json"

# 每种卡的牌库总量。muster 不限上限；review 显示张数 = max(0, total - muster_count)。
const TOTAL_PER_CARD: int = 10

const REVIEW_COLUMNS: int = 3
const REVIEW_VISUAL_GAP: int = 16
const REVIEW_CARD_OVERFLOW: int = 10
const REVIEW_V_SEPARATION: int = REVIEW_VISUAL_GAP + REVIEW_CARD_OVERFLOW * 2
const REVIEW_CARD_WIDTH: int = 250

const OVERSCROLL_RESISTANCE: float = 0.55
const OVERSCROLL_SETTLE_TIME: float = 0.28
const WHEEL_STEP_PX: float = 60.0

const SCROLL_THRESHOLD_PX: float = 18.0
const DRAG_START_PX: float = 40.0

enum GestureMode { NONE, SCROLL, DRAG }

@onready var hero_pnl: Panel = $HeroPnl
@onready var review_pnl: Panel = $ReviewPnl
@onready var filter_pnl: Panel = $FilterPnl
@onready var muster_pnl: Panel = $MusterPnl

var _hero_carousel: EmpireCarousel
var _current_hero_key: String = ""

enum SortMode { NO_SORT, COST_ASC, COST_DESC }
const SORT_LABELS: Dictionary = {
	SortMode.NO_SORT: "无排序",
	SortMode.COST_ASC: "费用升",
	SortMode.COST_DESC: "费用降",
}
const SORT_CYCLE: Array = [SortMode.COST_ASC, SortMode.COST_DESC]

var _sort_mode: int = SortMode.NO_SORT
var _sort_btn: Button

var _review_margin: MarginContainer
var _review_grid: GridContainer
var _review_viewport: Control
var _review_content: Control
var _hand_cards: Array = []

# 牌库总量表：name -> {card: CardBase, total: int}。从 empire_cards.json 装填。
var _card_pool: Dictionary = {}

var _pressed_card: Node = null
const PRESS_SCALE: Vector2 = Vector2(1.1, 1.1)
const PRESS_TWEEN_TIME: float = 0.1

var _detail_panel: DetailPanelController

var _logical_offset: float = 0.0
var _pressing: bool = false
var _gesture: int = GestureMode.NONE
var _press_pos: Vector2 = Vector2.ZERO
var _start_offset: float = 0.0
var _settle_tween: Tween

var _drag_preview: Control
var _drag_card_data = null

var _muster_entries: Dictionary = {}
var _muster_list: VBoxContainer
var _muster_press_card = null


func _apply_styles() -> void:
	var pnl_style := ThemeFactory.panel(Color.WHITE, Color(1, 1, 1, 0.6), 1, 20, true)
	var muster_style := ThemeFactory.panel(Color(0.94, 0.95, 0.96, 1.0), Color(1, 1, 1, 1.0), 1, 20, false)
	hero_pnl.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	review_pnl.add_theme_stylebox_override("panel", pnl_style)
	filter_pnl.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	muster_pnl.add_theme_stylebox_override("panel", muster_style)
	_init_card_pool()
	_populate_review()
	_build_muster()
	_build_sort_panel()
	_install_detail_panel()
	_install_deck_persistence()


# 装填 _card_pool：从 empire_cards.json 读出每张卡，total 设为 TOTAL_PER_CARD。
func _init_card_pool() -> void:
	_card_pool.clear()
	for card in DataLoader.load_cards(REVIEW_CARD_JSON):
		_card_pool[String(card.name)] = {"card": card, "total": TOTAL_PER_CARD}


func _install_deck_persistence() -> void:
	_hero_carousel = hero_pnl.get_node_or_null("Carousel") as EmpireCarousel
	if _hero_carousel == null:
		push_warning("EmpireArmyPanel: HeroPnl/Carousel not found, deck persistence disabled")
		return
	_hero_carousel.current_hero_changed.connect(_on_hero_changed)
	tree_exiting.connect(_save_current_deck)
	await get_tree().process_frame
	_current_hero_key = _hero_carousel.current_hero_key()
	_load_deck_for(_current_hero_key)


func _on_hero_changed(new_key: String) -> void:
	_save_current_deck()
	_current_hero_key = new_key
	_load_deck_for(new_key)


func _load_deck_for(hero_key: String) -> void:
	_muster_entries.clear()
	var saved: Dictionary = EmpireDeckStorage.load_deck(hero_key)
	var cards_map: Dictionary = saved.get("cards", {})
	var order: Array = saved.get("order", [])
	var sort_mode_str: String = String(saved.get("sort_mode", "no_sort"))
	if not cards_map.is_empty():
		var name_to_card: Dictionary = {}
		for card in DataLoader.load_cards(REVIEW_CARD_JSON):
			name_to_card[card.name] = card
		for cname in order:
			var card = name_to_card.get(String(cname), null)
			if card == null:
				push_warning("EmpireArmyPanel: saved card not found in empire_cards.json: " + String(cname))
				continue
			_muster_entries[String(cname)] = {"card": card, "count": int(cards_map[cname])}
	_set_sort_mode(_sort_mode_from_string(sort_mode_str))
	_refresh_muster_list()
	_refresh_review_cards()


func _save_current_deck() -> void:
	if _current_hero_key == "":
		return
	var out: Dictionary = {}
	var order: Array = []
	for key in _muster_entries.keys():
		out[key] = int(_muster_entries[key].count)
		order.append(String(key))
	var data := EmpireDeckStorage.load_all()
	if not data.has("decks") or typeof(data["decks"]) != TYPE_DICTIONARY:
		data["decks"] = {}
	data["decks"][_current_hero_key] = {
		"cards":     out,
		"order":     order,
		"sort_mode": _sort_mode_to_string(_sort_mode),
	}
	data["selected_hero"] = _current_hero_key
	EmpireDeckStorage.save_all(data)


func _sort_mode_to_string(mode: int) -> String:
	match mode:
		SortMode.COST_ASC: return "cost_asc"
		SortMode.COST_DESC: return "cost_desc"
		_: return "no_sort"


func _sort_mode_from_string(s: String) -> int:
	match s:
		"cost_asc": return SortMode.COST_ASC
		"cost_desc": return SortMode.COST_DESC
		_: return SortMode.NO_SORT


func detach_with_fade(duration: float) -> void:
	_save_current_deck()
	super.detach_with_fade(duration)


func _install_detail_panel() -> void:
	_detail_panel = DetailPanelController.new()
	_detail_panel.name = "DetailPanel"
	add_child(_detail_panel)
	_detail_panel.setup(self, HAND_CARD_SCENE)
	_detail_panel.get_clip().move_to_front()
	_detail_panel.attach_to_rect(hero_pnl)


# 仅构建容器骨架（viewport / margin / grid），不预填卡。
# 真正的卡片填充由 _refresh_review_cards 完成（依赖 _card_pool 与 _muster_entries）。
func _populate_review() -> void:
	for child in review_pnl.get_children():
		child.queue_free()

	var viewport := Control.new()
	viewport.name = "Viewport"
	viewport.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	viewport.clip_contents = true
	viewport.mouse_filter = Control.MOUSE_FILTER_STOP
	review_pnl.add_child(viewport)
	viewport.gui_input.connect(_on_viewport_input)
	_review_viewport = viewport

	var margin := MarginContainer.new()
	margin.name = "Content"
	margin.mouse_filter = Control.MOUSE_FILTER_PASS
	viewport.add_child(margin)
	_review_margin = margin
	_review_content = margin

	var grid := GridContainer.new()
	grid.name = "Grid"
	grid.columns = REVIEW_COLUMNS
	grid.add_theme_constant_override("v_separation", REVIEW_V_SEPARATION)
	margin.add_child(grid)
	_review_grid = grid

	# 初次铺卡（此时 muster 还为空，每种卡显示 total 张）。
	_refresh_review_cards()

	review_pnl.resized.connect(_relayout_review_grid)
	await get_tree().process_frame
	_relayout_review_grid()


# 按 _card_pool 当前剩余库存重铺 grid：
#   每种卡显示张数 = max(0, total - muster_count)
# muster 加/减卡后调用此函数同步 review 视图。
func _refresh_review_cards() -> void:
	if _review_grid == null:
		return
	for child in _review_grid.get_children():
		child.queue_free()
	_hand_cards.clear()

	# 预计算全局占用表，避免在循环内重复读盘。
	var global_taken: Dictionary = _calc_global_taken()

	var pool_keys: Array = _card_pool.keys()
	pool_keys.sort_custom(func(a, b):
		var ca = _card_pool[a].card
		var cb = _card_pool[b].card
		if ca.cost != cb.cost:
			return ca.cost < cb.cost
		return ca.name < cb.name)

	for key in pool_keys:
		var entry = _card_pool[key]
		var card = entry.card
		var taken: int = int(global_taken.get(key, 0))
		var remaining: int = max(0, int(entry.total) - taken)
		for i in range(remaining):
			var hc := HAND_CARD_SCENE.instantiate()
			_review_grid.add_child(hc)
			hc.setup(card, 0)
			hc.mouse_filter = Control.MOUSE_FILTER_IGNORE
			hc.set_process(false)
			for desc in hc.find_children("*", "Control", true, false):
				desc.mouse_filter = Control.MOUSE_FILTER_IGNORE
			_hand_cards.append(hc)

	# 内容高度变了，重新触发 content 测量与 offset clamp。
	if _review_margin != null and _review_viewport != null:
		_review_margin.queue_sort()
		await get_tree().process_frame
		var min_h: float = _review_margin.get_combined_minimum_size().y
		_review_content.size = Vector2(_review_viewport.size.x, min_h)
		_logical_offset = clamp(_logical_offset, 0.0, _max_scroll())
		_apply_offset()


# 计算所有将领当前占用的卡张数（全局共享牌池）。
# 逻辑：
#   - 从 EmpireDeckStorage 读所有将领的落盘数据，累加每张卡的 count。
#   - 当前将领（_current_hero_key）用内存 _muster_entries 替代其磁盘数据，
#     确保未落盘的操作（刚拖入/移出）实时反映在剩余库存里。
func _calc_global_taken() -> Dictionary:
	var result: Dictionary = {}
	var all_data: Dictionary = EmpireDeckStorage.load_all()
	var decks: Dictionary = all_data.get("decks", {})
	for hero_key in decks.keys():
		var deck = decks[hero_key]
		if typeof(deck) != TYPE_DICTIONARY:
			continue
		var cards_map = deck.get("cards", {})
		if typeof(cards_map) != TYPE_DICTIONARY:
			continue
		if String(hero_key) == _current_hero_key:
			# 当前将领跳过磁盘，后面用内存数据覆盖
			continue
		for cname in cards_map.keys():
			var cnt: int = int(cards_map[cname])
			result[String(cname)] = int(result.get(String(cname), 0)) + cnt
	# 叠加当前将领的内存状态
	for cname in _muster_entries.keys():
		var cnt: int = int(_muster_entries[cname].count)
		result[String(cname)] = int(result.get(String(cname), 0)) + cnt
	return result


func _relayout_review_grid() -> void:
	if _review_grid == null or _review_margin == null or _review_viewport == null:
		return
	var panel_w: float = review_pnl.size.x
	if panel_w <= 0.0:
		return
	var total_card_w: float = float(REVIEW_COLUMNS * REVIEW_CARD_WIDTH)
	var gap: int = int(max(0.0, (panel_w - total_card_w) / float(REVIEW_COLUMNS + 1)))
	_review_grid.add_theme_constant_override("h_separation", gap)
	var v_pad: int = REVIEW_VISUAL_GAP + REVIEW_CARD_OVERFLOW
	_review_margin.add_theme_constant_override("margin_left", gap)
	_review_margin.add_theme_constant_override("margin_right", gap)
	_review_margin.add_theme_constant_override("margin_top", v_pad)
	_review_margin.add_theme_constant_override("margin_bottom", v_pad)

	_review_content.size.x = _review_viewport.size.x
	_review_margin.queue_sort()
	await get_tree().process_frame
	var min_h: float = _review_margin.get_combined_minimum_size().y
	_review_content.size = Vector2(_review_viewport.size.x, min_h)

	_logical_offset = clamp(_logical_offset, 0.0, _max_scroll())
	_apply_offset()


func _max_scroll() -> float:
	if _review_viewport == null or _review_content == null:
		return 0.0
	return max(0.0, _review_content.size.y - _review_viewport.size.y)


func _apply_offset() -> void:
	if _review_content == null:
		return
	var display: float = _to_display(_logical_offset)
	_review_content.position = Vector2(0, -display)


func _to_display(logical: float) -> float:
	var max_s: float = _max_scroll()
	if logical < 0.0:
		return -_rubber(-logical)
	if logical > max_s:
		return max_s + _rubber(logical - max_s)
	return logical


func _rubber(x: float) -> float:
	var d: float = max(1.0, _review_viewport.size.y)
	var c: float = OVERSCROLL_RESISTANCE
	return (x * c * d) / (d + c * x)


func _on_viewport_input(event: InputEvent) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_WHEEL_UP and mb.pressed:
			_scroll_by(-WHEEL_STEP_PX)
			_settle_to_clamped()
			_review_viewport.accept_event()
			return
		if mb.button_index == MOUSE_BUTTON_WHEEL_DOWN and mb.pressed:
			_scroll_by(WHEEL_STEP_PX)
			_settle_to_clamped()
			_review_viewport.accept_event()
			return
		if mb.button_index == MOUSE_BUTTON_LEFT:
			if mb.pressed:
				_pressing = true
				_gesture = GestureMode.NONE
				_press_pos = mb.global_position
				_start_offset = _logical_offset
				_kill_settle_tween()
				var hit := _card_at_position(mb.global_position)
				if hit != null:
					_press_card(hit)
					if _detail_panel != null:
						_detail_panel.start_long_press(hit.card_data)
			return
	if event is InputEventMouseMotion and _pressing:
		var mm := event as InputEventMouseMotion
		var delta: Vector2 = mm.global_position - _press_pos
		if _gesture == GestureMode.NONE:
			if absf(delta.y) >= SCROLL_THRESHOLD_PX:
				_enter_scroll_mode()
			elif absf(delta.x) >= DRAG_START_PX and _pressed_card != null:
				_enter_drag_mode()
		if _gesture == GestureMode.SCROLL:
			_logical_offset = _start_offset - delta.y
			_apply_offset()
			_review_viewport.accept_event()
		elif _gesture == GestureMode.DRAG:
			_update_drag_preview(mm.global_position)
			_review_viewport.accept_event()


func _enter_scroll_mode() -> void:
	_gesture = GestureMode.SCROLL
	_release_pressed_card()
	if _detail_panel != null:
		_detail_panel.cancel_long_press()


func _enter_drag_mode() -> void:
	_gesture = GestureMode.DRAG
	if _pressed_card == null:
		return
	_drag_card_data = _pressed_card.card_data
	_drag_preview = _make_drag_preview(_drag_card_data)
	add_child(_drag_preview)
	_drag_preview.z_index = 300
	_update_drag_preview(get_global_mouse_position())


func _update_drag_preview(global_pos: Vector2) -> void:
	if _drag_preview == null:
		return
	_drag_preview.global_position = global_pos - _drag_preview.size / 2.0


func _finish_drag(global_pos: Vector2) -> void:
	if _drag_preview != null:
		_drag_preview.queue_free()
		_drag_preview = null
	if muster_pnl != null and muster_pnl.get_global_rect().has_point(global_pos):
		if _drag_card_data != null:
			_add_to_muster(_drag_card_data)
	_drag_card_data = null


static func _make_drag_preview(card_data) -> Control:
	var preview := Panel.new()
	preview.size = Vector2(REVIEW_CARD_WIDTH, 95)
	preview.mouse_filter = Control.MOUSE_FILTER_IGNORE
	preview.add_theme_stylebox_override(
		"panel",
		ThemeFactory.card_panel(Color.WHITE, Color("#339af0"), 2, 15, true)
	)
	var lbl := Label.new()
	lbl.text = String(card_data.name)
	lbl.add_theme_color_override("font_color", Color("#339af0"))
	lbl.add_theme_font_size_override("font_size", 24)
	lbl.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	preview.add_child(lbl)
	return preview


func _press_card(card: Node) -> void:
	_release_pressed_card()
	_pressed_card = card
	card.z_index = 1
	if card.get_tree():
		var tw := card.create_tween()
		tw.tween_property(card, "scale", PRESS_SCALE, PRESS_TWEEN_TIME)


func _release_pressed_card() -> void:
	if _pressed_card != null and is_instance_valid(_pressed_card):
		_pressed_card.z_index = 0
		if _pressed_card.get_tree():
			var tw := _pressed_card.create_tween()
			tw.tween_property(_pressed_card, "scale", Vector2.ONE, PRESS_TWEEN_TIME)
	_pressed_card = null


func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and _pressing and _gesture == GestureMode.DRAG:
		var mm := event as InputEventMouseMotion
		_update_drag_preview(mm.global_position)
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		var release_pos: Vector2 = (event as InputEventMouseButton).global_position
		if _pressing and _gesture == GestureMode.DRAG:
			_finish_drag(release_pos)
		if _pressing and _gesture == GestureMode.SCROLL:
			_settle_to_clamped()
		if _pressing:
			_pressing = false
			_gesture = GestureMode.NONE
			_release_pressed_card()
		if _detail_panel != null:
			_detail_panel.cancel_long_press()
			_detail_panel.hide_panel()
		_muster_press_card = null


func _card_at_position(global_pos: Vector2) -> Node:
	if _review_viewport != null and not _review_viewport.get_global_rect().has_point(global_pos):
		return null
	for hc in _hand_cards:
		if is_instance_valid(hc) and hc.get_global_rect().has_point(global_pos):
			return hc
	return null


func _scroll_by(dy: float) -> void:
	_logical_offset = clamp(_logical_offset + dy, 0.0, _max_scroll())
	_apply_offset()


func _settle_to_clamped() -> void:
	var target: float = clamp(_logical_offset, 0.0, _max_scroll())
	if is_equal_approx(target, _logical_offset):
		return
	_kill_settle_tween()
	_settle_tween = create_tween()
	_settle_tween.tween_method(_set_logical_offset, _logical_offset, target,
		OVERSCROLL_SETTLE_TIME).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


func _set_logical_offset(v: float) -> void:
	_logical_offset = v
	_apply_offset()


func _kill_settle_tween() -> void:
	if _settle_tween != null and _settle_tween.is_running():
		_settle_tween.kill()
	_settle_tween = null


static func _card_sort_key(a, b) -> bool:
	if a.cost != b.cost:
		return a.cost < b.cost
	return a.name < b.name


# ============================================================================
# Muster（点兵）面板
# ============================================================================

const MUSTER_TITLE_HEIGHT: float = 60.0
const MUSTER_TITLE_FONT_SIZE: int = 28
const MUSTER_ITEM_FONT_SIZE: int = 22
const MUSTER_ITEM_SEPARATION: int = 10
const MUSTER_PADDING: int = 20


func _build_muster() -> void:
	for child in muster_pnl.get_children():
		child.queue_free()

	var title := Label.new()
	title.text = "点兵"
	title.add_theme_font_size_override("font_size", MUSTER_TITLE_FONT_SIZE)
	title.add_theme_color_override("font_color", Color(0.2, 0.2, 0.2, 1))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.set_anchors_preset(Control.PRESET_TOP_WIDE, false)
	title.offset_top = 20
	title.offset_bottom = 20 + MUSTER_TITLE_HEIGHT
	muster_pnl.add_child(title)

	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	scroll.offset_top = 20 + MUSTER_TITLE_HEIGHT + 10
	scroll.offset_bottom = -MUSTER_PADDING
	scroll.offset_left = MUSTER_PADDING
	scroll.offset_right = -MUSTER_PADDING
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	muster_pnl.add_child(scroll)
	var vbar := scroll.get_v_scroll_bar()
	if vbar:
		vbar.custom_minimum_size = Vector2.ZERO
		vbar.modulate = Color(1, 1, 1, 0)
		vbar.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", MUSTER_ITEM_SEPARATION)
	scroll.add_child(vbox)
	_muster_list = vbox


func _add_to_muster(card_data) -> void:
	if card_data == null:
		return
	var key: String = String(card_data.name)
	var is_new_kind: bool = not _muster_entries.has(key)
	if is_new_kind:
		_muster_entries[key] = {"card": card_data, "count": 1}
	else:
		_muster_entries[key].count += 1
	if is_new_kind:
		_set_sort_mode(SortMode.NO_SORT)
	_refresh_muster_list()
	_refresh_review_cards()


func _refresh_muster_list() -> void:
	if _muster_list == null:
		return
	for c in _muster_list.get_children():
		c.queue_free()
	for key in _muster_entries.keys():
		var entry = _muster_entries[key]
		_muster_list.add_child(_make_muster_row(entry.card, int(entry.count)))


const MUSTER_ROW_WIDTH: float = 390.0
const MUSTER_BADGE_SIZE: int = 30
const MUSTER_BADGE_FONT: int = 14
const MUSTER_ITEM_GAP: int = 10


func _make_muster_row(card_data, count: int) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	row.add_theme_constant_override("separation", MUSTER_ITEM_GAP)

	var badge := ThemeFactory.cost_badge(int(card_data.cost), MUSTER_BADGE_SIZE, MUSTER_BADGE_FONT)
	badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(badge)

	var btn := _make_muster_item(card_data, count)
	btn.custom_minimum_size = Vector2(MUSTER_ROW_WIDTH - MUSTER_BADGE_SIZE - MUSTER_ITEM_GAP, 0)
	btn.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	row.add_child(btn)
	return row


func _make_muster_item(card_data, count: int) -> Button:
	var b := Button.new()
	var cname: String = String(card_data.name)
	b.text = cname if count == 1 else cname + " x " + str(count)
	b.set_meta("card_data", card_data)
	b.add_theme_font_size_override("font_size", MUSTER_ITEM_FONT_SIZE)
	b.add_theme_color_override("font_color", Color(0.2, 0.2, 0.2, 1))
	b.add_theme_color_override("font_hover_color", Color(0.1, 0.1, 0.1, 1))
	b.add_theme_color_override("font_pressed_color", Color(0.0, 0.0, 0.0, 1))
	b.mouse_filter = Control.MOUSE_FILTER_PASS
	var styles := ThemeFactory.list_item_styles()
	b.add_theme_stylebox_override("normal", styles.normal)
	b.add_theme_stylebox_override("hover", styles.hover)
	b.add_theme_stylebox_override("pressed", styles.pressed)
	b.add_theme_stylebox_override("focus", styles.focus)
	b.button_down.connect(_on_muster_item_press.bind(b))
	b.button_up.connect(_on_muster_item_release)
	b.mouse_exited.connect(_on_muster_item_release)
	b.gui_input.connect(_on_muster_item_gui_input.bind(b))
	return b


func _on_muster_item_gui_input(event: InputEvent, btn: Button) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.double_click:
			var card = btn.get_meta("card_data", null)
			if card != null:
				_remove_one_from_muster(String(card.name))
				if _detail_panel != null:
					_detail_panel.cancel_long_press()
					_detail_panel.hide_panel()
				_muster_press_card = null
				btn.accept_event()


func _remove_one_from_muster(card_name: String) -> void:
	if not _muster_entries.has(card_name):
		return
	_muster_entries[card_name].count -= 1
	if _muster_entries[card_name].count <= 0:
		_muster_entries.erase(card_name)
	_refresh_muster_list()
	_refresh_review_cards()


func _on_muster_item_press(btn: Button) -> void:
	if _detail_panel == null:
		return
	var card = btn.get_meta("card_data", null)
	if card == null:
		return
	_muster_press_card = card
	_detail_panel.start_long_press(card)


func _on_muster_item_release() -> void:
	if _detail_panel != null:
		_detail_panel.cancel_long_press()
	_muster_press_card = null


# ============================================================================
# 排序面板
# ============================================================================

func _build_sort_panel() -> void:
	for child in filter_pnl.get_children():
		child.queue_free()
	var btn := Button.new()
	btn.text = SORT_LABELS[_sort_mode]
	btn.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	btn.add_theme_font_size_override("font_size", 32)
	ThemeFactory.apply_button_styles(btn, ThemeFactory.primary_button_styles())
	btn.add_theme_color_override("font_color", Color.WHITE)
	btn.add_theme_color_override("font_hover_color", Color.WHITE)
	btn.add_theme_color_override("font_pressed_color", Color.WHITE)
	btn.pressed.connect(_on_sort_btn_pressed)
	filter_pnl.add_child(btn)
	_sort_btn = btn


func _on_sort_btn_pressed() -> void:
	var next_mode: int
	var idx: int = SORT_CYCLE.find(_sort_mode)
	if idx < 0:
		next_mode = SORT_CYCLE[0]
	else:
		next_mode = SORT_CYCLE[(idx + 1) % SORT_CYCLE.size()]
	_set_sort_mode(next_mode)
	_refresh_muster_list()


func _set_sort_mode(mode: int) -> void:
	_sort_mode = mode
	if _sort_btn != null:
		_sort_btn.text = SORT_LABELS[mode]
	if mode == SortMode.NO_SORT:
		return
	if _muster_entries.is_empty():
		return
	var keys: Array = _muster_entries.keys()
	keys.sort_custom(func(a, b):
		var ca = _muster_entries[a].card
		var cb = _muster_entries[b].card
		if ca.cost != cb.cost:
			if mode == SortMode.COST_ASC:
				return ca.cost < cb.cost
			return ca.cost > cb.cost
		return ca.name < cb.name)
	var new_dict: Dictionary = {}
	for k in keys:
		new_dict[k] = _muster_entries[k]
	_muster_entries = new_dict
