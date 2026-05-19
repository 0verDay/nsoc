class_name Effect
extends RefCounted

# Effect 基类。所有效果脚本继承此类并重写需要的方法。
# 通过 EffectRegistry 启动期扫描注册，运行期 O(1) 查表，单例复用。

func id() -> String:
	return ""

func display_name() -> String:
	return id()

func description() -> String:
	return ""

# 出牌时触发。ctx 为 EffectContext，提供受控的游戏状态访问接口。
func on_play(card_data, ctx) -> void:
	pass

# 死亡时触发。返回 true 表示该效果已接管尸体处理（如除外），
# false 表示走默认流程（入墓）。
func on_death(card_data, ctx) -> bool:
	return false

# 法术解析后该卡的去向。返回 "graveyard" / "banish" / "" (不处理)。
# 用于替代 main.gd 中硬编码的 "exhaust" 分支。
func resolve_destination(card_data, ctx) -> String:
	return ""
