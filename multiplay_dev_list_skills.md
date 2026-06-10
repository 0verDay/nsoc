# NSOC 多人联机开发规划文档







> 本文件记录 PVP 模式的全部决策与开发难点，后续开发以此为准。



> 最后更新：2026-06，包含完整决策清单 + 1v3 / 3v3 全部实施记录。







---







## 1. 决策锁定







### 1.1 总体架构







| 维度 | 决策 |



|---|---|



| 联机范围 | 远程联机（互联网，非局域网） |



| 网络架构 | **云服务器**（纯中继 + 房间列表服务） |



| 服务器部署 | 单台云服务器（中继 + 房间列表二合一） |



| 服务器语言 | **Go** |



| 服务器持久化 | **不持久化**，仅内存中保持房间状态（重启即清空） |



| 服务器房间数 | **不设限制**（原型期） |



| 服务器日志 | **不记录任何日志**（原型期） |



| 消息协议 | **JSON 文本协议**（原型期，便于调试） |



| 心跳检测 | **不设心跳**，仅依靠 WebSocket 连接状态检测断线 |



| 客户端版本兼容 | **不检查**（原型期），玩家自行保证版本一致 |



| 房间加入方式 | **房号制 + 公开房间列表**（服务器提供所有可加入房间，玩家点击加入） |



| 房号格式 | **5 位纯数字**，**服务器随机生成 + 冲突重试** |



| 房间生命周期 | 创建后无人在线 60 分钟自动销毁；房间未启动战斗也走此规则 |



| 战斗启动后 | **拒绝新玩家加入**（点击提示"房间已启动"） |



| 战斗结算后 | **服务器发 `game/end` 并销毁房间**，玩家返回主菜单 |



| 反作弊 | **不做**（原型期），服务器完全信任房主发来的状态 |



| 房主权限 | **不提供踢人 / 转让 / 锁房**（原型期），房主只是"先进者" |







### 1.2 对战规模







| 维度 | 决策 |



|---|---|



| 房间最大人数 | 6 人 |



| **原型期目标** | **仅 1v1**（先做最简形态） |



| **后续目标** | 2v2 / 3v3 / 1v3（增量扩展） |



| 行动顺序 | 房主点开始后，**服务器随机生成 1-N 号顺序** |



| 回合制规则 | **严格轮流制**，按号位依次行动 |



| 战前阶段 | **房主点"开始"后立即进入战斗**（无倒计时、无准备阶段） |







### 1.3 玩法设定







| 维度 | 决策 |



|---|---|



| 棋盘布局 | **同 PVE：6 行 × 3 列**，玩家半场 row 3-5，对手半场 row 0-2 |



| 英雄选择 | **玩家在备战界面自主选择**：A「科因」（再起技能） / B「多人模式·测试」（测试技能）/ C（待完善）；退出备战界面时保存，多人游戏各自携带自己选定的英雄 |



| 英雄技能 | **启用**：A「再起」（消耗1费弃全手牌补满）/ B「测试技能」（消耗1费选一手牌弃置补1张） |



| 装备系统 | **启用**（同 PVE，仁之剑 / 义之剑 / 测试刀等装备牌可用） |



| 卡组来源 | **玩家自带卡组**：从 `DeckStorage.decks[selected_hero]` 读取，各玩家携带自己备战界面编辑的卡组 |



| 卡组数量 | **每位玩家独立一套**，各自洗牌 |



| 卡组下发时机 | 玩家点「准备」时发 `room/deck_ready`（携带牌组名列表 + 英雄 key）到房主；房主开始时汇总广播 `game/start` |



| 双方手牌 | **双方独立牌堆**，各自随机洗牌、独立抽牌 |



| 起手牌 | 同 PVE，开局抽 5 张 |



| 手牌上限 | **5 张**（同 PVE，超出则烧牌） |



| 费用系统 | 同 PVE，按轮次推进（1 轮 1 费、2 轮 2 费、… 各玩家各自主场轮数计算） |



| 牌库耗尽 | **墓地重洗进牌库**（耗尽后墓地洗回，可循环出牌） |



| Spawner | **完全不启用**，PVP 全靠玩家手牌出牌，无自动刷怪 |



| 单位详情查看 | **所有人都可以查看**（长按弹出面板，与 PVE 一致） |



| UI 布局 | **同 PVE**，本地玩家定位下方，对方定位上方 |



| 对方手牌可见 | **不可见**（手牌隐私，与 PVE 中敌方手牌不可见一致） |



| 对方费用可见 | **不可见**（原型期 UI 不展示） |



| 主动投降 | **已实现**：选项面板"投降"按钮 → damage_hero(100, triggered) → 走标准阵亡流程 |



| 中途退出 | **退出即投降**：退出战斗走"投降"同样逻辑，对手收 game/end 显示胜利画面 |







### 1.4 玩家身份







| 维度 | 决策 |



|---|---|



| 身份系统 | **本地设置昵称**，启动时处理，永久保存到 `user://profile.json` |



| 玩家 ID | 客户端随机生成 UUID + 本地昵称展示 |



| 昵称重复 | **允许**（仅是显示名，唯一性由 UUID 保证） |



| 服务器地址 | **从本地配置文件 `user://server.json` 读取**，玩家可在配置中修改 |







### 1.5 异常处理







| 维度 | 决策 |



|---|---|



| 客户端断线 | **掉线玩家对自己英雄造成 100 点伤害**，随后算作该玩家阵亡 |



| 房主断线 | **房间立即销毁**，本局不计胜负 |



| 玩家阵亡 | **任一英雄阵亡 → 该玩家被踢出 + 判断阵营胜负** |



| 重连支持 | **不支持**（原型期） |



| 超时机制 | **无超时限制**（原型期） |







### 1.6 动画与状态同步







| 维度 | 决策 |



|---|---|



| 同步策略 | **动画在本地完整播放，服务器只广播"动画事件信号"** |



| 实现方式 | 服务器发出形如 `attack_started` / `damage_dealt` / `unit_died` / `hero_damaged` 等事件 + 最终状态结果；客户端各自接收信号 → 播放对应本地动画 → 应用最终状态 |



| 优点 | 动画时长各端相同（避免长短不一），网络只传少量事件包 + 状态结果 |







### 1.7 暂不实现（原型期外）







- 文字聊天 / 表情系统



- 旁观模式



- 录像与回放



- 重连



- 反作弊



- AI 接管掉线玩家



- 玩家好友系统 / 匹配队列







---







## 2. 网络架构说明







### 2.1 拓扑







```



玩家A（房主 / 游戏逻辑权威端）



│   游戏逻辑在本机运行



│



├── 云服务器（中继 + 房间列表服务）



│   ├── 维护 room_id → players 映射



│   ├── 提供房间列表查询 API（玩家进游戏后看到所有可加入的房间）



│   └── 转发消息包（不执行任何游戏逻辑、不验证状态）



│



└── 玩家B / C / ...（客户端）



    └── 通过房号或公开房间列表加入；只发输入、收状态渲染



```







### 2.2 服务器职责（仅以下四项）







1. **房间管理**：创建/销毁房间、维护成员名单、发布公开房间列表



2. **消息中继**：转发房主与客户端之间的所有消息（不解析游戏内容）



3. **行动顺序生成**：房主点"开始游戏"时，服务器生成随机 1-N 号顺序并广播



4. **房间生命周期管理**：60 分钟无人在线自动销毁；房主断线时立即销毁







### 2.3 为什么不用 P2P







- 国内运营商大量使用**对称型 NAT**，纯 P2P 打洞成功率 50%～70%，不稳定



- Listen Server（房主开房）在国内同样有 NAT 问题，远程连不上



- 云服务器中继可靠性 100%，带宽消耗极低（卡牌战棋每操作约 1-5KB）







### 2.4 为什么不用权威服务器







- 游戏逻辑复杂（大量 GDScript + await 协程），移植到服务器端成本极高



- 纯中继下房主作为权威端，对小规模对战（6 人）完全够用



- 原型期完全信任房主，作弊问题留待运营期再处理







### 2.5 推荐技术选型







| 层 | 选型 | 说明 |



|---|---|---|



| 客户端网络 | Godot 4 内置 `WebSocketMultiplayerPeer` | 原生支持，无需第三方 SDK |



| 中继服务端 | **Go**（已锁定） | 性能好、内存占用低、对 WebSocket 友好；静态编译为单一 binary 直接部署 |



| 消息协议 | JSON 文本协议 | 原型期易调试 |



| 房间发现 | 服务器维护公开列表 + 房号制（双轨） | 既支持点击加入，也支持房号输入 |



| 房号生成 | 服务器随机生成 5 位数字 + 冲突重试 | 简单，玩家好记 |







---







## 3. 对战形式说明







### 3.1 1v1（原型期目标）







```



[玩家A]



─────────



[玩家B]



```







- 2 个 `BoardSlot`，玩家各 1 盘



- **最优先实现的形态**，最接近现有 PVE 架构



- 2 名玩家轮流（号位 1 → 2）



- 胜负判定：英雄先死的一方失败







### 3.2 2v2 / 3v3（后续扩展）







```



[队A-P1] [队A-P2] [队A-P3]



─────────────────────────



[队B-P4] [队B-P5] [队B-P6]



```







- 6 个 `BoardSlot`，两队各 3 盘，左右横排



- 任一玩家英雄阵亡 → 该玩家被踢出房间



- 一队所有玩家被踢出 → 该队失败



- 严格轮流：1 → 2 → 3 → 4 → 5 → 6 依次行动







### 3.3 1v3（后续扩展）







```



      [守方-P1]



─────────────────



[攻方-P2] [攻方-P3] [攻方-P4]



```







- 4 个 `BoardSlot`，1 守方盘 vs 3 攻方盘



- 接近现有 PVE 守关结构



- 守方英雄阵亡 → 守方失败 → 房间结束



- 所有攻方英雄阵亡 → 守方胜利 → 房间结束







### 3.4 共同规则







- 当前回合玩家发出操作请求 → 房主验证 → 广播状态变更



- 非当前行动玩家的所有操作请求被房主直接拒绝



- 玩家英雄阵亡时**立即退出房间**，剩余玩家继续直至胜负判定



- **棋盘均使用 6 行 × 3 列布局**，玩家半场 row 3-5，对手半场 row 0-2（同 PVE）



- **不启用 SpawnerSystem**，全靠玩家手牌出牌



- **牌库耗尽后墓地重洗回牌库**（与 PVE 不同，PVE 中通常牌库耗尽不再补牌）







---







## 4. 开发难点清单







> 按重要性排序。**核心瓶颈**：异步效果改造 + 状态序列化，占总工作量约 70%，与网络架构无关。







---







### 🔴 P0 难点（必须解决，无法绕过）







#### 4.1 回合控制流彻底改造







**现状**：`TurnSystem.run()` 是单人线性协程，玩家阶段→刷怪→敌方阶段一路 `await` 跑完，没有"等待远端输入"的挂起点。







