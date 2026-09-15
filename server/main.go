package main

// nsoc 多人联机中继服务器。
//
// 启动：
//   cd server
//   go mod tidy        # 拉依赖（首次）
//   go run .           # 默认 :8080
//
// 自定义端口：
//   set PORT=9000 && go run .       (cmd)
//   $env:PORT="9000"; go run .       (PowerShell)
//
// 健康检查：
//   curl http://localhost:8080/health
//
// WebSocket 端点：
//   ws://localhost:8080/ws?uuid=<uuid>&nickname=<nick>
//
// 决策（multiplay_dev_list_skills.md 1.1 / 1.4）：
//   - 不持久化、无日志（除关键事件 stdout）、无心跳、无版本检查
//   - 房号 5 位数字、冲突重试
//   - 60 分钟闲置销毁
//   - 战斗启动后拒新玩家加入

import (
	"log"
	"net/http"
	"os"
)

func main() {
	// 权威进程注册密钥（环境变量 NSOC_AUTHORITY_KEY）；未设置时**禁用**权威注册
	// （默认安全：任何客户端都不能自称权威）。详见 security.go / hub.handleAuthorityJoin。
	if k := loadAuthorityKey(); k == "" {
		log.Printf("NSOC_AUTHORITY_KEY not set: authority registration disabled")
	} else {
		log.Printf("authority registration enabled (key length=%d)", len(k))
	}

	hub := NewHub()
	go hub.Run()

	mux := http.NewServeMux()
	mux.HandleFunc("/ws", func(w http.ResponseWriter, r *http.Request) {
		ServeWS(hub, w, r)
	})
	mux.HandleFunc("/health", func(w http.ResponseWriter, r *http.Request) {
		w.Write([]byte("ok"))
	})

	addr := ":" + getenv("PORT", "8080")
	log.Printf("nsoc server listening on %s", addr)
	if err := http.ListenAndServe(addr, mux); err != nil {
		log.Fatal(err)
	}
}

func getenv(key, fallback string) string {
	if v := os.Getenv(key); v != "" {
		return v
	}
	return fallback
}
