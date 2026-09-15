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

// ── 派单：待命权威 + 房主请求权威模式 + 开局配置交给权威 ─────────────────────

func readyAuthority(t *testing.T, h *Hub, uuid, key string) *Client {
	t.Helper()
	c := newAuthorityClient(h, uuid)
	payload, _ := json.Marshal(map[string]any{"key": key})   // 不带 room_id = 待命
	h.route(inboundMsg{client: c, msg: &Message{Type: "room/authority_join",
		From: c.uuid, Payload: payload}})
	msgs := drain(c)
	if len(msgs) == 0 || msgs[len(msgs)-1].Type != "authority/ready" {
		t.Fatalf("待命注册应回 authority/ready，got %+v", msgs)
	}
	return c
}

func TestIdleAuthorityGetsAssignedOnCreate(t *testing.T) {
	old := authorityKey
	authorityKey = "secret"
	defer func() { authorityKey = old }()

	h := NewHub()
	auth := readyAuthority(t, h, "uuid-auth", "secret")
	if !isIdleAuthority(auth) {
		t.Fatal("待命权威应处于 idle 状态")
	}

	// 房主请求权威模式建房
	host := newTestClient(h, "uuid-host")
	h.clients[host.uuid] = host
	payload, _ := json.Marshal(map[string]any{"match_type": "1v1", "authoritative": true})
	h.route(inboundMsg{client: host, msg: &Message{Type: "room/create",
		From: host.uuid, Payload: payload}})

	hostMsgs := drain(host)
	if len(hostMsgs) == 0 || hostMsgs[0].Type != "room/create_ok" {
		t.Fatalf("房主应收到 room/create_ok，got %+v", hostMsgs)
	}
	var ok map[string]any
	_ = json.Unmarshal(hostMsgs[0].Payload, &ok)
	if ok["authoritative"] != true {
		t.Fatalf("有待命权威时应回 authoritative=true，got %v", ok)
	}
	roomID := hostMsgs[0].RoomID

	// 权威应收到派单
	authMsgs := drain(auth)
	if len(authMsgs) != 1 || authMsgs[0].Type != "authority/host_room" {
		t.Fatalf("权威应收到 authority/host_room，got %+v", authMsgs)
	}
	var hostRoom map[string]any
	_ = json.Unmarshal(authMsgs[0].Payload, &hostRoom)
	if hostRoom["room_id"] != roomID || hostRoom["host_uuid"] != "uuid-host" {
		t.Fatalf("派单载荷不正确: %v", hostRoom)
	}
	if room := h.rooms[roomID]; room == nil || room.AuthorityUUID != auth.uuid {
		t.Fatalf("房间未记录权威: %+v", h.rooms[roomID])
	}
	if !isAuthority(auth) || auth.roomID != roomID {
		t.Fatalf("权威应已挂到房间: roomID=%q", auth.roomID)
	}
}

func TestCreateFallsBackWhenNoAuthority(t *testing.T) {
	old := authorityKey
	authorityKey = "secret"
	defer func() { authorityKey = old }()

	h := NewHub()
	host := newTestClient(h, "uuid-host")
	h.clients[host.uuid] = host
	payload, _ := json.Marshal(map[string]any{"match_type": "1v1", "authoritative": true})
	h.route(inboundMsg{client: host, msg: &Message{Type: "room/create",
		From: host.uuid, Payload: payload}})

	msgs := drain(host)
	var ok map[string]any
	_ = json.Unmarshal(msgs[0].Payload, &ok)
	if ok["authoritative"] != false {
		t.Fatalf("没有待命权威时应回 authoritative=false（客户端退回 v1），got %v", ok)
	}
	if room := h.rooms[msgs[0].RoomID]; room == nil || room.AuthorityUUID != "" {
		t.Fatalf("不应记录权威: %+v", h.rooms[msgs[0].RoomID])
	}
}

