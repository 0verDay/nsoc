class_name NetProtocol
extends RefCounted

## 联机协议定义（重构文档.md §4.2）。
##
## 这是客户端与服务端**唯一**的协议真相来源：
##   - 上行只有"意图"（intent/*），客户端不上报任何结算结果
##   - 下行只有"权威结果"（auth/*），客户端只渲染
##
## 分层约束：本文件位于纯规则层（scripts/core/**），不得引用 UI / 场景树 /
## 反射 / 资源路径（由 tools/ci/check_layers.py 强制）。

## 协议版本：结构不兼容时必须递增，服务器据此拒绝旧客户端。
## v1 = 旧的"结果广播"协议（result_atk / game/end 等）
## v2 = 意图 + 权威结果协议（本文件）
const VERSION: int = 2

# ── 上行：客户端意图 ──────────────────────────────────────────────────────
const INTENT_PLAY_CARD := "intent/play_card"
const INTENT_PLAY_EQUIP := "intent/play_equip"
const INTENT_ACTIVATE_EQUIP := "intent/activate_equip"
const INTENT_ACTIVATE_HERO := "intent/activate_hero"
const INTENT_END_TURN := "intent/end_turn"
const INTENT_CROSS_BOARD := "intent/cross_board"
const INTENT_CHOICE := "intent/choice"
const INTENT_SURRENDER := "intent/surrender"

# ── 下行：权威结果 ────────────────────────────────────────────────────────
const AUTH_HELLO := "auth/hello"                 # 握手：协议版本 / 内容哈希 / 你的 slot
const AUTH_STATE := "auth/state"                 # 按玩家过滤的对局视图
const AUTH_EVENT := "auth/event"                 # 权威事件流（客户端据此播动画）
const AUTH_REQUEST_CHOICE := "auth/request_choice"  # 要求玩家做选择（取代 effect 里 await UI）
const AUTH_VERDICT := "auth/verdict"             # 胜负
const AUTH_REJECT := "auth/reject"               # 拒绝某个意图

# ── 拒绝原因（客户端据此回滚本地预览）────────────────────────────────────
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

# ── 权限分类 ──────────────────────────────────────────────────────────────
const _INTENT_TYPES: Array = [
	INTENT_PLAY_CARD, INTENT_PLAY_EQUIP, INTENT_ACTIVATE_EQUIP, INTENT_ACTIVATE_HERO,
	INTENT_END_TURN, INTENT_CROSS_BOARD, INTENT_CHOICE, INTENT_SURRENDER,
]

## 只能由服务器产生的消息。客户端发包时必须被服务器丢弃（对应漏洞：
## 伪造 disconnect/notify 秒杀对手、伪造 game/end 直接判胜）。
const _SERVER_ONLY_TYPES: Array = [
	AUTH_HELLO, AUTH_STATE, AUTH_EVENT, AUTH_REQUEST_CHOICE, AUTH_VERDICT, AUTH_REJECT,
	"disconnect/notify", "game/end", "game/start",
]

## 各意图必须携带的字段（值类型见 _check_field）。
const _REQUIRED_FIELDS: Dictionary = {
	INTENT_PLAY_CARD: {"card_name": TYPE_STRING, "seq": TYPE_INT},
	INTENT_PLAY_EQUIP: {"card_name": TYPE_STRING, "seq": TYPE_INT},
	INTENT_ACTIVATE_EQUIP: {"equip_name": TYPE_STRING, "seq": TYPE_INT},
	INTENT_ACTIVATE_HERO: {"ability_id": TYPE_STRING, "seq": TYPE_INT},
	INTENT_END_TURN: {"seq": TYPE_INT},
	INTENT_CROSS_BOARD: {"source_slot_id": TYPE_STRING, "target_slot_id": TYPE_STRING, "seq": TYPE_INT},
	INTENT_CHOICE: {"request_id": TYPE_STRING, "option_index": TYPE_INT, "seq": TYPE_INT},
	INTENT_SURRENDER: {"seq": TYPE_INT},
}


static func is_intent(type: String) -> bool:
	return type in _INTENT_TYPES


static func is_server_only(type: String) -> bool:
	return type in _SERVER_ONLY_TYPES


## 校验意图结构（只看"字段是否存在且类型正确"，不看规则合法性）。
## 返回 "" 表示通过，否则返回 NetProtocol.REJECT_* 原因。
static func validate_intent(type: String, payload: Dictionary) -> String:
	if not is_intent(type):
		return REJECT_UNKNOWN_TYPE
	var required: Dictionary = _REQUIRED_FIELDS.get(type, {})
	for field in required.keys():
		var want: int = int(required[field])
		if not payload.has(field):
			return REJECT_BAD_PAYLOAD
		if typeof(payload[field]) != want:
			return REJECT_BAD_PAYLOAD
	if payload.has("seq") and int(payload["seq"]) < 0:
		return REJECT_BAD_PAYLOAD
	return ""


## 客户端在发送前自检：避免把服务器专属 type 发出去。
static func client_may_send(type: String) -> bool:
	return is_intent(type) and not is_server_only(type)


## 服务器在处理入站消息时的判定：非意图、或属于服务器专属 type 一律不转发。
static func server_may_accept(type: String) -> bool:
	return is_intent(type)


## 内容哈希：用于握手校验两端内容一致（data/*.json）。
## 计算方式与文件顺序无关：按路径排序后逐个累加 sha256。
static func content_hash(files: Dictionary) -> String:
	var keys: Array = []
	for k in files.keys():
		keys.append(String(k))
	keys.sort()
	var acc: String = "nsoc-content-v1"
	for k in keys:
		acc += "|" + k + ":" + String(files[k]).sha256_text()
	return acc.sha256_text()
