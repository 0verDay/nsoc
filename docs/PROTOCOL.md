# NSOC 联机协议（v2：意图 / 权威）

> 现行规范。定义文件：`dev_gd/nsoc/scripts/core/net/protocol.gd`（`NetProtocol`）。
> 服务端实现：`scripts/server/battle_authority.gd` + `scripts/server/server_session.gd`。
> 传输层：`server/`（Go WebSocket 中继）。最后更新：重构阶段 1 进行中。

## 1. 核心原则

**服务器是唯一规则执行者。** 客户端只做两件事：把玩家操作变成"意图"发给服务器；把服务器返回的
"权威结果"渲染出来。客户端**不再计算任何影响胜负的数值**，也不再上报结算结果。

因此 v2 协议里**不存在** `result_atk` / `result_health` / `result_cleared` 这类字段，
`game/end`、`disconnect/notify`、`game/start` 也不再由客户端发送。

## 2. 版本与握手

| 常量 | 含义 |
|---|---|
| `NetProtocol.VERSION = 2` | 协议版本；结构不兼容时递增，服务器据此拒绝旧客户端 |
| `content_hash` | `data/*.json` 的内容哈希（与文件顺序无关），用于提示两端内容不一致 |

客户端连接后先发 `client/hello`：

```json
{ "type": "client/hello", "payload": { "protocol": 2, "content_hash": "…" } }
```

- 版本不匹配 → 服务器回 `auth/reject{reason:"protocol_mismatch"}` 并记审计；
- 内容哈希不匹配 → **仍然接受**，但在 `auth/hello` 回执里带 `warning:"content_mismatch"`（不炸局）；
- 未握手前发送意图 → `auth/reject{reason:"not_handshaken"}`。

## 3. 上行（客户端 → 服务器）

### 3.1 意图 `intent/*`

| type | 必需字段 | 说明 |
|---|---|---|
| `intent/play_card` | `card_name`(str), `seq`(int) | 出单位 / 施放法术 |
| `intent/play_equip` | `card_name`, `seq` | 打出装备 |
| `intent/activate_equip` | `equip_name`, `seq` | 激活装备 |
| `intent/activate_hero` | `ability_id`, `seq` | 英雄技能 |
| `intent/end_turn` | `seq` | 结束回合 |
| `intent/cross_board` | `source_slot_id`, `target_slot_id`, `seq` | 跨棋盘选择 |
| `intent/choice` | `request_id`, `option_index`, `seq` | 回应服务器的选择请求 |
| `intent/surrender` | `seq` | 投降（任意时刻可用） |

**落点字段（棋盘接入后）**：`intent/play_card` 还需带 `target_slot_id`(str) 与
`row`(int) / `col`(int)。服务器会用**同一套棋盘规则**校验：盘必须是发送者名下的
（否则 `illegal_target`）、格必须在 3×3 内且为空（否则 `illegal_target`）、卡必须是单位
（`CardUnit`；法术 / 装备 / 英雄技能的权威结算尚未接入 → `not_allowed`）。校验失败时
**不消耗手牌与费用**（原子性）。单位属性（攻击 / 四维血量 / 效果）一律取自服务器卡库，
客户端上报的任何结果字段都被忽略。

**已接入权威端的意图**（其余仍 `not_allowed`）：

| type | 服务器校验 | 效果执行 |
|---|---|---|
| `intent/play_card`（单位） | 手牌 / 费用 / 盘归属 / 格空 | 立即落子（同步） |
| `intent/play_card`（法术） | 手牌 / 费用 / 目标格（有目标策略时必须有单位） | 排队，`tick` 中执行 `Effects.trigger_play` |
| `intent/play_equip` | 手牌 / 费用 / 必须是 `CardEquipment` | 立即生成装备实例（**不入墓**，破损才入墓） |
| `intent/activate_equip` | 装备归属 / 耐久 / 每回合一次 | 排队，`tick` 中 `EquipmentInstance.activate` |
| `intent/activate_hero` | 技能已注册 / **必须属于该英雄** / `can_activate` / 费用 / 每回合一次 | 排队，`tick` 中 `on_activate` |
| `intent/end_turn` | 回合归属 | 登记待结算，`tick` 中由 `TurnSystem` 算完整侧行动再推进回合 |

> 权威端的费用 / 每回合状态**只从服务器自身状态读取**（`ctx.mana_system` 等注入缝），
> 绝不采信客户端 payload 里的任何数值字段。

`seq` 必须**单调递增**：重复或回退会被拒（`stale_seq`），用于防重放。

### 3.2 控制消息

| type | 说明 |
|---|---|
| `client/hello` | 握手（见 §2） |
| `client/ping` | 心跳 |

