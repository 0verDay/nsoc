class_name PreparePanel
extends SecondaryPanel

# “备战”二级界面（res://scenes/PreparePanel.tscn）。
# 在 SecondaryPanel 基础上新增 4 个子面板的样式应用：
#   HeroPnl   : 左 1/3，整高
#   ReviewPnl : 中 1/3，整高 —— 展示当前所有可用卡牌的卡面
#                按 (cost 升, name 字典序升) 排列，从左到右、从上到下铺到
#                自定义 Viewport(裁剪) 内的 GridContainer。
#                竖向滚动 + 过度滑动弹性（rubber band，越界阻力 + 释放回弹）。
#   FilterPnl : 右 1/3 顶部，与 BackBtn 等高
#   MusterPnl : 右 1/3 底部，补足右下剩余区域

const HAND_CARD_SCENE: PackedScene = preload("res://scenes/HandCard.tscn")

# 备战界面专用卡牌数据源（含正式卡与占位卡）。
# 与战斗用的 all_cards.json / 运行时 user://battle_cards.json 分离，
# 避免备战调试卡污染战斗牌池。
const REVIEW_CARD_JSON: String = "res://data/review_cards.json"

# Review 网格参数
# HandCard 的 CostBg / AtkBg / 四向 HpLabel 向卡片外缘溢出 ~10px。
# "视觉间隙"指相邻两卡可见边距，= GridContainer 的 separation - 2 × overflow。
# 水平方向 separation 由面板宽动态算（见 _relayout_review_grid），保证
# 卡间隙 == 卡到左/右边栏间隙；竖直方向用固定 VISUAL_GAP。
const REVIEW_COLUMNS: int = 3
const REVIEW_VISUAL_GAP: int = 16
const REVIEW_CARD_OVERFLOW: int = 10
const REVIEW_V_SEPARATION: int = REVIEW_VISUAL_GAP + REVIEW_CARD_OVERFLOW * 2
const REVIEW_CARD_WIDTH: int = 250  # 与 HandCard.tscn 的 custom_minimum_size.x 同步

# 过度滑动参数
const OVERSCROLL_RESISTANCE: float = 0.55      # rubber band 强度系数（越小阻力越大）
const OVERSCROLL_SETTLE_TIME: float = 0.28     # 释放后回弹时长
const WHEEL_STEP_PX: float = 60.0              # 鼠标滚轮单步

# 手势阈值：按下后未达任一阈值前处于"按下"态（保留详情计时 + 缩放）。
# - 竖直位移 |dy| ≥ SCROLL_THRESHOLD_PX 先触发 → 进入滚动模式，永久取消详情/拖拽。
# - 水平位移 |dx| ≥ DRAG_START_PX 先触发（且按下时命中卡） → 进入拖拽模式，
#   保留详情显示与卡片缩放（按需求：松开后才退）。
# DRAG_START_PX 设得大于 SCROLL_THRESHOLD_PX，让"想拖卡"的动作必须明显水平。
const SCROLL_THRESHOLD_PX: float = 18.0
const DRAG_START_PX: float = 40.0

# 手势模式枚举。
enum GestureMode { NONE, SCROLL, DRAG }

@onready var hero_pnl: Panel = $HeroPnl
@onready var review_pnl: Panel = $ReviewPnl
@onready var filter_pnl: Panel = $FilterPnl
@onready var muster_pnl: Panel = $MusterPnl

# HeroCarousel 引用（HeroPnl 内唯一 Control 类型节点）。
# 提供 current_hero_key() + current_hero_changed 信号。
var _hero_carousel: HeroCarousel
var _current_hero_key: String = ""

# 排序模式：NO_SORT = 按加入 muster 的先后顺序（依赖 Dictionary 插入序）
#         COST_ASC / COST_DESC = 按费用升/降；同费用按名字 Unicode 升序兜底。
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
var _review_viewport: Control       # 自定义裁剪容器（取代 ScrollContainer）
var _review_content: Control        # 可越界平移的内容根（= _review_margin）
var _hand_cards: Array = []         # 网格内的 HandCard 实例，用于命中测试

# 按下时高亮放大的卡（与游玩界面同样的 1.1× 缩放动效）。
var _pressed_card: Node = null
const PRESS_SCALE: Vector2 = Vector2(1.1, 1.1)
const PRESS_TWEEN_TIME: float = 0.1

# 长按详情面板（与游玩界面同一实现）。
var _detail_panel: DetailPanelController

