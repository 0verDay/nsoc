extends Control

# 威震华夏章节场景。
# 入场动效：描述面板从左滑入、检阅面板从右滑入、底部进度条从下方滑入；
# 与 CampaignPanel 长按业务的渐隐过渡衔接。
#
# 数据驱动：
#   章节标题 / 描述 / 卡牌列表来自 res://data/chapters/weizhenhuaxia.json，
#   通过 campaigns.json c1.威震华夏.config 字段引用。
#   卡牌 cost / 详情属性反查 res://data/all_cards.json（DataLoader.load_cards）。
#
# 检阅列表交互：
#   长按 → 弹出详情面板（复用 DetailPanelController，与点兵列表同款）。
#   松开 / 拖动 → 收回详情。

const SLIDE_IN_DURATION: float = 0.5
const CHAPTER_NAME: String = "威震华夏"
const CONFIG_PATH: String = "res://data/chapters/weizhenhuaxia.json"
const HAND_CARD_SCENE: PackedScene = preload("res://scenes/HandCard.tscn")
# 加载完成后切到的下级场景（战斗主场景）。
const NEXT_SCENE_PATH: String = "res://scenes/Main.tscn"

# 进度条加载完成 → 滑出 → 文本浮现 的两段动效时长。
const BAR_SLIDE_OUT_DURATION: float = 0.4
const START_TEXT_FADE_IN_DURATION: float = 0.3
# 点击"开始"区域 → 渐隐过渡 → change_scene 时长。
const START_TRANSITION_DURATION: float = 0.5
const START_TEXT: String = "————点击此处开始————"
const START_TEXT_FONT_SIZE: int = 22
# 呼吸动效：alpha 在 [BREATH_LOW, 1.0] 之间往返，单程 BREATH_HALF 秒。
const START_TEXT_BREATH_LOW: float = 0.4
const START_TEXT_BREATH_HALF: float = 0.9

# 描述面板内布局参数。
const DESC_PAD: float = 32.0
const DESC_TITLE_FONT_SIZE: int = 48
const DESC_TITLE_HEIGHT: float = 96.0
const DESC_BODY_FONT_SIZE: int = 22

# 检阅面板内布局参数（沿用 PreparePanel.MusterPnl 的视觉规格）。
const REVIEW_TITLE_FONT_SIZE: int = 28
const REVIEW_ITEM_FONT_SIZE: int = 22
const REVIEW_ITEM_SEPARATION: int = 10
const REVIEW_TITLE_HEIGHT: float = 60.0
const REVIEW_PADDING: int = 20

# 行宽 / 徽章 / 间距：保持与点兵列表一致。
const REVIEW_ROW_WIDTH: float = 390.0
const REVIEW_BADGE_SIZE: int = 30
const REVIEW_BADGE_FONT: int = 14
const REVIEW_ITEM_GAP: int = 10

@onready var desc_pnl: Panel = $DescPnl
@onready var review_pnl: Panel = $ReviewPnl
@onready var progress_bar: ProgressBar = $ProgressBar

# 长按详情面板（复用 PreparePanel/Main 同款）。
var _detail_panel: DetailPanelController
# 当前正在长按的卡，用于 mouse_exited 时取消计时。
var _press_card = null

# 资源加载状态：
#   _load_started   = 已发起 load_threaded_request
#   _load_finished  = 加载完成（packed 已就绪），进度条已满 → 触发滑出动画
#   _start_clickable = 文本已显示且接受点击 → 切场景
var _load_started: bool = false
var _load_finished: bool = false
var _start_clickable: bool = false
# 已加载好的下级场景 packed，点击开始时直接 change_scene_to_packed，秒切无延迟。
var _next_scene_packed: PackedScene
# "点击此处开始"文本 + 点击区域（覆盖原进度条范围，捕获点击）。
var _start_label: Label
var _start_hit: Control
# 文本呼吸 tween：循环往返 alpha 1↔BREATH_LOW；点击进入战斗时 kill。
var _start_breath_tween: Tween