**需要改造为**：



```



回合 N 开始



├── current_player = order[N % player_count]



├── 广播"轮到玩家 X 行动"



├── 挂起，等玩家 X 发来操作（出牌/技能/结束回合）



├── 每次收到操作 → 执行 → 广播状态变更



├── 收到"结束回合"信号



├── 执行本盘单位行动（front_row 推进、跨盘攻击）



├── 广播本盘结算结果



└── 切换到下一玩家，repeat



```







**影响范围**：`TurnSystem.run()`、`PlayController`、`FrontRowSelector`、`HeroActionBar`







---







#### 4.2 含 `await` 的效果改消息驱动







**现状**：所有需要玩家选目标的效果，都在协程内部 `await ctx.pick_target_async()`，阻塞本地协程等本地点击。







**PVP 必须改为消息驱动**：



```



主机 on_play() → 广播 {type:"pick_target", player_id:X, filter:"enemy_unit"}



→ 主机协程挂起（等回包）



→ 玩家 X 客户端收到请求 → 显示目标选择 UI → 玩家点击格子



→ 客户端发回 {slot_id, cell_id}



→ 主机收包，恢复协程，继续执行



→ 广播执行结果（全员同步状态）



```







**受影响的效果与技能**（完整列表）：







| 类型 | 名称 | 异步交互点 |



|---|---|---|



| 效果 | `destroy_unit` | 选敌方目标单位 |



| 效果 | `empower` | 选友方目标单位 |



| 效果 | `inspire` | 选友方目标单位 |



| 效果 | `weaken` | 选目标单位（SpellCasterSystem 驱动，PVP 可能不需要） |



| 效果 | `ming_jin` | 选友方目标单位放回牌库 |



| 效果 | `discard_hand_card` | 选手牌弃置 |



| 效果 | `assault_charge` | 随机尸位（需同步随机种子或由主机决定） |



| 英雄技能 | `flood_strategy_hero` | 选敌方目标单位施加浸水 |



| 英雄技能 | `yi_yong_jun` | 无目标选择但涉及召唤（需同步召唤结果） |



| 装备 | 仁之剑（`destroy_unit`） | 选敌方目标单位 |



| 装备 | 义之剑（`discard_hand_card`） | 选手牌弃置 |



| 跨盘选择 | `front_row_action_requested` | 玩家选目标盘 |







**每个效果需单独改造，无法批量处理。**







---







#### 4.3 状态序列化全套







**现状**：零序列化机制，所有状态在本地 GDScript 对象内存里。







**需要为以下对象实现 `to_dict() / from_dict()`**：







| 对象 | 需序列化的字段 |



|---|---|



| `Cell` 节点 | `has_card`、`card_name`、`attack`、`health` 字典、`max_health` 字典、`effects` 数组、`is_enemy`、`origin`、`owner_slot_id`、`slot_id`、`is_phantom` |



| `BoardModel` | `grid_cells` 中所有 cell 状态（按 row/col 键） |



| `HeroState` | `health`、`max_health`、`name_short`、`name_full`、`abilities`、`stacks`、`flags`、`is_dead` |



| `DeckManager` | `draw_pile`（仅发给本人）、`graveyard`、`banished`、`hand`（仅发给本人）、`hand` 数量（发给其他人） |



| `BoardSlot` | board 快照 + hero 快照 + spawners 配置 + owner_player_id |



| `Game.counters` | 全部键值对 |



| `Equipments` | 每个玩家的装备实例（耐久、名称、`once_per_turn` 已用状态） |



| `ManaSystem` | `current`、`max`（按玩家分） |



| `SpawnerSystem` | `spawners` 配置、`pause_turns` |







**注意**：手牌是私有信息，序列化时需按 `player_id` 过滤，只把自己的手牌完整发给自己，其他人只发手牌数量。







---







### 🟠 P1 难点（核心功能，需在完整版前解决）







#### 4.4 BoardSlot 所有权与权限多人扩展







**现状**：`BoardSlot.allow_player_deploy` 单一 bool；`is_enemy` 是格子级固定属性；`PlayController.can_play_at` 用 `cell.is_enemy` 判定。







**PVP 改造**：



- 每个 `BoardSlot` 加 `owner_player_id: String`



- `is_enemy` 变为"相对于当前行动玩家"的动态属性（P1 看 P4 是敌，P2 看 P4 也是敌；P1 看 P2 是友）



- `PlayController.can_play_at` 需按当前行动玩家 ID + 阵营映射重新判定



- `front_row_action_requested` 跨盘选择按当前玩家阵营过滤可选目标







> **1v1 简化**：1v1 模式下只有 2 个 BoardSlot，is_enemy 判定相对简单，可暂用现有 `is_enemy` 字段，扩展到多人时再做整改。







#### 4.5 Orientation 视角多人扩展







**现状**：`Orientation` 的 front/back 以"玩家在下方、敌方在上方"硬编码。







**PVP 改造**：



- 3v3 中，队 A 的"前方"是向下推，队 B 的"前方"是向上推



- `Orientation.abs_to_side` / `side_to_abs` 需加入"当前玩家阵营"参数



- 或者统一以"房主视角"作为绝对方向，客户端渲染时做镜像翻转







> **1v1 简化**：1v1 模式可直接复用现有上下两半场逻辑，无需视角扩展。







#### 4.6 手牌私密性







**现状**：`HandView` 直接读 `Game.deck.hand`，全部正面显示，无隐藏信息概念。







**PVP 改造**：



- 客户端只渲染本玩家手牌（正面）



- 其他玩家手牌显示卡背 + 数量



- 服务端（房主）维护 N 份 `DeckManager`，序列化时按 `player_id` 过滤







#### 4.7 随机性同步







**现状**：`DeckManager.shuffle()`、`assault_charge` 随机尸位、`spawn_unit` `any_empty` 策略全用 Godot 默认随机数，各端独立不一致。







**PVP 改造**：



- 所有随机操作只在房主（权威端）执行



- 结果通过消息广播给所有客户端



- 客户端不独立执行随机逻辑，只接收结果并渲染







#### 4.8 多玩家 DeckManager / ManaSystem







**现状**：`Game.deck` 单一 `DeckManager`；`Game.mana` 单一 `ManaSystem`，均假设只有一位玩家。







**PVP 改造**：



- `Game.decks: Dictionary[player_id, DeckManager]`（N 份，1v1 是 2 份）



- `Game.manas: Dictionary[player_id, ManaSystem]`（N 份）



- 费用每回合 +1 上限只对当前行动玩家生效



- `HeroActionBar` 绑定本地玩家对应的 `mana` 实例







#### 4.9 Equipments autoload 多人扩展







**现状**：`Equipments` 单例持有全局 `EquipmentInstance[]`，假设只有一位玩家。







**PVP 改造**：装备实例按 `player_id` 分组；`HeroActionBar` 只显示本玩家的装备。







---







### 🟡 P2 难点（完整体验需要，但不影响核心验证）







#### 4.10 UI 屏幕空间分配







- 6 个棋盘横排在移动端屏幕空间极紧张



- 需要设计新的多盘 UI 布局（可能需要缩放 cell、简化英雄面板）



- 手牌区、费用显示、行动顺序指示器均需重新排布







> **1v1 简化**：1v1 模式 UI 布局与现有 PVE 几乎一致，仅需调整下半场为"对方玩家英雄面板"而非 NPC 面板。







#### 4.11 ScriptedEvents / 剧情系统的旁路







**现状**：`TurnSystem.run()` 内有 `await Events.run_turn_events_and_wait()`，`Game.bootstrap()` 走章节加载路径。







**PVP 改造**：



- PVP 模式下整个 `ScriptedEvents` / `Dialogue` / `BoardOrchestrator.add_board` 体系应禁用



- `Game.bootstrap()` 需分支：PVE 走原路径，PVP 走新路径（无章节、无 trigger、N 套独立 deck）



- `TurnSystem.run()` 中 `await Events.run_turn_events_and_wait()` 加 PVP 模式跳过判断







#### 4.12 胜负判定新逻辑







**现状**：`Objective` 系统：`survive_turns` / `kill_enemy_hero`，单一目标。







**PVP 新规则**：



- **任一玩家英雄阵亡 → 该玩家被踢出房间**



- **1v1**：英雄先死的一方失败



- **2v2 / 3v3**：一队所有玩家被踢出 → 该队失败



- **1v3**：守方英雄死亡 → 守方失败；所有攻方英雄死亡 → 守方胜利



- 需要新 Objective 类型 `pvp_team_elimination` 或专用 PVP 胜负判定模块







#### 4.13 断线处理逻辑（已具体化）







- **客户端断线**：服务器检测到掉线 → 房主收到通知 → **对掉线玩家自身英雄造成 100 点伤害**（`damage_hero` 走 triggered 路径，穿透死守）→ 该玩家英雄死亡触发标准阵亡流程



- **房主断线**：服务器检测到房主掉线 → **立即销毁房间**，向所有客户端发"房间已解散"消息 → 客户端返回主菜单 → 本局不计胜负







---







## 5. 工作量分级估算







| 模块 | 优先级 | 工作量 | 备注 |



|---|---|---|---|



| 网络层（中继服务器 + 客户端连接） | P0 | 小 | WebSocket 中继代码量少 |



| 房间列表服务 | P0 | 小 | 服务器维护字典，提供查询/创建/销毁 API |



| 状态序列化全套 | P0 | **大** | 体力活，每个对象都要做 |



| 回合控制流改造 | P0 | **大** | TurnSystem 重构 |



| 异步效果改消息驱动 | P0 | **极大** | 每个效果单独改，无法批量 |



| 多玩家 Deck/Mana 扩展 | P1 | 中 | 从单例改为字典索引 |



| BoardSlot 所有权 + 权限 | P1 | 中 | 1v1 可暂缓 |



| Orientation 视角扩展 | P1 | 中 | 1v1 可暂缓 |



| 手牌私密性 | P1 | 中 | |



| 随机性同步 | P1 | 小 | 权威端执行，广播结果 |



| Equipments 多人扩展 | P1 | 小 | |



| ScriptedEvents 旁路 | P2 | 小 | 加 is_pvp 判断即可 |



| 胜负判定新逻辑 | P2 | 小 | |



| 多盘 UI 布局（2v2/3v3/1v3） | P2 | 中 | 1v1 可暂缓 |



| 断线处理（自残 100 + 房间销毁） | P2 | 小 | 服务器检测 + 房主响应 |







---







## 6. 推荐推进路径







> **核心思路**：先做 1v1 跑通端到端流程，再扩展到多人。







