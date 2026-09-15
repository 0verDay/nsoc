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
	"strings"
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

	// 权威进程断线：清掉注册（房间仍在，但 v2 意图不再有裁决者；v1 路径不受影响）
	if room.AuthorityUUID == c.uuid {
		room.AuthorityUUID = ""
		log.Printf("authority left room=%s uuid=%s", room.ID, c.uuid)
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
		// 房间要销毁：把权威放回待命，否则它再也接不到下一局
		h.releaseAuthority(room, "room_empty")
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
	// ① 每连接限速（20 条/秒，超限丢弃 + 记日志，不断开连接）
	if !h.allowRate(c) {
		return
	}
	// ② 服务器专属消息：**玩家**发来一律丢弃 + 记日志（不转发、不执行）。
	//    权威连接例外 —— 它本身就是服务器侧，auth/* 正该由它下发。
	if !isAuthority(c) && serverOnlyMessageType(msg.Type) {
		c.forgedMessages++
		log.Printf("SECURITY drop forged server-only message type=%s uuid=%s", msg.Type, c.uuid)
		return
	}
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
	case "room/authority_join":
		h.handleAuthorityJoin(c, msg)
	case "room/authority_release":
		h.handleAuthorityRelease(c, msg)
	default:
		h.forward(c, msg)
	}
}

// handleAuthorityJoin 权威进程注册。
//
// 两种用法：
//  1. **待命**（room_id 为空）：只校验密钥，标记 authorityOK —— 之后可被派单；
//  2. **挂到指定房间**（room_id 非空）：校验密钥（已校验过则跳过）后接管该房间。
//
// 门槛：连接 role=authority **且** payload.key == NSOC_AUTHORITY_KEY（未配置 key 则一律拒绝）。
func (h *Hub) handleAuthorityJoin(c *Client, msg *Message) {
	var payload struct {
		RoomID string `json:"room_id"`
		Key    string `json:"key"`
	}
	_ = json.Unmarshal(msg.Payload, &payload)
	roomID := payload.RoomID
	if roomID == "" {
		roomID = c.roomID
	}
	if !isAuthority(c) {
		c.forgedMessages++
		log.Printf("SECURITY authority join rejected (role=%q) uuid=%s", c.role, c.uuid)
		c.push(&Message{Type: "authority/rejected",
			Payload: jsonRaw(map[string]any{"reason": "not_authority_role"})})
		return
	}
	if !c.authorityOK {
		if authorityKey == "" || payload.Key != authorityKey {
			c.forgedMessages++
			log.Printf("SECURITY authority join rejected (bad key) uuid=%s room=%s", c.uuid, roomID)
			c.push(&Message{Type: "authority/rejected",
				Payload: jsonRaw(map[string]any{"reason": "bad_key"})})
			return
		}
		c.authorityOK = true
	}
	// 待命：不挂房间，等 room/create{authoritative:true} 派单
	if roomID == "" {
		log.Printf("authority ready uuid=%s (waiting for assignment)", c.uuid)
		c.push(&Message{Type: "authority/ready", Payload: jsonRaw(map[string]any{})})
		return
	}
	room, ok := h.rooms[roomID]
	if !ok {
		c.push(&Message{Type: "authority/rejected",
			Payload: jsonRaw(map[string]any{"reason": "no_such_room"})})
		return
	}
	room.AuthorityUUID = c.uuid
	room.LastActive = time.Now()
	c.roomID = roomID
	roster := make([]string, 0, len(room.Players))
	for _, p := range room.Players {
		roster = append(roster, p.uuid)
	}
	log.Printf("authority joined room=%s uuid=%s players=%v", roomID, c.uuid, roster)
	c.push(&Message{Type: "authority/joined",
		Payload: jsonRaw(map[string]any{
			"room_id": roomID, "players": roster, "match_type": room.MatchType,
			"host_uuid": room.HostUUID,
		})})
}

