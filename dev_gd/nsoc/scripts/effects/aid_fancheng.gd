extends Effect

# 援樊：英雄被击败时，对"樊城·曹仁"（slot_id="enemy_main"）造成 10 点"triggered"伤害。
# 通过 HeroAbility on_death 触发（英雄层，非单位层）。
# 本 Effect 仅用于展示/注册，实际驱动由 HeroAbility 子类调用。

func id() -> String:
	return "aid_fancheng"

func display_name() -> String:
	return "援樊"

func description() -> String:
	return "援樊：英雄被击败后，对「樊城·曹仁」造成 10 点伤害（可穿透死守）"
