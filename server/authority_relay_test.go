package main

// 权威进程与中继的对接测试（v2 权威链路；见 hub.handleAuthorityJoin）。
//
// 覆盖：
//   - 注册门槛：非 authority 角色 / 错误 key / 未配置 key → 拒绝；正确 key → 挂到房间
//   - 意图路由：房间有权威时 intent/*、client/* **只发给权威**（不进 P2P 广播）
//   - 权威下行：auth/* 按 `to` 路由（"" = 全员广播，pid = 只发该玩家）
//   - 身份不被重写：权威载荷里的 player_id 保持原样（它合法地代表某个玩家）
//   - 断线清理：权威断开后房间不再有权威，意图退回原转发行为

import (
	"encoding/json"
	"testing"
	"time"
)

func newAuthorityClient(h *Hub, uuid string) *Client {
	c := newTestClient(h, uuid)
	c.role = authorityRole
	c.send = make(chan []byte, 64)
	h.clients[uuid] = c   // 生产环境由 register 完成；测试直接登记
	return c
}

func joinAuthority(t *testing.T, h *Hub, c *Client, roomID, key string) Message {
	t.Helper()
	payload, _ := json.Marshal(map[string]any{"room_id": roomID, "key": key})
	h.route(inboundMsg{client: c, msg: &Message{Type: "room/authority_join",
		From: c.uuid, Payload: payload}})
	msgs := drain(c)
	if len(msgs) == 0 {
		t.Fatalf("权威注册没有任何回执")
	}
	return msgs[len(msgs)-1]
}

func TestAuthorityJoinRequiresKey(t *testing.T) {
	old := authorityKey
	defer func() { authorityKey = old }()

	h, host, _, room := newTestRoom(t)
	auth := newAuthorityClient(h, "uuid-auth")

	// ① 未配置 key：一律拒绝
	authorityKey = ""
	msg := joinAuthority(t, h, auth, room.ID, "whatever")
	if msg.Type != "authority/rejected" || room.AuthorityUUID != "" {
		t.Fatalf("未配置 key 时应拒绝，got %s / %q", msg.Type, room.AuthorityUUID)
	}

	// ② 配置了 key 但客户端给错
	authorityKey = "secret"
	msg = joinAuthority(t, h, auth, room.ID, "wrong")
	if msg.Type != "authority/rejected" || room.AuthorityUUID != "" {
		t.Fatalf("错误 key 应拒绝，got %s / %q", msg.Type, room.AuthorityUUID)
	}
	if auth.forgedMessages != 2 {
		t.Fatalf("两次非法注册应计入 forgedMessages，got %d", auth.forgedMessages)
	}

	// ③ 角色不是 authority 的连接即使 key 正确也拒绝
	player := newTestClient(h, "uuid-plain")
	payload, _ := json.Marshal(map[string]any{"room_id": room.ID, "key": "secret"})
	h.route(inboundMsg{client: player, msg: &Message{Type: "room/authority_join",
		From: player.uuid, Payload: payload}})
	msgs := drain(player)
	if len(msgs) == 0 || msgs[0].Type != "authority/rejected" {
		t.Fatalf("非 authority 角色应被拒绝，got %+v", msgs)
	}

	// ④ 正确 key：注册成功并拿到名单
	msg = joinAuthority(t, h, auth, room.ID, "secret")
	if msg.Type != "authority/joined" {
		t.Fatalf("正确 key 应注册成功，got %s %+v", msg.Type, msg)
	}
	if room.AuthorityUUID != auth.uuid {
		t.Fatalf("房间未记录权威 uuid: %q", room.AuthorityUUID)
	}
	_ = host
}