```



Step 1：状态快照原型（无网络）



  ├── 为 BoardModel / Cell / HeroState / DeckManager 实现 to_dict / from_dict



  └── 验证能从快照完整恢复战局（local save/load 作为练手）



  目标：确认序列化边界，发现遗漏字段







Step 2：单效果改消息驱动（无网络）



  ├── 把 destroy_unit / empower 等改为"请求-响应"模式



  ├── 用本地伪信号模拟远端回包



  └── 验证回合流程仍然正确



  目标：验证异步效果改造可行







Step 3：回合控制流改造（无网络）



  ├── TurnSystem 支持"等待指定 player_id 的行动"



  ├── 本地模拟 2 个玩家轮流（单机双角色测试）



  └── 验证轮流机制正确



  目标：确认控制流架构







Step 4：搭建中继服务器



  ├── Go/Node WebSocket 中继程序



  ├── 实现房间创建、加入、销毁、消息转发



  ├── 实现公开房间列表 API



  └── 部署到云服务器（开发期使用最便宜的 1Mbps 实例）



  目标：服务器端基础设施就绪







Step 5：1v1 端到端联通【原型期目标】



  ├── 客户端接入 WebSocketMultiplayerPeer



  ├── 实现房主创建房间、客户端加入、点开始 → 服务器生成顺序 → 进入战斗



  ├── 验证 2 人远程对战完整流程（出牌 → 同步 → 异步效果 → 胜负判定）



  └── 验证断线处理（自残 100、房间销毁）



  目标：原型期完成，可玩的 1v1 PVP







Step 6：扩展到 1v3（后续）



  ├── 4 个 BoardSlot，1 守方 vs 3 攻方



  ├── 复用现有多盘架构，守方逻辑接近 PVE



  └── 验证多盘联网同步



  目标：第一个多人 PVP 模式







Step 7：扩展到 2v2 / 3v3（后续）



  ├── 6 个 BoardSlot，两队各 3 盘



  ├── 调整 Orientation 阵营视角映射



  ├── BoardSlot.owner_player_id 引入



  └── 完善 UI 布局



  目标：完整多人 PVP 体验



```







---







## 7. 现有架构中的可复用部分







| 模块 | 复用程度 | 说明 |



|---|---|---|



| `BoardModel` / `Cell` | 高 | 加序列化后直接复用 |



| `BoardSlot` / `BoardRegistry` | 高 | 加 `owner_player_id` 后复用 |



| `CombatSystem` | 高 | 纯结算逻辑，无状态，复用 |



| `SpawnerSystem` | 高 | 加 `pause_for_turns` 已有，复用（PVP 中可能不需要 spawner） |



| `Effects` 效果逻辑 | 中 | 不含 await 的效果直接复用；含 await 的需改造 |



| `HeroState` | 高 | 加序列化后复用 |



| `DeckManager` | 中 | 改为多实例后复用 |



| `ManaSystem` | 中 | 改为多实例后复用 |



| `TurnSystem` | 低 | 需大改，逻辑框架可参考 |



| `PlayController` | 低 | 出牌权限逻辑需重写 |



| `ScriptedEvents` / `Dialogue` | 不复用 | PVP 模式禁用 |



| `BoardOrchestrator` | 中 | 布局逻辑可参考，动态增删盘逻辑可复用 |



| UI 组件（HandCard、Cell 视觉、HeroActionBar） | 中 | 需加私密性分支，其余复用 |







---







## 8. 关键设计约定







### 8.1 权威与同步







- **权威端**：房主是唯一权威，所有游戏逻辑在房主本地执行，结果广播给客户端



- **客户端只做输入+渲染**：客户端发送操作意图（出哪张牌、选哪个目标），不自行执行游戏逻辑



- **服务器完全信任房主**：原型期不做任何状态验证，房主发什么客户端就显示什么



- **随机性**：所有随机操作只在房主端执行，结果广播







### 8.2 私密信息







- **手牌私密**：序列化时按 `player_id` 过滤，手牌内容只发给本人，其他人收到的是手牌数量



- **卡组私密**：原型期使用服务器预设卡组，所有玩家相同；扩展后玩家自带卡组时，卡组内容也只对本人可见







### 8.3 回合权限







- 非当前行动玩家的所有操作请求在房主端直接拒绝



- 当前行动玩家可执行：出牌、激活英雄技能、激活装备、点击结束回合



- 玩家阵亡（被踢出）后号位顺延，跳过该号位







### 8.4 数据来源







- **all_cards.json**：图鉴原型库，全局共享，所有端都有完整副本



- **decks.json**：玩家本地卡组存档（`user://decks.json`），按英雄 key 分组；多人游戏各玩家携带自己在备战界面编辑的卡组，点「准备」时上报给房主



- **selected_hero**：`decks.json` 顶级字段，记录玩家退出备战界面时选定的英雄 key；多人游戏双方各自携带不同英雄，通过 `game/start` 的 `per_player_heroes` 字段广播



- **hero.json**：英雄配置；多人可选英雄目前为 A（科因/再起）/ B（测试/测试技能）/ C（待完善）



- **profile.json**：客户端本地玩家身份信息（昵称 + UUID），保存于 `user://profile.json`，启动时读取，玩家可改昵称



- **server.json**：客户端本地服务器配置（地址、端口），保存于 `user://server.json`







### 8.5 PVE 与 PVP 完全分支







- `Game.bootstrap()` 加 `is_pvp: bool` 开关



- PVP 跳过：章节加载、ScriptedEvents、剧情 trigger、Dialogue、BoardOrchestrator 动态增删盘等所有 PVE 专属流程



- PVP 启用：墓地重洗回牌库（耗尽时）、多 DeckManager / ManaSystem 实例、远端等待挂起点



- PVP 禁用：SpawnerSystem（不刷怪）、SpellCasterSystem（无 NPC 自动施法）







### 8.6 服务器协议规范







- **协议格式**：JSON 文本协议（原型期）



- **基础消息字段**：



  ```json



  {



    "type": "msg_type",          // 消息类型



    "from": "player_uuid",       // 发送者（服务器内部填）



    "to": "player_uuid|all|host", // 接收者



    "room_id": "12345",          // 房号（5 位数字）



    "payload": {...}             // 业务数据



  }



  ```



- **房号格式**：5 位纯数字，由服务器分配，唯一不重复



- **客户端连接信息**：UUID（本地随机生成）+ 昵称（本地保存）



- **核心消息类型**（待开发期细化具体 payload）：



  - **房间相关**：`room/create`、`room/join`、`room/join_rejected`（房间已启动）、`room/list`、`room/leave`、`room/destroy`、`room/expired`



  - **配置下发**：`config/deck_dispatch`（玩家加入房间后立即下发预设牌组配置）



  - **游戏控制**：`game/start`、`game/order_assigned`、`game/end`、`game/turn_advance`



  - **玩家操作**：`action/play_card`、`action/activate_hero`、`action/activate_equip`、`action/end_turn`



  - **目标选择请求**：`request/pick_target`、`response/pick_target`、`request/pick_hand_card`、`response/pick_hand_card`



  - **状态同步**：`state/full_snapshot`（首次同步全量状态）、`state/delta`（增量状态变更）



  - **动画事件信号**：`event/attack_started`、`event/damage_dealt`、`event/unit_died`、`event/hero_damaged`、`event/card_drawn`、`event/effect_triggered`、`event/deck_reshuffle`（牌库耗尽墓地重洗）



  - **断线相关**：`disconnect/notify`（服务器告知房主某玩家掉线）、`disconnect/auto_damage`（房主对掉线玩家执行自残100）







### 8.7 心跳与断线检测







- **不主动发心跳包**，仅依靠 WebSocket 底层的 TCP 连接状态



- TCP 连接断开 → WebSocket 触发 `connection_closed` → 服务器立即广播 `disconnect/notify` 给同房间内其他玩家



- 房主收到 `disconnect/notify` 后调用 `damage_hero(掉线玩家slot, 100, "triggered")` → 走标准阵亡流程







### 8.8 服务器内存模型（无持久化）







- 服务器仅以内存字典维护房间状态：



  ```



  rooms: {



    "12345": {



      host_uuid: "...",



      players: [{uuid, nickname, ws_conn, slot_index}, ...],



      created_at: timestamp,



      last_active_at: timestamp,



      started: false,



      action_order: []  // game/start 后赋值



    },



    ...



  }



  ```



- 服务器重启即清空所有房间，玩家需重新创建



- 后台定时任务每分钟扫描，销毁 60 分钟无活跃的房间







---







## 9. 待后续开发期细化的问题（暂不阻塞原型设计）







- 服务器协议消息格式的精确定义（每类消息的 payload 字段细节）



- 卡组配置文件的格式设计（服务器预设卡组的 JSON 结构）



- 房间列表 API 的查询参数（过滤条件、分页）



- 1v1 模式下玩家英雄阵亡时的胜负展示 UI（沿用 PVE `_show_game_over` 即可）



- 玩家被踢出房间后的客户端表现（直接返主菜单 / 显示战败画面）



- 云服务器厂商与配置（待运营期决定）



- 客户端 WebSocket 连接异常的本地表现（toast 提示 / 重试逻辑）



- 卡组配置文件的下发协议消息类型设计（`game/config_dispatch` 等）







---







## 10. 决策版本记录







| 时间 | 决策范围 | 备注 |



|---|---|---|



| 第一轮 | PVP 整体方向、网络架构、对战形式、回合制、卡池来源 | 决定云服务器纯中继 + 6 人最大 |



| 第二轮 | 房间加入方式、行动顺序、英雄/卡组、断线、超时、协议、协议格式、阵亡处理 | 14 项细化决策，原型期改为 1v1 |



| 第三轮 | 玩家身份、房号格式、服务器地址、房间生命周期、棋盘布局、Spawner、手牌上限、牌库耗尽、战前阶段、持久化、房间数限制、动画同步策略、单位详情、UI 布局、装备系统、英雄技能、心跳检测 | 17 项进一步细化，明确所有原型期实现选项 |



| 第四轮 | 服务器语言（Go）、昵称重复、房号生成、战斗结算后流程、投降功能、战斗启动后加入、中途退出、版本检查、房主权限、服务器日志、卡组下发时机、牌组数量、双方手牌处理 | 13 项实施层面细化，所有原型期内待决策点已基本闭环 |



| 第五轮 | SparringPanel 内嵌联机大厅、Mode 分工（我的房间/加入房间/随机匹配/排位）、默认昵称 player、本地服务器 127.0.0.1:8080、6 格玩家槽位网格（中央 2 格开放）、准备系统、房主断线/退出随机转让、刷新冷却内联按钮 | 围绕 UI 重构 + 房主转让 + 准备系统的实施细节 |







---







## 11. 实施进度（2026-06）







### 11.1 已完成（按 step 推进）







#### Step 1: 状态序列化（无网络依赖）







| 文件 | 改动 |



|---|---|



| `cell.gd` | `to_dict / from_dict`（原地恢复 Panel 节点，不创建新节点） |



| `core/board_model.gd` | `to_dict / from_dict`（按 `"r,c"` 键分发到 cell） |



| `core/hero_state.gd` | `to_dict / from_dict` |