func _ready() -> void:
	# 整个根 Control 先隐藏，等一帧让 anchor/offset 解析出真实 size 后，
	# 把三个组件移到屏外起点再显示，避免 anchor 解析帧期间露出原位。
	visible = false

	# 风格化先做，避免 stylebox 切换在动效中视觉跳变。
	desc_pnl.add_theme_stylebox_override(
		"panel",
		ThemeFactory.panel(Color.WHITE, Color(1, 1, 1, 0.6), 1, 20, true)
	)
	review_pnl.add_theme_stylebox_override(
		"panel",
		ThemeFactory.panel(Color(0.94, 0.95, 0.96, 1.0), Color(1, 1, 1, 1.0), 1, 20, false)
	)
	_apply_progress_bar_style()

	# 装填内容（不依赖 size，可在 process_frame 前完成）。
	var cfg := _load_config()
	_build_desc(cfg)
	_build_review(cfg)
	_install_detail_panel()

	await get_tree().process_frame
	_play_intro()
	visible = true

	# 入场动画启动后立刻发起下级场景的后台加载，让进度条与入场并行推进。
	_start_threaded_load()


# 启动 main.tscn 后台加载。_process 会轮询进度更新进度条。
func _start_threaded_load() -> void:
	if _load_started:
		return
	_load_started = true
	progress_bar.value = 0.0
	ResourceLoader.load_threaded_request(NEXT_SCENE_PATH)


func _process(_delta: float) -> void:
	if not _load_started or _load_finished:
		return
	var progress: Array = []
	var status := ResourceLoader.load_threaded_get_status(NEXT_SCENE_PATH, progress)
	if progress.size() > 0:
		progress_bar.value = clampf(float(progress[0]) * 100.0, 0.0, 100.0)
	match status:
		ResourceLoader.THREAD_LOAD_LOADED:
			_next_scene_packed = ResourceLoader.load_threaded_get(NEXT_SCENE_PATH) as PackedScene
			progress_bar.value = 100.0
			_load_finished = true
			_on_load_complete()
		ResourceLoader.THREAD_LOAD_FAILED, ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			push_error("Weizhenhuaxia: failed to load " + NEXT_SCENE_PATH)
			_load_finished = true


# 加载完毕：进度条向下滑出 → 同位置浮现"点击开始"文本 + 透明命中区。
func _on_load_complete() -> void:
	var vh: float = size.y

	# 提前建好"开始"文本 + 命中区（alpha 0），位置完全覆盖原进度条范围，
	# 进度条滑出动画结束后再 tween 渐显。直接复用 ProgressBar 的 anchor + offset
	# 配置（底部锚定 + 固定上下 offset），不读 progress_bar.position（值依赖
	# 父容器实时 size，第二次进入场景时若 size 未就绪会得到错位坐标）。
	_build_start_zone()

	var tw := create_tween()
	tw.tween_property(progress_bar, "position:y", vh, BAR_SLIDE_OUT_DURATION).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	await tw.finished
	progress_bar.visible = false

	# 文本 + 命中区渐显。命中区 mouse_filter=STOP 接点击；alpha 0 → 1。
	_start_hit.mouse_filter = Control.MOUSE_FILTER_STOP
	var tw2 := create_tween()
	tw2.tween_property(_start_label, "modulate:a", 1.0, START_TEXT_FADE_IN_DURATION).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	await tw2.finished
	_start_clickable = true
	_start_breath_loop()


# 文本呼吸：alpha 在 [BREATH_LOW, 1.0] 之间往返循环。
# 用 set_loops() 永续，直到 _enter_battle 内 kill。
func _start_breath_loop() -> void:
	if _start_label == null:
		return
	if _start_breath_tween and _start_breath_tween.is_valid():
		_start_breath_tween.kill()
	var tw := create_tween()
	tw.set_loops()
	tw.tween_property(_start_label, "modulate:a", START_TEXT_BREATH_LOW, START_TEXT_BREATH_HALF).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	tw.tween_property(_start_label, "modulate:a", 1.0, START_TEXT_BREATH_HALF).set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_start_breath_tween = tw


# 在原进度条位置建一个透明命中 Control（捕获点击）+ 内嵌 Label（显示文本）。
# 用 anchor + offset 与 ProgressBar 完全一致（PRESET 不可用，手动设值同 .tscn）：
#   底部锚定 + offset_top=-60 + offset_bottom=-24 + offset_left=24 + offset_right=-24
# 这样多次进出场景都能稳定在原进度条位置，避免依赖 control.position 实时值。
const _START_OFFSET_LEFT: float = 24.0
const _START_OFFSET_RIGHT: float = -24.0
const _START_OFFSET_TOP: float = -60.0
const _START_OFFSET_BOTTOM: float = -24.0