# 逻辑滚动偏移（允许越界，负数 / 大于 max 时表示过度滑动）。
# 视觉位移 = _to_display(_logical_offset) 经 rubber band 衰减。
var _logical_offset: float = 0.0
var _pressing: bool = false
var _gesture: int = GestureMode.NONE  # 当前手势（NONE/SCROLL/DRAG）
var _press_pos: Vector2 = Vector2.ZERO
var _start_offset: float = 0.0
var _settle_tween: Tween

# 拖拽预览（跟随鼠标的临时卡视觉）。仅 DRAG 模式下存在。
var _drag_preview: Control
var _drag_card_data = null

# Muster（点兵）面板状态：每种卡 -> {card: CardBase, count: int}
var _muster_entries: Dictionary = {}
var _muster_list: VBoxContainer
# 当前正在长按的 muster 列表项（用于松开时清除按下样式 / 取消计时）。
var _muster_press_card = null


func _apply_styles() -> void:
	var pnl_style := ThemeFactory.panel(Color.WHITE, Color(1, 1, 1, 0.6), 1, 20, true)
	# 点兵面板用游玩界面牌堆同款灰底（无阴影），与其它白底面板做视觉区分。
	var muster_style := ThemeFactory.panel(Color(0.94, 0.95, 0.96, 1.0), Color(1, 1, 1, 1.0), 1, 20, false)
	# HeroPnl 不应用样式：作为透明裁剪容器，由 HeroCarousel 内的每个 page
	# 各自携带相同样式，整张面板随滑动一起位移。
	hero_pnl.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	review_pnl.add_theme_stylebox_override("panel", pnl_style)
	# FilterPnl 不再当面板用，仅作为排序按钮的容器，背景透明。
	filter_pnl.add_theme_stylebox_override("panel", StyleBoxEmpty.new())
	muster_pnl.add_theme_stylebox_override("panel", muster_style)
	_populate_review()
	_build_muster()
	_build_sort_panel()
	_install_detail_panel()
	_install_deck_persistence()


# 接入 DeckStorage：
#   - 进入界面：加载当前英雄的卡组到 _muster_entries 并渲染。
#   - 切英雄（HeroCarousel.current_hero_changed）：先保存旧英雄卡组，再切。
#   - 退出（detach_with_fade / tree_exiting）：保存当前英雄卡组。
func _install_deck_persistence() -> void:
	_hero_carousel = hero_pnl.get_node_or_null("Carousel") as HeroCarousel
	if _hero_carousel == null:
		push_warning("PreparePanel: HeroPnl/Carousel not found, deck persistence disabled")
		return
	_hero_carousel.current_hero_changed.connect(_on_hero_changed)
	# tree_exiting 兜底：任何路径销毁本面板都会触发，保存最后状态。
	tree_exiting.connect(_save_current_deck)
	# carousel._ready 是 await 异步的，current_hero_key() 在帧后才稳定可读。
	await get_tree().process_frame
	_current_hero_key = _hero_carousel.current_hero_key()
	_load_deck_for(_current_hero_key)


func _on_hero_changed(new_key: String) -> void:
	# 先保存旧英雄的当前 muster，再切到新英雄并加载。
	_save_current_deck()
	_current_hero_key = new_key
	_load_deck_for(new_key)


# 从存档加载 hero_key 的卡表 → 重建 _muster_entries + 排序复位 + 刷新 UI。
# DataLoader.load_cards(REVIEW_CARD_JSON) 已缓存于此次调用；
# 用 name → CardBase 映射快速还原 muster 条目（O(N+M)，M 通常 < 30）。
func _load_deck_for(hero_key: String) -> void:
	_muster_entries.clear()
	var saved: Dictionary = DeckStorage.load_deck(hero_key)
	if not saved.is_empty():
		var name_to_card: Dictionary = {}
		for card in DataLoader.load_cards(REVIEW_CARD_JSON):
			name_to_card[card.name] = card
		for cname in saved.keys():
			var card = name_to_card.get(String(cname), null)
			if card == null:
				push_warning("PreparePanel: saved card not found in card.json: " + String(cname))
				continue
			_muster_entries[String(cname)] = {"card": card, "count": int(saved[cname])}
	# 加载后默认按 NO_SORT 显示（即按存档插入序）。
	_set_sort_mode(SortMode.NO_SORT)
	_refresh_muster_list()


