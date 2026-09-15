# NSOC 架构说明

> 现行规范（本文件）。历史设计稿见 `docs/archive/`，索引见 `docs/ARCHIVE-INDEX.md`。
> 适用代码：`dev_gd/nsoc/`（Godot 4.7.2 / GDScript）。最后更新：重构阶段 3 进行中。

## 1. 这是什么

卡牌 + 战棋对战游戏。6 行 × 3 列棋盘，单位有四面血量（`front/back/left/right`）与单一攻击力，
攻击只伤对位面；多棋盘（1v3 / 3v3）下单位可跨盘行动。对局模式见 §5。

## 2. 目录与分层

```
dev_gd/nsoc/
├─ scripts/
│   ├─ core/       纯规则内核：不依赖 UI、不依赖场景树（自动加载 Game/Effects/... 在此）
│   │   └─ net/    protocol.gd —— 客户端与服务端共用的协议定义
│   ├─ server/     服务器侧：权威核心 + 会话入口（BattleAuthority / BattleServerSession）
│   ├─ effects/    效果脚本（extends Effect，RefCounted），32 个
│   ├─ abilities/  英雄技能脚本，15 个
│   ├─ actions/    关卡脚本动作，10 个
│   ├─ objectives/ 关卡目标，1 个
│   ├─ ai/         AI 决策与行动落地
│   ├─ net/        客户端网络层（WebSocket 连接、消息分发）
│   ├─ ui/         全部表现层：面板、徽章、轮播、滚动工具、场景气泡
│   └─ app/        场景控制器：main / test_main / main_menu / splash_screen / video_splash
├─ scenes/         .tscn（视图组合）
├─ data/           全部内容数据（卡牌 / 英雄 / 关卡 / 战役 / 演义剧本 / 地图）
└─ tests/          headless 测试与状态哈希工具
```

**分层禁令（由 `tools/ci/check_layers.py` 机器强制，基线棘轮）**

| 层 | 禁止 |
|---|---|
| `core/` `effects/` `abilities/` `actions/` `objectives/` `server/` | 引用 `Control/Panel/Node2D/Label`、`add_child`、`create_tween`、`create_timer`、`get_tree()`、`get_node(`、`$节点`、`/root/`、`has_method(`、`.call(`、`res://scripts/ui/`、`res://scenes/`，以及 `ui/` 里声明的任何 `class_name` |
| 其它层 | `ui/` 可依赖 core，反之禁止；`server/` 不得依赖 `ui/`、`app/` |

当前违规 **87 处**（全部是既有的 `Control` 字段/`add_child` 生命周期等硬骨头，见 `tools/ci/layer_baseline.json`）；
**只允许减少，不允许新增**。

## 3. 核心子系统

| 模块 | 职责 | 关键文件 |
|---|---|---|
| `Game`（自动加载） | 全局上下文：持有 decks / manas / registry / turn / deck / mana、对局模式、规则随机源、等待入口 | `core/game_context.gd` |
| `BoardRegistry` / `BoardSlot` / `BoardModel` | 多棋盘：盘注册表、单盘上下文（棋盘+英雄+墓地+生成器）、6×3 纯数据棋盘 | `core/board_registry.gd`、`core/board_slot.gd`、`core/board_model.gd` |
| `TurnSystem` | 回合驱动：阶段遍历、单格行动裁决、跨盘、冲锋、警戒 | `core/turn_system.gd` |
| `CombatSystem` | 战斗：**纯结算** `resolve_attack()` / `is_cell_dead()` + 表现与时序 `attack_cells()` / `move_card()` | `core/combat_system.gd` |
| `PlayController` | 出牌规则唯一来源（`can_play_at`）、法术/装备落地、PVP 出牌广播 | `core/play_controller.gd` |
| 四个注册表 | 效果 / 技能 / 关卡动作 / 关卡目标的**显式路径表**（新增必须登记，CI 校验表与目录一致） | `core/*_registry.gd` |
| `DeckManager` / `ManaSystem` / `HeroState` | 牌堆（含确定性洗牌）、费用、英雄状态 | `core/deck_manager.gd` 等 |
| `BoardOrchestrator` | 棋盘装配与附盘动画（属表现层，已移出 core） | `ui/board_orchestrator.gd` |
| `Net` / `Dialogue` / `QuitConfirm` | 客户端网络、对话气泡队列、退出确认（后两者是纯 UI，已移出 core） | `net/`、`ui/dialogue_manager.gd`、`ui/quit_confirm.gd` |

## 4. 数据驱动与扩展点