func _build_start_zone() -> void:
	var hit := Control.new()
	hit.name = "StartHit"
	hit.set_anchors_preset(Control.PRESET_BOTTOM_WIDE, false)
	hit.offset_left = _START_OFFSET_LEFT
	hit.offset_right = _START_OFFSET_RIGHT
	hit.offset_top = _START_OFFSET_TOP
	hit.offset_bottom = _START_OFFSET_BOTTOM
	hit.mouse_filter = Control.MOUSE_FILTER_IGNORE   # 渐显完前不响应
	hit.gui_input.connect(_on_start_hit_input)
	add_child(hit)
	_start_hit = hit

	var lbl := Label.new()
	lbl.name = "StartLabel"
	lbl.text = START_TEXT
	lbl.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	lbl.add_theme_font_size_override("font_size", START_TEXT_FONT_SIZE)
	lbl.add_theme_color_override("font_color", Color(0.45, 0.45, 0.45))
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.modulate.a = 0.0
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hit.add_child(lbl)
	_start_label = lbl


# 命中区点击 → 切场景。仅在 _start_clickable=true 时响应。
# 流程：设置 Game.pending_chapter_config → 整屏渐隐 → change_scene_to_packed。
func _on_start_hit_input(event: InputEvent) -> void:
	if not _start_clickable:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		_start_clickable = false
		_enter_battle()


func _enter_battle() -> void:
	# 关键时序：先赋值，再切场景。Game.bootstrap 在新场景 _ready 内调用，
	# 届时 pending_chapter_config 必须已就绪。
	Game.pending_chapter_config = CONFIG_PATH

	# 屏蔽后续输入 + 停止文本呼吸（避免与整屏渐隐 tween 在 modulate 上冲突）。
	if _start_hit:
		_start_hit.mouse_filter = Control.MOUSE_FILTER_IGNORE
	if _start_breath_tween and _start_breath_tween.is_valid():
		_start_breath_tween.kill()
		_start_breath_tween = null

	var tw := create_tween()
	tw.tween_property(self, "modulate:a", 0.0, START_TRANSITION_DURATION).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	await tw.finished
	if _next_scene_packed != null:
		get_tree().change_scene_to_packed(_next_scene_packed)
	else:
		# 兜底：未拿到 packed → 走文件路径，与 SplashScreen 同款回退。
		get_tree().change_scene_to_file(NEXT_SCENE_PATH)


# 复用游玩界面的长按详情面板（DetailPanelController），与游玩界面同款视觉与
# 弹出方式：默认 LEFT_WIDE 锚点 + 464px 宽，从场景左侧滑出（不再覆盖检阅区）。
func _install_detail_panel() -> void:
	_detail_panel = DetailPanelController.new()
	_detail_panel.name = "DetailPanel"
	add_child(_detail_panel)
	_detail_panel.setup(self, HAND_CARD_SCENE)
	_detail_panel.get_clip().move_to_front()


# 读 weizhenhuaxia.json：返回 {description, cards: [{name, count}]}。
# 文件缺失/损坏 → 返回空骨架，UI 仍能空载渲染。
func _load_config() -> Dictionary:
	var empty := {"description": "", "cards": []}
	if not ResourceLoader.exists(CONFIG_PATH):
		push_warning("Weizhenhuaxia: config missing → " + CONFIG_PATH)
		return empty
	var f := FileAccess.open(CONFIG_PATH, FileAccess.READ)
	if f == null:
		return empty
	var text := f.get_as_text()
	f.close()
	var parsed = JSON.parse_string(text)
	if typeof(parsed) != TYPE_DICTIONARY:
		return empty
	if not parsed.has("cards") or typeof(parsed["cards"]) != TYPE_ARRAY:
		parsed["cards"] = []
	return parsed