| `core/deck_manager.gd` | `to_dict / to_dict_public / from_dict`（卡牌按 name 序列化） |



| `core/mana_system.gd` | `to_dict / from_dict` |



| `core/equipment_instance.gd` | `to_dict` + 静态 `from_dict` |



| `core/equipment_manager.gd` | `to_dict / from_dict`（重建时发 added/removed） |



| `core/board_slot.gd` | `to_dict / from_dict`（视觉容器不序列化） |



| `core/snapshot_io.gd` | **新建**：顶层 `serialize_battle / restore_battle / save/load_to_file` |



| `main.gd` / `test_main.gd` | F5 存档、F9 读档热键 |







#### Step 3: 多实例 DeckManager / ManaSystem







| 文件 | 改动 |



|---|---|



| `core/game_context.gd` | 加 `decks: Dict / manas: Dict / local_player_id / is_pvp / pvp_action_order / pvp_active_idx / pvp_room_id`，加 `get_deck/get_mana/add_deck/add_mana/clear_extra_decks_and_manas/deck_of_slot/mana_of_slot/pvp_active_player_id/pvp_is_my_turn/pvp_advance_turn/bootstrap_pvp` |



| `core/board_slot.gd` | 加 `owner_player_id` 字段（PVP 槽位归属） |







#### Step 4: Go 中继服务器







| 文件 | 说明 |



|---|---|



| `server/main.go` | HTTP 入口，`PORT` env 配置 |



| `server/hub.go` | 中央调度循环（rooms/clients 字典）+ 房间管理 + 路由 + 60min 过期清理 |



| `server/room.go` | Room 结构 + 5 位房号生成 + 冲突重试 |



| `server/client.go` | Client 封装 + WebSocket upgrader + read/writeLoop |



| `server/message.go` | Message 结构（`type / from / to / room_id / payload`） |



| `server/README.md` | 启动说明 + 协议参考 |







**关键修复**：



- `handleDisconnect` 用**指针比对**（`stored == c`）而非 UUID 比对，支持同 UUID 多连接（同机测试必需）



- `_safeSendClose` + `deliver` 加 `recover` 防 double-close panic



- `handleJoin` 也按指针去重，允许同 UUID 视为不同玩家







#### 客户端网络层（新增 `scripts/net/`）







| 文件 | 说明 |



|---|---|



| `scripts/net/profile_manager.gd` | 静态工具：`user://profile.json` uuid/昵称 + `user://server.json` 服务器配置 |



| `scripts/net/network_manager.gd` | autoload `Net`：WebSocket 连接 + 消息收发 + 信号 + **`session_id = uuid + 4位随机后缀`**（解决同机两实例同 UUID） |







`session_id` 是关键：原本同一台机两个 Godot 实例共享 `user://profile.json` 拿到相同 UUID，服务器无法区分。每次启动给 UUID 加随机后缀作 session 身份，解决了这个问题。







#### 大厅 UI（不接演武切磋）







| 文件 | 说明 |



|---|---|



| `scripts/ui/pvp_lobby.gd` | **新建**：纯代码构建 UI，无 .tscn。CONNECT/CONNECTING/LOBBY/ROOM 四个页面 |



| `scripts/main_menu.gd` | 加屏幕中央"联机对战"按钮（无样式，待迁入演武切磋面板） |



| `data/test_multiplayer_deck.json` | **新建**：填线宝宝×3 + 鼓舞×1 + 测试刀×1 测试牌组 |







#### Step 5-A/B/C: 战斗场景 PVP 化







`test_main.gd` 加 PVP 分支：



- `_inject_pvp_level_data()`：注入合成 level_data（player_main + enemy_main，无 spawner / spell_caster / events）



- `_setup_pvp_slots()`：boot 后注入 `owner_player_id`



- `_pvp_default_hero_spec()`：从 `hero.json` 读"往日之王·科因 / 再起 / HP 30"



- `_on_end_turn_pressed()` PVP 分支：跑 `run_pvp_phase(PLAYER)` → 发 `action/end_turn` 给对手 → 推进回合



- `_on_remote_end_turn()`：跑 `run_pvp_phase(ENEMY)` → 推进回合（带 `pvp_is_my_turn()` 守卫防双 advance）



- `_pvp_msg_queue` + `_drain_pvp_queue` + `_handle_pvp_message`：**消息队列顺序处理**，避免 await 并发导致单位/法术处理竞态



- `_update_pvp_turn_ui()`：刷新结束回合按钮 + 同步刷新英雄技能按钮（解决 `pvp_advance_turn()` 时序问题）







`play_controller.gd`：



- `can_play_at` / `can_equip` 加 `pvp_is_my_turn()` 检查



- `_pvp_broadcast_play_card()` 出牌后广播（带 `card_type / slot_id / row / col`，法术额外带 `result_atk / result_health`）



- `_pvp_broadcast_play_equip()` 装备出牌广播



- `handle_remote_play_card()` 远端镜像执行（坐标 + slot_id 双重翻转，见 §12.3）



- `handle_remote_end_turn()` 远端结算



- 改用 `_pvp_opponent_id()` 定向发送，**不发 `to=all`** 避免 echo 干扰队列



- `handle_unit_death` 路由：PVP `is_enemy=true` 单位入 `ROLE_MAIN_ENEMY` slot.graveyard（不再走 `Game.deck`）







`turn_system.gd`：



- 新增 `run_pvp_phase(faction)`：只跑指定阵营单侧，不递增 `turn_number`，不发 turn_started/ended、不跑 events / spawn







`hero_action_bar.gd`：



- 加 PVP 回合检查（按钮禁用 + 点击拦截）



- `_make_ctx()` 注入 `hand_view` 和 `hero`（修复"再起"技能 ctx 缺字段）







`effect_context.gd`：



- 加 `hand_view / hero` 字段



- `banish_card / send_to_graveyard` 也按 `is_enemy + is_pvp` 路由对手单位入 enemy_main slot







#### Step 5-D 部分: 胜负 + 退出







- 英雄死亡发 `game/end` 给服务器（销毁房间）



- `_game_over_shown` flag 防对手 `game/end` 立即退出盖掉胜负画面



- 退出战斗自动 `Net.disconnect_from_server()` + 清 PVP 状态







### 11.2 关键 bug 修复记录







| Bug | 根因 | 修复 |



|---|---|---|



| 两实例 UUID 相同导致服务器混淆 | `user://profile.json` 共享 | `session_id = uuid + 4位随机后缀` |



| 服务器 `panic: send on closed channel` | `handleDisconnect` 用 UUID 删 map 错删另一连接 | 指针比对 + `_safeSendClose` + `deliver` recover |



| 二次打开大厅显示"连接中"卡死 | Net 已连接但 `connected` 信号不会再触发 | `_ready` 检查 `Net.is_connected_to_server()` 跳到对应页 |



| `bootstrap_pvp` 把 `Game.deck` 节点 free 掉 | `clear_extra_decks_and_manas` 用 `local_player_id` 比对，bootstrap 先改 `local_player_id` 再调此函数 | 改用**实例指针**比对（`d == deck`）保留 |



| 鼓舞对端不生效 | inspire 检查 `cell.is_enemy` 跳过 enemy 单元格 | 广播带 `result_atk / result_health`，对端**直接写数值**绕过效果 |



| 鼓舞数值显示带小数点 | JSON 往返后 int 变 float | 接收时显式 `int(rh[k])` |



| 单位坐标对端镜像错 | A 放右下角 → B 应看到左上角（两人面对面） | `row_b = (ROWS-1)-row_a, col_b = (COLS-1)-col_a` |



| 鼓舞跨回合失效 | 单位移动后 spell 在 enemy_main 找不到（如已跨入 player_main） | 广播带 `slot_id`，**接收端按 `player_main↔enemy_main` 翻转**定位单元格 |



| 对手单位死亡墓地为空 | `cell.origin == "hand"` 一律入 `Game.deck` | PVP 模式下 `is_enemy` 单位入 `ROLE_MAIN_ENEMY` slot.graveyard |



| 装备双方都装上 | `Equipments` 是全局 autoload | 远端 `action/play_equip` 不调 `Equipments.equip` |



| TurnSystem 跑双侧导致单位走两次 | `run()` 跑 PLAYER+ENEMY 两阶段 | 新增 `run_pvp_phase(faction)` 只跑一侧 |



| 双方都显示"等待对方" | echo 进入消息队列被处理两次 advance turn | 改用 `Net.send_to(opp_id)` 不发 `to=all` + `_on_remote_end_turn` 加 `pvp_is_my_turn()` 守卫 |



| 同回合鼓舞 OK 但跨回合 NG | 消息队列 await 并发：单位 play_card 还没落格，鼓舞 play_card 已检查 cell.has_card | `_pvp_msg_queue` 顺序处理，每条 await 完才处理下条 |



| 行动方按钮置灰 / 等待方按钮亮 | `_refresh_ability_button` 在 `pvp_advance_turn` 之前触发 | `_update_pvp_turn_ui` 末尾强制再调一次 `_refresh_ability_button` |



| `_on_remote_end_turn` 无 `[MSG]` 前缀被二次调用 | Godot signal 协程机制 + `await` 重入 | 加 `if pvp_is_my_turn(): return` 守卫 |



| 再起报错 `hand_view` 不存在 | `EffectContext` 没有 `hand_view` 字段 | EffectContext 加 `hand_view / hero` 字段，`_make_hero_ability_ctx` 注入 |



| `settings_panel_controller.gd` 解析失败 | `_apply_danger_button_style` 调用 `ThemeFactory.has_method()`（static 不可用）且引用不存在的 `danger_button_styles` | 删除 `has_method` 检查，直接手搓红色 StyleBoxFlat |



| 鸣金对端污染牌库 / counter | 对端 else 分支自跑 ming_jin effect → `deck.add_to_draw_pile` + `set_counter("ming_jin_used")` 误操作对端状态 | 广播加 `result_cleared: true` 标志；对端直接 `cell.clear_card()`，不跑 effect |



| game/end winner_id 错误（投降场景） | `_on_hero_died` 用 `pvp_active_player_id()` 作 winner，玩家死亡时 winner 可能是自己 | 改用 `_pvp_opponent_id()` 确保 winner 是对手 |







---







### 11.3 本轮新增（2026-06 本次会话）







#### Step 6-A：RNG 随机种子同步







| 文件 | 改动 |



|---|---|



| `core/deck_manager.gd` | 加 `_rng / _rng_base_seed / _reshuffle_count`；加 `setup_seeded(cards, seed)`；`reshuffle` 改调 `_shuffle_draw_pile()`；加确定性 Fisher-Yates 洗牌；`_rng==null` 时退回 `Array.shuffle()`（PVE 不变） |



| `core/game_context.gd` | 加 `pvp_rng_seed: int`；`bootstrap_pvp` 加 `rng_seed: int = 0` 参数；逐玩家 `setup_seeded(deck_cards, rng_seed + pid_index)` |