func TestStartMatchGoesOnlyToAuthority(t *testing.T) {
	old := authorityKey
	authorityKey = "secret"
	defer func() { authorityKey = old }()

	h, host, guest, room := newTestRoom(t)
	auth := newAuthorityClient(h, "uuid-auth")
	joinAuthority(t, h, auth, room.ID, "secret")
	drain(host)
	drain(guest)
	drain(auth)

	// 房主把开局配置交给权威：只到权威，不进 P2P 广播
	send(h, host, "authority/start_match", `{"players":["uuid-host","uuid-guest"],"decks":{}}`)
	authMsgs := drain(auth)
	if len(authMsgs) != 1 || authMsgs[0].Type != "authority/start_match" {
		t.Fatalf("开局配置应只到权威，got %+v", authMsgs)
	}
	if n := len(drain(guest)); n != 0 {
		t.Fatalf("开局配置不应广播给其他玩家，got %d", n)
	}

	// 无权威时 authority/* 退回原转发（至少不崩、房主拿不到权威回执）
	h.handleDisconnect(auth)
	drain(host)
	send(h, host, "authority/start_match", `{}`)
	if n := len(drain(host)); n > 1 {
		t.Fatalf("无权威时不应异常放大投递，got %d", n)
	}
	_ = room
}

func TestIdleAuthorityBadKeyRejected(t *testing.T) {
	old := authorityKey
	authorityKey = "secret"
	defer func() { authorityKey = old }()

	h := NewHub()
	c := newAuthorityClient(h, "uuid-auth")
	payload, _ := json.Marshal(map[string]any{"key": "wrong"})
	h.route(inboundMsg{client: c, msg: &Message{Type: "room/authority_join",
		From: c.uuid, Payload: payload}})
	msgs := drain(c)
	if len(msgs) == 0 || msgs[0].Type != "authority/rejected" {
		t.Fatalf("错误密钥应拒绝，got %+v", msgs)
	}
	if c.authorityOK || isIdleAuthority(c) {
		t.Fatal("被拒的权威不得进入待命池")
	}
}

// ── 权威回待命：一个权威进程必须能服务多局 ──────────────────────────────────
//
// 历史缺陷：派单把 c.roomID 钉在房间上，而房间销毁只清"玩家"的 roomID，
// 于是权威永远不再是 idle —— 表现为"一个权威进程只能服务一局"，
// 之后所有 authoritative 建房静默退回 v1。
//
// 另外 GDScript 侧 AuthorityMain 只认 c.roomID，房间销毁时若中继不通知它，
// 它自己也不知道该复位。因此两条路径都要覆盖：中继主动释放 + 权威主动交还。

// createAuthoritativeRoom 用新客户端建一个权威模式房间，返回房号与 authoritative 字段。
func createAuthoritativeRoom(t *testing.T, h *Hub, uuid string) (string, bool) {
	t.Helper()
	host := newTestClient(h, uuid)
	h.clients[uuid] = host
	payload, _ := json.Marshal(map[string]any{"match_type": "1v1", "authoritative": true})
	h.route(inboundMsg{client: host, msg: &Message{Type: "room/create",
		From: uuid, Payload: payload}})
	msgs := drain(host)
	if len(msgs) == 0 || msgs[0].Type != "room/create_ok" {
		t.Fatalf("建房应回 room/create_ok，got %+v", msgs)
	}
	var ok map[string]any
	_ = json.Unmarshal(msgs[0].Payload, &ok)
	authoritative, _ := ok["authoritative"].(bool)
	return msgs[0].RoomID, authoritative
}

