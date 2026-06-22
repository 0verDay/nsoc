class_name EmpireMapThumbnail
extends Control

# 地图缩略图：读取帝国地图 JSON，用 _draw 直接绘制节点与连线。
# 供 EmpireMain、EmpireScenarioView 等共享复用。

const PADDING: float    = 12.0
const DOT_RADIUS: float = 8.0
const LINE_WIDTH: float = 1.5
const LINE_COLOR: Color = Color(0.4, 0.4, 0.4, 0.7)

var _shapes: Array = []
var _connections: Array = []
var _faction_colors: Dictionary = {}


func _ready() -> void:
	mouse_filter = Control.MOUSE_FILTER_IGNORE


func _notification(what: int) -> void:
	if what == NOTIFICATION_RESIZED:
		queue_redraw()


func load_from_file(path: String) -> void:
	var file := FileAccess.open(path, FileAccess.READ)
	if file == null:
		push_warning("EmpireMapThumbnail: cannot open " + path)
		return
	var json := JSON.new()
	var err := json.parse(file.get_as_text())
	if err != OK:
		push_warning("EmpireMapThumbnail: JSON parse error in " + path)
		return
	var data: Dictionary = json.data
	_shapes = data.get("shapes", [])
	_connections = data.get("connections", [])
	_faction_colors.clear()
	for f in data.get("factions", []):
		_faction_colors[int(f.get("id", -1))] = Color(f.get("color", "#808080"))
	queue_redraw()


func _draw() -> void:
	if _shapes.is_empty():
		return
	var min_x: float = INF
	var max_x: float = -INF
	var min_y: float = INF
	var max_y: float = -INF
	for s in _shapes:
		var x: float = float(s.get("x", 0.0))
		var y: float = float(s.get("y", 0.0))
		min_x = min(min_x, x)
		max_x = max(max_x, x)
		min_y = min(min_y, y)
		max_y = max(max_y, y)
	var src_w: float = max(max_x - min_x, 1.0)
	var src_h: float = max(max_y - min_y, 1.0)

	var avail_w: float = size.x - PADDING * 2.0
	var avail_h: float = size.y - PADDING * 2.0
	if avail_w <= 0.0 or avail_h <= 0.0:
		return
	var sc: float = min(avail_w / src_w, avail_h / src_h)
	var off_x: float = PADDING + (avail_w - src_w * sc) * 0.5
	var off_y: float = PADDING + (avail_h - src_h * sc) * 0.5

	var id_to_pos: Dictionary = {}
	for s in _shapes:
		var lp := Vector2(
			off_x + (float(s.get("x", 0.0)) - min_x) * sc,
			off_y + (float(s.get("y", 0.0)) - min_y) * sc
		)
		id_to_pos[int(s.get("id", -1))] = lp

	for conn in _connections:
		var f := int(conn.get("from", -1))
		var t := int(conn.get("to", -1))
		if id_to_pos.has(f) and id_to_pos.has(t):
			draw_line(id_to_pos[f], id_to_pos[t], LINE_COLOR, LINE_WIDTH, true)

	for s in _shapes:
		var pos: Vector2   = id_to_pos[int(s.get("id", -1))]
		var fid: int       = int(s.get("faction", 0))
		var color: Color   = _faction_colors.get(fid, Color.GRAY)
		var kind: String   = str(s.get("kind", "circle"))
		var r: float       = DOT_RADIUS
		var outline: Color = Color(0, 0, 0, 0.4)

		match kind:
			"circle":
				draw_circle(pos, r, color)
				draw_arc(pos, r, 0.0, TAU, 32, outline, 1.2, true)
			"triangle":
				var pts := PackedVector2Array([
					pos + Vector2(0.0,        -r * 1.15),
					pos + Vector2( r, r * 0.65),
					pos + Vector2(-r, r * 0.65),
				])
				draw_colored_polygon(pts, color)
				draw_polyline(PackedVector2Array([pts[0], pts[1], pts[2], pts[0]]), outline, 1.2, true)
			"square", _:
				var half: float = r * 0.9
				var rect := Rect2(pos - Vector2(half, half), Vector2(half * 2.0, half * 2.0))
				draw_rect(rect, color)
				draw_rect(rect, outline, false, 1.2)
