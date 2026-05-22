extends Control

# 章节场景入场淡入。挂在章节根 Control 上 → _ready 自动 modulate.a=0 渐显到 1。
# 与 CampaignPanel 长按业务的"前一个场景渐隐 + change_scene"配合，构成完整黑场过渡。
# 若章节场景需要自定义 _ready 逻辑，可继承本脚本并 super._ready()，
# 或不挂本脚本直接在自己 _ready 里 fade_in_self()。

const FADE_IN_DURATION: float = 0.4


func _ready() -> void:
	fade_in_self()


# 给子类 / 外部脚本复用：将自身 modulate.a 从 0 tween 到 1。
func fade_in_self() -> void:
	modulate.a = 0.0
	var tw := create_tween()
	tw.tween_property(self, "modulate:a", 1.0, FADE_IN_DURATION).set_trans(Tween.TRANS_CUBIC).set_ease(Tween.EASE_OUT)
