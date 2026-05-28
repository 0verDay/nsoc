class_name CombatSystem
extends Node

# 战斗动画与伤害结算。

const HERO_HIT_FADE: float = 0.5
const ATTACK_HIT_DELAY: float = 0.45
const DEATH_DELAY: float = 0.45
const MOVE_HALF_DURATION: float = 0.2
const MOVE_ARC_OFFSET: Vector2 = Vector2(0, -70)
const SCALE_PEAK: Vector2 = Vector2(1.08, 1.08)

var _root: Control                          # 用于挂载移动动画 visual / 闪烁面板
var _cell_scene: PackedScene
var _play_controller: PlayController        # 死亡时回调（牌入墓/除外）

# 退出到菜单时置 true，所有 await 后检查此 flag 并提前 return，避免 invalid 引用报错。
var aborted: bool = false

func setup(root: Control, cell_scene: PackedScene, play_controller: PlayController) -> void:
	_root = root
	_cell_scene = cell_scene
	_play_controller = play_controller

# 退出到菜单时调用：标记中止，所有正在 await 的协程在下一个 resume 点安全退出。
func abort() -> void:
	aborted = true

# 旧 API 兼容：英雄受伤面板闪红已下沉到 BoardSlot.damage_hero。
# 调用方应改为通过 slot.hero_resolver / slot.damage_hero。

func attack_cells(attacker, defender_data_list: Array) -> void:
	var a_atk: int = attacker.attack
	var dead_cells: Array = []

	attacker.play_attack_effect()
	for defender_data in defender_data_list:
		var defender = defender_data.cell
		# defender_data.opp_dir 为屏幕绝对方向（top/bottom/left/right），
		# defender.health 以 side 存储 → 转换。
		var hit_side := Orientation.abs_to_side(defender_data.opp_dir, defender.is_enemy)
		# "虚弱"：受到任意方向伤害时，同步扣除四面血量
		if defender.effects.has("frail"):
			for s in Orientation.SIDES:
				defender.health[s] -= a_atk
		else:
			defender.health[hit_side] -= a_atk
		defender._update_hp_labels()
		defender.play_damage_effect()

	await get_tree().create_timer(ATTACK_HIT_DELAY).timeout
	# 退出到菜单时 aborted=true 或节点已被 free，协程 resume 后立即返回
	if aborted or not is_instance_valid(self):
		return

	for defender_data in defender_data_list:
		var defender = defender_data.cell
		var hit_side := Orientation.abs_to_side(defender_data.opp_dir, defender.is_enemy)
		var dead: bool = false
		if defender.effects.has("frail"):
			# 任一面 <=0 即视为阵亡
			for s in Orientation.SIDES:
				if defender.health[s] <= 0:
					dead = true
					break
		else:
			dead = defender.health[hit_side] <= 0
		if dead and not dead_cells.has(defender):
			dead_cells.append(defender)

	if dead_cells.size() > 0:
		for dc in dead_cells:
			dc.play_death_effect()
		await get_tree().create_timer(DEATH_DELAY).timeout
		# 退出到菜单时 aborted=true 或节点已被 free
		if aborted or not is_instance_valid(self):
			return
		# 收集 victim 快照（card_name / is_enemy）供 handle_kills 使用，
		# 因 clear_card 会清空这些字段。
		var victims: Array = []
		for dc in dead_cells:
			var snap := {
				"cell": dc,
				"card_name": dc.card_name,
				"is_enemy": dc.is_enemy,
			}
			_play_controller.handle_unit_death(dc)
			if dc.has_card:
				dc.clear_card()
			victims.append(snap)
		# 攻击者击杀回调（冲阵等）。attacker 自身可能因警戒等被打死，需校验 has_card。
		if attacker != null and attacker.has_card:
			await _play_controller.handle_kills(attacker, victims)

func move_card(start, end) -> void:
	var cname: String = start.card_name
	var atk: int = start.attack
	var hp: Dictionary = start.health
	var is_e: bool = start.is_enemy
	var effs: Array = start.effects
	var charged: bool = start.has_charged

	var visual = _cell_scene.instantiate()
	_root.add_child(visual)
	visual.global_position = start.global_position
	visual.z_index = 100
	visual.pivot_offset = visual.custom_minimum_size / 2.0
	visual.set_card(cname, atk, hp, is_e, effs)
	visual.self_modulate.a = 0.0

	start.clear_card()

	var tween := get_tree().create_tween()
	var total_duration: float = MOVE_HALF_DURATION * 2.0
	var start_pos: Vector2 = start.global_position
	var end_pos: Vector2 = end.global_position

	# 水平/整体位移：单段 sine 缓动，全程匀畅，无中点速度归零
	tween.tween_property(visual, "global_position", end_pos, total_duration) \
		.set_trans(Tween.TRANS_SINE).set_ease(Tween.EASE_IN_OUT)
	# 弧形拱起：用 method tween 输出 0→1 进度，依抛物 sin(pi*t) 叠加 y 偏移
	tween.parallel().tween_method(
		func(t: float) -> void:
			if not is_instance_valid(visual):
				return
			var base: Vector2 = start_pos.lerp(end_pos, t)
			var arc_y: float = sin(PI * t) * MOVE_ARC_OFFSET.y
			visual.global_position = base + Vector2(0.0, arc_y),
		0.0, 1.0, total_duration)
	# 缩放：先放大再回落，整段单 tween 用 sine 平滑
	tween.parallel().tween_method(
		func(t: float) -> void:
			if not is_instance_valid(visual):
				return
			var s: float = 1.0 + (SCALE_PEAK.x - 1.0) * sin(PI * t)
			visual.scale = Vector2(s, s),
		0.0, 1.0, total_duration)

	await tween.finished
	if is_instance_valid(visual):
		visual.queue_free()
	# 退出到菜单时 aborted=true，不再操作可能已 free 的 end 节点
	if aborted or not is_instance_valid(self):
		return

	end.set_card(cname, atk, hp, is_e, effs)
	end.has_charged = charged