# 描述面板：顶部章节标题 + 下方描述文本。
func _build_desc(cfg: Dictionary) -> void:
	for c in desc_pnl.get_children():
		c.queue_free()

	var title := Label.new()
	title.text = CHAPTER_NAME
	title.set_anchors_preset(Control.PRESET_TOP_WIDE, false)
	title.offset_left = DESC_PAD
	title.offset_right = -DESC_PAD
	title.offset_top = DESC_PAD
	title.offset_bottom = DESC_PAD + DESC_TITLE_HEIGHT
	title.add_theme_font_size_override("font_size", DESC_TITLE_FONT_SIZE)
	title.add_theme_color_override("font_color", Color(0.1, 0.1, 0.1))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	desc_pnl.add_child(title)

	var body := RichTextLabel.new()
	body.text = MarkupParser.parse(String(cfg.get("description", "")))
	body.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	body.offset_left = DESC_PAD
	body.offset_right = -DESC_PAD
	body.offset_top = DESC_PAD * 2.0 + DESC_TITLE_HEIGHT
	body.offset_bottom = -DESC_PAD
	body.add_theme_font_size_override("normal_font_size", DESC_BODY_FONT_SIZE)
	body.add_theme_color_override("default_color", Color(0.25, 0.25, 0.25))
	body.bbcode_enabled = true
	body.autowrap_mode = TextServer.AUTOWRAP_WORD_SMART
	body.scroll_active = false
	body.fit_content = false
	body.mouse_filter = Control.MOUSE_FILTER_IGNORE
	desc_pnl.add_child(body)


# 检阅面板：复刻 PreparePanel.MusterPnl 的标题 + 滚动列表结构。
# 卡牌按 cost 降序排列（cost 取自 all_cards.json）。
func _build_review(cfg: Dictionary) -> void:
	for c in review_pnl.get_children():
		c.queue_free()

	var title := Label.new()
	title.text = "检阅"
	title.add_theme_font_size_override("font_size", REVIEW_TITLE_FONT_SIZE)
	title.add_theme_color_override("font_color", Color(0.2, 0.2, 0.2, 1))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.set_anchors_preset(Control.PRESET_TOP_WIDE, false)
	title.offset_top = 20
	title.offset_bottom = 20 + REVIEW_TITLE_HEIGHT
	review_pnl.add_child(title)

	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	scroll.offset_top = 20 + REVIEW_TITLE_HEIGHT + 10
	scroll.offset_bottom = -REVIEW_PADDING
	scroll.offset_left = REVIEW_PADDING
	scroll.offset_right = -REVIEW_PADDING
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	review_pnl.add_child(scroll)
	# 隐藏滚动条以与点兵面板风格统一。
	var vbar := scroll.get_v_scroll_bar()
	if vbar:
		vbar.custom_minimum_size = Vector2.ZERO
		vbar.modulate = Color(1, 1, 1, 0)
		vbar.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", REVIEW_ITEM_SEPARATION)
	scroll.add_child(vbox)

	# 卡反查 + 排序（cost 降，同 cost 按名字升）。entry.card 存 CardBase 对象，
	# 给后续长按详情用；不在 all_cards 里的卡跳过 + push_warning。
	var card_db := _load_card_db()
	var entries: Array = []
	for raw in cfg.get("cards", []):
		if typeof(raw) != TYPE_DICTIONARY:
			continue
		var cname := String(raw.get("name", ""))
		if cname == "":
			continue
		var card = card_db.get(cname, null)
		if card == null:
			push_warning("Weizhenhuaxia: card not in all_cards.json → " + cname)
			continue
		entries.append({
			"name": cname,
			"count": int(raw.get("count", 1)),
			"cost": int(card.cost),
			"card": card,
		})
	entries.sort_custom(func(a, b):
		if a.cost != b.cost:
			return a.cost > b.cost
		return a.name < b.name)

	for e in entries:
		vbox.add_child(_make_review_row(e))


# all_cards.json → name → CardBase。复用 DataLoader.load_cards，确保子类化
# （CardUnit / CardSpell）与详情面板渲染兼容。
func _load_card_db() -> Dictionary:
	var out: Dictionary = {}
	for c in DataLoader.load_cards(DataLoader.ALL_CARDS_JSON):
		out[String(c.name)] = c
	return out


