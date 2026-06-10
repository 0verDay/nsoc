package main

// Hub —— 中央调度循环。所有共享状态（rooms / clients）只在 Hub.Run 单 goroutine 内修改，
// 其他 goroutine 通过 chan 投递事件，避免锁。
//
// 主要职责：
//   1. 客户端注册 / 注销
//   2. 房间管理（创建 / 加入 / 列表 / 离开）
//   3. 业务消息路由（按 to 字段转发到对应 client）
//   4. 60 分钟过期房间清理

import (
	"encoding/json"
	"log"
	"math/rand"
	"time"
)

type inboundMsg struct {
	client *Client
	msg    *Message
}

type Hub struct {
	rooms      map[string]*Room
	clients    map[string]*Client // uuid -> client
	register   chan *Client
	unregister chan *Client
	dispatch   chan inboundMsg
}

func NewHub() *Hub {
	return &Hub{
		rooms:      map[string]*Room{},
		clients:    map[string]*Client{},
		register:   make(chan *Client),
		unregister: make(chan *Client),
		dispatch:   make(chan inboundMsg, 256),
	}
}

func (h *Hub) Run() {
	cleanup := time.NewTicker(60 * time.Second)
	defer cleanup.Stop()
	for {
		select {
		case c := <-h.register:
			h.clients[c.uuid] = c
			log.Printf("connect uuid=%s nickname=%s", c.uuid, c.nickname)
		case c := <-h.unregister:
			h.handleDisconnect(c)
		case in := <-h.dispatch:
			h.route(in)
		case <-cleanup.C:
			h.cleanupExpired()
		}
	}
}

// handleDisconnect 客户端断线：从房间移除 + 通知房内其他人。
// 决策 8.7：服务器立即广播 disconnect/notify 给同房间其他玩家，
// 房主收到后对掉线 slot 调用 damage_hero(100, "triggered") 走标准阵亡流程。
func (h *Hub) handleDisconnect(c *Client) {
	// 按指针比对：同 uuid 不同连接各自独立处理，避免 UUID 冲突时误删另一连接。
	if stored, ok := h.clients[c.uuid]; ok && stored == c {
		delete(h.clients, c.uuid)
	}
	// 安全关闭 send channel（deliver 有 recover，双重保护）
	_safeSendClose(c.send)
	log.Printf("disconnect uuid=%s", c.uuid)
	if c.roomID == "" {
		return
	}
	room, ok := h.rooms[c.roomID]
	if !ok {
		return
	}
	// 按指针移除（允许同 uuid 多连接共存于同一房间）
	for i, p := range room.Players {
		if p == c {
			room.Players = append(room.Players[:i], room.Players[i+1:]...)
			break
		}
	}

	// 若断线的是房主且房间仍有其他玩家，随机转让房主
	newHostUUID := room.HostUUID
	if room.HostUUID == c.uuid && len(room.Players) > 0 {
		newHost := room.Players[rand.Intn(len(room.Players))]
		room.HostUUID = newHost.uuid
		newHostUUID = newHost.uuid
	}

	notify := &Message{
		Type:   "disconnect/notify",
		RoomID: room.ID,
		Payload: jsonRaw(map[string]any{
			"uuid":           c.uuid,
			"dead_player_id": c.uuid,   // 客户端按此字段路由阵亡
			"nickname":       c.nickname,
			"new_host_uuid":  newHostUUID,
		}),
	}
	h.broadcast(room, notify, "")
	if len(room.Players) == 0 {
		delete(h.rooms, room.ID)
		log.Printf("room %s destroyed (empty)", room.ID)
	}
}

// _safeSendClose 安全关闭 channel，防止 double-close panic。
func _safeSendClose(ch chan []byte) {
	defer func() { recover() }()
	close(ch)
}

func (h *Hub) route(in inboundMsg) {
	msg := in.msg
	c := in.client
	switch msg.Type {
	case "room/create":
		h.handleCreate(c, msg)
	case "room/join":
		h.handleJoin(c, msg)
	case "room/list":
		h.handleList(c, msg)
	case "room/leave":
		h.handleLeave(c, msg)
	case "room/update_config":
		h.handleUpdateConfig(c, msg)
	default:
		h.forward(c, msg)
	}
}

