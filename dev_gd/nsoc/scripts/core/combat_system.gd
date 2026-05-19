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
var _hero_pnl_resolver: Callable            # (is_enemy: bool) -> Panel  闪红用

func setup(root: Control, cell_scene: PackedScene, play_controller: PlayController, hero_pnl_resolver: Callable) -> void:
	_root = root
	_cell_scene = cell_scene
	_play_controller = play_controller
	_hero_pnl_resolver = hero_pnl_resolver

func apply_damage_to_hero(is_enemy: bool, damage: int) -> void:
	Game.hero.apply_damage(is_enemy, damage)
	var pnl: Panel = _hero_pnl_resolver.call(is_enemy)
	if pnl == null:
		return
	pnl.self_modulate = Color("#ffc9c9")
	if get_tree():
		var tween := get_tree().create_tween()
		tween.tween_property(pnl, "self_modulate", Color.WHITE, HERO_HIT_FADE)

func attack_cells(attacker, defender_data_list: Array) -> void:
	var a_atk: int = attacker.attack
	var dead_cells: Array = []

	attacker.play_attack_effect()
	for defender_data in defender_data_list:
		var defender = defender_data.cell
		defender.health[defender_data.opp_dir] -= a_atk
		defender._update_hp_labels()
		defender.play_damage_effect()

	await get_tree().create_timer(ATTACK_HIT_DELAY).timeout

	for defender_data in defender_data_list:
		var defender = defender_data.cell
		if defender.health[defender_data.opp_dir] <= 0:
			if not dead_cells.has(defender):
				dead_cells.append(defender)

	if dead_cells.size() > 0:
		for dc in dead_cells:
			dc.play_death_effect()
		await get_tree().create_timer(DEATH_DELAY).timeout
		for dc in dead_cells:
			_play_controller.handle_unit_death(dc)
			if dc.has_card:
				dc.clear_card()

func move_card(start, end) -> void:
	var cname: String = start.card_name
	var atk: int = start.attack
	var hp: Dictionary = start.health
	var is_e: bool = start.is_enemy
	var effs: Array = start.effects

	var visual = _cell_scene.instantiate()
	_root.add_child(visual)
	visual.global_position = start.global_position
	visual.z_index = 100
	visual.pivot_offset = visual.custom_minimum_size / 2.0
	visual.set_card(cname, atk, hp, is_e, effs)
	visual.self_modulate.a = 0.0

	start.clear_card()

	var tween := get_tree().create_tween()
	var mid_pos: Vector2 = (start.global_position + end.global_position) / 2.0

	tween.tween_property(visual, "global_position", mid_pos + MOVE_ARC_OFFSET, MOVE_HALF_DURATION).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.parallel().tween_property(visual, "scale", SCALE_PEAK, MOVE_HALF_DURATION).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_OUT)
	tween.tween_property(visual, "global_position", end.global_position, MOVE_HALF_DURATION).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)
	tween.parallel().tween_property(visual, "scale", Vector2.ONE, MOVE_HALF_DURATION).set_trans(Tween.TRANS_QUAD).set_ease(Tween.EASE_IN)

	await tween.finished
	visual.queue_free()

	end.set_card(cname, atk, hp, is_e, effs)
