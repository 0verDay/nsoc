extends Node

# 全面屏安全区域工具（autoload "SafeArea"）。
# - 计算左侧刘海/摄像头占用的虚拟坐标像素宽度（left_inset）
# - 自动在最底层 CanvasLayer 绘制黑色填充条，遮住刘海区域
# 仅在 Android / iOS 生效；PC 端 left_inset = 0，不渲染填充条。

# 虚拟分辨率宽度（与 project.godot window/size/viewport_width 一致）
const VIEWPORT_W: float = 1920.0

# 左侧安全区偏移量（虚拟坐标系像素），供各 UI 模块读取。
var left_inset: float = 0.0

func _ready() -> void:
	if OS.get_name() != "Android" and OS.get_name() != "iOS":
		return
	var safe_area: Rect2i = DisplayServer.get_display_safe_area()
	var screen_size: Vector2i = DisplayServer.screen_get_size()
	if screen_size.x <= 0:
		return
	var left_px: int = safe_area.position.x
	if left_px <= 0:
		return
	left_inset = float(left_px) / float(screen_size.x) * VIEWPORT_W
	left_inset = clamp(left_inset, 0.0, 300.0)
	if left_inset > 0.0:
		_add_black_bar()

# 在 CanvasLayer layer=-10（位于所有游戏 UI 之下）添加黑色填充条，
# 宽度为 left_inset，高度铺满屏幕，填充刘海区域。
func _add_black_bar() -> void:
	var canvas := CanvasLayer.new()
	canvas.name = "_SafeAreaBlackBar"
	canvas.layer = -10
	add_child(canvas)
	var rect := ColorRect.new()
	rect.color = Color.BLACK
	rect.set_anchors_preset(Control.PRESET_LEFT_WIDE, false)
	rect.offset_left = 0.0
	rect.offset_right = left_inset
	rect.offset_top = 0.0
	rect.offset_bottom = 0.0
	rect.anchor_bottom = 1.0
	rect.mouse_filter = Control.MOUSE_FILTER_IGNORE
	canvas.add_child(rect)

# ── 辅助：给左侧锚定的 clip 控件（PRESET_LEFT_WIDE）应用安全区偏移 ──
# clip 的 offset_left/right 同时右移 left_inset，保持宽度不变。
func shift_left_clip(clip: Control, base_left: float, width: float) -> void:
	if clip == null or left_inset <= 0.0:
		return
	clip.offset_left  = base_left + left_inset
	clip.offset_right = base_left + left_inset + width

# ── 辅助：给普通面板节点（PRESET_LEFT_WIDE 或自由 offset_left）右移偏移 ──
# 仅移动 offset_left，offset_right 同步加，保持宽度。
func shift_panel(pnl: Control) -> void:
	if pnl == null or left_inset <= 0.0:
		return
	pnl.offset_left  += left_inset
	pnl.offset_right += left_inset