| 想扩展什么 | 只需改哪里 |
|---|---|
| 加一张卡 | `data/all_cards.json`（需要新机制时再加一个 `scripts/effects/xxx.gd` 并在 `core/effect_registry.gd` 的 `EFFECT_PATHS` 登记） |
| 加一个效果 / 英雄技能 / 关卡动作 / 关卡目标 | 对应目录新增一个脚本 + 在对应注册表登记（CI 会校验漏登记） |
| 加一个关卡 / 战役章节 | `data/chapters/*.json`（`scenes/chapters/` 已有通用 `ChapterPanelBase` 面板） |
| 加一个演义剧本 | `data/empire_maps/*.json`（地图编辑器见 `dev_gd/tools/empire_map_tool/`） |
| 加一种对局模式 | `core/battle_mode.gd` 增加枚举 + `Game` 对应装配路径 |
| 加一条网络消息 | `core/net/protocol.gd` 声明 + 递增 `VERSION` |

关卡 JSON 的字段（`boards` / `initial_units` / `spawners` / `cards` / `triggers` / `board_events` / `objective`）
由 `tools/ci/check_content.py` 做结构与交叉引用校验（含卡名、技能、动作、场景路径、坐标范围）。

## 5. 对局模式（`BattleMode`）

| 模式 | 触发 | 特点 |
|---|---|---|
| `CAMPAIGN` | `pending_chapter_config` 或 `pending_level_path` 非空 | 脚本化关卡，固定牌堆，不接 AI |
| `SKIRMISH` | 两者皆空 | 默认关卡 + 接 AI |
| `EMPIRE` | `pending_empire_battle` 非空 | 演义出征，关卡在代码中合成，结束回写结果 |
| `PVP` | `Game.bootstrap_pvp(...)` | 牌组/槽位由服务器下发 |

## 6. 确定性与"瞬时模式"

- **规则随机源**：所有影响对局的随机都必须走 `Game.battle_rng`（`rand_index()` / `shuffle_in_place()`）。
  PVP 由服务器下发的种子驱动；PVE 可用 `Game.pending_battle_seed` 固定；规则层**禁止**裸 `randi()` / `Array.shuffle()`。
- **行动定序**：按 `BoardSlot.order_key()`（即 `slot_index`）升序，**不读取任何屏幕坐标**。
- **动画等待**：规则层所有等待统一走 `Game.wait_delay()`。
  `Game.instant_battle = true` 时立即返回（服务器批量结算 / CI），**只跳过等待，不改变状态转移**。

## 7. 测试与验证（全部 headless，已接入 CI）

| 套件 | 场景 | 覆盖 |
|---|---|---|
| `HeadlessBattle` | 单盘战役 3 回合 | 冒烟 + 逐回合状态哈希 + 确定性 |
| `HeadlessTestBattle` | 多棋盘 PVE（6 盘 + AI） | 第二条黄金路径 + 无头选盘决策器 |
| `AuthorityTest` | 46 条断言 | 权威核心：身份/回合/序号/限速/私有视图 |
| `ServerSessionTest` | 32 条断言 | 服务器边界：伪造服务器消息、身份绑定、事件路由 |
| `SceneLoadTest` | 27 个 `.tscn` | 场景可装配 + 章节面板契约 |
| `RulesTest` | 41 条断言 | 规则层纯逻辑：方向/费用/牌堆/标记/模式/定序/随机源/战斗结算 |

本地运行：

```powershell
# 全部一次性跑（预热导入 + 冒烟 + 确定性校验）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\ci\run_headless_smoke.ps1 -TempCopy -Verify

# 跑任意测试场景
powershell -NoProfile -ExecutionPolicy Bypass -File tools\ci\run_headless_smoke.ps1 `
    -TempCopy -Scene "res://tests/RulesTest.tscn"

# 静态检查
py -3 tools\ci\check_layers.py     # 分层棘轮
py -3 tools\ci\check_content.py    # 内容与注册表一致性
```

**状态哈希基线**：单盘 `cc675fe8…`、多棋盘 `0576fcc9…`（信息性基线；CI 断言的是"两次运行一致"）。
任何重构都应做到"哈希逐位不变"，否则需要说明为何是刻意的行为变更。

## 8. 常见陷阱（都踩过）

1. **全新副本必须先 `--import` 预热**：没有 `.godot/global_script_class_cache.cfg` 时所有 `class_name` 都会解析失败，报出上百条假错误。
2. **协程不能取返回值**：`Game.turn.run()` 是 `-> void` 协程，`var s = Game.turn.run()` 会直接 Parse Error，必须 `await`。
3. **脚本解析失败 = Godot 静默空转**：场景根节点没挂上脚本时进程不会退出，外层必须有进程级超时 + Kill。
4. **GDScript 运行时错误不会终止 `_ready()`**：测试函数被错误打断时会"假通过"，因此所有测试都有 `EXPECTED_CASES` 总数校验。
5. **Windows PowerShell 5.1 把无 BOM UTF-8 当 GBK**：`.ps1` 一律保持纯 ASCII；`.py` / `.gd` 用 UTF-8。
6. **PS 5.1 的 `[ordered]@{}` 不能用整数做键**（会被当成位置索引抛异常），用普通 `@{}`。