// assignAuthority 给房间派一个待命权威（没有空闲权威时返回 false，调用方退回 P2P/v1）。
func (h *Hub) assignAuthority(room *Room) bool {
	if room == nil || room.AuthorityUUID != "" {
		return room != nil && room.AuthorityUUID != ""
	}
	roster := make([]string, 0, len(room.Players))
	for _, p := range room.Players {
		roster = append(roster, p.uuid)
	}
	for uuid, c := range h.clients {
		if !isIdleAuthority(c) {
			continue
		}
		room.AuthorityUUID = uuid
		c.roomID = room.ID
		log.Printf("authority assigned room=%s uuid=%s", room.ID, uuid)
		c.push(&Message{Type: "authority/host_room",
			Payload: jsonRaw(map[string]any{
				"room_id": room.ID, "match_type": room.MatchType,
				"players": roster, "host_uuid": room.HostUUID,
			})})
		return true
	}
	return false
}

// authorityOf 取房间当前的权威连接（未注册则 nil）。
func (h *Hub) authorityOf(room *Room) *Client {
	if room == nil || room.AuthorityUUID == "" {
		return nil
	}
	c, ok := h.clients[room.AuthorityUUID]
	if !ok {
		return nil
	}
	return c
}

// releaseAuthority 把房间的权威连接放回**待命**（房间即将销毁，或权威主动交还）。
//
// 为什么必须做：派单时会把权威连接的 c.roomID 钉在该房间上，而 isIdleAuthority
// 要求 roomID == ""。房间销毁时若不释放，这个权威进程就**永远**不再是待命状态，
// 之后所有 authoritative 建房都会静默退回 v1 —— 表现为"一个权威进程只能服务一局"。
//
// 房间已无权威、或权威连接已消失时是空操作。
func (h *Hub) releaseAuthority(room *Room, reason string) {
	if room == nil || room.AuthorityUUID == "" {
		return
	}
	uuid := room.AuthorityUUID
	room.AuthorityUUID = ""
	c, ok := h.clients[uuid]
	if !ok {
		return
	}
	c.roomID = ""
	log.Printf("authority released room=%s uuid=%s reason=%s", room.ID, uuid, reason)
	c.push(&Message{Type: "authority/released",
		Payload: jsonRaw(map[string]any{"room_id": room.ID, "reason": reason})})
}

// handleAuthorityRelease 权威**主动**交还房间（它自己判定对局已结束）。
//
// 典型场景：一局打完，客户端还没退房，但权威已经可以接下一局了。
// 只允许已通过密钥校验的权威连接调用；重复调用是幂等的。
func (h *Hub) handleAuthorityRelease(c *Client, _ *Message) {
	if !isAuthority(c) {
		c.forgedMessages++
		log.Printf("SECURITY authority release rejected (role=%q) uuid=%s", c.role, c.uuid)
		return
	}
	roomID := c.roomID
	if roomID == "" {
		// 已经是待命状态：再确认一次，方便客户端重连后自愈
		c.push(&Message{Type: "authority/ready", Payload: jsonRaw(map[string]any{})})
		return
	}
	if room, ok := h.rooms[roomID]; ok && room.AuthorityUUID == c.uuid {
		room.AuthorityUUID = ""
	}
	c.roomID = ""
	log.Printf("authority released room=%s uuid=%s reason=match_finished", roomID, c.uuid)
	c.push(&Message{Type: "authority/released",
		Payload: jsonRaw(map[string]any{"room_id": roomID, "reason": "match_finished"})})
}

