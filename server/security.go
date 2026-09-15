package main

// 服务端安全策略（重构文档.md §4 / docs/PROTOCOL.md §6）。
//
// 这是"服务器权威"的第一道闸门：在客户端尚未接入 v2 权威协议之前，先把现有 v1
// 转发路径按三条已确认的策略加固：
//
//	1. 服务器专属消息：客户端发来一律**丢弃 + 记日志**（不转发、不执行）
//	   对应漏洞：任意房内成员伪造 disconnect/notify 秒杀对手、伪造 game/end 直接判胜
//	2. 房主专属消息：game/start 只允许房主发送
//	   对应漏洞：任意成员重定义整局（牌组 / 英雄 / 行动顺序 / 棋盘布局）
//	3. 身份字段重写：payload 里的 player_id / uuid 一律改写为**发送连接的真实 uuid**
//	   对应漏洞：action/end_turn 携带他人 player_id 冒充其结束回合
//	4. 限速：每连接 20 条/秒，超限丢弃 + 记日志
//
// 其余消息（room/*、action/*、大厅自定义类型）的行为**完全不变**。

import (
	"encoding/json"
	"log"
	"os"
	"strings"
	"time"
)

// 每连接每秒允许的消息数；超限丢弃，不主动断开连接。
const rateLimitPerSec = 20

// 权威进程（Godot headless 权威服务器）的连接标识。
//   role=authority 的连接：不限速、不做身份重写/房主校验 —— 它是可信服务器侧，
//   且它下发的 auth/* 载荷里会合法携带"某个玩家"的字段（重写会破坏它）。
// 注册需要 NSOC_AUTHORITY_KEY 与 payload.key 一致；**未配置 key 时禁用注册**
// （默认安全：任何人都不能自称权威）。
const authorityRole = "authority"

// authorityKey 由 main() 从环境变量 NSOC_AUTHORITY_KEY 读入；测试可直接赋值。
var authorityKey = ""

// loadAuthorityKey 读环境变量（部署时设置）。
func loadAuthorityKey() string {
	authorityKey = strings.TrimSpace(os.Getenv("NSOC_AUTHORITY_KEY"))
	return authorityKey
}

func isAuthority(c *Client) bool {
	return c != nil && c.role == authorityRole
}

// isIdleAuthority：已通过密钥校验、但还没挂到任何房间的权威连接（可被派单）。
func isIdleAuthority(c *Client) bool {
	return isAuthority(c) && c.authorityOK && c.roomID == ""
}

// serverOnlyMessageTypes 只允许服务器产生的消息类型。
// 客户端发来这些类型时一律丢弃 —— 它们要么是服务器的推送，要么会直接改动权威状态。
var serverOnlyMessageTypes = map[string]bool{
	// 会改变对局/房间权威状态的消息
	"game/end":          true, // 判胜广播（原漏洞：伪造即判自己赢，且服务器会销毁房间）
	"disconnect/notify": true, // 断线通知（原漏洞：伪造即让所有端替受害者执行 damage_hero(100)）
	// 服务器推送的房间状态（客户端从不发送）
	"room/create_ok":      true,
	"room/create_failed":  true,
	"room/joined":         true,
	"room/join_rejected":  true,
	"room/left":           true,
	"room/list_response":  true,
	"room/config_updated": true,
	"room/expired":        true,
	"room/destroy":        true,
	"auth/rejected":       true,
}

// serverOnlyMessageType 判断 type 是否只允许服务器产生。
// 除显式列表外，整个 "auth/" 前缀（v2 权威下行消息）也属服务器专属。
func serverOnlyMessageType(t string) bool {
	if strings.HasPrefix(t, "auth/") {
		return true
	}
	return serverOnlyMessageTypes[t]
}

// identityKeys 是 payload 中可能被伪造的身份字段。
// 只改写"本来就存在"的键，不新增字段；值一律改为发送连接的真实 uuid。
var identityKeys = []string{"player_id", "uuid"}

// rewriteIdentityFields 把 payload 里的身份字段改写为发送连接的真实 uuid。
// 非对象载荷 / 解析失败时原样返回（不因为脏载荷丢弃整条消息）。
func rewriteIdentityFields(payload json.RawMessage, senderUUID string) json.RawMessage {
	if len(payload) == 0 || senderUUID == "" {
		return payload
	}
	var obj map[string]any
	if err := json.Unmarshal(payload, &obj); err != nil {
		return payload
	}
	changed := false
	for _, k := range identityKeys {
		v, ok := obj[k]
		if !ok {
			continue
		}
		if s, isStr := v.(string); isStr && s == senderUUID {
			continue
		}
		obj[k] = senderUUID
		changed = true
	}
	if !changed {
		return payload
	}
	out, err := json.Marshal(obj)
	if err != nil {
		return payload
	}
	return json.RawMessage(out)
}

// allowRate 每连接限速：滚动 1 秒窗口内不超过 rateLimitPerSec 条。
// 权威连接不限速（它要广播全场事件）。
// 只在 Hub 单 goroutine 内调用，因此无需加锁。
func (h *Hub) allowRate(c *Client) bool {
	if isAuthority(c) {
		return true
	}
	now := time.Now()
	if c.rateWindowStart.IsZero() || now.Sub(c.rateWindowStart) >= time.Second {
		c.rateWindowStart = now
		c.rateWindowCount = 0
	}
	c.rateWindowCount++
	if c.rateWindowCount > rateLimitPerSec {
		c.droppedMessages++
		log.Printf("SECURITY rate-limited uuid=%s count=%d/s limit=%d", c.uuid, c.rateWindowCount, rateLimitPerSec)
		return false
	}
	return true
}