# 把当前 _muster_entries 序列化成 name→count 写盘到 _current_hero_key 名下。
# _current_hero_key 为空 → 跳过（界面初始化未完成时）。
func _save_current_deck() -> void:
	if _current_hero_key == "":
		return
	var out: Dictionary = {}
	for key in _muster_entries.keys():
		out[key] = int(_muster_entries[key].count)
	DeckStorage.save_deck(_current_hero_key, out)


# 重写父类淡出回调，淡出动画开始前先保存（避免 tree_exiting 路径下
# Game.deck 已 free 等极端情况导致写入异常）。
func detach_with_fade(duration: float) -> void:
	_save_current_deck()
	super.detach_with_fade(duration)


# 复用游玩界面的长按详情面板（DetailPanelController）。
# 弹出/收回动画、Card 渲染均一致，确保两处视觉统一。
func _install_detail_panel() -> void:
	_detail_panel = DetailPanelController.new()
	_detail_panel.name = "DetailPanel"
	add_child(_detail_panel)
	_detail_panel.setup(self, HAND_CARD_SCENE)
	# 让 detail clip 在备战面板内置顶，盖住 HeroPnl/ReviewPnl 等。
	_detail_panel.get_clip().move_to_front()
	# 让详情面板锁定到 HeroPnl 的实时矩形，任意分辨率下都能完全覆盖英雄卡片。
	# 直接用固定 PANEL_WIDTH 在 expand 拉伸模式下不同屏宽比例时会偏小或偏大。
	_detail_panel.attach_to_rect(hero_pnl)


# 在 ReviewPnl 内构建带过度滑动弹性的卡面网格。
# 节点结构：
#   ReviewPnl
#   └ Viewport (Control, clip_contents, MOUSE_STOP)
#     └ Content (MarginContainer, position.y 受 _apply_offset 控制)
#       └ Grid (GridContainer, REVIEW_COLUMNS 列)
func _populate_review() -> void:
	# 清掉已有子节点，重入安全。
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

	# 内容根用 MarginContainer：自身按 minimum_size 提供高度，便于 content_height 测量。
	# 通过 position.y 平移实现滚动（裁剪由 viewport 处理）。
	var margin := MarginContainer.new()
	margin.name = "Content"
	margin.mouse_filter = Control.MOUSE_FILTER_PASS
	# 不挂 anchor：手动管 position/size。
	viewport.add_child(margin)
	_review_margin = margin
	_review_content = margin

	var grid := GridContainer.new()
	grid.name = "Grid"
	grid.columns = REVIEW_COLUMNS
	grid.add_theme_constant_override("v_separation", REVIEW_V_SEPARATION)
	margin.add_child(grid)
	_review_grid = grid

	# 数据：从 REVIEW_CARD_JSON 读取（备战界面专属，含占位卡）。
	# 每种卡仅展示一张卡面（count 字段由 Muster/牌库逻辑解释）。
	var cards: Array = DataLoader.load_cards(REVIEW_CARD_JSON)
	cards.sort_custom(_card_sort_key)

	_hand_cards.clear()
	for card in cards:
		var hc := HAND_CARD_SCENE.instantiate()
		grid.add_child(hc)
		hc.setup(card, 0)
		# 仅展示用：禁用拖拽/悬停/光标变化等交互。鼠标由 viewport 统一接管，
		# 长按检测在 _on_viewport_input 内通过命中测试转发到 _detail_panel。
		hc.mouse_filter = Control.MOUSE_FILTER_IGNORE
		hc.set_process(false)
		# CostBg / AtkBg / Hp Label 默认 MOUSE_FILTER_PASS，关掉它们更彻底
		for desc in hc.find_children("*", "Control", true, false):
			desc.mouse_filter = Control.MOUSE_FILTER_IGNORE
		_hand_cards.append(hc)

	# 监听 ReviewPnl 尺寸变化以重算左右 margin / h_separation / 内容宽度。
	review_pnl.resized.connect(_relayout_review_grid)
	# 首帧 review_pnl.size 可能为 0，等一帧再算。
	await get_tree().process_frame
	_relayout_review_grid()


