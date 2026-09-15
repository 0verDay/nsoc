class_name BattleMode
extends RefCounted

## 对局模式（重构文档.md §3.4-4）。
##
## 取代过去分散的隐式判断：`Game.is_pvp` 布尔 + `pending_*` 字符串 +
## `main.gd` 里临时推断的 `_is_campaign`。服务器将按此显式模式选择装配路径。
##
## 模式语义（与既有行为逐一对应，迁移期不得改变行为）：
##   CAMPAIGN  脚本化关卡：`pending_chapter_config` 或 `pending_level_path` 非空。
##             与 main.gd 既有的 `_is_campaign` 判断完全一致 —— 该模式下不接 AI，
##             牌堆来自章节 JSON（固定牌堆）。
##   SKIRMISH  自由对战 / 默认关卡：两个 pending 字段皆空，走默认关卡并接 AI。
##   EMPIRE    演义（帝国）出征：`pending_empire_battle` 非空；关卡在代码中合成，
##             结束后回写 `empire_battle_result`。
##   PVP       联机对战：由 `Game.bootstrap_pvp(...)` 装配，牌组/槽位由服务器下发。

enum Kind {
	CAMPAIGN = 0,
	SKIRMISH = 1,
	EMPIRE   = 2,
	PVP      = 3,
}

const NAMES: Dictionary = {
	Kind.CAMPAIGN: "campaign",
	Kind.SKIRMISH: "skirmish",
	Kind.EMPIRE:   "empire",
	Kind.PVP:      "pvp",
}


static func name_of(mode: int) -> String:
	return String(NAMES.get(mode, "unknown"))


static func is_valid(mode: int) -> bool:
	return NAMES.has(mode)


## 该模式默认是否接入敌方 AI（战役章节不接；PVP 由真人/服务器驱动）。
static func default_uses_ai(mode: int) -> bool:
	return mode == Kind.SKIRMISH or mode == Kind.EMPIRE


## 该模式是否由服务器权威驱动（阶段 1 的 BattleAuthority 只服务 PVP）。
static func is_authoritative(mode: int) -> bool:
	return mode == Kind.PVP


## 由 pending_* 输入派生模式（仅用于 PVE 侧；PVP 由 bootstrap_pvp 显式指定）。
static func from_pending(chapter_config: String, level_path: String, has_empire_ctx: bool) -> int:
	if has_empire_ctx:
		return Kind.EMPIRE
	if chapter_config != "" or level_path != "":
		return Kind.CAMPAIGN
	return Kind.SKIRMISH
