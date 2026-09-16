extends Control

# 启动前置缓冲界面：
# - 上方标题 "SOC"
# - 下方小字提示 "————点击进入游戏————"（呼吸渐显渐隐）
# - 任意位置点击 → 后台预加载 MainMenu + 整体淡出 → 切换到 MainMenu
#   并通过 Engine meta 通知 MainMenu 播放入场水平滑入动画
#
# 预加载策略：使用 ResourceLoader.load_threaded_request 并行于淡出动画，
# 避免 change_scene_to_file 的同步加载导致黑屏空帧。

const MAIN_MENU_PATH := "res://scenes/MainMenu.tscn"

# 呼吸节奏：从 BREATH_MIN 渐变到 BREATH_MAX 再回到 BREATH_MIN，循环。
const BREATH_MIN: float = 0.25
const BREATH_MAX: float = 1.0
const BREATH_HALF_DURATION: float = 0.9

# 点击后整体淡出时长。
const FADE_OUT_DURATION: float = 0.35

# Engine meta key：MainMenu _setup_transition 完成时读取并消费，
# 据此触发首次入场水平滑入动画。
const INTRO_META_KEY := "play_main_menu_intro"

@onready var _bg: Panel = $Bg
@onready var _hint: Label = $HintLbl

var _switching: bool = false
# 持有循环呼吸 tween 引用，场景切换前显式 kill 避免节点离树时残余 tick
# 触发 "can_process: !is_inside_tree()" 警告。
var _breath_tween: Tween = null


func _ready() -> void:
	# 全屏拦截输入。
	mouse_filter = Control.MOUSE_FILTER_STOP
	# 与项目其它白色风格化背景一致：白底 + 浅灰边、零圆角。
	_bg.add_theme_stylebox_override(
		"panel",
		ThemeFactory.panel(Color.WHITE, Color("#e1e8ed"), 1, 0)
	)
	_start_breath()


# 提示文字呼吸：modulate.a 在 [BREATH_MIN, BREATH_MAX] 间正弦循环。
func _start_breath() -> void:
	_hint.modulate.a = BREATH_MIN
	# 绑定到 _hint 而非 self：节点被释放时 tween 立即随之 kill，
	# 避免引擎在 SplashScreen 离树后还要尝试一次 process 检测。
	_breath_tween = _hint.create_tween()
	_breath_tween.set_loops()
	_breath_tween.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	_breath_tween.tween_property(_hint, "modulate:a", BREATH_MAX, BREATH_HALF_DURATION)
	_breath_tween.tween_property(_hint, "modulate:a", BREATH_MIN, BREATH_HALF_DURATION)


func _gui_input(event: InputEvent) -> void:
	if _switching:
		return
	if event is InputEventMouseButton and event.button_index == MOUSE_BUTTON_LEFT and event.pressed:
		accept_event()
		_switching = true
		_fade_out_and_switch()


func _fade_out_and_switch() -> void:
	# 显式 kill 循环呼吸 tween，避免 change_scene 释放节点时残余 tick
	# 触发 "can_process: !is_inside_tree()" 警告。
	if _breath_tween and _breath_tween.is_valid():
		_breath_tween.kill()
	_breath_tween = null
	# 标记：MainMenu 入场后播放滑入动画。
	Engine.set_meta(INTRO_META_KEY, true)
	# 后台开始加载 MainMenu，与淡出并行。
	ResourceLoader.load_threaded_request(MAIN_MENU_PATH)
	# 整体淡出（含 Bg / 标题 / 提示，使用 self.modulate）。
	var tw := create_tween()
	tw.tween_property(self, "modulate:a", 0.0, FADE_OUT_DURATION).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN)
	await tw.finished
	# 等待预加载完成（通常此时已就绪），切换到内存中的 PackedScene 避免再次同步 IO。
	while ResourceLoader.load_threaded_get_status(MAIN_MENU_PATH) == ResourceLoader.THREAD_LOAD_IN_PROGRESS:
		await get_tree().process_frame
	var packed: PackedScene = ResourceLoader.load_threaded_get(MAIN_MENU_PATH)
	if packed is PackedScene:
		get_tree().change_scene_to_packed(packed)
	else:
		get_tree().change_scene_to_file(MAIN_MENU_PATH)
