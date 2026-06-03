# nsoc 多人联机中继服务器

WebSocket 中继 + 房间列表服务。Go 实现。无持久化，重启即清空。

## 启动

```bash
cd server
go mod tidy        # 首次拉依赖
go run .           # 默认 :8080
```

自定义端口：

```bash
# Windows cmd
set PORT=9000 && go run .

# Windows PowerShell
$env:PORT="9000"; go run .
```

## 端点

| 路径 | 说明 |
|---|---|
| `GET /health` | 健康检查，返回 `ok` |
| `WS  /ws?uuid=<uuid>&nickname=<nick>` | WebSocket 业务通道 |

握手 query 参数：
- `uuid`：客户端本地随机生成、保存于 `user://profile.json`，必填
- `nickname`：玩家昵称，可空（缺省 "玩家"）

## 消息协议

JSON 文本协议。基础结构：

```json
{
  "type":    "room/create",
  "from":    "<uuid>",
  "to":      "all|host|<uuid>",
  "room_id": "12345",
  "payload": {}
}
```

`from` 由服务器自动覆盖为连接 uuid，客户端无需填写。

### 服务器处理的消息

| type | 说明 | 响应 |
|---|---|---|
| `room/create` | 创建房间 | `room/create_ok{room_id, host_uuid, players}` 或 `room/create_failed` |
| `room/join` | 加入房间。payload `{room_id}` 或顶层 `room_id` 字段 | 房内广播 `room/joined{host_uuid, players}`；失败 `room/join_rejected{reason: not_found|started}` |
| `room/list` | 查询所有可加入房间 | `room/list_response{rooms: [{id, host_nickname, player_count}, ...]}` |
| `room/leave` | 主动离开 | 房内广播 `room/left{uuid, nickname}`，房空自动销毁 |

### 服务器转发的消息

`type` 不以 `room/` 开头时按 `to` 字段路由：

| `to` 字段 | 路由目标 |
|---|---|
| `all` 或空 | 房间所有人（含发送者） |
| `host` | 房主 |
| `<uuid>` | 精确匹配 |

特殊语义：

- `game/start` → 服务器标记房间 `started=true`，拒后续 join
- `game/end`   → 转发后销毁房间

### 服务器主动推送

| type | 触发 |
|---|---|
| `disconnect/notify{uuid, nickname}` | 房内任一客户端断线 |
| `room/expired` | 房间 60 分钟无活跃，强制销毁前推 |
| `auth/rejected{reason}` | 握手缺 uuid 等参数错误 |

## 内存模型

```
rooms: map[string]*Room {
  ID, HostUUID, Players[*Client], Started, CreatedAt, LastActive
}
clients: map[uuid]*Client
```

每分钟扫一次过期房间。

## 调试

```bash
# 测试连接
go run .

# 另一个终端：用 wscat 试试（npm i -g wscat）
wscat -c "ws://localhost:8080/ws?uuid=test1&nickname=alice"
> {"type":"room/create"}
< {"type":"room/create_ok","room_id":"12345",...}

wscat -c "ws://localhost:8080/ws?uuid=test2&nickname=bob"
> {"type":"room/join","payload":{"room_id":"12345"}}
< {"type":"room/joined",...}
```

## 决策约束（来自 multiplay_dev_list_skills.md 1.1 / 1.4）

- **不持久化** — 重启清空所有房间
- **无日志** — 仅打印关键事件到 stdout
- **无心跳** — 仅靠 TCP 连接状态检测断线
- **无版本检查** — 玩家自行保证客户端版本一致
- **不限房间数** — 原型期
- **不做反作弊** — 完全信任房主发来的状态
- **房号** — 5 位纯数字，服务器随机 + 冲突重试
- **房间生命周期** — 60 分钟无活跃自动销毁；`game/end` 后立即销毁
