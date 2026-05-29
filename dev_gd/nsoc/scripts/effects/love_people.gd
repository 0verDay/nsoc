extends Effect

# 爱民：被击败后，对名为 TARGET_HERO 的英雄造成 1 点伤害。
# 用于"乡勇"单位，长坂坡章节专属。

const TARGET_HERO: String = "长坂坡·刘备"
const DAMAGE: int = 1

func id() -> String:
	return "love_people"

func display_name() -> String:
	return "爱民"

func description() -> String:
	return "爱民：被击败后，对英雄「%s」造成 %d 点伤害。" % [TARGET_HERO, DAMAGE]

func on_death(_card_data, ctx) -> bool:
	ctx.damage_hero_by_name(TARGET_HERO, DAMAGE)
	return false   # 走默认入墓流程，不接管尸体
