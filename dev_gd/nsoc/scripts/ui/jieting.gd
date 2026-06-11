extends Control

# 街亭遗恨章节场景。
# 与 changbanpo / weizhenhuaxia 的差异（见 user 需求）：
#   1. 右侧检阅面板拆为上下两块：上"马谡" / 下"王平"，均为"填线宝宝 x10"占位
#   2. 玩家点击其中一块 → 蓝色描边选中态（互斥单选，不可取消）
#   3. 加载条读完后立即向下滑出（与其它章节一致）；
#      未选中时呼吸文本显示"选择英雄进入战役"提示玩家点选；
#      选中后实时切换为"————作为{X}进入战役————"
#   4. 已选中英雄后点击呼吸文本 → 渐隐 → 切到 Main.tscn，并通过
#      Game.pending_chapter_config 注入 chapters/jieting_<选中英雄>.json
#      （章节 config 文件由后续数据迭代提供；缺失时 DataLoader 走空 level
#      回退默认英雄，不致崩溃）
#
# 描述文本直接嵌在脚本里，不依赖外部 chapters/jieting.json，
# 数据迭代后再迁移到独立 chapter config。

const SLIDE_IN_DURATION: float = 0.5
const CHAPTER_NAME: String = "街亭遗恨"
const HAND_CARD_SCENE: PackedScene = preload("res://scenes/HandCard.tscn")
# 仍后台预加载 Main.tscn 用于推进进度条（与其它章节一致），但加载完成后不真的切场景。
const NEXT_SCENE_PATH: String = "res://scenes/Main.tscn"

const BAR_SLIDE_OUT_DURATION: float = 0.4
const START_TEXT_FADE_IN_DURATION: float = 0.3
# 点击文本 → 整屏渐隐 → change_scene 时长（与 changbanpo 一致）。
const START_TRANSITION_DURATION: float = 0.5
const START_TEXT_FONT_SIZE: int = 22
# 呼吸：alpha 在 [BREATH_LOW, 1.0] 之间往返。
const START_TEXT_BREATH_LOW: float = 0.4
const START_TEXT_BREATH_HALF: float = 0.9

# 描述面板内布局参数（与 changbanpo 一致）。
const DESC_PAD: float = 32.0
const DESC_TITLE_FONT_SIZE: int = 48
const DESC_TITLE_HEIGHT: float = 96.0
const DESC_BODY_FONT_SIZE: int = 22

# 检阅面板内布局参数（沿用 changbanpo 的视觉规格）。
const REVIEW_TITLE_FONT_SIZE: int = 28
const REVIEW_ITEM_FONT_SIZE: int = 22
const REVIEW_ITEM_SEPARATION: int = 10
const REVIEW_TITLE_HEIGHT: float = 60.0
const REVIEW_PADDING: int = 20
const REVIEW_ROW_WIDTH: float = 390.0
const REVIEW_BADGE_SIZE: int = 30
const REVIEW_BADGE_FONT: int = 14
const REVIEW_ITEM_GAP: int = 10

# 选中态视觉。未选 = 默认 review 风格（border=#FFFFFF, w=1）；选中 = 清冷蓝 + 加粗。
const SELECT_BG_COLOR:        Color = Color(0.94, 0.95, 0.96, 1.0)
const SELECT_NORMAL_BORDER:   Color = Color(1, 1, 1, 1.0)
const SELECT_NORMAL_W:        int   = 1
const SELECT_ACTIVE_BORDER:   Color = Color("#4a90e2")
const SELECT_ACTIVE_W:        int   = 3
const SELECT_PNL_RADIUS:      int   = 20

# 街亭描述头部（两路英雄共用，拼接在各自正文前）。
const _DESC_HEADER: String = "英雄（可选）：{ally:街亭遗恨·马谡}  血量：20  技能：{key:围山}——无法受到直接伤害；己方单位每消灭一个，失去 1 点血量\n英雄（可选）：{ally:街亭遗恨·王平}  血量：20  技能：{key:协防}——起始费用与费用上限均为 5，不再随回合递增\n敌方英雄：{enemy:街亭遗恨·张郃}  血量：30  技能：{key:巧变}——己方单位死亡时，在其原位召唤「疑兵」\n关卡目标：{warn:坚守 15 回合}"

# 未选中时的正文提示。
const _DESC_BODY_DEFAULT: String = "{break}{para}请在右侧选择出战英雄——{ally:马谡}或{ally:王平}——以阅读其视角的战前故事。"

