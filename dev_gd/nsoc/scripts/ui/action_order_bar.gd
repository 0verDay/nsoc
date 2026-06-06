class_name ActionOrderBar
extends HBoxContainer

# 行动顺序指示器：顶部状态条，显示 1v3 全部玩家昵称。
# 高亮当前行动者；阵亡玩家文字加删除线。
# PVE / 1v1 不显示（hide()）。

var _labels: Array = []   # Array[Label]，按 pvp_action_order 顺序

func setup(parent: Control) -> void:
	if parent == null:
		return
	parent.add_child(self)
	# 绝对定位到顶部居中
	set_anchors_preset(Control.PRESET_TOP_WIDE)
	offset_top    = 2.0
	offset_bottom = 30.0
	alignment = BoxContainer.ALIGNMENT_CENTER
	add_theme_constant_override("separation", 16)
	visible = false

# 每次 pvp_advance_turn 后调用刷新
func refresh() -> void:
	if not has_node("/root/Game") or not Game.is_pvp:
		visible = false
		return
	if Game.pvp_match_type != "1v3":
		visible = false
		return
	visible = true
	var order: Array = Game.pvp_action_order
	# 初始化 label 数量
	while _labels.size() < order.size():
		var lbl := Label.new()
		lbl.add_theme_font_size_override("font_size", 14)
		add_child(lbl)
		_labels.append(lbl)
	# 隐藏多余 label
	for i in range(order.size(), _labels.size()):
		_labels[i].visible = false
	var active_pid: String = Game.pvp_active_player_id()
	for i in range(order.size()):
		var pid: String = String(order[i])
		var lbl: Label = _labels[i]
		lbl.visible = true
		# 昵称：取 Net 当前房间玩家 nickname，无则用 pid 后 4 位
		var nick: String = _nickname_of(pid)
		var is_dead: bool = Game.pvp_dead_players.has(pid)
		var is_active: bool = pid == active_pid
		if is_dead:
			lbl.text = "~~%s~~" % nick
			lbl.add_theme_color_override("font_color", Color("#adb5bd"))
		elif is_active:
			lbl.text = "▶ %s" % nick
			lbl.add_theme_color_override("font_color", Color("#f76707"))
		else:
			lbl.text = nick
			lbl.add_theme_color_override("font_color", Color("#495057"))

static func _nickname_of(pid: String) -> String:
	if Engine.get_main_loop() == null:
		return _short_id(pid)
	var root: Node = Engine.get_main_loop().root
	if root.has_node("/root/Net"):
		var players = Net.get_room_players() if Net.has_method("get_room_players") else []
		for p in players:
			if String(p.get("uuid", "")) == pid:
				var nick: String = String(p.get("nickname", ""))
				if nick != "":
					return nick
	return _short_id(pid)

static func _short_id(pid: String) -> String:
	return pid.substr(pid.length() - 4) if pid.length() >= 4 else pid
