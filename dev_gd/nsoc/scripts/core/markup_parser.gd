class_name MarkupParser
extends RefCounted

# 自定义轻量标记 → Godot BBCode 转换器。
# 供 JSON 文本字段声明富文本样式，避免在 JSON 中裸写 BBCode 标签。
#
# 标记规范：
#   {place:文字}  地名         #ffd43b 金黄
#   {ally:文字}   己方人名      #74c0fc 浅蓝
#   {enemy:文字}  敌方人名      #ff6b6b 红
#   {warn:文字}   警示/关键词   #ff922b 橙
#   {key:文字}    游戏关键词    #fcc419 黄（与效果 pill 配色一致）
#   {break}       空行（属性区与正文区之间的视觉分隔）
#   {para}        自然段分隔：换行 + 段首两格缩进
#
# 段首缩进实现说明：
#   使用两个透明汉字 [color=#00000000]文字[/color] 占位。
#   - 汉字字形在 NotoSerifCJK 及所有 CJK 字体中必然存在，宽度精确为 2em
#   - 设为透明（#00000000）后不可见，但保留布局空间
#   - 不依赖全角空格 / NBSP 的平台渲染行为，Android 和桌面效果一致
#   换行使用 \n，配合 bbcode_enabled=true 全平台均有效。
#
# 使用：
#   rich_text_label.bbcode_enabled = true
#   rich_text_label.text = MarkupParser.parse(json_text)

const COLOR_MAP: Dictionary = {
	"place": "#ffd43b",
	"ally":  "#74c0fc",
	"enemy": "#ff6b6b",
	"warn":  "#ff922b",
	"key":   "#fcc419",
}

# 两个透明汉字，宽度恰好等于 2 个汉字（2em），不可见但占位
const _INDENT: String = "[color=#00000000]文字[/color]"

static func parse(text: String) -> String:
	if text.is_empty():
		return text

	var result: String = text

	# {break} → 空行（双换行）
	result = result.replace("{break}", "\n\n")

	# {para} → 换行 + 透明汉字占位缩进（2 个汉字宽）
	result = result.replace("{para}", "\n" + _INDENT)

	# 颜色标记：{tag:内容} → [color=#xxx]内容[/color]
	for tag in COLOR_MAP.keys():
		result = _replace_color_tag(result, tag, COLOR_MAP[tag])

	return result

static func _replace_color_tag(text: String, tag: String, color: String) -> String:
	var out: String = ""
	var open_tag: String = "{" + tag + ":"
	var search_from: int = 0

	while true:
		var tag_start: int = text.find(open_tag, search_from)
		if tag_start == -1:
			out += text.substr(search_from)
			break

		var content_start: int = tag_start + open_tag.length()
		var tag_end: int = text.find("}", content_start)
		if tag_end == -1:
			out += text.substr(search_from)
			break

		out += text.substr(search_from, tag_start - search_from)
		var inner: String = text.substr(content_start, tag_end - content_start)
		out += "[color=%s]%s[/color]" % [color, inner]
		search_from = tag_end + 1

	return out
