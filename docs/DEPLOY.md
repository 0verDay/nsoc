# 部署与联调清单（服务器权威模式）

> 面向"把 NSOC 跑成服务器权威的一局"：一个 Go 中继 + 一个 Godot 权威进程 + 若干客户端。
> 代码侧的验收证据见 `重构文档.md` §11 与 `docs/PROTOCOL.md` §7（拓扑）。

## 1. 拓扑

```
玩家 A ─┐                                  ┌─ intent/* （只发给权威）
        ├─ Go 中继 :8080 （房间 / 转发） ─┤
玩家 B ─┘                                  └─ auth/*   （按 to 广播或定向）
                    ▲
                    │ room/authority_join（待命）/ authority/host_room（派单）
             Godot 权威进程（headless，跑同一套规则）
```

- 中继只做传输 + 安全策略（服务器专属消息丢弃、房主校验、身份重写、限速、权威派单）。
- 权威进程跑 `BattleServerSession` + `AuthorityBoard` + `BattleSimHost`：**只有它算规则**。
- 客户端默认走 v1（P2P 锁步）；只有**请求权威模式**且**有权威进程待命**时才走 v2。

## 2. 环境变量

| 变量 | 作用 | 谁需要 |
|---|---|---|
| `PORT` | 中继监听端口（默认 8080） | 中继 |
| `NSOC_AUTHORITY_KEY` | 权威注册密钥；**未设置则禁用权威注册**（任何客户端都不能自称权威） | 中继 **与** 权威进程（必须一致） |
| `NSOC_RELAY_HOST` / `NSOC_RELAY_PORT` | 权威进程连哪个中继（默认 127.0.0.1:8080） | 权威进程 |
| `NSOC_ROOM_ID` | 直接接管指定房间（**可选**；不设 = 待命，由中继派单） | 权威进程 |
| `NSOC_MATCH_CONFIG` | 指定开局配置 JSON（**可选**；不设 = 用内置默认，或等大厅的 `authority/start_match`） | 权威进程 |
| `NSOC_AUTHORITATIVE` | `1` = 建房时请求服务器权威（默认关闭） | **客户端** |
| `GOCACHE` / `GOMODCACHE` / `GOPROXY` | Go 构建缓存/代理（无管理员权限时指向可写目录；离线可用 `GOPROXY=off`） | 构建中继时 |

> ⚠️ `NSOC_AUTHORITY_KEY` 是**共享密钥**：泄露给玩家等于让任何人都能自称权威。公网部署请用随机长串，并且只给权威进程与中继。

## 3. 启动（Windows / PowerShell）

```powershell
# ① 构建中继（只需一次；离线环境把 GOPROXY 设成 off）
cd server
$env:GOCACHE="$env:TEMP\gocache"; $env:GOPATH="$env:TEMP\gopath"
$env:GOMODCACHE="$env:TEMP\gopath\pkg\mod"; $env:GOTMPDIR="$env:TEMP\gotmp"
go build -o nsoc-server.exe .

# ② 起中继（常驻）。密钥自定，务必与权威进程一致
$env:NSOC_AUTHORITY_KEY = "<随机长串>"
$env:PORT = "8080"
.\nsoc-server.exe            # 日志应出现: authority registration enabled (key length=..)

# ③ 起权威进程（常驻，headless，**不带 --room = 待命**）
$env:NSOC_AUTHORITY_KEY = "<随机长串>"       # 同一密钥
& "<Godot 控制台可执行文件>" --headless --path dev_gd/nsoc `
    res://server/AuthorityMain.tscn -- --host=127.0.0.1 --port=8080
# 日志应出现: [authority] ready, waiting for room assignment

# ④ 起客户端（每台机器一个实例；想走权威就设 NSOC_AUTHORITATIVE=1）
$env:NSOC_AUTHORITATIVE = "1"
& "<Godot 控制台可执行文件>" --path dev_gd/nsoc
```

Linux 等价：把 `$env:X` 换成 `export X=`，可执行文件换成对应平台的二进制；`--headless` 参数相同。

## 4. 一局怎么跑（验收步骤）

1. 客户端 A：主菜单 → 对战（联机）→ 我的房间 → 建房。**若中继日志出现**
   `authority assigned room=<房号>`，说明派单成功（否则见 §5）。
2. 客户端 B：加入房间（输入房号），双方准备。
3. 房主点开始。此时应看到：
   - 权威进程日志：`[authority] assigned room=<房号>` → `authority joined room=...` →（大厅配置到达后）`[authority] start_match players=[...]`；
   - 双方进入战斗；**任何出牌/结束回合/投降都由权威裁决**：权威日志出现 `[authority] intent/... from=<pid> accepted=true` 与 `tick 结算完成`；
   - 客户端盘面/手牌/费用/回合按钮都按 `auth/state` 显示（服务器给什么就画什么）。
4. 结束时：有人英雄阵亡 → 权威下发 `auth/verdict` → 双方看到结算画面。

**预期"权威确实在管事"的三条硬证据**：
- 中继日志里，玩家发的 `intent/*` **没有**在两名玩家之间互转（只在权威侧出现）；
- 权威日志里每次操作都有 `accepted=true/false`（`false` 会给出 `reason`，如 `not_your_turn`、`stale_seq`）；
- 客户端收到 `auth/event` 的 `board_action`（attack/death/move）与 `phase_resolved`。

## 5. 故障排查

| 现象 | 原因 | 处理 |
|---|---|---|
| 建房后立刻退回 v1（`authoritative=false`） | 中继没有"待命权威" | 确认权威进程已启动且日志有 `ready, waiting for room assignment`；确认它连的是同一中继 host/port |
| `authority/rejected {reason:"bad_key"}` | 两边 `NSOC_AUTHORITY_KEY` 不一致 | 统一密钥后重启两者 |
| `authority/rejected {reason:"no_such_room"}` | 用 `--room=` 指定了一个不存在的房号 | 去掉 `--room` 让它待命，或先建房再启动 |
| 客户端 `auth/reject {reason:"not_handshaken"}` | 握手发生在权威开局之前 | 正常流程会自动重握手；若持续出现，检查客户端 `Net.use_v2` 是否被打开 |
| 玩家之间仍能互相看到 `action/*` | 该局走的是 v1 | 这是"无权威时的降级"，符合预期；要 v2 请按 §3 起权威 |
| Godot 输出 `Failed to read the root certificate store` / `user://logs` | headless 环境无证书库 / 无 user 目录 | 无害噪音，可忽略 |
| 跨机连不上 | 端口/防火墙 | 放行 8080（或你设的 PORT）；公网建议放在反向代理后并启用 WSS |

## 6. 公网部署建议（可选）

- 中继与权威进程各起一个常驻服务（systemd / NSSM / 计划任务），崩溃自动重启；
- 只暴露中继端口；权威进程不需要对外端口（它是**主动连**中继的 WS 客户端）；
- 需要 WSS 时在 nginx/Caddy 终止 TLS，反代到 `127.0.0.1:8080/ws`；
- 客户端侧把服务器地址写进 `user://server.json`（见 `ProfileManager.get_server_config()`）。