# 马谡视角正文。
const _DESC_BODY_MASU: String = "{break}{para}{ally:丞相}召我入帐，我心中热血奔涌——此番出{place:祁山}，三郡归附，北伐气势如虹，正是建功立业的天赐良机。我熟读兵法，上知天时，下通地利，区区一个{place:街亭}，不过是我此生事业的垫脚之石，有何难哉？{ally:丞相}叮嘱我\"{warn:当道下寨}\"，我当面应允，心中却已另有打算——凭高临下，以山势为援，背水则困，登山则无忧，此兵法精要，{ally:丞相}拘谨，未必深知。{para}然而，我错了。{enemy:张郃}铁骑至，不正面交锋，反而围山断水——这一招，我竟未曾料到。山上绝水，军心溃散，我在山顶眼睁睁看着这一切崩塌，却无能为力。{ally:子均}鸣鼓缓退，独木难支，蜀师溃散如潮。那一刻，我终于明白，{ally:丞相}的每一句叮嘱，都是以血换来的经验，而我，以自己的傲慢，葬送了他倾注心血的战局。{para}归师之日，{ally:丞相}泣而斩我。我跪于刀下，无话可说，唯有愧恨。我一生熟读圣贤之书，却在最要紧的时刻，被傲慢蒙了眼。若有来生，我只愿踏踏实实，{warn:不以书卷之见轻天下事}。{place:街亭}山上，风声呜咽，是我留给自己的祭文。"

# 王平视角正文。
const _DESC_BODY_WANGPING: String = "{break}{para}我随{ally:幼常}至{place:街亭}，一见地形，心便沉了下去。道旁有险可据，有水可守，可他执意要登山——我不通文墨，讲不出那许多兵书上的大道理，但我知道，{warn:断水}就是死路，山高则孤，一旦被围，再多人马也是瓮中之鳖。我苦苦劝谏，{ally:幼常}一笑置之，说我不懂兵法。或许，我真的不懂。{para}但战场会说话。{enemy:张郃}一到，立刻看出破绽，铁骑合围，断我军汲道。半日之内，全军焦渴，阵脚大乱。我在山下，鸣鼓收拢余卒，一步一步缓退，护着残部不被尽数歼灭。那些丢盔弃甲的同袍从我身边奔逃而过，我咬紧牙关，不敢回头看山顶那片火光。{para}{place:街亭}一失，北伐大局尽毁。我活着回来，却不知该喜还是悲——活着，意味着要亲历{ally:丞相}挥泪落刀的那一刻，要带着这份{warn:苦谏未果}的遗憾，继续走下去。{place:街亭}的风，吹得人心里发凉。我不恨{ally:幼常}，只是此后每逢阵前，那道山影便会浮现眼前，提醒我：{warn:战场无书，唯有实地}。"

# 选项标识 → 显示名（用于"作为{X}进入战役"）。
const HERO_NAMES: Dictionary = {"masu": "马谡", "wangping": "王平"}
# 未选中英雄时的呼吸文本（提示玩家先选）。
const PROMPT_TEXT: String = "————选择英雄进入战役————"
# 占位卡组：每个面板都是"填线宝宝 x10"。
const PLACEHOLDER_CARDS: Array = [{"name": "填线宝宝", "count": 10}]

@onready var desc_pnl: Panel = $DescPnl
@onready var top_review_pnl: Panel = $TopReviewPnl
@onready var bottom_review_pnl: Panel = $BottomReviewPnl
@onready var progress_bar: ProgressBar = $ProgressBar

# 长按详情面板（与 changbanpo 同款，从左侧滑出）。
var _detail_panel: DetailPanelController
var _press_card = null

# 资源加载状态。
var _load_started: bool = false
var _load_finished: bool = false
# 是否已开始（或已完成）滑出动画，避免重复触发。
var _outro_started: bool = false
var _next_scene_packed: PackedScene

# 选中态：""=未选 / "masu" / "wangping"。
var _selected: String = ""

# 进度条同位置渐显的提示/进入文本：
#   _start_hit       —— 透明命中 Control，仅在 fade-in 完成后 STOP 接收点击
#   _start_label     —— 嵌在 hit 内部的视觉文本，呼吸 tween 作用对象
#   _start_clickable —— 仅在 outro fade-in 完成 & 选中英雄 后才允许点击进战
var _start_hit: Control
var _start_label: Label
var _start_breath_tween: Tween
var _start_clickable: bool = false

# 进度条同位置定位常量（与 .tscn 中 ProgressBar 同 anchor/offset）。
const _START_OFFSET_LEFT: float = 24.0
const _START_OFFSET_RIGHT: float = -24.0
const _START_OFFSET_TOP: float = -60.0
const _START_OFFSET_BOTTOM: float = -24.0