func TestAuthorityReturnsToStandbyAfterRoomDestroyed(t *testing.T) {
	old := authorityKey
	authorityKey = "secret"
	defer func() { authorityKey = old }()

	h := NewHub()
	auth := readyAuthority(t, h, "uuid-auth", "secret")

	roomID, authoritative := createAuthoritativeRoom(t, h, "uuid-host")
	if !authoritative {
		t.Fatal("第一个房间应拿到待命权威")
	}
	drain(auth)
	if auth.roomID != roomID || isIdleAuthority(auth) {
		t.Fatalf("派单后权威应占用该房间: roomID=%q", auth.roomID)
	}

	// 玩家退房 → 房间空 → 销毁。权威必须被释放回待命。
	send(h, h.clients["uuid-host"], "room/leave", "")
	if h.rooms[roomID] != nil {
		t.Fatalf("玩家退房后房间应销毁，got %+v", h.rooms[roomID])
	}
	if auth.roomID != "" || !isIdleAuthority(auth) {
		t.Fatalf("房间销毁后权威应回待命: roomID=%q idle=%v", auth.roomID, isIdleAuthority(auth))
	}
	relMsgs := drain(auth)
	if len(relMsgs) == 0 || relMsgs[0].Type != "authority/released" {
		t.Fatalf("权威应收到 authority/released，got %+v", relMsgs)
	}

	// 关键判定：同一个权威进程必须能直接服务第二局（这就是"一局一重启"的根治点）
	roomID2, authoritative2 := createAuthoritativeRoom(t, h, "uuid-host2")
	if !authoritative2 {
		t.Fatal("第二个房间仍应拿到同一个待命权威（缺陷回归）")
	}
	if auth.roomID != roomID2 {
		t.Fatalf("权威应被派到第二局: roomID=%q want=%q", auth.roomID, roomID2)
	}
}

func TestAuthorityReleaseOnRequest(t *testing.T) {
	old := authorityKey
	authorityKey = "secret"
	defer func() { authorityKey = old }()

	h := NewHub()
	auth := readyAuthority(t, h, "uuid-auth", "secret")
	roomID, _ := createAuthoritativeRoom(t, h, "uuid-host")
	drain(auth)

	// 权威自己判定对局已结束，主动交还房间（此时玩家还没退房、房间还在）
	send(h, auth, "room/authority_release", `{"room_id":"`+roomID+`"}`)

	relMsgs := drain(auth)
	if len(relMsgs) == 0 || relMsgs[0].Type != "authority/released" {
		t.Fatalf("主动交还应回 authority/released，got %+v", relMsgs)
	}
	if room := h.rooms[roomID]; room != nil && room.AuthorityUUID != "" {
		t.Fatalf("房间不应再记录权威: %q", room.AuthorityUUID)
	}
	if auth.roomID != "" || !isIdleAuthority(auth) {
		t.Fatalf("交还后应回待命: roomID=%q idle=%v", auth.roomID, isIdleAuthority(auth))
	}

	// 交还后立刻能接下一局
	roomID2, authoritative2 := createAuthoritativeRoom(t, h, "uuid-host2")
	if !authoritative2 || auth.roomID != roomID2 {
		t.Fatalf("交还后应能直接服务下一局: authoritative=%v roomID=%q", authoritative2, auth.roomID)
	}

	// 幂等：已是待命时重复交还不报错，并再确认一次 ready
	drain(auth)
	send(h, auth, "room/authority_release", `{}`)   // 交还第二局
	first := drain(auth)
	if len(first) == 0 || first[0].Type != "authority/released" {
		t.Fatalf("交还第二局应回 authority/released，got %+v", first)
	}
	send(h, auth, "room/authority_release", `{}`)   // 此时已是待命，重复调用
	again := drain(auth)
	if len(again) == 0 || again[0].Type != "authority/ready" {
		t.Fatalf("重复交还应幂等回 authority/ready，got %+v", again)
	}
}

func TestPlayerCannotReleaseAuthority(t *testing.T) {
	old := authorityKey
	authorityKey = "secret"
	defer func() { authorityKey = old }()

	h := NewHub()
	auth := readyAuthority(t, h, "uuid-auth", "secret")
	roomID, _ := createAuthoritativeRoom(t, h, "uuid-host")
	drain(auth)

	player := h.clients["uuid-host"]
	send(h, player, "room/authority_release", `{"room_id":"`+roomID+`"}`)

	if player.forgedMessages == 0 {
		t.Fatal("玩家伪造 authority_release 应被记为伪造消息")
	}
	if room := h.rooms[roomID]; room == nil || room.AuthorityUUID != auth.uuid {
		t.Fatalf("玩家的 authority_release 不得摘掉权威: %+v", h.rooms[roomID])
	}
	if !isAuthority(auth) || auth.roomID != roomID {
		t.Fatalf("权威应仍在房间上: roomID=%q", auth.roomID)
	}
}

