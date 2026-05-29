extends Control

# 开场 Logo 视频播放场景。
# 黑色背景 + 居中正方形 VideoStreamPlayer（视频 1440×1440，屏幕 1920×1080，
# 等比填充为 1080×1080 居中，两侧各 420px 黑边）。
#
# 流程：
#   视频播放完毕（finished 信号）→ 黑色渐入 0.3s → 切到 SplashScreen.tscn
#   点击 / 触摸任意位置           → 同上（跳过）
#   视频文件不存在                → 直接切到 SplashScreen.tscn

const VIDEO_PATH:  String = "res://assets/OverDay_logo.ogv"
const NEXT_SCENE:  String = "res://scenes/SplashScreen.tscn"
const FADE_DURATION: float = 0.3

# 视频正方形尺寸：与屏幕高度一致（1080），两侧留黑边
const VIDEO_SIDE: float = 1080.0

var _player:  VideoStreamPlayer
var _overlay: ColorRect
var _done:    bool = false


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_STOP

	# ── 黑色全屏底板 ─────────────────────────────────────────────────
	var bg := ColorRect.new()
	bg.color = Color.BLACK
	bg.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	bg.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(bg)

	# ── 居中正方形 VideoStreamPlayer ─────────────────────────────────
	_player = VideoStreamPlayer.new()
	_player.name = "VideoPlayer"
	_player.set_anchors_preset(Control.PRESET_CENTER, false)
	_player.offset_left   = -VIDEO_SIDE * 0.5
	_player.offset_right  =  VIDEO_SIDE * 0.5
	_player.offset_top    = -VIDEO_SIDE * 0.5
	_player.offset_bottom =  VIDEO_SIDE * 0.5
	_player.expand        = true    # 拉伸填满控件（1440×1440 → 1080×1080，等比无失真）
	_player.autoplay      = true
	_player.mouse_filter  = Control.MOUSE_FILTER_IGNORE

	var stream = load(VIDEO_PATH)
	if stream == null:
		push_warning("VideoSplash: 找不到视频文件 %s，直接跳过" % VIDEO_PATH)
		_switch_scene()
		return

	_player.stream = stream
	_player.finished.connect(_on_video_finished)
	add_child(_player)

	# ── 黑色渐入遮罩（初始透明）────────────────────────────────────
	_overlay = ColorRect.new()
	_overlay.name = "FadeOverlay"
	_overlay.color = Color.BLACK
	_overlay.modulate.a = 0.0
	_overlay.set_anchors_preset(Control.PRESET_FULL_RECT, false)
	_overlay.mouse_filter = Control.MOUSE_FILTER_IGNORE
	add_child(_overlay)


func _input(event: InputEvent) -> void:
	if _done:
		return
	if (event is InputEventMouseButton and event.pressed) \
			or (event is InputEventScreenTouch and event.pressed):
		accept_event()
		_finish()


func _on_video_finished() -> void:
	_finish()


# 渐黑后切场景（视频结束或跳过，保证只触发一次）
func _finish() -> void:
	if _done:
		return
	_done = true
	if _player != null and _player.is_playing():
		_player.stop()
	var tw := create_tween()
	tw.tween_property(_overlay, "modulate:a", 1.0, FADE_DURATION) \
		.set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	await tw.finished
	_switch_scene()


func _switch_scene() -> void:
	get_tree().change_scene_to_file(NEXT_SCENE)
