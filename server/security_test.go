package main

// 服务端安全策略测试（security.go）。
//
// 覆盖四条已确认策略：
//   ① 服务器专属消息 → 丢弃 + 记日志（不转发、不执行）
//   ② game/start 只允许房主
//   ③ payload 身份字段改写为真实连接 uuid
//   ④ 每连接 20 条/秒限速
// 并回归验证普通业务消息（action/*、room/ready_update 等）行为不变。

import (
	"encoding/json"
	"testing"
	"time"
)

func newTestClient(h *Hub, uuid string) *Client {
	return &Client{
		hub:      h,
		uuid:     uuid,
		nickname: uuid,
		send:     make(chan []byte, 64),
	}
}

// newTestRoom 构造 hub + 房主/成员双人房间（1v1）。
func newTestRoom(t *testing.T) (*Hub, *Client, *Client, *Room) {
	t.Helper()
	h := NewHub()
	host := newTestClient(h, "uuid-host")
	guest := newTestClient(h, "uuid-guest")
	h.clients[host.uuid] = host
	h.clients[guest.uuid] = guest
	now := time.Now()
	room := &Room{
		ID:         "12345",
		HostUUID:   host.uuid,
		Players:    []*Client{host, guest},
		MatchType:  "1v1",
		MaxPlayers: 2,
		CreatedAt:  now,
		LastActive: now,
	}
	h.rooms[room.ID] = room
	host.roomID = room.ID
	guest.roomID = room.ID
	return h, host, guest, room
}

func send(h *Hub, c *Client, msgType string, payload string) {
	sendTo(h, c, "all", msgType, payload)
}

func sendTo(h *Hub, c *Client, to string, msgType string, payload string) {
	msg := &Message{Type: msgType, From: c.uuid, To: to}
	if payload != "" {
		msg.Payload = json.RawMessage(payload)
	}
	h.route(inboundMsg{client: c, msg: msg})
}

// drain 取出该客户端 send 队列中的全部消息。
func drain(c *Client) []Message {
	var out []Message
	for {
		select {
		case data := <-c.send:
			var m Message
			if err := json.Unmarshal(data, &m); err != nil {
				continue
			}
			out = append(out, m)
		default:
			return out
		}
	}
}

// ---- ① 服务器专属消息 ----

func TestServerOnlyMessagesDropped(t *testing.T) {
	forged := []string{
		"game/end",
		"disconnect/notify",
		"room/joined",
		"room/left",
		"room/destroy",
		"room/config_updated",
		"auth/rejected",
		"auth/hello",
		"auth/state",
	}
	for _, msgType := range forged {
		h, host, guest, room := newTestRoom(t)
		send(h, guest, msgType, `{"dead_player_id":"uuid-host"}`)

		if n := len(drain(host)); n != 0 {
			t.Fatalf("%s: 伪造消息被转发到房主（收到 %d 条）", msgType, n)
		}
		if n := len(drain(guest)); n != 0 {
			t.Fatalf("%s: 伪造消息被回投给发送者", msgType)
		}
		if guest.forgedMessages != 1 {
			t.Fatalf("%s: forgedMessages = %d, want 1", msgType, guest.forgedMessages)
		}
		if host.forgedMessages != 0 {
			t.Fatalf("%s: 房主被误判为伪造", msgType)
		}
		if _, ok := h.rooms[room.ID]; !ok {
			t.Fatalf("%s: 房间被伪造消息销毁", msgType)
		}
	}
}

func TestGameEndCannotDestroyRoom(t *testing.T) {
	h, _, guest, room := newTestRoom(t)
	send(h, guest, "game/end", `{"winner":"uuid-guest"}`)
	if _, ok := h.rooms[room.ID]; !ok {
		t.Fatal("伪造 game/end 销毁了房间")
	}
	if room.Started {
		t.Fatal("伪造 game/end 改变了房间状态")
	}
}

func TestDisconnectNotifyCannotKillHost(t *testing.T) {
	h, host, guest, _ := newTestRoom(t)
	send(h, guest, "disconnect/notify", `{"dead_player_id":"uuid-host"}`)
	if got := drain(host); len(got) != 0 {
		t.Fatalf("伪造 disconnect/notify 到达房主：%+v", got)
	}
}

