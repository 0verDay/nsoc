extends HeroAbility

# 援樊——庞德/于禁/徐晃 共用被动。
# 自身英雄被击败（HeroState.died 信号）时，对 enemy_main（曹仁）造成 10 点 triggered 伤害。
# 通过 hero.died 信号驱动，不可主动激活。

func id() -> String:
	return "aid_fancheng_ability"

func display_name() -> String:
	return "援樊"

func description() -> String:
	return "援樊：英雄被击败后，对「樊城·曹仁」造成 10 点伤害（穿透死守）"

func can_activate(_ctx) -> bool:
	return false  # 被动，不可主动激活

# 由 BoardSlot._on_hero_died 的 notify_hero_died trigger 触发，
# 或由 ScriptedEvents action "trigger_aid_fancheng" 调用。
# 此处提供静态调用入口，供 on_hero_died_action 直接调用。
static func trigger(game_node: Node) -> void:
	if game_node == null or game_node.registry == null:
		return
	for slot in game_node.registry.by_role(BoardSlot.ROLE_MAIN_ENEMY):
		slot.damage_hero(10, "triggered")
		return