| `scripts/ui/pvp_lobby.gd` | `_on_start_game` 生成 `rng_seed = rng.randi()`，写入 `game/start` payload；`game/start` handler 解析 `rng_seed`，传入 `bootstrap_pvp` |







**关键设计**：



- 房主在 `game/start` 时生成种子，一次广播双方同时收到



- 每位玩家种子 = `base_seed + pid_index`，避免双方洗出完全一样的顺序



- 后续 reshuffle（墓地重洗）用 `_rng_base_seed + _reshuffle_count` 推导，双端确定性一致







#### Step 6-B：装备激活同步







| 文件 | 改动 |



|---|---|



| `core/play_controller.gd` | 加 `_PVP_BROADCAST_EQUIP_EFFECTS = ["destroy_unit"]` 白名单；加 `_pvp_broadcast_activate_equip(equip_name, target_cell)`（检查白名单后才发）；加 `handle_remote_activate_equip(payload)`（坐标翻转 + `Effects.trigger_play` 镜像执行） |



| `scripts/ui/hero_action_bar.gd` | `_on_equip_btn_pressed` 加 PVP 回合检查；激活成功后调 `_pvp_broadcast_equip_activation`；`_refresh_equipment_button` 加 PVP 非自己回合时禁用 |



| `scripts/test_main.gd` | `_handle_pvp_message` 加 `action/activate_equip` 分支；顺手清理重复的 `match` 块（历史 bug） |







**白名单说明**：



- `destroy_unit`（仁之剑）影响对手单位状态 → 广播 + 对端镜像执行



- `gain_mana_1`（测试刀）只影响自家 mana → 不广播



- `discard_hand_card`（义之剑）只影响自家手牌 → 不广播







#### Step 6-C：断线自残 100







| 文件 | 改动 |



|---|---|



| `scripts/test_main.gd` | `disconnect/notify` 分支：找 `ROLE_MAIN_ENEMY` slot，调 `e_slot.damage_hero(100, "triggered")` → 走标准阵亡 → `_on_enemy_hero_died` → 发 `game/end` + 显示胜利画面 |







**链路**：TCP 断 → 服务器广播 `disconnect/notify` → 存活方 `damage_hero(100)` → 阵亡流程 → 服务器销毁房间







#### Step 6-D：投降功能







| 文件 | 改动 |



|---|---|



| `scripts/ui/settings_panel_controller.gd` | 加 `_surrender_action: Callable`；`setup` 接受 `surrender_action` 配置；面板高度按是否含投降按钮动态切换（3 按钮=400px / 4 按钮=490px，vbox 同比适配）；加 `_on_surrender_pressed`、`_apply_danger_button_style`（红色样式） |



| `scripts/test_main.gd` | `setup` 无条件注入 `surrender_action`（PVE + PVP 均有）；加 `_on_pvp_surrender`（`ROLE_MAIN_PLAYER` slot `damage_hero(100)`）；`game/end` 分支按 `winner_id` 判断本端胜负（投降方对端显示胜利画面而非直接退出）；修 `_on_hero_died` winner_id 用 `_pvp_opponent_id()` |



| `scripts/main.gd` | `setup` 注入 `surrender_action`；加 `_on_surrender`；`_show_game_over` 加 `_game_over_shown = true` 防重复触发 |







**两类面板**：主菜单（无 surrender_action）→ 400px，3 按钮；游戏内（有 surrender_action）→ 490px，4 按钮







#### Step 6-E：含 await effect 同步审查







审查结果：







| Effect | 状态 | 说明 |



|---|---|---|



| `inspire` | ✅ 正确 | 无 await，broadcast 后 attack 已更新，result_atk 直写 |



| `empower` | ✅ 正确 | 无 await，result_health 直写 |



| `weaken`（存活） | ✅ 正确 | 无 await，result_health 直写 |



| `weaken`（打死） | ✅ 正确 | await 后 cell 清空，对端走 else 自跑 weaken 完整流程 |



| `discard_hand_card` | ✅ 正确 | 不广播，只影响自家手牌 |



| **`ming_jin`** | ✅ 已修复 | 对端 else 分支会污染牌库 / counter，加 `result_cleared: true` 标志 |







| 文件 | 改动 |



|---|---|



| `core/play_controller.gd` | `_pvp_broadcast_play_card` 对法术格子清空时检查 `_RETURN_TO_HAND_EFFECTS = ["ming_jin"]`；含返手效果则加 `result_cleared: true`；`handle_remote_play_card` 法术 else 加 `result_cleared` 分支直接 `cell.clear_card()` |



| `data/test_multiplayer_deck.json` | 加入鸣金×1，方便测试 |







#### Step 6-F：英雄技能同步（再起）







| 文件 | 改动 |



|---|---|



| `scripts/ui/hero_action_bar.gd` | `_on_ability_pressed` activate **之前**拍手牌快照（`_pvp_snapshot_for_ability`）；await 后发 `action/activate_hero`；加 `_pvp_snapshot_for_ability`（restart 拍 discarded 名单）；加 `_pvp_broadcast_activate_hero` |



| `scripts/test_main.gd` | `action/activate_hero` 分支调 `_handle_remote_activate_hero`；加函数：restart → 把 discarded 卡名追加入 `ROLE_MAIN_ENEMY` slot.graveyard，触发 `pile_changed` → enemy_side_panels 自动刷新 |







**设计决策**：



- 对端不调 `HeroAbilities.activate`（会操作对端自家 hand_view）



- 对端只做"视觉状态镜像"：追加弃牌进 enemy_main 墓地



- mana / deck 抽牌不同步（锁步模型下下回合 `start_new_turn` 自动修正 mana；抽牌由 RNG seed 保证一致）



- `_pvp_snapshot_for_ability` 预留扩展点，未来加其他 ability 时按 id 添加快照逻辑







#### Step 6-G：对手装备详情面板展示







| 文件 | 改动 |



|---|---|



| `scripts/ui/detail_panel_controller.gd` | `_build_panel` 末尾追加三节点 `EquipSep`/`EquipTitleLbl`/`EquipDescLbl`，默认隐藏；`start_long_press_hero` / `_on_long_press_timeout` / `show_hero` 全部加第 4 参数 `equip_descs: Array = []`，长按英雄时在技能描述下方显示分隔线 + "已装备" 标题 + 描述行 |



| `scripts/ui/hero_panel_drag_controller.gd` | `_on_press` 从 `_hero_args_resolver` 返回数组取 `args[3]` 作 `equip_descs` 透传给 `start_long_press_hero`，兼容旧 3 项数组 |



| `scripts/test_main.gd` | 加 `_remote_equip_insts: Array` 字段（对手装备镜像，不进 `Equipments` 单例）；`_get_player_hero_long_press_args` 返回扩到 4 项，新增 `_collect_equip_descs` / `_collect_remote_equip_descs`；`_on_enemy_hero_panel_gui_input` 传镜像列表；`action/play_equip` 分支从 `pass` 改为按 `card_name` 创建 `EquipmentInstance` 加入镜像；`action/activate_equip` 分支在 await 后按名字找镜像实例扣耐久（`durability_left -= 1`，≤0 移除） |







**设计决策**：



- 装备格式：`【装备名】效果1；效果2（剩余耐久：N）`，多件每行一条



- 对手装备**不进 `Equipments` 全局单例**，避免战斗结算误用对手装备 effect / 耐久



- 镜像列表只服务详情面板查看，**不与服务器再次同步**——耐久数据由本端按 `action/activate_equip` 锁步推算



- 装备破损（耐久=0）由对端 `_on_inst_changed` 自动 unequip 入墓，本端镜像同步移除即可



- PVE 不受影响：敌方英雄长按显式传 `_collect_remote_equip_descs()`，PVE 阶段该列表恒空







### 11.4 待完成







#### 优先级 P0（核心可玩性）







- [x] ~~再起技能两端牌堆 desync~~ → **Step 6-A 已解决**（RNG seed 同步）



- [x] ~~装备激活同步~~ → **Step 6-B 已解决**（白名单广播 + 对端镜像）



- [x] ~~跨盘单位的鼓舞同步~~ → 已加 slot_id 翻转，测试通过



- [x] ~~跨盘冲锋时英雄受击同步~~ → **Step 7-A 已验证**（锁步模型天然对称：PLAYER phase 打 enemy hero，ENEMY phase 打 player hero，两端各打各端 hero_resolver，结果对称；已在 turn_system.gd 加注释说明）







#### 优先级 P1（体验完善）







- [x] ~~PvpLobby UI 迁入演武切磋面板~~ → **Step 7-B 已完成**（SparringPanel ModeBtn0「我的房间」点击弹出联机大厅；移除 main_menu.gd 临时按钮）



- [x] ~~投降功能~~ → **Step 6-D 已解决**（选项面板红色投降按钮，PVE + PVP 通用）



- [x] ~~战斗中途退出处理~~ → **Step 6-C 已解决**（disconnect/notify → damage_hero(100)）



- [x] ~~房间列表过滤 / 分页 / 刷新冷却~~ → **Step 7-C/7-D 已完成**（刷新冷却 3s 内联倒计时；过滤 started=true 房间；进入大厅页可立即拉一次）



- [x] ~~房间内 UI 重设计~~ → **Step 7-D 已完成**（6格玩家槽位网格 + 房主/准备按钮 + 弹性滚动 + 数字键盘）



- [x] ~~房主转让~~ → **Step 7-E 已完成**（hub.go 服务端 random 选新房主 + new_host_uuid 广播）



- [x] ~~准备系统~~ → **Step 7-E 已完成**（room/ready_update 广播，房主"开始"按钮 gated by 全员 ready）



- [x] ~~对手装备 UI 显示~~ → **Step 6-G 已解决**（详情面板"已装备"分区 + 对手装备镜像列表）



- [x] ~~含 await 效果同步验证~~ → **Step 6-E 审查完毕**，修复 ming_jin 对端污染问题



- [x] ~~英雄技能同步（再起）~~ → **Step 6-F 已解决**（弃牌入对端 enemy_main 墓地）







#### 优先级 P2（扩展）







- [ ] **真实云服务器部署**：当前只本机 localhost:8080



- [ ] **JSON 协议精确化**：每类消息的 payload schema 文档化



- [ ] **2v2 / 3v3 / 1v3 扩展**：多 enemy_main / ally slot



- [ ] **客户端版本检查**（原型期决策不做）



- [ ] **服务器持久化 / 日志 / 反作弊**（原型期决策不做）



- [x] ~~其他英雄技能同步扩展~~ → **Step 8-B 已完成**（test_discard 同步，含取消不广播逻辑）



- [ ] **英雄 C 技能设计与实现**







---







### 11.5 本轮新增（Step 7，2026-06 续）







#### Step 7-A：跨盘冲锋英雄受击同步验证







经过逐行分析 `run_pvp_phase`、`_process_cell`、`_run_charge_on_board`、`_enemy_auto_cross` 等函数：