// ---- ② game/start 房主专属 ----

func TestNonHostGameStartDropped(t *testing.T) {
	h, host, guest, room := newTestRoom(t)
	send(h, guest, "game/start", `{"seed":1}`)
	if room.Started {
		t.Fatal("非房主的 game/start 把房间标记为已开始")
	}
	if got := drain(host); len(got) != 0 {
		t.Fatalf("非房主的 game/start 被转发：%+v", got)
	}
	if guest.forgedMessages != 1 {
		t.Fatalf("forgedMessages = %d, want 1", guest.forgedMessages)
	}
	_ = h
}

func TestHostGameStartForwarded(t *testing.T) {
	h, host, guest, room := newTestRoom(t)
	send(h, host, "game/start", `{"seed":1}`)
	if !room.Started {
		t.Fatal("房主的 game/start 未标记房间已开始")
	}
	got := drain(guest)
	if len(got) != 1 || got[0].Type != "game/start" {
		t.Fatalf("房主 game/start 未转发给成员：%+v", got)
	}
	if got[0].From != host.uuid {
		t.Fatalf("from = %q, want %q", got[0].From, host.uuid)
	}
	if host.forgedMessages != 0 {
		t.Fatalf("房主被误判为伪造：%d", host.forgedMessages)
	}
	_ = h
}

// ---- ③ 身份字段重写 ----

func TestIdentityFieldsRewritten(t *testing.T) {
	cases := []struct {
		name    string
		msgType string
		payload string
		checks  map[string]string
	}{
		{
			name:    "end_turn 冒充他人",
			msgType: "action/end_turn",
			payload: `{"player_id":"uuid-host","uuid":"uuid-host"}`,
			checks:  map[string]string{"player_id": "uuid-guest", "uuid": "uuid-guest"},
		},
		{
			name:    "deck_reshuffle 冒充他人",
			msgType: "action/deck_reshuffle",
			payload: `{"player_id":"uuid-host","new_deck":["a"]}`,
			checks:  map[string]string{"player_id": "uuid-guest"},
		},
		{
			name:    "ready_update 冒充他人",
			msgType: "room/ready_update",
			payload: `{"uuid":"uuid-host","ready":true}`,
			checks:  map[string]string{"uuid": "uuid-guest"},
		},
		{
			name:    "本就正确则原样",
			msgType: "action/end_turn",
			payload: `{"player_id":"uuid-guest"}`,
			checks:  map[string]string{"player_id": "uuid-guest"},
		},
		{
			name:    "无身份字段不新增",
			msgType: "action/play_card",
			payload: `{"card_id":"c1","target":"t1"}`,
			checks:  map[string]string{},
		},
	}
	for _, tc := range cases {
		t.Run(tc.name, func(t *testing.T) {
			h, host, guest, _ := newTestRoom(t)
			send(h, guest, tc.msgType, tc.payload)
			got := drain(host)
			if len(got) != 1 {
				t.Fatalf("房主收到 %d 条消息，want 1", len(got))
			}
			var obj map[string]any
			if err := json.Unmarshal(got[0].Payload, &obj); err != nil {
				t.Fatalf("payload 解析失败: %v", err)
			}
			for k, want := range tc.checks {
				if obj[k] != want {
					t.Fatalf("payload[%s] = %v, want %s", k, obj[k], want)
				}
			}
			if tc.msgType == "action/play_card" {
				for _, k := range identityKeys {
					if _, ok := obj[k]; ok {
						t.Fatalf("play_card payload 被新增身份字段 %s", k)
					}
				}
			}
			if got[0].From != guest.uuid {
				t.Fatalf("顶层 from = %q, want %q", got[0].From, guest.uuid)
			}
			_ = h
		})
	}
}