func TestIntentGoesOnlyToAuthority(t *testing.T) {
	old := authorityKey
	authorityKey = "secret"
	defer func() { authorityKey = old }()

	h, host, guest, room := newTestRoom(t)
	auth := newAuthorityClient(h, "uuid-auth")
	if msg := joinAuthority(t, h, auth, room.ID, "secret"); msg.Type != "authority/joined" {
		t.Fatalf("注册失败: %s", msg.Type)
	}
	drain(host)
	drain(guest)
	drain(auth)

	// 客户端发意图：只有权威收到，对手收不到（不泄漏、也不 P2P 结算）
	send(h, guest, "intent/end_turn", `{"seq": 1}`)
	if n := len(drain(auth)); n != 1 {
		t.Fatalf("权威应收到 1 条意图，got %d", n)
	}
	if n := len(drain(host)); n != 0 {
		t.Fatalf("对手不应收到意图，got %d", n)
	}
	if n := len(drain(guest)); n != 0 {
		t.Fatalf("意图不应回投给发送者，got %d", n)
	}

	// v1 的 action/* 仍走原转发（迁移期两套并存）：广播给房间全员（含发送者）
	send(h, guest, "action/play_card", `{"card_id":"c1"}`)
	if n := len(drain(host)); n != 1 {
		t.Fatalf("action/* 应保持原转发行为，host got %d", n)
	}
	if n := len(drain(guest)); n != 1 {
		t.Fatalf("action/* 广播应含发送者，guest got %d", n)
	}

	// 权威下行：to = 具体玩家
	authMsg := &Message{Type: "auth/state", To: "uuid-host", From: auth.uuid,
		Payload: jsonRaw(map[string]any{"turn": 1})}
	h.route(inboundMsg{client: auth, msg: authMsg})
	hostMsgs := drain(host)
	if len(hostMsgs) != 1 || hostMsgs[0].Type != "auth/state" {
		t.Fatalf("auth/state 未定向到 host: %+v", hostMsgs)
	}
	if n := len(drain(guest)); n != 0 {
		t.Fatalf("定向 auth 不应发给他人，got %d", n)
	}

	// 权威下行：to = "" → 广播给所有玩家
	h.route(inboundMsg{client: auth, msg: &Message{Type: "auth/event", From: auth.uuid,
		Payload: jsonRaw(map[string]any{"event": "turn_started"})}})
	if n := len(drain(host)); n != 1 {
		t.Fatalf("广播 auth/event 应到达 host，got %d", n)
	}
	if n := len(drain(guest)); n != 1 {
		t.Fatalf("广播 auth/event 应到达 guest，got %d", n)
	}
}

func TestAuthorityPayloadIdentityNotRewritten(t *testing.T) {
	old := authorityKey
	authorityKey = "secret"
	defer func() { authorityKey = old }()

	h, host, _, room := newTestRoom(t)
	auth := newAuthorityClient(h, "uuid-auth")
	joinAuthority(t, h, auth, room.ID, "secret")
	drain(host)

	// 权威载荷里合法携带 player_id=uuid-host：不得被改写成权威自己的 uuid
	h.route(inboundMsg{client: auth, msg: &Message{Type: "auth/event", To: "uuid-host",
		From: auth.uuid, Payload: jsonRaw(map[string]any{"player_id": "uuid-host"})}})
	msgs := drain(host)
	if len(msgs) != 1 {
		t.Fatalf("host 应收到 1 条，got %d", len(msgs))
	}
	var got map[string]any
	if err := json.Unmarshal(msgs[0].Payload, &got); err != nil {
		t.Fatalf("payload 解析失败: %v", err)
	}
	if got["player_id"] != "uuid-host" {
		t.Fatalf("权威载荷的身份字段被重写: %v", got["player_id"])
	}
}

func TestAuthorityDisconnectClearsRoom(t *testing.T) {
	old := authorityKey
	authorityKey = "secret"
	defer func() { authorityKey = old }()

	h, host, guest, room := newTestRoom(t)
	auth := newAuthorityClient(h, "uuid-auth")
	joinAuthority(t, h, auth, room.ID, "secret")
	if room.AuthorityUUID != auth.uuid {
		t.Fatal("未注册")
	}

	// 模拟权威断线（handleDisconnect 会走 unregister 路径）
	h.handleDisconnect(auth)
	if room.AuthorityUUID != "" {
		t.Fatalf("权威断线后应清空注册，got %q", room.AuthorityUUID)
	}

	// 之后意图退回原转发行为（对局仍可用 v1 继续）
	drain(host)
	drain(guest)
	send(h, guest, "intent/end_turn", `{"seq": 2}`)
	if n := len(drain(host)); n != 1 {
		t.Fatalf("无权威时意图应按原行为转发给房间，host got %d", n)
	}
}

func TestAuthorityNotRateLimited(t *testing.T) {
	old := authorityKey
	authorityKey = "secret"
	defer func() { authorityKey = old }()

	h, host, _, room := newTestRoom(t)
	auth := newAuthorityClient(h, "uuid-auth")
	joinAuthority(t, h, auth, room.ID, "secret")
	drain(host)

	// 权威连发 3 倍限速阈值的事件（广播），不得被丢弃
	for i := 0; i < rateLimitPerSec*3; i++ {
		h.route(inboundMsg{client: auth, msg: &Message{Type: "auth/event", From: auth.uuid,
			Payload: jsonRaw(map[string]any{"event": "tick", "n": i})}})
	}
	if auth.droppedMessages != 0 {
		t.Fatalf("权威不应被限速，dropped=%d", auth.droppedMessages)
	}
	deadline := time.Now()
	_ = deadline
	if n := len(drain(host)); n != rateLimitPerSec*3 {
		t.Fatalf("权威广播应全部送达，got %d", n)
	}
}