func _ready() -> void:
	visible = false

	desc_pnl.add_theme_stylebox_override(
		"panel",
		ThemeFactory.panel(Color.WHITE, Color(1, 1, 1, 0.6), 1, 20, true)
	)
	_apply_review_pnl_style(top_review_pnl, false)
	_apply_review_pnl_style(bottom_review_pnl, false)
	_apply_progress_bar_style()

	_build_desc(_selected)
	_build_review_panel(top_review_pnl, "马谡", "masu")
	_build_review_panel(bottom_review_pnl, "王平", "wangping")
	_install_detail_panel()

	await get_tree().process_frame
	_play_intro()
	visible = true

	_start_threaded_load()


# ============== 资源加载（仅推进进度条，不真切场景）==============

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
			_maybe_run_outro()
		ResourceLoader.THREAD_LOAD_FAILED, ResourceLoader.THREAD_LOAD_INVALID_RESOURCE:
			push_error("Jieting: failed to load " + NEXT_SCENE_PATH)
			_load_finished = true


# 进入条件：加载完成 + 尚未触发过。选中状态不再门控，由文本内容反映。
func _maybe_run_outro() -> void:
	if _outro_started or not _load_finished:
		return
	_outro_started = true
	_run_outro()


func _run_outro() -> void:
	var vh: float = size.y
	# 提前建好"进入战役"文本 + 透明命中区（alpha 0，hit 暂为 IGNORE 不响应）。
	_build_start_zone()

	var tw := create_tween()
	tw.tween_property(progress_bar, "position:y", vh, BAR_SLIDE_OUT_DURATION).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	await tw.finished
	progress_bar.visible = false

	# 文本 + 命中区渐显。命中区 fade-in 完成后置 STOP 开始接收点击；
	# 是否真正进战仍需 _on_start_hit_input 内检查 _selected != ""。
	var tw2 := create_tween()
	tw2.tween_property(_start_label, "modulate:a", 1.0, START_TEXT_FADE_IN_DURATION).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	await tw2.finished
	if _start_hit != null:
		_start_hit.mouse_filter = Control.MOUSE_FILTER_STOP
	_start_clickable = true
	_start_breath_loop()


# 文本呼吸：alpha [BREATH_LOW, 1.0] 往返循环（与 changbanpo 同款）。
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


# 在原进度条位置建一个透明命中 Control（接点击）+ 内嵌 Label（视觉）。
# - 仅在 outro fade-in 完成后才把 hit 改 STOP 接收事件
# - _on_start_hit_input 进一步检查 _selected != "" 才进战，否则忽略
# 锚点 + offset 与 ProgressBar 完全一致，多次进出场景位置稳定。
func _build_start_zone() -> void:
	var hit := Control.new()
	hit.name = "StartHit"
	hit.set_anchors_preset(Control.PRESET_BOTTOM_WIDE, false)
	hit.offset_left = _START_OFFSET_LEFT
	hit.offset_right = _START_OFFSET_RIGHT
	hit.offset_top = _START_OFFSET_TOP
	hit.offset_bottom = _START_OFFSET_BOTTOM
	hit.mouse_filter = Control.MOUSE_FILTER_IGNORE  # 渐显完前不响应
	hit.gui_input.connect(_on_start_hit_input)
	add_child(hit)
	_start_hit = hit

	var lbl := Label.new()
	lbl.name = "StartLabel"
	lbl.text = _compose_start_text()
	lbl.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	lbl.add_theme_font_size_override("font_size", START_TEXT_FONT_SIZE)
	lbl.add_theme_color_override("font_color", Color(0.45, 0.45, 0.45))
	lbl.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	lbl.vertical_alignment = VERTICAL_ALIGNMENT_CENTER
	lbl.modulate.a = 0.0
	lbl.mouse_filter = Control.MOUSE_FILTER_IGNORE
	hit.add_child(lbl)
	_start_label = lbl


# 当前文案：未选 → PROMPT_TEXT；已选 → 带英雄名的"进入战役"文案。
func _compose_start_text() -> String:
	if _selected == "":
		return PROMPT_TEXT
	var hero: String = String(HERO_NAMES.get(_selected, ""))
	return "————作为%s进入战役————" % hero


# 命中区点击：仅在 _start_clickable=true 且玩家已选中英雄时进战。
# 未选状态下点击呼吸文本视为提示性文案，不响应。
func _on_start_hit_input(event: InputEvent) -> void:
	if not _start_clickable:
		return
	if _selected == "":
		return
	if event is InputEventMouseButton \
			and event.button_index == MOUSE_BUTTON_LEFT \
			and event.pressed:
		_start_clickable = false
		_enter_battle()


