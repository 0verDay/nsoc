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
- `uuid`：客户端本地随机生成、保存于 `user://profile.json`，必填；缺失时服务器回
  `auth/rejected{reason:"missing_uuid"}` 后断开
- `nickname`：玩家昵称，可空（缺省 "玩家"）

单条消息读取上限 64 KB（`conn.SetReadLimit(64*1024)`）；`CheckOrigin` 恒为 `true`，
即接受任意来源的连接（原型期无鉴权、无反作弊）。

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

`from` 由服务器自动覆盖为连接 uuid，客户端无需填写（防止伪造发送方）。

### 服务器处理的消息

服务器按 `type` **精确匹配**下列五个类型；`type` 以 `room/` 开头但不在表内的消息会走
转发逻辑，不做房间管理处理。

| type | 说明 | 响应 |
|---|---|---|
| `room/create` | 创建房间。payload 可选 `{match_type}`，缺省 `1v1`，并据此决定人数上限 | `room/create_ok`，顶层带 `room_id`，payload `{host_uuid, players, match_type, max_players}`；房间号重试耗尽时 `room/create_failed{reason:"id_collision"}` |
| `room/join` | 加入房间。payload `{room_id}` 或顶层 `room_id` 字段 | 房内广播 `room/joined{host_uuid, players, match_type, max_players}`；失败 `room/join_rejected{reason}`，`reason` ∈ `not_found` / `started` / `full`（`full` 时附 `max_players`） |
| `room/list` | 查询所有可加入房间（跳过 `started` 的房间） | `room/list_response{rooms: [{id, host_nickname, player_count, match_type, max_players}, ...]}` |
| `room/leave` | 主动离开（保留连接，仅退房）；走与断线相同的清理路径 | 房内广播 `room/left{uuid, nickname, new_host_uuid}`，房空自动销毁 |
| `room/update_config` | **仅房主**（`HostUUID == 发送者`）动态改模式；payload `{match_type}`，空值忽略 | 房内广播 `room/config_updated{match_type, max_players}` |

人数上限由 `match_type` 决定（`server/room.go` 的 `MaxPlayersForType`）：

| match_type | 人数上限 |
|---|---|
| `1v1`（缺省） | 2 |
| `1v3` | 4 |
| `3v3` | 6 |

未知 `match_type` 一律按 `1v1`（上限 2）处理。`players` 数组元素为
`{uuid, nickname, slot}`，`slot` 为加入顺序下标。

去重语义：同一连接重复 `room/join` 同一房间是幂等的（直接回 `room/joined`）；
相同 uuid 的**不同连接**按不同玩家处理，可共存于同一房间（便于同机多开测试）。

### 服务器转发的消息

不在上表中的 `type` 按 `to` 字段路由；发送者必须已在房间内，否则直接丢弃。

| `to` 字段 | 路由目标 |
|---|---|
| `all` 或空 | 房间所有人（含发送者） |
| `host` | 房主 |
| `<uuid>` | 精确匹配 |

特殊语义：

- `game/start` → 服务器标记房间 `started=true`（此后拒绝 `room/join`），消息照常转发
- `game/end`   → 转发后立即销毁房间

转发同时刷新房间 `LastActive`。目标客户端 `send` 队列（容量 32）满时**丢包并打印日志**，
不阻塞 Hub 主循环。

### 服务器主动推送

| type | 触发 |
|---|---|
| `disconnect/notify{uuid, dead_player_id, nickname, new_host_uuid}` | 房内任一客户端断线。`dead_player_id` 供客户端路由阵亡，`new_host_uuid` 为房主转让结果 |
| `room/expired` | 房间 60 分钟无活跃，强制销毁前推（同时清空玩家 `room_id`） |
| `auth/rejected{reason}` | 握手缺 uuid 等参数错误 |

断线者若是房主且房内仍有其他玩家，服务器随机把房主转让给其中一人，并把新 `host_uuid`
随 `disconnect/notify` 下发（与 `room/leave` 的 `room/left` 语义一致）；房空则直接销毁房间。

## 内存模型

```
rooms: map[string]*Room {
  ID, HostUUID, Players []*Client, Started, MatchType, MaxPlayers, CreatedAt, LastActive
}
clients: map[uuid]*Client
```

- 房间号：5 位纯数字，随机生成 + 冲突重试（最多 100 次）
- `rooms` / `clients` 的所有修改都发生在 `Hub.Run` 单 goroutine 内，其它 goroutine 通过
  `register` / `unregister` / `dispatch`（缓冲 256）投递事件，避免加锁
- 每分钟扫一次过期房间（60 分钟无活跃即销毁）
- 客户端 `send` 缓冲 32 条；断线关闭 channel 后并发的 `deliver` 由 `recover` 兜底，
  避免 `send on closed channel` panic 拖垮进程

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
- **无日志文件** — 仅打印关键事件到 stdout（部署时通常重定向到 `server.log`）
- **无心跳** — 仅靠 TCP 连接状态检测断线（未设置读超时，也未启用 ping/pong）
- **无版本检查** — 玩家自行保证客户端版本一致
- **不限房间数** — 原型期
- **不做反作弊** — 完全信任房主发来的状态；但 `from` 字段由服务器强制覆盖为连接 uuid
- **房号** — 5 位纯数字，服务器随机 + 冲突重试
- **房间生命周期** — 60 分钟无活跃自动销毁；`game/end` 后立即销毁
