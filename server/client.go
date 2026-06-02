package main

// WebSocket 客户端封装。每个连接对应一个 Client：
//   - readLoop：读 ws 消息 → 反序列化 → 投递给 hub.dispatch
//   - writeLoop：从 send chan 取消息写回 ws
//
// 握手参数：客户端通过 query 传 uuid 与 nickname。
//   ws://host:8080/ws?uuid=<uuid>&nickname=<nick>
//
// 决策约定：
//   - 不做版本检查、不做心跳。TCP 断开即触发 unregister。
//   - 同一 uuid 重复连接不做去重（原型期，玩家自行保证）。

import (
	"encoding/json"
	"log"
	"net/http"

	"github.com/gorilla/websocket"
)

var upgrader = websocket.Upgrader{
	CheckOrigin: func(r *http.Request) bool { return true },
}

type Client struct {
	hub      *Hub
	conn     *websocket.Conn
	uuid     string
	nickname string
	roomID   string
	send     chan []byte
}

func (c *Client) readLoop() {
	defer func() {
		c.hub.unregister <- c
		c.conn.Close()
	}()
	c.conn.SetReadLimit(64 * 1024)
	for {
		_, data, err := c.conn.ReadMessage()
		if err != nil {
			return
		}
		var msg Message
		if err := json.Unmarshal(data, &msg); err != nil {
			log.Printf("invalid json from %s: %v", c.uuid, err)
			continue
		}
		// from 字段始终由服务器覆盖为真实连接 uuid，避免伪造
		msg.From = c.uuid
		c.hub.dispatch <- inboundMsg{client: c, msg: &msg}
	}
}

func (c *Client) writeLoop() {
	defer c.conn.Close()
	for data := range c.send {
		if err := c.conn.WriteMessage(websocket.TextMessage, data); err != nil {
			return
		}
	}
}

// push 把消息序列化后投递到该客户端 send 队列。
// send 队列满时（默认 32）丢弃最老消息（select default 分支），不阻塞 hub 主循环。
func (c *Client) push(msg *Message) {
	data, _ := json.Marshal(msg)
	select {
	case c.send <- data:
	default:
		// 队列满：客户端写阻塞或网络拥塞。原型期直接丢，关闭连接交给 readLoop 处理。
		log.Printf("client %s send queue full, dropping message %s", c.uuid, msg.Type)
	}
}

// ServeWS HTTP handler：升级为 WebSocket，注册到 hub。
func ServeWS(hub *Hub, w http.ResponseWriter, r *http.Request) {
	conn, err := upgrader.Upgrade(w, r, nil)
	if err != nil {
		log.Println("upgrade:", err)
		return
	}
	uuid := r.URL.Query().Get("uuid")
	nickname := r.URL.Query().Get("nickname")
	if uuid == "" {
		conn.WriteMessage(websocket.TextMessage, []byte(`{"type":"auth/rejected","payload":{"reason":"missing_uuid"}}`))
		conn.Close()
		return
	}
	if nickname == "" {
		nickname = "玩家"
	}
	client := &Client{
		hub:      hub,
		conn:     conn,
		uuid:     uuid,
		nickname: nickname,
		send:     make(chan []byte, 32),
	}
	hub.register <- client
	go client.writeLoop()
	go client.readLoop()
}
