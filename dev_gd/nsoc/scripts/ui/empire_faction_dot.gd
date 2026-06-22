class_name EmpireFactionDot
extends Control

# 势力色块：纯色圆 + 细白描边。供 InfoPanel 使用。

var _color: Color = Color.GREEN


func init(c: Color) -> void:
	_color = c
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _draw() -> void:
	var r: float = min(size.x, size.y) * 0.5
	var c := Vector2(size.x * 0.5, size.y * 0.5)
	draw_circle(c, r, _color)
	draw_arc(c, r, 0.0, TAU, 32, Color(1, 1, 1, 0.7), 1.5, true)