func (h *Hub) handleCreate(c *Client, msg *Message) {
	var payload struct {
		MatchType string `json:"match_type"`
		// authoritative=true：房主想要"服务器权威"这一局。
		// 有**待命权威**时中继把房间派给它（房主随后用 authority/start_match 交配置）；
		// 没有待命权威时**静默退回 P2P/v1**（不让房主开不了局）。
		Authoritative bool `json:"authoritative"`
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
	// 房主想要权威模式 → 试着派一个待命权威（没有就如实告诉房主，客户端退回 v1）
	authoritative := false
	if payload.Authoritative {
		authoritative = h.assignAuthority(room)
		if !authoritative {
			log.Printf("room %s requested authoritative but no idle authority", id)
		}
	}
	c.push(&Message{
		Type:   "room/create_ok",
		RoomID: id,
		Payload: jsonRaw(map[string]any{
			"host_uuid":     c.uuid,
			"players":       room.PlayerList(),
			"match_type":    matchType,
			"max_players":   room.MaxPlayers,
			"authoritative": authoritative,
		}),
	})
	log.Printf("room %s created by %s match_type=%s authoritative=%v",
		id, c.uuid, matchType, authoritative)
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
		// 房间要销毁：把权威放回待命，否则它再也接不到下一局
		h.releaseAuthority(room, "room_empty_after_leave")
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
//   - game/start 只允许房主发送，否则丢弃 + 记日志；通过后标记房间 Started（拒新玩家加入）
//   - payload 中的身份字段（player_id / uuid）改写为发送连接的真实 uuid
//   - 其他按 to 字段路由：all/空 = 全员；host = 房主；其他 = 精确 uuid
//
// 注意：game/end 已在 route 阶段按"服务器专属消息"拦下，客户端无法再触发房间销毁；
// 房间由 room/leave、断线清理与房间过期回收。
func (h *Hub) forward(c *Client, msg *Message) {
	if c.roomID == "" {
		return
	}
	room, ok := h.rooms[c.roomID]
	if !ok {
		return
	}
	room.LastActive = time.Now()

	// 权威进程发来的 auth/*：按 `to` 路由给玩家（或广播）。不做身份重写、不做房主校验
	// —— 它是可信服务器侧，载荷里的 player_id 是合法的"某个玩家"。
	if isAuthority(c) {
		if strings.HasPrefix(msg.Type, "auth/") {
			h.routeToPlayers(room, msg, msg.To, nil)
		}
		return
	}

	if msg.Type == "game/start" {
		if room.HostUUID != c.uuid {
			c.forgedMessages++
			log.Printf("SECURITY drop non-host game/start uuid=%s host=%s", c.uuid, room.HostUUID)
			return
		}
		room.Started = true
	}

	// v2 意图与控制消息：房间有权威进程时**只发给权威**（不进 P2P 广播，
	// 避免对手提前看到意图 / 客户端自行结算）。未注册权威时保持原转发行为。
	// `authority/*`（如开局配置 authority/start_match）同样只交给权威。
	if authorityMsgType(msg.Type) || strings.HasPrefix(msg.Type, "authority/") {
		if auth := h.authorityOf(room); auth != nil {
			data, _ := json.Marshal(msg)
			h.deliver(auth, data)
			return
		}
	}

	// 身份字段一律以真实连接 uuid 为准（防止冒充他人结束回合 / 上报牌组）
	msg.Payload = rewriteIdentityFields(msg.Payload, c.uuid)
	// from 已在 readLoop 填好
	data, _ := json.Marshal(msg)
	h.routeToPlayers(room, msg, msg.To, data)
}

// authorityMsgType 判断该 type 是否属于"v2 上行、必须交给权威进程裁决"的消息。
func authorityMsgType(t string) bool {
	return strings.HasPrefix(t, "intent/") || strings.HasPrefix(t, "client/")
}

// routeToPlayers 按 `to` 把一条消息投递给房间玩家。
//   ""/"all" = 全员；"host" = 房主；其他 = 精确 uuid。
// data 为 nil 时按 msg 序列化（权威路径会复用同一序列化结果）。
func (h *Hub) routeToPlayers(room *Room, msg *Message, target string, data []byte) {
	if data == nil {
		data, _ = json.Marshal(msg)
	}
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
			// 权威不在 room.Players 里，必须单独释放（否则它永远是"占用中"）
			h.releaseAuthority(r, "room_expired")
			delete(h.rooms, id)
			log.Printf("room %s destroyed (expired)", id)
		}
	}
}
