package main

// Room —— 内存中的房间状态。无持久化，重启即清空。

import (
	"math/rand"
	"time"
)

// RoomPlayer —— 暴露给客户端的玩家信息（不含 ws conn）。
type RoomPlayer struct {
	UUID     string `json:"uuid"`
	Nickname string `json:"nickname"`
	Slot     int    `json:"slot"`
}

type Room struct {
	ID         string
	HostUUID   string
	Players    []*Client
	Started    bool
	MatchType  string    // "1v1" / "1v3" / "3v3"（默认 "1v1"）
	MaxPlayers int       // 按 MatchType 决定：1v1=2, 1v3=4, 3v3=6
	CreatedAt  time.Time
	LastActive time.Time
}

func (r *Room) PlayerList() []RoomPlayer {
	out := make([]RoomPlayer, 0, len(r.Players))
	for i, c := range r.Players {
		out = append(out, RoomPlayer{UUID: c.uuid, Nickname: c.nickname, Slot: i})
	}
	return out
}

// MaxPlayersForType 按 match_type 返回最大玩家数
func MaxPlayersForType(matchType string) int {
	switch matchType {
	case "1v3":
		return 4
	case "3v3":
		return 6
	}
	return 2 // 默认 1v1
}

// generateRoomID 生成不与现存房间冲突的 5 位数字房号。
// 100 次冲突仍未找到则返回空串（理论概率极低，原型期不细化）。
func generateRoomID(rooms map[string]*Room) string {
	for tries := 0; tries < 100; tries++ {
		id := genID5()
		if _, exists := rooms[id]; !exists {
			return id
		}
	}
	return ""
}

func genID5() string {
	const digits = "0123456789"
	b := make([]byte, 5)
	for i := range b {
		b[i] = digits[rand.Intn(10)]
	}
	return string(b)
}

func init() {
	rand.Seed(time.Now().UnixNano())
}