**payload 里的身份字段（`player_id` / `from` / `uuid` 等）一律被忽略** ——
身份永远取连接绑定的 `sender_pid`。这是防冒充的关键。

## 4. 下行（服务器 → 客户端）

| type | 载荷 | 说明 |
|---|---|---|
| `auth/hello` | `protocol, match_id, you, players, content_hash, warning` | 握手回执 |
| `auth/state` | `turn, active, you{hand, mana, hero, graveyard, draw_count, seq_ack, equipments}, others[{hand_count, …, equipments}], board{slot_id: {owner, team_id, faction, hero, cells{"r,c": cell}, graveyard, banished}}` | **按玩家过滤**的视图：自己手牌明文，对手手牌只有数量；**盘面与装备是公开信息**（战棋单位位置 / 装备本就可见），由权威端 `AuthorityBoard` + 权威装备表下发 |
| `auth/event` | `event, pid, …` | 权威事件流（`match_started` / `turn_started` / `card_played` / `card_drawn` / `card_ended` / `intent_accepted` …） |
| `auth/request_choice` | `request_id, kind, options` | 要求玩家做选择（取代旧实现里"效果 await 玩家点 UI"） |
| `auth/verdict` | `finished, winner` | 胜负（客户端不再自行判定） |
| `auth/reject` | `reason, intent` | 拒绝某个意图，客户端据此回滚本地预览 |

**事件路由规则**：`to == ""` 的事件广播给所有人（`match_started` / `turn_started` / `card_played` /
`match_finished`）；否则只发给该玩家（`card_drawn` / `draw_failed` / `intent_accepted`）。

## 5. 拒绝原因

| reason | 触发 |
|---|---|
| `unknown_type` | 非法 type（含 v1 的 `action/*`） |
| `bad_payload` | 缺字段或类型不符 |
| `unknown_player` | 发送者不在本局玩家列表 |
| `match_finished` | 对局已结束 |
| `stale_seq` | 序号重复 / 回退 |
| `not_your_turn` | 非当前行动玩家 |
| `rate_limited` | 超过每秒意图上限 |
| `card_not_in_hand` | 手牌里没有这张牌 |
| `not_enough_mana` | 费用不足 |
| `illegal_target` | 目标非法 |
| `not_allowed` | 该意图当前不受支持 / 伪造的服务器专属消息 |
| `protocol_mismatch` | 协议版本不符 |
| `not_handshaken` | 未握手 |

## 6. 反作弊规则（服务端强制）

1. **服务器专属消息一律丢弃**：客户端发来 `game/end`、`disconnect/notify`、`game/start`、`auth/*`
   → 不转发、不执行，只记审计日志（`audit_log()` 中 `event:"forged_server_message"`）。
   > 原架构下任意房内成员都能靠伪造 `disconnect/notify` 秒杀对手、靠伪造 `game/end` 直接判胜。
2. **身份取连接绑定**（§3.2）。
3. **握手与版本校验**（§2）。
4. **序号单调 + 限速**（默认 10 次/秒，`BattleAuthority.rate_limit_per_sec`）。
5. **随机由服务器掌握**：洗牌种子与抽牌堆顺序只存在于服务器；客户端拿不到（`auth/state` 里对手只有数量）。
6. **未经服务器结算的状态不生效**：客户端不做本地权威决策。

### 6.1 中继层（Go）已强制的部分

`server/security.go` 在**客户端尚未接入 v2 权威协议之前**先堵住 v1 转发路径上的漏洞，
两条路径的判定保持一致（都是"丢弃 + 记日志"，不断开连接）：

| 策略 | 实现 | 被堵住的漏洞 |
|---|---|---|
| 服务器专属消息丢弃 | `serverOnlyMessageType()`：`game/end`、`disconnect/notify`、`auth/*`、`room/*` 服务器推送 | 任意成员伪造秒杀 / 判胜 / 伪造房间状态；`game/end` 也不再能销毁房间 |
| 房主专属消息 | `game/start` 校验 `room.HostUUID == sender` | 任意成员重定义整局（牌组 / 英雄 / 行动顺序 / 布局） |
| 身份字段重写 | `rewriteIdentityFields()`：payload 里 `player_id` / `uuid` 改写为连接真实 uuid | `action/end_turn` 携带他人 `player_id` 冒充其结束回合 |
| 每连接限速 | `allowRate()`：滚动 1 秒窗口 20 条，超限丢弃 | 消息洪泛 |

对应单测：`server/security_test.go`（10 个用例，`go test ./...`）。

