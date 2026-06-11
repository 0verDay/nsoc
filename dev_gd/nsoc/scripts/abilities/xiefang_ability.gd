extends HeroAbility

# 协防（展示用）—— 街亭遗恨·王平 专属被动。
# 实际效果由 chapters/jieting_wangping.json 的 initial_mana=5 + mana_max_cap=5
# 在 Game.bootstrap → ManaSystem.setup 时一次性应用：起始 5 费、上限永久封顶 5。
# 本脚本仅提供 UI 描述文本，不可主动激活。

func id() -> String:
	return "xiefang_ability"

func display_name() -> String:
	return "协防"

func description() -> String:
	return "协防：本局起始费用与费用上限均为 5，且不再随回合递增。"

func cost() -> int:
	return 0

func can_activate(_ctx) -> bool:
	return false