func (h *Hub) handleCreate(c *Client, msg *Message) {
	var payload struct {
		MatchType string `json:"match_type"`
	}
	_ = json.Unmarshal(msg.Payload, &payload)
	matchType := payload.MatchType
	if matchType == "" {
		matchType = "1v1"
	}
	id := generateRoomID(h.rooms)
	if id == "" {
		c.push(&Message{
			Type:    "room/create_failed",
			Payload: jsonRaw(map[string]any{"reason": "id_collision"}),
		})
		return
	}
	room := &Room{
		ID:         id,
		HostUUID:   c.uuid,
		Players:    []*Client{c},
		MatchType:  matchType,
		MaxPlayers: MaxPlayersForType(matchType),
		CreatedAt:  time.Now(),
		LastActive: time.Now(),
	}
	h.rooms[id] = room
	c.roomID = id
	c.push(&Message{
		Type:   "room/create_ok",
		RoomID: id,
		Payload: jsonRaw(map[string]any{
			"host_uuid":   c.uuid,
			"players":     room.PlayerList(),
			"match_type":  matchType,
			"max_players": room.MaxPlayers,
		}),
	})
	log.Printf("room %s created by %s match_type=%s", id, c.uuid, matchType)
}

func (h *Hub) handleJoin(c *Client, msg *Message) {
	var p struct {
		RoomID string `json:"room_id"`
	}
	_ = json.Unmarshal(msg.Payload, &p)
	rid := p.RoomID
	if rid == "" {
		rid = msg.RoomID
	}
	room, ok := h.rooms[rid]
	if !ok {
		c.push(&Message{
			Type:    "room/join_rejected",
			Payload: jsonRaw(map[string]any{"reason": "not_found"}),
		})
		return
	}
	if room.Started {
		c.push(&Message{
			Type:    "room/join_rejected",
			Payload: jsonRaw(map[string]any{"reason": "started"}),
		})
		return
	}
	// 人数上限：按房间当前 MaxPlayers 限制（0 = 不限制，兼容旧房间）
	if room.MaxPlayers > 0 && len(room.Players) >= room.MaxPlayers {
		c.push(&Message{
			Type:    "room/join_rejected",
			Payload: jsonRaw(map[string]any{"reason": "full", "max_players": room.MaxPlayers}),
		})
		return
	}
	// 按连接指针去重（允许同 UUID 的不同连接作为不同玩家加入，支持同机测试）
	for _, existing := range room.Players {
		if existing == c {
			// 同一连接已在房内，幂等回 joined
			c.push(&Message{
				Type:   "room/joined",
				RoomID: rid,
				Payload: jsonRaw(map[string]any{
					"host_uuid":   room.HostUUID,
					"players":     room.PlayerList(),
					"match_type":  room.MatchType,
					"max_players": room.MaxPlayers,
				}),
			})
			return
		}
	}
	room.Players = append(room.Players, c)
	c.roomID = rid
	room.LastActive = time.Now()
	payload := map[string]any{
		"host_uuid":   room.HostUUID,
		"players":     room.PlayerList(),
		"match_type":  room.MatchType,
		"max_players": room.MaxPlayers,
	}
	h.broadcast(room, &Message{
		Type:    "room/joined",
		RoomID:  rid,
		Payload: jsonRaw(payload),
	}, "")
	log.Printf("client %s joined room %s (now %d players)", c.uuid, rid, len(room.Players))
}

func (h *Hub) handleLeave(c *Client, _ *Message) {
	if c.roomID == "" {
		return
	}
	// 主动离开走与断线相同的清理路径，但保留 client 注册（不关闭连接）。
	room, ok := h.rooms[c.roomID]
	if !ok {
		c.roomID = ""
		return
	}
	for i, p := range room.Players {
		if p.uuid == c.uuid {
			room.Players = append(room.Players[:i], room.Players[i+1:]...)
			break
		}
	}
	old := c.roomID
	c.roomID = ""

	// 若离开的是房主且房间仍有其他玩家，随机转让房主
	newHostUUID := room.HostUUID
	if room.HostUUID == c.uuid && len(room.Players) > 0 {
		newHost := room.Players[rand.Intn(len(room.Players))]
		room.HostUUID = newHost.uuid
		newHostUUID = newHost.uuid
	}

	h.broadcast(room, &Message{
		Type:   "room/left",
		RoomID: old,
		Payload: jsonRaw(map[string]any{
			"uuid":          c.uuid,
			"nickname":      c.nickname,
			"new_host_uuid": newHostUUID,
		}),
	}, "")
	if len(room.Players) == 0 {
		delete(h.rooms, old)
		log.Printf("room %s destroyed (empty after leave)", old)
	}
}