- PVP 锁步模型下，`hero_resolver` 只修改**本端对应 HeroState**，天然对称，无需额外广播



- A 端 `run_pvp_phase(PLAYER)` → 玩家单位冲锋打 A 的 `enemy_main`（对手）英雄 ✅



- B 端收 `action/end_turn` 跑 `run_pvp_phase(ENEMY)` → 敌方单位冲锋打 B 的 `player_main`（自己）英雄 ✅



- 两端计算来源不同（A 端的 enemy_main 英雄 = B 端的 player_main 英雄），无双重扣血







| 文件 | 改动 |



|---|---|



| `scripts/core/turn_system.gd` | `_process_cell`、`_run_charge_on_board`、`_enemy_auto_cross` 三处 `hero_resolver.call` 加 PVP 锁步说明注释 |







#### Step 7-B：联机大厅完全迁入 SparringPanel（重构）







**决策变更**：放弃 PvpLobby 浮层方案，将所有联机交互内嵌到 SparringPanel 的 `LeftContentPnl`，按 Mode 标签分工：







| Mode | 标签 | 内容 |



|---|---|---|



| 0 | 我的房间 | 进入即视为创建房间，显示房号 / 玩家列表 / 开始战斗 / 离开房间 |



| 1 | 加入房间 | 房间列表 + 刷新按钮（带 3s 冷却） |



| 2/3 | 随机匹配 / 排位 | 占位（施工中） |







**测试期默认配置**（跳过昵称 / 服务器配置环节）：



- 昵称固定为 `player`



- 服务器固定为 `127.0.0.1:8080`







| 文件 | 改动 |



|---|---|



| `scripts/ui/sparring_panel.gd` | 完全重写：内嵌房间 UI 渲染 + 网络信号处理 + game/start 切场景；DEFAULT_MODE 改为 0；BackBtn 退房（不主动断开 Net 长连） |



| `scripts/ui/pvp_lobby.gd` | **删除**（功能完全迁入 SparringPanel） |



| `scripts/main_menu.gd` | 之前已删除临时联机按钮（Step 7-B 第一版） |







**交互流程（首次进入）**：



1. `SecondaryPanel._ready` → 转场附加 SparringPanel



2. `_apply_styles` 调用 `_enter_mode(0)` 进入「我的房间」



3. `_ensure_connected_then(true)`：未连接 → `Net.set_nickname("player")` + `Net.connect_to_server("127.0.0.1", 8080)`



4. UI 显示「正在连接服务器…」



5. `Net.connected` 信号 → `_on_ready_after_connect` → 发 `room/create` → UI 显示「正在创建房间…」



6. `room/create_ok` → 房间号 + 玩家列表 + 开始战斗按钮渲染







**离开行为**：



- 「离开房间」按钮 → 发 `room/leave` + 自动切到 Mode 1（加入房间）显示房间列表



- BackBtn → 发 `room/leave` + 保持 Net 长连（下次再开 SparringPanel 直接 connected 状态）



- `game/start` 收到 → `bootstrap_pvp` + `change_scene_to_file("res://scenes/TestMain.tscn")`







#### Step 7-C：房间列表刷新冷却 + 已启动房间过滤







| 文件 | 改动 |



|---|---|



| `scripts/ui/sparring_panel.gd` | `REFRESH_COOLDOWN = 3.0`、`_last_refresh_time` 字段；点刷新按钮冷却中显示剩余秒数；`room/list_response` 解析时过滤 `started=true` 的房间 |







#### Step 7-D：SparringPanel UI 全面重构（Mode 分工 + 房间内 UI 重做）







**决策回滚**：DEFAULT_MODE 改回 3「随机排位」（占位页，不联网），按用户主动点击触发联机；离开 Mode 0 时视为退出当前房间（自动 `room/leave`）。







##### Mode 0「我的房间」UI 设计







| 区域 | 内容 |



|---|---|



| **顶部** | 标题「我的房间」 |



| **左半 `left_col`** | 房号（48px 蓝色大字）+ 身份（房主/玩家）+ 6 格玩家显示网格（2行×3列，竖直 EXPAND_FILL） |



| **右半 `right_panel`**（宽 280，蓝灰底圆角） | 顶部弹性空白 + 底部「开始」/「准备」按钮（大字 BTN_HEIGHT+24） |







**6 格玩家网格**：



- 锁定格（4 个边角格）：浅灰底，居中显示 `×`



- 开放格（中央两格 `[1, 4]`）：对应 server slot 0 / 1



  - 空：淡蓝底，居中 `…`



  - 有人：白底蓝边 + 昵称 + ` ✓`（已准备时）+ 房主下方换行 `【host】`（蓝色小字）







**房主 vs 非房主按钮**：



- 房主：「开始」按钮，`disabled` 直到 `_players ≥ 2` AND 所有非房主玩家均 `_player_ready[uuid] == true`



- 非房主：「准备」/「已准备 ✓」切换按钮（绿色样式 `#2f9e44` 表示已准备）







##### Mode 1「加入房间」UI 设计







| 区域 | 内容 |



|---|---|



| **顶部行** | 「刷新列表」按钮（带内联倒计时） + 标签「可加入的房间（未开战）」 |



| **左半（`SIZE_EXPAND_FILL`）** | 房间列表底板（蓝灰底圆角投影）+ ElasticScrollList 弹性滚动列表 |



| **右半（宽 280）** | 数字键盘面板（输入栏 + 1-9 网格 + 0/加入房间）|







**列表行**：白底浅灰边小圆角的 `PanelContainer` 卡片，单行：`房间 12345    房主: player    人数: 1/6` + 「加入」按钮。







**数字键盘**：



```



[ 房间号显示 ]  [ × 清空 ]



[ 1 ][ 2 ][ 3 ]



[ 4 ][ 5 ][ 6 ]



[ 7 ][ 8 ][ 9 ]



[ 0 ][  加入房间（2 列宽）  ]



```



- 显示栏空时不显示占位符



- 数字键 / 0 / 加入房间均 `SIZE_EXPAND_FILL` 双向，自动等比撑满竖直空间



- 点击加入房间 → `_on_join_room(_room_input)` + 清空输入







**刷新按钮内联倒计时**：



- 按下后按钮文字每 0.25s 刷新：`"3 秒"` → `"2 秒"` → `"1 秒"` → `"刷新列表"`



- 倒计时期间 `disabled = true`



- UI 重建时（如切 tab 再回来）自动恢复正确文字 + 重启协程，不会重置倒计时



- 协程实现 `_run_refresh_countdown` + 幂等 `_start_refresh_countdown`（已运行则只刷新引用）







##### 弹性滚动新组件 `ElasticScrollList`







新文件 `scripts/ui/elastic_scroll_list.gd`：完全自管 clip 容器，支持过度拉动 + 释放回弹，行为对齐备战界面卡牌列表。







| 参数 | 值 |



|---|---|



| `OVERSCROLL_RESISTANCE` | 0.55 |



| `OVERSCROLL_SETTLE_TIME` | 0.28s（cubic ease-out） |



| `SCROLL_THRESHOLD_PX` | 18px |



| `WHEEL_STEP_PX` | 60px |







公式 `f(x) = (x·c·d)/(d + c·x)`，越界量 → rubber band 衰减，视觉永不超过视口高度。







##### ThemeFactory 补完







`settings_button_styles()` 增加 `disabled` 样式（`#adb5bd` 灰底 + 同款 12px 圆角），解决 disabled 按钮丢失圆角的视觉 bug。







##### 文件清单







| 文件 | 改动 |



|---|---|



| `scripts/ui/sparring_panel.gd` | 重写 `_build_my_room` + `_build_join_room`；新增数字键盘、弹性滚动列表、准备系统、玩家格网格、刷新倒计时协程 |



| `scripts/ui/elastic_scroll_list.gd` | **新建**：rubber band 弹性滚动容器 |



| `scripts/ui/theme_factory.gd` | `settings_button_styles` 加 `disabled` 项 |







#### Step 7-E：服务器房主转让 + 准备系统消息







**问题**：原服务器在房主退出 / 断线时**不转让房主**——同一玩家再次进房还会被认作房主（因为本地无状态）。







##### 服务器改动







| 文件 | 改动 |



|---|---|



| `server/hub.go` | `handleLeave` 和 `handleDisconnect` 移除房主玩家后，若房间仍有其他人则 `rand.Intn` 随机选一人为新房主，broadcast payload 加 `new_host_uuid` 字段 |







##### 客户端改动







| 文件 | 改动 |



|---|---|



| `scripts/ui/sparring_panel.gd` | `room/left` 和 `disconnect/notify` 解析 `new_host_uuid` 更新 `_host_uuid`；新增 `_player_ready: Dict / _is_local_ready: bool` 字段；新增 `_on_toggle_ready` 发 `room/ready_update` 广播；新增 `_all_non_host_ready` 校验房主开始按钮启用条件；新增 `room/ready_update` 入站消息处理 |







##### 准备协议







| 消息 | 方向 | payload |



|---|---|---|



| `room/ready_update` | 玩家 → 服务器 → 全房 | `{uuid, ready: bool}` |







服务器无需任何改动——`forward()` 现有逻辑会按 `to: "all"` 自动广播。准备状态完全由客户端 `_player_ready` 字典维护（原型期不上服务器持久化）。







##### Bug 修复合订







| Bug | 根因 | 修复 |



|---|---|---|



| 刷新按钮卡在"3 秒"且永远 disabled | `_request_room_list(force=true)` 写 `_last_refresh_time` 但未启动协程 | 协程启动逻辑统一到 `_request_room_list` 末尾 + `_update_refresh_btn_label` 按需重启 |



| 数字键盘竖向不填充 | 按钮固定 `NUMPAD_BTN_H` | 改 `SIZE_EXPAND_FILL` 双向，VBox / 每行 / 每键全部 EXPAND_FILL |



| ⌫ 退格键改 × 清空 + 移除 `_ _ _ _ _` 占位符 | 用户偏好简化 | 直接改函数行为 |



| 倒计时按钮无圆角 | `settings_button_styles` 缺 disabled StyleBox | ThemeFactory 补完 |



| 6 格下方提示破坏排版 | hint Label 和 EXPAND_FILL grid 混挂同 VBox | 删除 grid 后所有 hint |



| 房主退出仍是房主 | 服务器从未转让 | hub.go 加随机选新房主 + new_host_uuid 字段 |







---







## 12. 当前架构现状







### 12.1 锁步（lockstep）模型







不走"权威服务器 + 状态广播"，而是双方各自完整跑游戏逻辑，靠**同步操作消息**保持一致。简化实现，但要求：







- 所有玩家行动通过消息广播给对手（出牌 / 结束回合 / 装备激活 / 英雄技能）



- 对手收到消息后在本端**镜像执行**



- 战斗结算（攻击、移动、英雄受击）由各端自行计算，依赖于初始状态相同 + 锁步性







### 12.2 消息流