func TestIdentityRewriteIgnoresNonObjectPayload(t *testing.T) {
	for _, payload := range []string{`[1,2,3]`, `"plain"`, `42`} {
		got := rewriteIdentityFields(json.RawMessage(payload), "uuid-guest")
		if string(got) != payload {
			t.Fatalf("非对象载荷被改动：%s -> %s", payload, got)
		}
	}
	if got := rewriteIdentityFields(nil, "uuid-guest"); got != nil {
		t.Fatalf("空载荷被改动：%v", got)
	}
}

// ---- ④ 限速 ----

func TestRateLimitDropsBeyondQuota(t *testing.T) {
	h, _, guest, _ := newTestRoom(t)
	for i := 0; i < rateLimitPerSec; i++ {
		send(h, guest, "action/ping", `{}`)
	}
	if guest.droppedMessages != 0 {
		t.Fatalf("配额内被丢弃 %d 条", guest.droppedMessages)
	}
	send(h, guest, "action/ping", `{}`)
	if guest.droppedMessages != 1 {
		t.Fatalf("第 %d 条未被限速丢弃", rateLimitPerSec+1)
	}
	if guest.rateWindowCount != rateLimitPerSec+1 {
		t.Fatalf("rateWindowCount = %d, want %d", guest.rateWindowCount, rateLimitPerSec+1)
	}
}

func TestRateLimitWindowResets(t *testing.T) {
	h, host, guest, _ := newTestRoom(t)
	for i := 0; i < rateLimitPerSec+3; i++ {
		send(h, guest, "action/ping", `{}`)
	}
	if guest.droppedMessages != 3 {
		t.Fatalf("droppedMessages = %d, want 3", guest.droppedMessages)
	}
	drain(host)
	// 模拟窗口滚动：把窗口起点拨回 2 秒前
	guest.rateWindowStart = time.Now().Add(-2 * time.Second)
	send(h, guest, "action/ping", `{}`)
	if guest.droppedMessages != 3 {
		t.Fatalf("窗口滚动后仍被限速：droppedMessages = %d", guest.droppedMessages)
	}
	if got := drain(host); len(got) != 1 {
		t.Fatalf("窗口滚动后的消息未转发：%d 条", len(got))
	}
	if guest.rateWindowCount != 1 {
		t.Fatalf("窗口未重置：rateWindowCount = %d", guest.rateWindowCount)
	}
}

func TestRateLimitPerConnection(t *testing.T) {
	h, host, guest, _ := newTestRoom(t)
	for i := 0; i < rateLimitPerSec+5; i++ {
		send(h, guest, "action/ping", `{}`)
	}
	if guest.droppedMessages == 0 {
		t.Fatal("超限连接未被限速")
	}
	// 房主自己的配额不受成员影响
	for i := 0; i < rateLimitPerSec; i++ {
		send(h, host, "action/ping", `{}`)
	}
	if host.droppedMessages != 0 {
		t.Fatalf("房主配额被他人影响：droppedMessages = %d", host.droppedMessages)
	}
}

// ---- 回归：普通消息行为不变 ----

func TestNormalMessagesForwardedUnchanged(t *testing.T) {
	h, host, guest, room := newTestRoom(t)

	// 广播
	send(h, guest, "action/play_card", `{"card_id":"c1"}`)
	got := drain(host)
	if len(got) != 1 || got[0].Type != "action/play_card" {
		t.Fatalf("广播失败：%+v", got)
	}
	if len(drain(guest)) != 1 {
		t.Fatal("广播未包含发送者自身（原行为是全员投递）")
	}

	// 定向到房主（客户端 room/deck_ready 带 to=host）
	sendTo(h, guest, "host", "room/deck_ready", `{"uuid":"uuid-guest","hero_key":"h1"}`)
	got = drain(host)
	if len(got) != 1 || got[0].Type != "room/deck_ready" {
		t.Fatalf("定向转发失败：%+v", got)
	}
	if len(drain(guest)) != 0 {
		t.Fatal("定向消息被错误广播")
	}

	if room.LastActive.IsZero() {
		t.Fatal("LastActive 未刷新")
	}
	if h.rooms[room.ID].Started {
		t.Fatal("普通消息改变了 Started")
	}
}