# 动态算水平 separation 与左右 margin，使其三处间隙（卡 ↔ 卡 / 卡 ↔ 左 / 卡 ↔ 右）相等。
# 同时更新 Content 节点宽度与初始 position，并 clamp 当前偏移。
func _relayout_review_grid() -> void:
	if _review_grid == null or _review_margin == null or _review_viewport == null:
		return
	var panel_w: float = review_pnl.size.x
	if panel_w <= 0.0:
		return
	var total_card_w: float = float(REVIEW_COLUMNS * REVIEW_CARD_WIDTH)
	var gap: int = int(max(0.0, (panel_w - total_card_w) / float(REVIEW_COLUMNS + 1)))
	_review_grid.add_theme_constant_override("h_separation", gap)
	# 竖直方向 margin 用 visual gap + overflow，与水平不一定相等（用户只要求三处水平间隙相同）。
	var v_pad: int = REVIEW_VISUAL_GAP + REVIEW_CARD_OVERFLOW
	_review_margin.add_theme_constant_override("margin_left", gap)
	_review_margin.add_theme_constant_override("margin_right", gap)
	_review_margin.add_theme_constant_override("margin_top", v_pad)
	_review_margin.add_theme_constant_override("margin_bottom", v_pad)

	# 内容宽 = viewport 宽；高由 Container minimum_size 决定。
	_review_content.size.x = _review_viewport.size.x
	# 强制 Container 重排一次，拿到正确的 combined_minimum_size。
	_review_margin.queue_sort()
	await get_tree().process_frame
	var min_h: float = _review_margin.get_combined_minimum_size().y
	_review_content.size = Vector2(_review_viewport.size.x, min_h)

	# clamp 当前 logical_offset 到合法范围（避免布局变化后停在非法位置）。
	_logical_offset = clamp(_logical_offset, 0.0, _max_scroll())
	_apply_offset()


# 内容最大可滚动距离（>= 0）。内容比可视区短时返回 0（不可滚）。
func _max_scroll() -> float:
	if _review_viewport == null or _review_content == null:
		return 0.0
	return max(0.0, _review_content.size.y - _review_viewport.size.y)


# 把 _logical_offset（允许越界）换算为可视位移，并写到 content.position.y。
# 越界部分走 rubber band 衰减；正常范围内 1:1。
func _apply_offset() -> void:
	if _review_content == null:
		return
	var display: float = _to_display(_logical_offset)
	_review_content.position = Vector2(0, -display)


# rubber band 公式：f(x) = (x * c * d) / (d + c * x)
# 其中 x = 越界量，d = 可视区高度，c = OVERSCROLL_RESISTANCE。
# x 接近 0 时近似 c*x；x → ∞ 时趋近 d，永不超过可视高（视觉自然有限）。
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
				# 按下点若命中某张卡 → 启动长按计时 + 卡片放大动画。
				# 后续按手势分流：竖直阈值先到 → 滚动；位移阈值先到 → 拖拽。
				var hit := _card_at_position(mb.global_position)
				if hit != null:
					_press_card(hit)
					if _detail_panel != null:
						_detail_panel.start_long_press(hit.card_data)
			# 释放分支由 _input 统一处理（全局松开，无论拖到哪都要 settle）。
			return
	# 按住时的水平/竖直移动手势判定（仅当未进入任何模式时检查阈值）。
	if event is InputEventMouseMotion and _pressing:
		var mm := event as InputEventMouseMotion
		var delta: Vector2 = mm.global_position - _press_pos
		if _gesture == GestureMode.NONE:
			# 先达竖直阈值 → 滚动；先达水平阈值 → 拖拽（仅当按下时命中卡）。
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


# 进入滚动模式：取消长按详情 + 还原卡片缩放（永久退出按下卡状态）。
func _enter_scroll_mode() -> void:
	_gesture = GestureMode.SCROLL
	_release_pressed_card()
	if _detail_panel != null:
		_detail_panel.cancel_long_press()


# 进入拖拽模式：创建跟随鼠标的 preview，但保留详情显示与卡片缩放
# （按需求：拖拽时详情不撤，松开后才退）。
func _enter_drag_mode() -> void:
	_gesture = GestureMode.DRAG
	if _pressed_card == null:
		return
	_drag_card_data = _pressed_card.card_data
	_drag_preview = _make_drag_preview(_drag_card_data)
	add_child(_drag_preview)
	_drag_preview.z_index = 300  # 高于 detail panel clip (200)
	_update_drag_preview(get_global_mouse_position())


# 同步 preview 到鼠标位置（preview 中心对齐鼠标）。
func _update_drag_preview(global_pos: Vector2) -> void:
	if _drag_preview == null:
		return
	_drag_preview.global_position = global_pos - _drag_preview.size / 2.0


