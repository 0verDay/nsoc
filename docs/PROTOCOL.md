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
| `auth/state` | `turn, active, you{hand, mana, hero, graveyard, draw_count, seq_ack}, others[{hand_count, …}], board{slot_id: {owner, team_id, faction, hero, cells{"r,c": cell}, graveyard, banished}}` | **按玩家过滤**的视图：自己手牌明文，对手手牌只有数量；**盘面是公开信息**（战棋单位位置本就可见），由权威端 `AuthorityBoard.state()` 下发 |
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

## 7. 实现分层与当前状态

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
- **权威端只结算"单位落子 + 单侧行动阶段"** —— 法术 / 装备 / 英雄技能尚未接入；英雄血量在
  棋盘（`BoardSlot.hero`）与权威 `_hero_hp` 之间**还没打通**（棋盘上的英雄阵亡暂不会触发
  `auth/verdict`）；前排跨盘选择目前是确定性兜底，待换成 `auth/request_choice`；
  `TurnSystem` 的逐动作事件流（细粒度 `auth/event`）待补 —— 现在下发的是粗粒度
  `phase_resolved` + `auth/state.board`；
- **中继层仍是转发** —— Go 侧已按 §6.1 止血，但尚无对局规则；v1 与 v2 两套路径并存，
  待客户端接入 v2 后删除 `action/*`。