```



玩家 A 操作（如出牌）



  ↓



PlayController 本地执行



  ↓



_pvp_broadcast_play_card  ← Net.send_to(opp_id)（不发 to=all 避免 echo）



  ↓



Go 服务器（hub.go forward）按 to 字段精确路由



  ↓



玩家 B 收到 → Net.message_received.emit



  ↓



test_main._on_pvp_message 入 _pvp_msg_queue



  ↓



_drain_pvp_queue 顺序 await 处理（避免并发）



  ↓



_handle_pvp_message → 过滤 from==local → 分发到 handle_remote_*



  ↓



play_controller.handle_remote_play_card → 镜像坐标 + 翻转 slot → 镜像执行



```







### 12.3 坐标 + slot_id 翻转







PVP 1v1 双方面对面，棋盘对称镜像：







| 发送方坐标 | 接收方坐标 |



|---|---|



| `player_main(row, col)` | `enemy_main(2-row, 2-col)` |



| `enemy_main(row, col)`（已跨入对方盘） | `player_main(2-row, 2-col)` |







公式：



```



row_b = (ROWS-1) - row_a  // = 2 - row_a



col_b = (COLS-1) - col_a  // = 2 - col_a



target_slot = (sender_slot == "player_main") ? "enemy_main" : "player_main"



```







### 12.4 回合归属







- `Game.pvp_action_order: Array[session_id]` — 服务器或房主在 `game/start` 时 shuffle 生成



- `Game.pvp_active_idx: int` — 当前行动玩家在 order 中的下标



- `Game.pvp_active_player_id()` / `pvp_is_my_turn()` / `pvp_advance_turn()`



- 主动方按"结束回合"：本地跑 `run_pvp_phase(PLAYER)` → `Net.send_to(opp, "action/end_turn")` → 本地 `pvp_advance_turn()`



- 被动方收到：跑 `run_pvp_phase(ENEMY)`（即对手单位移动） → `pvp_advance_turn()`



- 双方推进同步保持 idx 一致







### 12.5 PVE / PVP 分支点







| 模块 | PVE | PVP |



|---|---|---|



| `Game.bootstrap()` | 原路径 | `bootstrap_pvp(local_pid, order, deck_cards)` |



| `level_data` | 章节 JSON | 合成 dict（player_main + enemy_main，无 spawner/events） |



| `TurnSystem` | `run()` 跑 PLAYER + ENEMY 双阶段 | `run_pvp_phase(faction)` 只跑单侧 |



| `BoardOrchestrator` | 章节 enabled 附盘 | 仅主盘双方 |



| `SpawnerSystem` | 启用 | 不挂载 |



| `SpellCasterSystem` | 启用 | 不挂载 |



| `ScriptedEvents / Dialogue / Objectives` | 启用 | 跳过 |



| `DeckManager / ManaSystem` | 单实例 | 双实例（per session_id） |



| `Equipments` | 全局 | 全局（仅本端，对手装备不互染） |







### 12.6 服务器交互优化点







- 所有 `action/*` 消息**只发对手**（`Net.send_to(opp_id)`）不用 `to=all`，避免 echo 触发自己消息队列处理



- 服务器 `handleJoin` 按指针去重（同 UUID 多连接 = 多个玩家），支持本机双开测试



- `panic` 全部 recover，单条消息异常不影响整个 hub







### 12.7 文件清单（PVP 相关新增 / 改动）







```



dev_gd/nsoc/



├── data/test_multiplayer_deck.json    新增：测试牌组



├── scripts/net/                       新增目录



│   ├── profile_manager.gd             静态：profile.json / server.json



│   └── network_manager.gd             autoload "Net"



├── scripts/ui/pvp_lobby.gd            新增：纯代码大厅 UI



├── scripts/core/snapshot_io.gd        新增：序列化顶层包装



├── scripts/core/game_context.gd       PVP 状态字段 + bootstrap_pvp



├── scripts/core/turn_system.gd        + run_pvp_phase



├── scripts/core/play_controller.gd    + PVP 广播 + handle_remote_*



├── scripts/core/effect_context.gd     + hand_view/hero, PVP 路由



├── scripts/core/board_slot.gd         + owner_player_id, 序列化



├── scripts/core/board_model.gd        + 序列化



├── scripts/core/hero_state.gd         + 序列化



├── scripts/core/deck_manager.gd       + 序列化



├── scripts/core/mana_system.gd        + 序列化



├── scripts/core/equipment_instance.gd + 序列化



├── scripts/core/equipment_manager.gd  + 序列化



├── scripts/cell.gd                    + 序列化



├── scripts/test_main.gd               + PVP 路径 + 消息队列



├── scripts/main.gd                    + F5/F9 序列化热键



├── scripts/main_menu.gd               + "联机对战"按钮



├── scripts/ui/hero_action_bar.gd      + PVP 回合检查



└── project.godot                      + Net autoload







server/                                新增目录



├── go.mod / go.sum



├── main.go / hub.go / room.go / client.go / message.go



├── README.md



└── nsoc-server.exe                    本地编译产物



```















---







### 11.6 本轮新增（Step 8，2026-06 续）







#### Step 8-A：玩家独立卡组携带







**决策变更**：各玩家携带备战界面编辑的卡组，放弃服务器统一预设卡组。







| 文件 | 改动 |



|---|---|



| `core/game_context.gd` | `bootstrap_pvp` 第三参数改为 `per_player_deck_cards`（Dict 或 Array 兼容旧调用）；逐玩家从 `deck_map[pid]` 取自己牌组建 DeckManager |



| `scripts/ui/sparring_panel.gd` | 新增 `_player_decks: Dict`；`_on_toggle_ready` 额外发 `room/deck_ready`（含 `deck_names`）给房主；`_on_start_game` 合并广播 `per_player_decks`；`_handle_game_start` 按 session_id 取本端牌组，兼容旧 `deck_names` 协议 |







**协议变更**：`game/start` 新增 `per_player_decks: {uuid: [card_name,...]}`；`room/deck_ready` 为新消息类型（只发房主）。







#### Step 8-B：玩家独立英雄携带







**决策变更**：各玩家携带备战界面选定的英雄，放弃全员同一默认英雄 A。







| 文件 | 改动 |



|---|---|



| `core/game_context.gd` | `bootstrap_pvp` 新增第六参数 `per_player_heroes: Dictionary = {}`；`hero_specs` 按此字典各自设置，缺失 pid 回退 `DeckStorage.get_selected_hero()` |



| `scripts/ui/sparring_panel.gd` | 新增 `_player_heroes: Dict`；`room/deck_ready` 追加 `hero_key` 字段；`_on_start_game` 合并广播 `per_player_heroes`；`_handle_game_start` 解析后传入 `bootstrap_pvp` 第六参数 |



| `scripts/test_main.gd` | `_pvp_default_hero_spec()` 改读 `DeckStorage.get_selected_hero()`，不再固定返回科因 |







**协议变更**：`game/start` 新增 `per_player_heroes: {uuid: hero_key}`；`room/deck_ready` payload 新增 `hero_key` 字段。







#### Step 8-C：英雄与卡组选择持久化（备战界面退出即生效）







| 文件 | 改动 |



|---|---|



| `core/deck_storage.gd` | `user://decks.json` 新增顶级字段 `selected_hero: String`；新增 `DEFAULT_HERO = "A"`；`load_all()` 兼容旧存档；新增 `get_selected_hero()` / `save_selected_hero(hero_key)` |



| `scripts/ui/hero_carousel.gd` | `_ready` 读 `DeckStorage.get_selected_hero()` → `HERO_NAMES.find(key)` → 设 `_current_page`，打开备战界面直接显示上次携带英雄 |



| `scripts/ui/prepare_panel.gd` | `_save_current_deck()` 重写：合并卡组 + `selected_hero` 为**一次 IO**（消除两次写盘之间崩溃的原子性风险） |



| `core/game_context.gd` | 新增 `static func get_battle_hero_key() -> String`（读 `DeckStorage.get_selected_hero()`）；`bootstrap()` 两处 `BATTLE_HERO_KEY` 改为 `get_battle_hero_key()` |







#### Step 8-D：英雄 B 「多人模式·测试」实现







| 文件 | 改动 |



|---|---|



| `data/hero.json` | 英雄 B：`display_name="多人模式·测试"`, `battle_name="测试"`, `max_health=30`, `abilities=["test_discard"]`, `skill_text="测试技能：消耗 1 费用，选择一张手牌弃置，并补一张。"` |



| `scripts/abilities/test_discard.gd` | **新建**：cost=1，once_per_turn=true；`can_activate` 检查手牌有非虚空真实卡；`on_activate`：锁 `turn.is_running` → `pick_async()` → 解锁 → 取消时退费 + `clear_turn_usage` 可重试 → 选中时 `hand_view.discard_card(chosen)` 自动补 1 张 |



| `core/hero_ability_registry.gd` | 新增 `clear_turn_usage(ability_id)` 公开 API（单条清除本回合使用记录，原仅有全清的 `reset_turn_usage`） |







**PVP 同步**：`hero_action_bar._on_ability_pressed` 改为 pre/post 双快照；`test_discard` 走 post-snapshot（激活后读 `Game.deck.graveyard.back()` 取弃置牌名）；广播条件改为 `activated and HeroAbilities.is_used_this_turn(ability_id)` 区分取消/成功；对端 `_handle_remote_activate_hero` 新增 `"test_discard"` 分支，弃置牌名追加到 `enemy_main` slot.graveyard。







#### Step 8-E：`_input` 守卫修复（第二次进入多人游戏崩溃）







| 文件 | 改动 |



|---|---|



| `scripts/test_main.gd` | `_input` 鼠标左键处理块前加 `is_instance_valid(detail_panel)` 守卫；`side_panels` / `enemy_side_panels` 等改为 `is_instance_valid` + `!= null` 检查 |







**根因**：切场景后 `_input` 先于 `await boot()` 触发，控制器尚为 null，第二次进入时更易复现。







#### Step 8-F：Bug 修复汇总（本轮）







| Bug | 根因 | 修复 |



|---|---|---|



| 取消「测试技能」后按钮不可再按 | `_used_this_turn` 未清除 + 费用未退 | 退费 + `HeroAbilities.clear_turn_usage(id())` |



| `_used_this_turn` 直接访问私有字段 | Registry 无单条清除公开 API | 新增 `clear_turn_usage(id)` 方法 |



| 取消「测试技能」仍广播给对手 | `activate` 取消时仍返回 true | 改为检查 `is_used_this_turn` 区分取消/成功 |



| 备战卡组+英雄两次写盘原子性问题 | 先 `save_deck` 再 `save_selected_hero` 两次 IO | 合并一次 `load_all → 修改 → save_all` |



| `_collect_deck_names` 回退固定用 "A" | 硬编码 `generate_battle_cards("A")` | 改为 `generate_battle_cards(hero_key)` |



