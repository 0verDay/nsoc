class_name SecondaryPanel
extends Control

# 主菜单二级面板基类。
# 主菜单点击导航按钮 → 对应面板扩展为全屏 → 在其内部 attach() 此类的具体场景实例。
#
# 子类（场景根节点）只需：
#   1. .tscn 中以 PRESET_FULL_RECT 锚定根 Control，挂上对应脚本（继承本类或本身）
#   2. .tscn 中包含一个名为 "BackBtn" 的 Button（位置任意，常用右上 160×80）
#   3. 自定义其它子面板/控件（如 PreparePanel 的 4 子面板）
#
# 行为：
#   - _ready 自动应用 BackBtn 的蓝色主按钮风格，连接 back_pressed 信号
#   - 自身整树 set_meta("transition_skip", true)，与 MainMenu 的转场淡出收集器兼容
#   - attach(origin_panel) 把自身挂到已扩展面板内并淡入
#   - detach_with_fade(duration) 整体 modulate 淡出 + queue_free

signal back_pressed

const FADE_DURATION: float = 0.45

@onready var back_btn: Button = get_node_or_null("BackBtn")


func _ready() -> void:
	# 标记整棵子树跳过 MainMenu 转场的按钮 alpha 收集器；
	# 我们自己用根 modulate 整体控制淡入淡出。
	set_meta("transition_skip", true)
	if back_btn:
		ThemeFactory.apply_button_styles(back_btn, ThemeFactory.primary_button_styles())
		back_btn.add_theme_color_override("font_color", Color.WHITE)
		back_btn.add_theme_color_override("font_hover_color", Color.WHITE)
		back_btn.add_theme_color_override("font_pressed_color", Color.WHITE)
		back_btn.pressed.connect(func(): back_pressed.emit())
	_apply_styles()


# 子类覆盖以应用各自子面板的样式。
func _apply_styles() -> void:
	pass


# 把场景挂到已扩展为全屏的 origin_panel 内部并淡入。
func attach(origin_panel: Control) -> void:
	modulate.a = 0.0
	origin_panel.add_child(self)
	var tw := create_tween()
	tw.tween_property(self, "modulate:a", 1.0, FADE_DURATION).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)


# 与父面板反向转场同步淡出；淡出完成后销毁自身。
func detach_with_fade(duration: float) -> void:
	if back_btn:
		back_btn.disabled = true
	var tw := create_tween()
	tw.tween_property(self, "modulate:a", 0.0, duration).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_IN_OUT)
	await tw.finished
	queue_free()