# 销毁拖拽 preview；判定是否落入 MusterPnl 并入库。
func _finish_drag(global_pos: Vector2) -> void:
	if _drag_preview != null:
		_drag_preview.queue_free()
		_drag_preview = null
	if muster_pnl != null and muster_pnl.get_global_rect().has_point(global_pos):
		if _drag_card_data != null:
			_add_to_muster(_drag_card_data)
	_drag_card_data = null


# 复刻 HandCard._get_drag_data 的 preview 样式：白底蓝边 + 卡名。
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


# 按下卡时播放放大动画；提升 z_index 避免被相邻卡片遮挡。
# 不能用 move_to_front()：GridContainer 按 child index 排位，会让该卡跳到末尾重排。
func _press_card(card: Node) -> void:
	_release_pressed_card()  # 兜底：清理可能未还原的上一张
	_pressed_card = card
	card.z_index = 1
	if card.get_tree():
		var tw := card.create_tween()
		tw.tween_property(card, "scale", PRESS_SCALE, PRESS_TWEEN_TIME)


# 还原当前按下卡的缩放与 z_index。
func _release_pressed_card() -> void:
	if _pressed_card != null and is_instance_valid(_pressed_card):
		_pressed_card.z_index = 0
		if _pressed_card.get_tree():
			var tw := _pressed_card.create_tween()
			tw.tween_property(_pressed_card, "scale", Vector2.ONE, PRESS_TWEEN_TIME)
	_pressed_card = null


# 全局监听鼠标事件以统一收尾：
#   - 左键松开：判定当前手势模式，触发对应清理（拖拽落入 muster / 滚动回弹 / 详情面板回退）。
#   - 鼠标移动（拖拽模式下）：preview 跟随鼠标，即使鼠标移出 viewport 也持续更新。
func _input(event: InputEvent) -> void:
	if event is InputEventMouseMotion and _pressing and _gesture == GestureMode.DRAG:
		var mm := event as InputEventMouseMotion
		_update_drag_preview(mm.global_position)
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		var release_pos: Vector2 = (event as InputEventMouseButton).global_position
		# 1. 拖拽收尾：落入 MusterPnl 则加卡，否则丢弃 preview。
		if _pressing and _gesture == GestureMode.DRAG:
			_finish_drag(release_pos)
		# 2. 滚动收尾：越界则回弹。
		if _pressing and _gesture == GestureMode.SCROLL:
			_settle_to_clamped()
		# 3. 统一清状态：还原卡片缩放、取消长按计时、关详情面板。
		if _pressing:
			_pressing = false
			_gesture = GestureMode.NONE
			_release_pressed_card()
		if _detail_panel != null:
			_detail_panel.cancel_long_press()
			_detail_panel.hide_panel()
		# 4. Muster 列表项松开 → 清按下标记（详情已被上方 hide_panel 关闭）。
		_muster_press_card = null


# 命中测试：在 _hand_cards 中找包含 global 点的第一张卡，返回 HandCard 实例。
# 命中失败返回 null。卡片在 viewport 裁剪范围外也会被排除（按 viewport 全局矩形）。
func _card_at_position(global_pos: Vector2) -> Node:
	if _review_viewport != null and not _review_viewport.get_global_rect().has_point(global_pos):
		return null
	for hc in _hand_cards:
		if is_instance_valid(hc) and hc.get_global_rect().has_point(global_pos):
			return hc
	return null


# 滚轮 / 程序触发的步进滚动（不引入越界）。
func _scroll_by(dy: float) -> void:
	_logical_offset = clamp(_logical_offset + dy, 0.0, _max_scroll())
	_apply_offset()


# 若 logical 越界 → tween 回到 clamp 范围内的最近合法值。
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


# 排序键：cost 升序优先，cost 相同按名字 Unicode 字典序升序。
# CardBase 子类持有 .cost 与 .name 字段。
static func _card_sort_key(a, b) -> bool:
	if a.cost != b.cost:
		return a.cost < b.cost
	return a.name < b.name


# ============================================================================
# Muster（点兵）面板：拖入的卡按种类汇总成"卡名 x N"列表。
# 结构：MusterPnl → Title(Label) → Scroll → VBox(列表项 Button)
# 风格与游玩界面 SidePanelManager 牌堆列表一致。
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
	# 隐藏滚动条以与 ReviewPnl 风格统一。
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


