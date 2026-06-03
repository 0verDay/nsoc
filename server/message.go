package main

// 消息基础结构。与 multiplay_dev_list_skills.md 8.6 对齐：
//   {
//     "type":    "msg_type",
//     "from":    "player_uuid",     // 服务器内部填充为发送方 uuid
//     "to":      "player_uuid|all|host",
//     "room_id": "12345",
//     "payload": {...}
//   }
//
// 服务器对 type 以 "room/" 开头的消息做处理（创建/加入/列表/离开），
// 其他类型按 to 字段直接转发到房间内对应客户端。
//
// 转发规则：
//   to == "all" 或空  → 房间所有人（含发送者）
//   to == "host"      → 房主
//   其他              → 按 uuid 精确匹配

import "encoding/json"

type Message struct {
	Type    string          `json:"type"`
	From    string          `json:"from,omitempty"`
	To      string          `json:"to,omitempty"`
	RoomID  string          `json:"room_id,omitempty"`
	Payload json.RawMessage `json:"payload,omitempty"`
}

// jsonRaw 把任意 go map / struct 编码为 json.RawMessage，方便填 Payload。
func jsonRaw(v any) json.RawMessage {
	b, _ := json.Marshal(v)
	return json.RawMessage(b)
}
