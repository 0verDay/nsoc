extends ChapterPanelBase

# 长坂坡章节入口面板（重构文档.md §7 阶段 2）。
#
# 全部逻辑在 ChapterPanelBase；本文件只提供章节参数。
# 与 weizhenhuaxia.gd 原本是两份各 490 行、逐行只差 14 行的复制体，
# 现已收敛为基类 + 参数覆写。

const CHAPTER_NAME: String = "长坂坡"
const CONFIG_PATH: String = "res://data/chapters/changbanpo.json"


func chapter_name() -> String:
	return CHAPTER_NAME


func config_path() -> String:
	return CONFIG_PATH


func log_tag() -> String:
	return "Changbanpo"