# 一行 = HBox(费用徽章 + Button)。
# 视觉与 PreparePanel 点兵列表项同款：Button + list_item_styles 三态 stylebox。
# 长按 → DetailPanelController 弹出详情；松开/移出 → 取消计时 + 隐藏面板。
func _make_review_row(entry: Dictionary) -> HBoxContainer:
	var row := HBoxContainer.new()
	row.size_flags_horizontal = Control.SIZE_SHRINK_CENTER
	row.add_theme_constant_override("separation", REVIEW_ITEM_GAP)

	var badge := ThemeFactory.cost_badge(int(entry.cost), REVIEW_BADGE_SIZE, REVIEW_BADGE_FONT)
	badge.size_flags_vertical = Control.SIZE_SHRINK_CENTER
	row.add_child(badge)

	var b := Button.new()
	var cname := String(entry.name)
	var cnt: int = int(entry.count)
	b.text = cname if cnt == 1 else cname + " x " + str(cnt)
	b.set_meta("card_data", entry.card)
	b.add_theme_font_size_override("font_size", REVIEW_ITEM_FONT_SIZE)
	b.add_theme_color_override("font_color", Color(0.2, 0.2, 0.2, 1))
	b.add_theme_color_override("font_hover_color", Color(0.1, 0.1, 0.1, 1))
	b.add_theme_color_override("font_pressed_color", Color(0.0, 0.0, 0.0, 1))
	b.mouse_filter = Control.MOUSE_FILTER_PASS
	var styles := ThemeFactory.list_item_styles()
	b.add_theme_stylebox_override("normal", styles.normal)
	b.add_theme_stylebox_override("hover", styles.hover)
	b.add_theme_stylebox_override("pressed", styles.pressed)
	b.add_theme_stylebox_override("focus", styles.focus)
	b.custom_minimum_size = Vector2(REVIEW_ROW_WIDTH - REVIEW_BADGE_SIZE - REVIEW_ITEM_GAP, 0)
	b.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	# 长按触发 → 详情面板弹出；松开/鼠标移出 → 取消计时（详情已显示则保留；
	# 详情显示后由全局 _input 统一处理收回，此处仅取消未到时的长按计时）。
	b.button_down.connect(_on_review_item_press.bind(b))
	b.button_up.connect(_on_review_item_release)
	b.mouse_exited.connect(_on_review_item_release)
	row.add_child(b)
	return row


# 长按按下：取 meta 中的 CardBase，调 detail_panel 启动长按计时器。
func _on_review_item_press(btn: Button) -> void:
	if _detail_panel == null:
		return
	var card = btn.get_meta("card_data", null)
	if card == null:
		return
	_press_card = card
	_detail_panel.start_long_press(card)


# 松开/移出：仅取消计时；面板隐藏交给全局 _input 统一处理（与 PreparePanel 同步）。
func _on_review_item_release() -> void:
	if _detail_panel != null:
		_detail_panel.cancel_long_press()
	_press_card = null


# 全局松开兜底：玩家在按钮外松开（鼠标已移出）也能收回详情面板。
# PreparePanel 同款逻辑；这里只做面板隐藏，不再处理事件路由。
func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		if _detail_panel != null:
			_detail_panel.cancel_long_press()
			_detail_panel.hide_panel()
		_press_card = null


# 入场动效：三组件从屏外滑入到原位。
func _play_intro() -> void:
	var vw: float = size.x
	var vh: float = size.y

	var desc_target: Vector2 = desc_pnl.position
	var review_target: Vector2 = review_pnl.position
	var bar_target: Vector2 = progress_bar.position

	desc_pnl.position = Vector2(-desc_pnl.size.x, desc_target.y)
	review_pnl.position = Vector2(vw, review_target.y)
	progress_bar.position = Vector2(bar_target.x, vh)

	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(desc_pnl, "position", desc_target, SLIDE_IN_DURATION).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(review_pnl, "position", review_target, SLIDE_IN_DURATION).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(progress_bar, "position", bar_target, SLIDE_IN_DURATION).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


# 进度条样式：背景灰底 + 圆角；填充主蓝。
func _apply_progress_bar_style() -> void:
	var bg := StyleBoxFlat.new()
	bg.bg_color = Color(0.94, 0.95, 0.96, 1.0)
	bg.border_color = Color(1, 1, 1, 1.0)
	bg.border_width_left = 1
	bg.border_width_right = 1
	bg.border_width_top = 1
	bg.border_width_bottom = 1
	bg.corner_radius_top_left = 12
	bg.corner_radius_top_right = 12
	bg.corner_radius_bottom_left = 12
	bg.corner_radius_bottom_right = 12

	var fill := StyleBoxFlat.new()
	fill.bg_color = Color("#339af0")
	fill.corner_radius_top_left = 12
	fill.corner_radius_top_right = 12
	fill.corner_radius_bottom_left = 12
	fill.corner_radius_bottom_right = 12

	progress_bar.add_theme_stylebox_override("background", bg)
	progress_bar.add_theme_stylebox_override("fill", fill)
