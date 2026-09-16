class_name NetProtocol
extends RefCounted

## 联机协议**常量表**（联机已移除，本文件降级保留）。
##
## ⚠️  本项目已转为**纯本地**（单机战役 + 自由对战 + 演义模式）。
##     中继服务端、权威裁判进程、客户端 WebSocket 传输层与协议校验逻辑已整体删除，
##     详见 `docs/archive/multiplayer-removal.md`。
##
## 为什么还留着这张表：
##   1. PVP 回合 / 队伍内核按决策保留为**死代码**，其中引用了下面这些消息名常量；
##   2. `tools/ci/build_release.ps1` 仍从本文件读取 `VERSION` 写进 `version.json`，
##      `tests/ContentHashTest` 仍用 `content_hash()` 校验构建侧与引擎实现一致。
##
## 已删除的东西（不再存在于本文件）：
##   * 意图结构校验（`validate_intent` / `_field_matches`）
##   * 权限分类（`is_intent` / `is_server_only` / `client_may_send` / `server_may_accept`）
##   * 以上函数依赖的 `_INTENT_TYPES` / `_CLIENT_CONTROL_TYPES` / `_SERVER_ONLY_TYPES`
##     / `_REQUIRED_FIELDS` 表
##   恢复联机时按归档清单从 git 历史取回。
##
## 分层约束：本文件位于纯规则层（scripts/core/**），不得引用 UI / 场景树 /
## 反射 / 资源路径（由 tools/ci/check_layers.py 强制）。

## 协议版本：结构不兼容时必须递增（构建侧据此写 version.json 的 PROTOCOL_VERSION）。
## v1 = 旧的"结果广播"协议（result_atk / game/end 等）
## v2 = 意图 + 权威结果协议
const VERSION: int = 2

# ── 上行：客户端意图（历史消息名，仅作常量留存）───────────────────────────
const INTENT_PLAY_CARD := "intent/play_card"
const INTENT_PLAY_EQUIP := "intent/play_equip"
const INTENT_ACTIVATE_EQUIP := "intent/activate_equip"
const INTENT_ACTIVATE_HERO := "intent/activate_hero"
const INTENT_END_TURN := "intent/end_turn"
const INTENT_CROSS_BOARD := "intent/cross_board"
const INTENT_CHOICE := "intent/choice"
const INTENT_SURRENDER := "intent/surrender"

# 客户端控制消息（历史消息名）：
const CLIENT_HELLO := "client/hello"
const CLIENT_PING := "client/ping"

# ── 下行：权威结果（历史消息名）─────────────────────────────────────────
const AUTH_HELLO := "auth/hello"                 # 握手：协议版本 / 内容哈希 / 你的 slot
const AUTH_STATE := "auth/state"                 # 按玩家过滤的对局视图
const AUTH_EVENT := "auth/event"                 # 权威事件流（客户端据此播动画）
const AUTH_REQUEST_CHOICE := "auth/request_choice"  # 要求玩家做选择
const AUTH_VERDICT := "auth/verdict"             # 胜负
const AUTH_REJECT := "auth/reject"               # 拒绝某个意图

# ── 拒绝原因（历史常量）────────────────────────────────────────────────
const REJECT_UNKNOWN_TYPE := "unknown_type"
const REJECT_BAD_PAYLOAD := "bad_payload"
const REJECT_UNKNOWN_PLAYER := "unknown_player"
const REJECT_MATCH_FINISHED := "match_finished"
const REJECT_STALE_SEQ := "stale_seq"
const REJECT_NOT_YOUR_TURN := "not_your_turn"
const REJECT_RATE_LIMITED := "rate_limited"
const REJECT_CARD_NOT_IN_HAND := "card_not_in_hand"
const REJECT_NOT_ENOUGH_MANA := "not_enough_mana"
const REJECT_ILLEGAL_TARGET := "illegal_target"
const REJECT_NOT_ALLOWED := "not_allowed"
const REJECT_PROTOCOL_MISMATCH := "protocol_mismatch"
const REJECT_NOT_HANDSHAKEN := "not_handshaken"


## 内容哈希：用于构建侧与引擎侧校验内容一致（data/*.json）。
## 计算方式与文件顺序无关：按路径排序后逐个累加 sha256。
## **仍在使用**：`tests/ContentHashTest` + `tools/ci/build_release.ps1` 两端比对。
static func content_hash(files: Dictionary) -> String:
	var keys: Array = []
	for k in files.keys():
		keys.append(String(k))
	keys.sort()
	var acc: String = "nsoc-content-v1"
	for k in keys:
		acc += "|" + k + ":" + String(files[k]).sha256_text()
	return acc.sha256_text()