func (h *Hub) handleList(c *Client, _ *Message) {
	list := make([]map[string]any, 0, len(h.rooms))
	for _, r := range h.rooms {
		if r.Started {
			continue
		}
		hostNickname := ""
		for _, p := range r.Players {
			if p.uuid == r.HostUUID {
				hostNickname = p.nickname
				break
			}
		}
		list = append(list, map[string]any{
			"id":            r.ID,
			"host_nickname": hostNickname,
			"player_count":  len(r.Players),
			"match_type":    r.MatchType,
			"max_players":   r.MaxPlayers,
		})
	}
	c.push(&Message{
		Type:    "room/list_response",
		Payload: jsonRaw(map[string]any{"rooms": list}),
	})
}

// handleUpdateConfig 房主动态更新房间模式与人数上限。
// 仅房主（HostUUID == c.uuid）可操作；更新后广播 room/config_updated 给全员。
func (h *Hub) handleUpdateConfig(c *Client, msg *Message) {
	if c.roomID == "" {
		return
	}
	room, ok := h.rooms[c.roomID]
	if !ok || room.HostUUID != c.uuid {
		return
	}
	var payload struct {
		MatchType string `json:"match_type"`
	}
	_ = json.Unmarshal(msg.Payload, &payload)
	if payload.MatchType == "" {
		return
	}
	room.MatchType  = payload.MatchType
	room.MaxPlayers = MaxPlayersForType(payload.MatchType)
	log.Printf("room %s config updated: match_type=%s max_players=%d", room.ID, room.MatchType, room.MaxPlayers)
	// 广播给房内全员（含房主自己），让所有人刷新 UI
	h.broadcast(room, &Message{
		Type:   "room/config_updated",
		RoomID: room.ID,
		Payload: jsonRaw(map[string]any{
			"match_type":  room.MatchType,
			"max_players": room.MaxPlayers,
		}),
	}, "")
}

// forward 业务消息转发。
//   - 不在房间内的客户端发的消息直接丢弃
//   - game/start 标记房间为 Started（拒新玩家加入）
//   - game/end 广播后销毁房间（决策 1.1：战斗结算后销毁）
//   - 其他按 to 字段路由：all/空 = 全员；host = 房主；其他 = 精确 uuid
func (h *Hub) forward(c *Client, msg *Message) {
	if c.roomID == "" {
		return
	}
	room, ok := h.rooms[c.roomID]
	if !ok {
		return
	}
	room.LastActive = time.Now()
	if msg.Type == "game/start" {
		room.Started = true
	}
	if msg.Type == "game/end" {
		h.broadcast(room, msg, "")
		delete(h.rooms, room.ID)
		log.Printf("room %s destroyed (game/end)", room.ID)
		return
	}
	// from 已在 readLoop 填好
	data, _ := json.Marshal(msg)
	target := msg.To
	switch target {
	case "all", "":
		for _, p := range room.Players {
			h.deliver(p, data)
		}
	case "host":
		for _, p := range room.Players {
			if p.uuid == room.HostUUID {
				h.deliver(p, data)
				break
			}
		}
	default:
		for _, p := range room.Players {
			if p.uuid == target {
				h.deliver(p, data)
				break
			}
		}
	}
}

func (h *Hub) deliver(p *Client, data []byte) {
	defer func() {
		if r := recover(); r != nil {
			log.Printf("deliver: recovered panic for %s: %v", p.uuid, r)
		}
	}()
	select {
	case p.send <- data:
	default:
		log.Printf("send queue full for %s, drop", p.uuid)
	}
}

func (h *Hub) broadcast(room *Room, msg *Message, exceptUUID string) {
	data, _ := json.Marshal(msg)
	for _, p := range room.Players {
		if p.uuid == exceptUUID {
			continue
		}
		h.deliver(p, data)
	}
}

// cleanupExpired 销毁 60 分钟无活跃的房间。
// 房间内仍有玩家时也强制销毁，先推送 room/expired 让客户端切回主菜单。
func (h *Hub) cleanupExpired() {
	now := time.Now()
	for id, r := range h.rooms {
		if now.Sub(r.LastActive) > 60*time.Minute {
			for _, p := range r.Players {
				p.push(&Message{Type: "room/expired", RoomID: id})
				p.roomID = ""
			}
			delete(h.rooms, id)
			log.Printf("room %s destroyed (expired)", id)
		}
	}
}
