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
| `auth/state` | `turn, active, you{hand, mana, hero, graveyard, draw_count, seq_ack}, others[{hand_count, …}]` | **按玩家过滤**的视图：自己手牌明文，对手手牌只有数量 |
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

## 7. 实现分层与当前状态

```
传输层（Go 中继：房间/转发/限速）      server/*.go
      ↑
BattleServerSession                   消息信封 / 协议校验 / 握手 / 按玩家路由
      ↑
BattleAuthority                       身份 / 回合 / 序号 / 限速 / 卡牌与费用结算 / 私有视图
      ↑
（待接入）棋盘规则引擎                   TurnSystem + CombatSystem + PlayController
```

**已完成（GDScript 侧）**：协议定义、权威核心、服务器会话层、78 条边界断言（`AuthorityTest` 46 + `ServerSessionTest` 32）。

**未完成**：
- **客户端尚未接入** —— `TestMain` 仍走 v1 的 `action/*` + `result_*` 广播路径；
- **棋盘战斗结算未接入权威端** —— `BattleAuthority` 目前只结算卡牌与费用，棋盘规则待与
  `TurnSystem`/`CombatSystem` 打通（前置：规则层与表现层解耦，见 `docs/ROADMAP.md`）；
- **Go 中继未加固** —— `server/*.go` 仍是纯转发，尚未做 type 白名单 / 房主校验 / 身份重写。