# 渐隐切场景：先注入章节 config，再渐隐 → change_scene_to_packed。
# Game.bootstrap 在新场景 _ready 内执行，此时 pending_chapter_config 必须已就绪。
# 章节 config 文件由后续数据迭代提供；缺失时 DataLoader.load_level_from_chapter
# 返回空 level → bootstrap 走默认英雄回退，不致崩溃。
func _enter_battle() -> void:
	var config_path: String = "res://data/chapters/jieting_%s.json" % _selected
	Game.pending_chapter_config = config_path

	# 屏蔽后续输入 + 停止呼吸 tween（避免与整屏渐隐 tween 在 modulate 上冲突）。
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
		# 兜底：未拿到 packed → 走文件路径。
		get_tree().change_scene_to_file(NEXT_SCENE_PATH)


# ============== 选择 ==============

# 互斥单选：再次点同一面板保持选中（不可取消）。
func _on_panel_clicked(key: String) -> void:
	if _selected == key:
		return
	_selected = key
	_apply_review_pnl_style(top_review_pnl, _selected == "masu")
	_apply_review_pnl_style(bottom_review_pnl, _selected == "wangping")
	_build_desc(_selected)
	_refresh_start_label_text()
	_maybe_run_outro()


# 把 _start_label 的文本与当前选中状态保持一致：未选 → 提示，已选 → 作为 {X}。
# 无 label 时静默返回（outro 还没建好）。
func _refresh_start_label_text() -> void:
	if _start_label == null:
		return
	_start_label.text = _compose_start_text()


# 风格化检阅面板：未选 = 默认（白边）/ 选中 = 清冷蓝 #4a90e2 + 加粗描边。
func _apply_review_pnl_style(pnl: Panel, selected: bool) -> void:
	var border_color: Color = SELECT_ACTIVE_BORDER if selected else SELECT_NORMAL_BORDER
	var border_w: int = SELECT_ACTIVE_W if selected else SELECT_NORMAL_W
	pnl.add_theme_stylebox_override(
		"panel",
		ThemeFactory.panel(SELECT_BG_COLOR, border_color, border_w, SELECT_PNL_RADIUS, false)
	)


# ============== 描述面板 ==============

func _build_desc(selected: String) -> void:
	for c in desc_pnl.get_children():
		c.queue_free()

	var body_text: String
	match selected:
		"masu":     body_text = _DESC_BODY_MASU
		"wangping": body_text = _DESC_BODY_WANGPING
		_:          body_text = _DESC_BODY_DEFAULT

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
	body.text = MarkupParser.parse(_DESC_HEADER + body_text)
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


# ============== 检阅面板（双块）==============

# 单个检阅面板：标题 + 卡牌列表（"填线宝宝 x10"占位）。
# 选中机制：直接监听 pnl.gui_input；面板内任何空白区、标题、卡牌行的点击事件
# 都会通过 PASS / IGNORE 的层级冒泡到 Panel（默认 STOP 兜底），
# 保证"点击整块面板任意位置都能选中"。卡牌行的长按详情逻辑独立工作，
# 互不干扰。
func _build_review_panel(pnl: Panel, title_text: String, key: String) -> void:
	for c in pnl.get_children():
		c.queue_free()

	# Panel 兜底接管点击 → _on_panel_clicked。
	pnl.gui_input.connect(_on_panel_gui_input.bind(key))

	var title := Label.new()
	title.text = title_text
	title.add_theme_font_size_override("font_size", REVIEW_TITLE_FONT_SIZE)
	title.add_theme_color_override("font_color", Color(0.2, 0.2, 0.2, 1))
	title.horizontal_alignment = HORIZONTAL_ALIGNMENT_CENTER
	title.set_anchors_preset(Control.PRESET_TOP_WIDE, false)
	title.offset_top = 20
	title.offset_bottom = 20 + REVIEW_TITLE_HEIGHT
	title.mouse_filter = Control.MOUSE_FILTER_IGNORE
	pnl.add_child(title)

	var scroll := ScrollContainer.new()
	scroll.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	scroll.offset_top = 20 + REVIEW_TITLE_HEIGHT + 10
	scroll.offset_bottom = -REVIEW_PADDING
	scroll.offset_left = REVIEW_PADDING
	scroll.offset_right = -REVIEW_PADDING
	scroll.horizontal_scroll_mode = ScrollContainer.SCROLL_MODE_DISABLED
	# PASS：让 ScrollContainer 内部的拖动滚动仍然工作，但点击事件冒泡至父 Panel
	# 触发选中（卡牌行不拦截时）。
	scroll.mouse_filter = Control.MOUSE_FILTER_PASS
	pnl.add_child(scroll)
	var vbar := scroll.get_v_scroll_bar()
	if vbar:
		vbar.custom_minimum_size = Vector2.ZERO
		vbar.modulate = Color(1, 1, 1, 0)
		vbar.mouse_filter = Control.MOUSE_FILTER_IGNORE

	var vbox := VBoxContainer.new()
	vbox.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	vbox.add_theme_constant_override("separation", REVIEW_ITEM_SEPARATION)
	vbox.mouse_filter = Control.MOUSE_FILTER_PASS
	scroll.add_child(vbox)

	var card_db := _load_card_db()
	for raw in PLACEHOLDER_CARDS:
		var cname := String(raw.get("name", ""))
		var card = card_db.get(cname, null)
		if card == null:
			push_warning("Jieting: card not in all_cards.json → " + cname)
			continue
		vbox.add_child(_make_review_row({
			"name": cname,
			"count": int(raw.get("count", 1)),
			"cost": int(card.cost),
			"card": card,
		}))


