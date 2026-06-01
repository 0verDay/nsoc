class_name DialogueBubble
extends PanelContainer

# 对话气泡组件。由 DialogueManager 动态实例化并添加到 CanvasLayer。
# 全部 UI 节点在 _ready() 中以代码构建，无需 .tscn 场景文件。
#
# 布局（自上而下）：
#   [英雄名称]
#   [头像 60x60]  [对话文本（自动换行）]
#
# 显示时长：max(2.0, min(6.0, 1.5 + 字符数 × 0.06)) 秒；玩家点击可提前关闭。

signal dismissed

const FONT_SIZE_NAME: int  = 18
const FONT_SIZE_TEXT: int  = 20
const PORTRAIT_SIZE: int   = 60
const FADE_IN_SEC: float   = 0.28
const FADE_OUT_SEC: float  = 0.22
const SLIDE_OFFSET: float  = 40.0   # 滑入/滑出的垂直位移（像素）
const TIME_PER_CHAR: float = 0.06
const TIME_MIN: float      = 2.0
const TIME_MAX: float      = 6.0

var _name_label:  Label          = null
var _portrait:    TextureRect    = null
var _text_label:  RichTextLabel  = null
var _timer:       Timer          = null
var _tween:       Tween          = null
var _closing:          bool      = false
var _rest_pos:         Vector2   = Vector2.ZERO  # 静止目标位置（由 manager 在外部设定）
var _slide_from_below: bool      = false         # true = 从下向上滑入（玩家侧气泡）

func _ready() -> void:
	# CanvasLayer 内 PanelContainer 默认会尝试填满 Canvas，显式收缩为内容尺寸。
	size_flags_horizontal = Control.SIZE_SHRINK_BEGIN
	size_flags_vertical   = Control.SIZE_SHRINK_BEGIN
	mouse_filter = Control.MOUSE_FILTER_STOP  # 整个气泡区域捕捉点击

	# ── 底板样式：白底 + 主蓝描边（与游戏整体风格一致）────────────────────
	add_theme_stylebox_override("panel",
		ThemeFactory.panel(
			Color.WHITE,              # 白色底板
			Color("#339af0"),         # 主蓝描边（同费用条、选中高亮）
			3, 16, true               # 边宽 3、圆角 16、带阴影
		)
	)

	# ── 最外层 MarginContainer ─────────────────────────────────────────
	var margin := MarginContainer.new()
	margin.add_theme_constant_override("margin_left",   14)
	margin.add_theme_constant_override("margin_right",  14)
	margin.add_theme_constant_override("margin_top",    10)
	margin.add_theme_constant_override("margin_bottom", 10)
	add_child(margin)

	# ── VBoxContainer：名称在上，头像+文字在下 ─────────────────────────
	var vbox := VBoxContainer.new()
	vbox.add_theme_constant_override("separation", 5)
	margin.add_child(vbox)

	# 英雄名称：标题蓝（同 settings 面板标题色）
	_name_label = Label.new()
	_name_label.add_theme_color_override("font_color", Color("#1c7ed6"))
	_name_label.add_theme_font_size_override("font_size", FONT_SIZE_NAME)
	vbox.add_child(_name_label)

	# HBoxContainer：头像 + 文本
	var hbox := HBoxContainer.new()
	hbox.add_theme_constant_override("separation", 12)
	vbox.add_child(hbox)

	# 头像容器：极浅蓝背景 + 主蓝细框（对应 front_row_selector 高亮配色）
	var portrait_bg := Panel.new()
	portrait_bg.custom_minimum_size = Vector2(PORTRAIT_SIZE, PORTRAIT_SIZE)
	portrait_bg.add_theme_stylebox_override("panel",
		ThemeFactory.panel(
			Color("#e8f4fd"),       # 极浅蓝底（同前排选择器高亮背景）
			Color("#339af0"),       # 主蓝框
			1, 8
		)
	)
	hbox.add_child(portrait_bg)

	_portrait = TextureRect.new()
	_portrait.set_anchors_preset(Control.PRESET_FULL_RECT)
	_portrait.offset_left   =  4; _portrait.offset_top    =  4
	_portrait.offset_right  = -4; _portrait.offset_bottom = -4
	_portrait.stretch_mode  = TextureRect.STRETCH_KEEP_ASPECT_CENTERED
	_portrait.expand_mode   = TextureRect.EXPAND_FIT_WIDTH_PROPORTIONAL
	var icon_path: String = "res://icon.svg"
	if ResourceLoader.exists(icon_path):
		_portrait.texture = load(icon_path)
	portrait_bg.add_child(_portrait)

	# 对话文本（RichTextLabel）：深色字体，白底清晰可读
	_text_label = RichTextLabel.new()
	_text_label.bbcode_enabled = true
	_text_label.fit_content    = false   # 不用 fit_content：节点加入树时 size.x=0，
	                                     # fit_content 会算出每字单行的巨大高度。
	                                     # 气泡高度由头像(60px)决定，文本在其中自动换行。
	_text_label.scroll_active  = false
	_text_label.size_flags_horizontal = Control.SIZE_EXPAND_FILL
	_text_label.size_flags_vertical   = Control.SIZE_EXPAND_FILL  # 填满头像高度
	_text_label.add_theme_font_size_override("normal_font_size", FONT_SIZE_TEXT)
	_text_label.add_theme_color_override("default_color", Color("#1f2937"))   # 深墨色
	hbox.add_child(_text_label)

	# ── 自动关闭计时器 ─────────────────────────────────────────────────
	_timer = Timer.new()
	_timer.one_shot = true
	_timer.timeout.connect(_on_timeout)
	add_child(_timer)

	# 初始透明
	modulate.a = 0.0