# 把一张卡加入 muster：
#   - 同名卡：count+1，位置不变，**保持当前排序模式**（重复加不影响视图顺序）
#   - 新种类：append 到末尾，并把排序模式切回 NO_SORT
#     （新卡落在已排序列表末尾会破坏严格排序，故用 NO_SORT 文字告知玩家
#     "当前不是严格排序"）
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


# 渲染列表：直接按 _muster_entries 当前 key 顺序输出。
# 顺序由谁维护：
#   - _add_to_muster：append 在尾（dict 自动）
#   - _set_sort_mode：切换排序模式时重排 dict 内部顺序
#   - _remove_one_from_muster：erase 不影响其他顺序
func _refresh_muster_list() -> void:
	if _muster_list == null:
		return
	for c in _muster_list.get_children():
		c.queue_free()
	for key in _muster_entries.keys():
		var entry = _muster_entries[key]
		_muster_list.add_child(_make_muster_item(entry.card, int(entry.count)))


# 列表项：复用游玩界面牌堆样式（ThemeFactory.list_item_styles），按下/松开转发长按。
# 直接把 CardBase 对象存 meta，避免 DetailPanelController 走 dict 路径找不到数据。
# 双击 → 从 muster 中移除一张（count-1，归零时删除项）。
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


# 监听双击事件以移除一张。InputEventMouseButton.double_click 由 Godot 在
# 按系统双击间隔内的第二次按下时设为 true（同一事件也带 pressed=true）。
func _on_muster_item_gui_input(event: InputEvent, btn: Button) -> void:
	if event is InputEventMouseButton:
		var mb := event as InputEventMouseButton
		if mb.button_index == MOUSE_BUTTON_LEFT and mb.double_click:
			var card = btn.get_meta("card_data", null)
			if card != null:
				_remove_one_from_muster(String(card.name))
				# 双击消耗：取消可能在第二次按下时被启动的长按计时。
				if _detail_panel != null:
					_detail_panel.cancel_long_press()
					_detail_panel.hide_panel()
				_muster_press_card = null
				btn.accept_event()


# 移除一张同名卡：count-1；归零时删除条目；最后重建列表。
func _remove_one_from_muster(card_name: String) -> void:
	if not _muster_entries.has(card_name):
		return
	_muster_entries[card_name].count -= 1
	if _muster_entries[card_name].count <= 0:
		_muster_entries.erase(card_name)
	_refresh_muster_list()


func _on_muster_item_press(btn: Button) -> void:
	if _detail_panel == null:
		return
	var card = btn.get_meta("card_data", null)
	if card == null:
		return
	_muster_press_card = card
	_detail_panel.start_long_press(card)


func _on_muster_item_release() -> void:
	# 仅取消计时；面板隐藏由全局 _input 在左键松开时统一处理。
	if _detail_panel != null:
		_detail_panel.cancel_long_press()
	_muster_press_card = null


# ============================================================================
# 排序面板（原 FilterPnl）：单个 Button 占满，点击循环切换排序模式。
# 切换后立刻刷新 muster 列表；加卡时会自动复位到 NO_SORT。
# ============================================================================

func _build_sort_panel() -> void:
	for child in filter_pnl.get_children():
		child.queue_free()
	var btn := Button.new()
	btn.text = SORT_LABELS[_sort_mode]
	# 按钮直接铺满 FilterPnl（FilterPnl 在 .tscn 中已设为与 BackBtn 同高 80px）。
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
	# 点击规则：
	#   - 当前 NO_SORT（只能由加卡触发）→ 切到 COST_ASC（cycle 起点）
	#   - 已在 cycle 内 → 在 [COST_ASC, COST_DESC] 间循环
	# 玩家无法主动回到 NO_SORT，只有加新卡才会复位。
	var next_mode: int
	var idx: int = SORT_CYCLE.find(_sort_mode)
	if idx < 0:
		next_mode = SORT_CYCLE[0]
	else:
		next_mode = SORT_CYCLE[(idx + 1) % SORT_CYCLE.size()]
	_set_sort_mode(next_mode)
	_refresh_muster_list()


# 集中改 _sort_mode + 同步按钮文字。切到 COST_ASC/DESC 时把 _muster_entries
# 重排成对应顺序（重建 dict）；NO_SORT 不重排（保持当前内部顺序）。
# 后续加卡总在 dict 末尾追加，自然落在视图最后。
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
	# 重建 dict（Godot 4 字典保留插入序）。
	var new_dict: Dictionary = {}
	for k in keys:
		new_dict[k] = _muster_entries[k]
	_muster_entries = new_dict

