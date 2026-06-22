class_name EmpireLineLayer
extends Node2D

# 地图连线层。在 Node2D 空间中绘制所有 connection 连线。

var _id_to_pos: Dictionary = {}
var _connections: Array = []
var _bounds_min: Vector2 = Vector2.ZERO
var _bounds_max: Vector2 = Vector2.ZERO


func set_data(id_to_pos: Dictionary, connections: Array) -> void:
	_id_to_pos = id_to_pos
	_connections = connections
	queue_redraw()


func set_bounds(bmin: Vector2, bmax: Vector2) -> void:
	_bounds_min = bmin
	_bounds_max = bmax
	queue_redraw()


func _draw() -> void:
	for conn in _connections:
		var a: Vector2 = _id_to_pos.get(int(conn.get("from", -1)), Vector2.ZERO)
		var b: Vector2 = _id_to_pos.get(int(conn.get("to",   -1)), Vector2.ZERO)
		draw_line(a, b, Color("#7ec8e3"), 2.0, true)