# ── 公开 API ──────────────────────────────────────────────────────────────

# 设置内容并开始显示（淡入 + 计时）。
# 调用前 manager 已设置好 position；此处读取并作为静止目标位置。
# slide_from_below = true：从下方滑入（玩家侧气泡）；false：从上方滑入（敌方侧气泡）。
func setup(speaker: String, text: String, slide_from_below: bool = false) -> void:
	_name_label.text = speaker
	_text_label.text = MarkupParser.parse(text)

	_slide_from_below = slide_from_below
	_rest_pos = position

	# 根据滑入方向设置初始偏移
	if _slide_from_below:
		position.y = _rest_pos.y + SLIDE_OFFSET   # 从下方（+Y）滑入到 _rest_pos
	else:
		position.y = _rest_pos.y - SLIDE_OFFSET   # 从上方（-Y）滑入到 _rest_pos

	var duration: float = clamp(1.5 + text.length() * TIME_PER_CHAR,
		TIME_MIN, TIME_MAX)
	_timer.start(duration)
	_animate_in()

# ── 输入（点击关闭）────────────────────────────────────────────────────

func _gui_input(event: InputEvent) -> void:
	if event is InputEventMouseButton and (event as InputEventMouseButton).pressed:
		_close()

# ── 私有 ─────────────────────────────────────────────────────────────────

func _on_timeout() -> void:
	_close()

func _close() -> void:
	if _closing:
		return
	_closing = true
	_timer.stop()
	_animate_out()

# 滑入动画：从偏移位置滑到 _rest_pos，同步淡入。
# EASE_OUT：越靠近目标越减速，产生"柔和落定"感。
func _animate_in() -> void:
	if _tween and _tween.is_valid():
		_tween.kill()
	_tween = create_tween().set_parallel(true) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
	_tween.tween_property(self, "position:y", _rest_pos.y, FADE_IN_SEC)
	_tween.tween_property(self, "modulate:a", 1.0,         FADE_IN_SEC).from(0.0)

# 滑出动画：沿与入场相反的方向飘出 SLIDE_OFFSET，同步淡出，结束后释放。
# EASE_IN：越离越快，产生"自然离场"感。
# slide_from_below=false（敌方）：从上滑入 → 向下飘出
# slide_from_below=true （玩家）：从下滑入 → 向上飘出（与敌方对称）
func _animate_out() -> void:
	if _tween and _tween.is_valid():
		_tween.kill()
	var exit_y: float = _rest_pos.y + SLIDE_OFFSET if not _slide_from_below \
	                    else _rest_pos.y - SLIDE_OFFSET
	_tween = create_tween().set_parallel(true) \
		.set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	_tween.tween_property(self, "position:y", exit_y,  FADE_OUT_SEC)
	_tween.tween_property(self, "modulate:a", 0.0,     FADE_OUT_SEC)
	# 等两个属性都播完后释放节点（set_parallel 并行，取最长的那条）
	_tween.chain().tween_callback(func() -> void:
		dismissed.emit()
		queue_free()
	)