> **结算不再依赖对端消息**：多队伍 PVP 的胜负由每端本地的确定性模拟直接推出
> （`Game.pvp_end_game()` → `match_result_decided` 信号），`game/end` 只是对旧服务端的兼容兜底。
> 投降因此改为显式网络消息（v1 路径 `action/surrender`，v2 路径 `intent/surrender`），
> 否则对端推算不出"本地触发的自杀伤害"。

## 7. 权威进程与中继的对接（拓扑）

权威规则跑在 **Godot headless 权威进程**里（GDScript 规则只有一份）；Go 中继仍是传输层，
但要知道"这一局由谁裁决"：

```
玩家 A ─┐                        ┌─ intent/*  →  权威进程（BattleServerSession + AuthorityBoard）
        ├─ Go 中继（房间/转发） ─┤
玩家 B ─┘                        └─ auth/*    ←  （按 to 广播或定向）
```

| 步骤 | 消息 | 说明 |
|---|---|---|
| 权威注册 | `room/authority_join{room_id, key}` | 连接需带 `role=authority`；`key` 必须等于中继环境变量 `NSOC_AUTHORITY_KEY`。**未配置该环境变量时一律拒绝**（默认安全：任何客户端都不能自称权威）。成功回 `authority/joined{players, match_type, host_uuid}` |
| 意图上行 | `intent/*`、`client/*` | 房间注册了权威时**只发给权威**，不进 P2P 广播（对手看不到意图、也无法自行结算）；未注册时保持原转发行为 |
| 权威下行 | `auth/*` | 由权威连接发出：`to==""` 广播给房间全员，`to=<pid>` 只发该玩家。**不做身份重写**（权威载荷里的 `player_id` 合法代表某个玩家） |
| 玩家伪造 | `auth/*`、`game/end`、`disconnect/notify`… | 玩家发来一律丢弃 + 记日志（§6.1） |
| 权威断线 | — | 房间的 `AuthorityUUID` 清空；对局退回 v1 转发语义（不崩、不静默判负） |

> 部署时需要设置 `NSOC_AUTHORITY_KEY`（见 §6.1 与 `server/main.go`）。
> 客户端侧开关：`Net.use_v2 = true` 后连接建立自动发 `client/hello`，
> 入站 `auth/*` 分发到 `auth_hello/auth_state/auth_event/auth_reject/auth_verdict/auth_request_choice` 信号；
> 默认 `false` 时老路径（`action/*` + `message_received`）行为逐字不变。

## 8. 实现分层与当前状态

```
传输层（Go 中继：房间/转发/限速）      server/*.go
      ↑
BattleServerSession                   消息信封 / 协议校验 / 握手 / 按玩家路由
      ↑
BattleAuthority                       身份 / 回合 / 序号 / 限速 / 卡牌与费用结算 / 私有视图
      ↑
AuthorityBoard                        权威盘面：装配（create_headless）+ 落子校验 + 盘面视图
      ↑
棋盘规则引擎                            BoardModel + CellData + BoardSlotFactory
                                       （CombatSystem / TurnSystem 共用同一份规则，表现可关）
```

**已完成（GDScript 侧）**：协议定义、权威核心、服务器会话层、**权威端棋盘落子与盘面视图**；
会话入口 `BattleServerSession.create_match(config)` 支持可选 `config.board` 接入权威盘面
（失败写审计并退回骨架模式）。
124 条断言（`AuthorityTest` 46 + `ServerSessionTest` 32 + `AuthorityBoardTest` 30 + Go 10 + 其余 headless 套件）。
**已完成（Go 中继侧）**：服务器专属消息拦截 / 房主校验 / 身份重写 / 每连接限速（`server/security.go` + 10 个单测）。

**未完成**：
- **客户端尚未接入** —— `TestMain` 仍走 v1 的 `action/*` 路径（结果广播与胜负已改为本端推导，
  不再信任对端消息，但出牌/装备等仍是"客户端算完再广播"，服务器不校验规则）；
- **装备/技能已接入，但"读客户端全局"的效果是空操作** —— 例如 `gain_mana_1` 读 `Game.mana`
  （服务器侧为 null → 静默无效）。英雄技能与装备的**前置校验**已通过 `ctx` 注入缝复用，
  但效果体本身仍需逐个迁移到 `ctx` 访问器；前排跨盘选择目前是确定性兜底，
  待换成 `auth/request_choice`；`TurnSystem` 的逐动作事件流（细粒度 `auth/event`）待补
  —— 现在下发的是粗粒度 `phase_resolved` + `auth/state.board`；
- **中继层仍是转发** —— Go 侧已按 §6.1 止血，但尚无对局规则；v1 与 v2 两套路径并存，
  待客户端接入 v2 后删除 `action/*`。
