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

# 客户端控制消息（非意图，但仍由客户端上行）：
#   握手 —— 上报协议版本与内容哈希，服务器据此拒绝不兼容的客户端。
const CLIENT_HELLO := "client/hello"
const CLIENT_PING := "client/ping"

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
const REJECT_PROTOCOL_MISMATCH := "protocol_mismatch"
const REJECT_NOT_HANDSHAKEN := "not_handshaken"

# ── 权限分类 ──────────────────────────────────────────────────────────────
const _INTENT_TYPES: Array = [
	INTENT_PLAY_CARD, INTENT_PLAY_EQUIP, INTENT_ACTIVATE_EQUIP, INTENT_ACTIVATE_HERO,
	INTENT_END_TURN, INTENT_CROSS_BOARD, INTENT_CHOICE, INTENT_SURRENDER,
]

## 客户端可上行的控制消息（不是意图，但不属于"服务器专属"）。
const _CLIENT_CONTROL_TYPES: Array = [CLIENT_HELLO, CLIENT_PING]

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


## 客户端可上行的控制消息（握手 / 心跳）。
static func is_client_control(type: String) -> bool:
	return type in _CLIENT_CONTROL_TYPES


## 校验意图结构（只看"字段是否存在且类型正确"，不看规则合法性）。
## 返回 "" 表示通过，否则返回 NetProtocol.REJECT_* 原因。
##
## 注意：**JSON 没有整数类型** —— 走网络的意图里 `seq`/`row`/`col` 回来都是浮点。
## 因此整数字段接受"整数值的浮点"（3.0 可以，3.5 不行）；否则真实客户端的意图
## 会被一律判 `bad_payload`（离线单测用原生 int，发现不了这一点 —— 端到端联调才发现）。
static func validate_intent(type: String, payload: Dictionary) -> String:
	if not is_intent(type):
		return REJECT_UNKNOWN_TYPE
	var required: Dictionary = _REQUIRED_FIELDS.get(type, {})
	for field in required.keys():
		var want: int = int(required[field])
		if not payload.has(field):
			return REJECT_BAD_PAYLOAD
		if not _field_matches(payload[field], want):
			return REJECT_BAD_PAYLOAD
	if payload.has("seq") and int(payload["seq"]) < 0:
		return REJECT_BAD_PAYLOAD
	return ""


## 单字段类型匹配：严格类型相等；整数字段额外接受整数值的浮点（JSON 往返）。
static func _field_matches(value, want: int) -> bool:
	if typeof(value) == want:
		return true
	if want == TYPE_INT and typeof(value) == TYPE_FLOAT:
		return is_equal_approx(float(value), roundf(float(value)))
	return false


## 客户端在发送前自检：避免把服务器专属 type 发出去。
static func client_may_send(type: String) -> bool:
	return (is_intent(type) or is_client_control(type)) and not is_server_only(type)


## 服务器在处理入站消息时的判定：服务器专属 type 一律拒绝；
## 其余只接受意图与客户端控制消息。
static func server_may_accept(type: String) -> bool:
	return not is_server_only(type) and (is_intent(type) or is_client_control(type))


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