# Panel 级点击：左键按下即视为选中本面板。卡牌行 Button 已设 PASS，
# 短按 / 长按事件会同时冒泡到这里 → 选中行为与卡牌长按详情共存。
func _on_panel_gui_input(event: InputEvent, key: String) -> void:
	if event is InputEventMouseButton \
			and event.button_index == MOUSE_BUTTON_LEFT \
			and event.pressed:
		_on_panel_clicked(key)


func _load_card_db() -> Dictionary:
	var out: Dictionary = {}
	for c in DataLoader.load_cards(DataLoader.ALL_CARDS_JSON):
		out[String(c.name)] = c
	return out


# 一行 = HBox(费用徽章 + Button)，与 changbanpo 同款。
# 行内 Button.pressed 不触发面板单选（pressed 仅短按；选中由整面板 hit 层接管）。
# 长按 → DetailPanelController 弹出详情。
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
	b.button_down.connect(_on_review_item_press.bind(b))
	b.button_up.connect(_on_review_item_release)
	b.mouse_exited.connect(_on_review_item_release)
	row.add_child(b)
	return row


func _on_review_item_press(btn: Button) -> void:
	if _detail_panel == null:
		return
	var card = btn.get_meta("card_data", null)
	if card == null:
		return
	_press_card = card
	_detail_panel.start_long_press(card)


func _on_review_item_release() -> void:
	if _detail_panel != null:
		_detail_panel.cancel_long_press()
	_press_card = null


func _input(event: InputEvent) -> void:
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and not event.pressed:
		if _detail_panel != null:
			_detail_panel.cancel_long_press()
			_detail_panel.hide_panel()
		_press_card = null


# ============== 长按详情面板 ==============

# 复用游玩界面的长按详情面板（DetailPanelController），与游玩界面同款视觉与
# 弹出方式：默认 LEFT_WIDE 锚点 + 464px 宽，从场景左侧滑出。
func _install_detail_panel() -> void:
	_detail_panel = DetailPanelController.new()
	_detail_panel.name = "DetailPanel"
	add_child(_detail_panel)
	_detail_panel.setup(self, HAND_CARD_SCENE)
	_detail_panel.get_clip().move_to_front()


# ============== 入场动效 ==============

# 描述面板从左滑入；上下两块检阅面板都从右滑入；进度条从下方滑入。
func _play_intro() -> void:
	var vw: float = size.x
	var vh: float = size.y

	var desc_target: Vector2 = desc_pnl.position
	var top_target: Vector2 = top_review_pnl.position
	var bottom_target: Vector2 = bottom_review_pnl.position
	var bar_target: Vector2 = progress_bar.position

	desc_pnl.position = Vector2(-desc_pnl.size.x, desc_target.y)
	top_review_pnl.position = Vector2(vw, top_target.y)
	bottom_review_pnl.position = Vector2(vw, bottom_target.y)
	progress_bar.position = Vector2(bar_target.x, vh)

	var tw := create_tween()
	tw.set_parallel(true)
	tw.tween_property(desc_pnl, "position", desc_target, SLIDE_IN_DURATION).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(top_review_pnl, "position", top_target, SLIDE_IN_DURATION).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(bottom_review_pnl, "position", bottom_target, SLIDE_IN_DURATION).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	tw.tween_property(progress_bar, "position", bar_target, SLIDE_IN_DURATION).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


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
