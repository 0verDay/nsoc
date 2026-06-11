extends HeroAbility

# 巧变（展示用）—— 街亭遗恨·张郃 专属被动。
# 实际效果由 chapters/jieting_*.json 的 unit_died trigger 调用 spawn_unit
# 实现：任一非"疑兵"的己方单位（faction=1, board=enemy_main）死亡 → 在原位
# (snap_origin) 召唤一个"疑兵"。原位被占则 spawn_unit 静默返回。
# 本脚本仅提供 UI 描述文本，不可主动激活。

func id() -> String:
	return "qiaobian_ability"

func display_name() -> String:
	return "巧变"

func description() -> String:
	return "巧变：任一己方单位死亡时，在其原位召唤一个「疑兵」。"

func cost() -> int:
	return 0

func can_activate(_ctx) -> bool:
	return false