| `game_context.gd` 注释"全员A" | 注释未更新 | 更新为"按 per_player_heroes 各自英雄" |













### 11.7 本轮新增（Step 9，2026-06 续）—— 1v3 跨盘逻辑镜像列重构





**背景**：原 1v3 跨盘攻击同列规则，存在两个问题：


1. 守方 owner 端走 UI 选盘，远端镜像走随机选盘 → 三端状态 desync


2. 同列规则下单位跨过整条屏幕，视觉不直观





**重构目标**：守方拥有者继续 UI 选目标盘，攻方完全自动跨（单一目标=守方盘）；落点列改为镜像列规则：`target_col = COLS - 1 - source_col`，配合 `board_orchestrator._reverse_grid_cells` 视觉翻转，单位在拥有者视角下视觉同列直线落地。





#### Step 9-A：TurnSystem 三分支跨盘分发





| 文件 | 改动 |


|---|---|


| `core/turn_system.gd` | `_process_cell` 跨盘块按 `slot.team_id` + `faction` 改写为三分支：① defender+PLAYER → UI 选盘并广播 ② defender+ENEMY → `consume_cross_choice` 取队列 ③ attacker（任意 faction）→ `_enemy_auto_cross`（确定性，单一目标=守方盘）；PVE/1v1 走 `slot.team_id==""` 旧分支 |


| `core/turn_system.gd` | `_enemy_auto_cross` 落点列改为 `dst_col = COLS - 1 - src_col`（仅 cell.team_id 与目标盘 team_id 均非空时启用） |


| `core/turn_system.gd` | 修复 `_enemy_auto_cross` 中 `tgt_is_hostile` / `nc_is_friendly` 三元表达式操作符优先级 bug（旧 `A and B if C else D` 解析为 `A and (B if C else D)`，PVE 下 hostile 永远 false） |





#### Step 9-B：跨盘选择队列





| 文件 | 改动 |


|---|---|


| `core/turn_system.gd` | 新增 `_pending_cross_choices: Array`，键值 `{source_slot_id, row, col, target_slot_id}` |


| `core/turn_system.gd` | 新增 `enqueue_cross_choice` / `consume_cross_choice` / `clear_cross_choices` API |


| `core/turn_system.gd` | 新增 `_broadcast_cross_board`，仅 1v3 模式调 `Net.send_to_room("action/cross_board", room, payload, "all")` |





**同步保证**：WebSocket FIFO + Go 纯中继；守方依次广播 cross_board#1..N 后才广播 end_turn；远端在 end_turn 触发 `run_pvp_phase_for_slot` 前队列已就绪，无需 await。`_iter_phase_cells_of_slot` 遍历顺序三端一致，键值匹配保证选择不串。





**兜底**：远端 consume 返回 `""` 时取 `enemy_slots[0]` + `push_warning`，避免 desync 卡死；生产中不应触发。





#### Step 9-C：FrontRowSelector 镜像列





| 文件 | 改动 |


|---|---|


| `scripts/ui/front_row_selector.gd` | `_on_target_chosen` 落点列计算改为 `dst_col = COLS - 1 - cell.col`（仅 1v3 模式启用）；前排敌人查找与目标格 lookup 都用 dst_col；冲锋穿透 / vigilance 逻辑保留不变 |





#### Step 9-D：消息处理





| 文件 | 改动 |


|---|---|


| `scripts/test_main.gd` | `_handle_pvp_message` 新增 `"action/cross_board"` 分支 → `Game.turn.enqueue_cross_choice(payload)`；`from == Game.local_player_id` 守卫保证守方 owner 不会自己入队 |





#### Step 9-E：消息协议（本轮新增）





| 消息 | 方向 | payload | 用途 |


|---|---|---|---|


| `action/cross_board` | 守方 owner → all | `{source_slot_id, row, col, target_slot_id}` | 1v3 守方 UI 跨盘选择广播，远端镜像消费；攻方无需广播（确定性） |





#### Step 9-F：文件清单变更（1v3 相关，本阶段实际新增）





```


dev_gd/nsoc/


├── scripts/core/board_layout_resolver.gd    新增：viewer-relative 布局解析器


├── scripts/core/board_registry.gd           新增 by_team / by_owner / adjacent_enemy_slots


├── scripts/core/board_slot.gd               新增 team_id / slot_index，序列化扩展


├── scripts/cell.gd                          新增 team_id / is_hostile_to / is_friendly_to


├── scripts/core/game_context.gd             新增 pvp_match_type / pvp_teams / pvp_dead_players + 工具方法；bootstrap_pvp 扩展 1v3 参数


├── scripts/core/turn_system.gd              新增 run_pvp_phase_for_slot / _pending_cross_choices / _broadcast_cross_board / _enemy_auto_cross 镜像列


├── scripts/core/board_orchestrator.gd       新增 _resolver 支持（1v3 布局装配）


├── scripts/ui/front_row_selector.gd         已存在（Step 6 抽出）；Step 9 补镜像列逻辑


├── scripts/ui/action_order_bar.gd           新增：行动顺序指示器（已完成）


└── scripts/test_main.gd                     _remote_equip_insts 改 dict；_inject_1v3_level_data；action/cross_board 消息处理


```





#### Step 9-G：未完成 / 待跟进





- [ ] `effects/assault_charge.gd` 仍调 `find_adjacent_enemies(dest, dest.is_enemy)` → 1v3 守方冲锋效果可能误判同队，需迁移 `is_hostile_to`


- [ ] `TeammateSidePanel` 队友公开信息面板（未建）


- [ ] 含 await 效果加 result 字段广播（`destroy_unit` / `weaken` / `flood_strategy_hero`）


- [ ] 守方 UI 选盘过程中若网络断开，可能出现部分广播部分未广播的不一致状态；当前依赖断线 → `damage_hero(100)` → 结局结算兜底，未做细粒度回滚






### 11.8 本轮新增（Step 10，2026-06 续）—— 3v3 模式



#### 决策锁定



| 维度 | 决策 |

|---|---|

| 人数 | 6 人（team_a 3 人 vs team_b 3 人） |

| 行动顺序 | A1→B1→A2→B2→A3→B3 严格队伍交替 |

| 跨盘选择 | 所有玩家 UI 选盘（拥有者广播 action/cross_board，其余 5 端消费队列） |

| 胜负 | 死一人即该队败（测试期，同 1v3） |

| 布局 | viewer 自盘居中（BottomGrid）+ 2 队友侧盘；上方敌队 3 盘横排 |

| 落点列 | 镜像列 target_col = COLS - 1 - src_col（沿用 1v3） |

| 队伍命名 | team_a / team_b |

| 1v3 攻方自动跨 | 保持不变 |



#### Step 10-A：服务端



| 文件 | 改动 |

|---|---|

| `server/room.go` | `MaxPlayersForType("3v3")` → 6 |



#### Step 10-B：核心辅助方法



| 文件 | 改动 |

|---|---|

| `game_context.gd` | 新增 `is_multi_team_pvp() -> bool`（返回 pvp_match_type == "1v3" or "3v3"） |

| `game_context.gd` | `bootstrap_pvp` teams_map 推断：优先从 slot_layout 提取 team_id（通用，1v3/3v3 均适用） |

| `board_model.gd` | `front_row_of_slot / back_row_of_slot / step_of_slot` 简化为 `team_id != ""` 统一处理 |

| `turn_system.gd` | `_iter_phase_cells_of_slot` 行顺序判断改为 `team_id != ""`（修复 3v3 对手盘 row 反向 bug） |



#### Step 10-C：布局解析器



| 文件 | 改动 |

|---|---|

| `board_layout_resolver.gd` | 新增 3v3（team_a/team_b）分支；对手队中间盘 → top_slot_id；对手另 2 盘 → extra_top_ids；己方 2 队友 → side_slot_ids |



#### Step 10-D：跨盘逻辑



| 文件 | 改动 |

|---|---|

| `turn_system.gd` | 新增 `team_a/team_b` UI 跨盘分支（owner 选盘广播，远端消费队列） |

| `turn_system.gd` | auto-cross 排除 `team_a/team_b`（禁用，已走 UI 路径） |

| `turn_system.gd` | `_broadcast_cross_board` 开放 3v3（守卫改为 `is_multi_team_pvp()`） |

| `front_row_selector.gd` | 镜像列条件注释更新（逻辑已通用，`cell.team_id != ""` 守卫不变） |



#### Step 10-E：全量广播替换



| 文件 | 改动 |

|---|---|

| `play_controller.gd` | 全部 `pvp_match_type == "1v3"` → `is_multi_team_pvp()`（6 处） |

| `board_orchestrator.gd` | 同上（1 处） |

| `test_main.gd` | 多处 `pvp_match_type == "1v3"` → `is_multi_team_pvp()`（约 7 处） |

| `action_order_bar.gd` | `pvp_match_type != "1v3"` → `not is_multi_team_pvp()`；3v3 team_a 蓝 / team_b 红 |

| `board_slot.gd` | `_on_hero_died` winner 计算改为 `pvp_teams.keys()` 动态取，兼容任意队名 |



#### Step 10-F：大厅与战场装配



| 文件 | 改动 |

|---|---|

| `sparring_panel.gd` | 加 "3v3" 模式按钮（两处 for 循环）；min_players=6；6 格槽位 UI（A/B 队标注） |

| `sparring_panel.gd` | `_on_start_game` 3v3 分支：随机分两队 → team_a/team_b slot_layout + A1→B1→A2→B2→A3→B3 action_order |

| `test_main.gd` | `_inject_3v3_level_data` / `_build_default_3v3_layout` / `_setup_pvp_slots_3v3`（复用 1v3 逻辑） |

| `test_main.gd` | `_inject_pvp_level_data` / `_setup_pvp_slots` 分发加 3v3 分支 |

| `test_main.gd` | 入口 resolver 分支：`is_multi_team_pvp()` 统一，内部按 `pvp_match_type == "3v3"` 区分 layout 来源 |



#### Step 10-G：消息协议汇总（3v3 无新增消息）



3v3 复用 1v3 的全部消息类型（action/play_card / play_equip / activate_equip / end_turn / cross_board / activate_hero）。

服务端纯中继，所有消息广播给 `to="all"`（与 1v3 相同）。



#### Step 10-H：Bug 修复



| Bug | 根因 | 修复 |

|---|---|---|

| teams_map 3v3 推断错误 | all_player_ids 是交替顺序 A1,B1,A2...，按位置切片会把 B1 误分到 team_a | 改从 slot_layout 提取 owner_pid → team_id 映射 |

| 3v3 对手盘行遍历反向 | `_iter_phase_cells_of_slot` 只处理 defender/attacker，ENEMY faction 走 row 2→0 | 改为 `team_id != ""` 统一 row 0→ROWS-1 |

| SparringPanel 3v3 只显示 2 格 | 未加 3v3 分支，else 走 1v1 的 2 格逻辑 | 新增 open_cells=[0..5] 分支 |

