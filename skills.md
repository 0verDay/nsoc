# NSOC (Godot 4 卡牌战棋项目) 架构与机制总结

## 1. 项目概述

NSOC 是基于 Godot 4.6 (GDScript) 的卡牌战棋游戏。核心玩法：
- 棋盘 6 行 × 3 列，玩家半场 (row 3-5) 与敌方半场 (row 0-2) 各占 3 行
- 单位有四面血量 (top/bottom/left/right) 与单一攻击力，攻击只伤对位面
- 玩家通过手牌出牌（单位 / 法术），费用每回合 +1 上限
- 回合制驱动：玩家阶段 → 敌方刷怪 → 敌方阶段，逐 cell 推进
- 双方独立"牌堆 / 墓地 / 除外"三区，玩家区参与抽牌循环，敌方区仅累积显示
- 数据驱动：卡牌 / 关卡 / 英雄信息全部 JSON 配置 (`data/test_card.json`、`test_level.json`、`test_hero.json`)
- 安卓导出已配置，目标平台移动端（已加触摸拖动滚动支持）

## 2. 核心系统架构

### 2.1 分层装配（autoload + 子系统注入）

```
Game (autoload "game_context.gd")
├── deck      DeckManager       玩家+敌方双方牌堆/墓地/除外
├── hero      HeroState         双英雄血量与名字 (player_name / enemy_name)
├── mana      ManaSystem        费用系统
├── board     BoardModel        棋盘抽象 + 邻接查询
├── spawners  SpawnerSystem     敌方刷怪（支持多 positions 共享一份配置）
├── turn      TurnSystem        回合驱动
├── play      PlayController    出牌规则唯一仲裁 + 击杀回调中心
├── combat    CombatSystem      战斗动画 / 伤害结算
└── card_db   Dictionary        name → CardBase 主表

Effects (autoload "effect_registry.gd")
              启动期扫描 res://scripts/effects/*.gd 自注册
              兼容 .gd / .gdc / .remap (适配安卓导出 mode=2)
```

`main.gd` 是薄装配器：实例化所有子模块、注入引用、连接信号、路由全局输入（点击外部关侧栏）。业务全部委托给 `Game.*` + `Effects.*` + UI 控制器。

### 2.2 卡牌生命周期与双阵营牌堆

`DeckManager` 管理 5 个数组：
- 玩家：`draw_pile` / `graveyard` / `banished`，参与抽牌循环（牌堆抽空时回收墓地洗回）
- 敌方：`enemy_graveyard` / `enemy_banished`，仅累积显示，不参与抽牌

`pile_changed` 信号统一驱动 UI 刷新（"draw"/"graveyard"/"banish"/"enemy_graveyard"/"enemy_banish"）。

`PlayController.handle_unit_death` 按 `cell.is_enemy` 路由到对应阵营牌堆；效果脚本通过 `EffectContext.banish_card / send_to_graveyard` 自动按 `dying_is_enemy` 字段路由，无需感知阵营。

### 2.3 效果注册表与多态钩子

`Effect` 基类提供 5 个可重写钩子（默认 no-op）：
- `id() / display_name() / description()` — 元数据，徽章 / 详情面板自动渲染
- `on_play(card_data, ctx)` — 出牌时触发；单位 ctx.target_cell = 落点 cell
- `on_death(card_data, ctx) -> bool` — 阵亡时；返回 true 表示接管尸体处理（如除外）
- `on_kill(attacker_cell, victim_cells, ctx)` — 击杀回调；victim_cells 为 `{cell, card_name, is_enemy}` 字典数组（cell 已 clear_card，所以快照原数据）
- `resolve_destination(card_data, ctx) -> String` — 法术结算去向 ("graveyard"/"banish")

注册表 `Effects.trigger_play / trigger_death / trigger_kill / resolve_destination` 提供分发；`trigger_kill` 内部 `await`，支持效果串联递归（如冲阵 → 攻击 → 再击杀 → 再冲阵）。

`EffectContext` 是受控访问门面：
- 子系统访问：`board() / combat() / turn() / game`
- 棋盘查询：`get_adjacent_occupied / get_adjacent_enemies`
- 卡牌去向：`banish_card / send_to_graveyard`（按 dying_is_enemy 路由）
- 战斗调用：`trigger_vigilance(cell)`、英雄伤害、计数器（`get_counter / inc_counter`）

### 2.4 战斗系统

`CombatSystem.attack_cells(attacker, defenders)`：
1. 攻击者播攻击动画
2. 对每个 defender 扣对位面血量；若 defender 含 `frail`（虚弱）则四面同步扣血
3. 等 0.45s 命中延迟
4. 收集死亡 cell（frail 时任一面 ≤0 即视为阵亡）
5. 等 0.45s 死亡延迟
6. 在 clear_card 之前快照 victim 的 `card_name / is_enemy` 供 on_kill 使用
7. 调 `_play_controller.handle_unit_death(dc)` 路由到墓地，再调 `dc.clear_card()`
8. attacker 仍存活时调 `handle_kills(attacker, victims)` 触发 on_kill

`CombatSystem.move_card`：单段 sine 缓动 + 抛物 sin(π·t) 拱起（避免中点速度归零的顿挫感）。

### 2.5 回合驱动

`TurnSystem.run` 三阶段：玩家 → 敌方刷怪 → 敌方。

`_run_phase(faction)` 每个 cell 行动顺序：
1. `has_card && !has_attacked && 是己方阵营` 才行动
2. 含 `charge` 且未 has_charged → `_run_charge`（一次性扫描终点 + 弧线移动 + 警戒哨 + 终点结算）
3. 邻接敌方 → `attack_cells`
4. 已到 goal_row → 直接攻击对方英雄
5. 含 `steadfast`（坚守）→ 跳过推进
6. 否则前移一格 → 移动后触发 `_trigger_vigilance(target, for_enemy)`

警戒哨实现：扫 entered_cell 四邻找含 `vigilance` 的敌方单位，依次发起攻击；mover 死亡后立即停止。

### 2.6 出牌规则

`PlayController.can_play_at(cell, data)` 是规则唯一仲裁：
- 回合运行中禁止
- 费用不足禁止
- 单位：cell 必须为空 + row > PLAYER_DEPLOY_MIN_ROW（玩家半场）
- 法术：按 `target` 字段判定（`""` 任意、`friendly_unit`、`enemy_unit`、`any_unit`）

`handle_drop` 流程：
1. 二次校验 → 扣费 → 标记手牌占位为已消耗
2. 法术：直接结算 `_play_spell`（按 `resolve_destination` 决定去向）
3. 单位：飞入动画 → `cell.set_card` → `_trigger_unit_play_effects` 触发 on_play（此时 ctx.target_cell = 落点，"突围" 等效果可正确读取相邻状态）

### 2.7 UI 控制器

- `HandView` 手牌渲染 + 抽牌动画（含"虚空"占位卡逻辑）
- `DetailPanelController` 长按看大图
- `SidePanelManager` 玩家右侧栏（牌堆 / 墓地 / 除外）右拉
- `EnemySidePanelManager` 敌方面板（墓地 / 除外）顶部下拉，按钮挂在 EnemyHpPnl 左右
- `SettingsPanelController` 设置
- `EffectBadgeFactory / ThemeFactory` 视觉工厂
- `DragScrollHelper` 给 ScrollContainer 加触摸拖动滚动（移动端）；列表按钮 `mouse_filter = PASS` 让事件冒泡

UI 锚点 / 阴影 / 圆角统一通过 `ThemeFactory` 派生，全局风格一致。

### 2.8 数据驱动

- `data_loader.gd` 静态读 JSON → CardBase / CardUnit / CardSpell + 关卡字典
- `test_card.json` 卡牌主表（每卡 effects 字符串数组）
- `test_level.json` 关卡：`initial_units` 初始摆放、`spawners` 刷怪表（支持 `positions` 数组共享 timer/interval，向后兼容单数 `position` 字段）
- `test_hero.json` 双英雄 `name` + `health`

## 3. 卡牌效果清单（已实现）

| ID | 名称 | 钩子 | 描述 |
|---|---|---|---|
| `ash` | 灰烬 | on_death | 死亡后从游戏中除外 |
| `autophagy` | 自噬 | on_play | 出牌时对己方英雄造成 x 伤害（x = 已触发次数计数） |
| `charge` | 冲锋 | （TurnSystem 主动） | 首次行动沿前进方向连步推进至障碍/敌人，遇敌发起攻击 |
| `empower` | 强化 | on_play | 法术，对友方单位四维各 +1 |
| `exhaust` | 除外 | resolve_destination | 法术专用，使用后入除外区而非墓地 |
| `vigilance` | 警戒 | （TurnSystem/EffectContext 主动） | 非己方回合时，敌方单位移动进入相邻格立即攻击之 |
| `breakout` | 突围 | on_play | 入场时，相邻每个敌方单位提供 +1 攻击力与 +1 四维 |
| `assault_charge` | 冲阵 | on_kill | 击杀后弧线飞入随机一具尸位，触发警戒哨；落点存活且邻敌存在则攻击（递归触发） |
| `frail` | 虚弱 | （CombatSystem 内联处理） | 受任意面伤害时，四面同步扣血 |
| `steadfast` | 坚守 | （TurnSystem 拦截） | 阶段推进时不主动移动；仍可攻击邻敌或英雄 |
| `terrify` | 破胆 | on_kill | 被本单位击杀的目标从对应阵营墓地移出送入除外 |
| `battle_hardened` | 历战 | on_kill | 击杀后攻击力 +N（N = 本次击杀数） |

## 4. 现有卡牌（test_card.json）

| 名称 | 类型 | 费用 | 攻击 | 四维 (T/B/L/R) | 效果 |
|---|---|---|---|---|---|
| 填线宝宝 | 单位 | 1 | 1 | 1/1/1/1 | — |
| 灰烬填线宝宝 | 单位 | 2 | 2 | 2/2/2/2 | ash |
| pro哥 | 单位 | 10 | 10 | 10/10/10/10 | ash, autophagy |
| 敢死队 | 单位 | 1 | 1 | 10/1/1/1 | charge |
| 看门狗 | 单位 | 3 | 1 | 2/2/2/2 | vigilance |
| 长板·赵云 | 单位 | 10 | 1 | 6/6/6/6 | breakout, assault_charge, frail |
| 长板·张飞 | 单位 | 10 | 3 | 20/1/10/10 | steadfast, terrify, battle_hardened |
| 强化 | 法术 | 1 | — | — | empower |

## 5. 添加新卡牌 / 新效果的工作流

**新效果**：
1. 在 `scripts/effects/` 新建 `<id>.gd`，继承 `Effect`，实现 `id() / display_name() / description()`
2. 按需重写 `on_play / on_death / on_kill / resolve_destination` 中之一或多个
3. 重启游戏，注册表自动扫描挂入 `Effects` 单例；徽章 / 详情面板自动渲染元数据

**新卡牌**：
1. `test_card.json` 增条目（name / type / cost / health / attack / count / effects）
2. 引用上面已注册的效果 ID 即可

**新关卡刷怪点**：
1. `test_level.json` 的 `spawners` 加配置（`positions` 数组共享一份 interval / timer）

## 6. 关键设计权衡

- **配置即代码**：效果脚本通过文件名 = ID 自动注册，避免中央注册表的同步成本
- **规则单点**：`PlayController.can_play_at` 是出牌规则唯一来源，cell 仅询问不仲裁
- **战斗与移动统一动画**：`move_card` / `attack_cells` 复用，确保冲锋、冲阵、普通推进视觉一致
- **clear_card 之前快照**：on_kill 拿不到 cell 上的 card_name 等字段，combat_system 显式快照 victim 数据传入
- **EffectContext 自动路由阵营**：效果脚本只调 `ctx.banish_card`，由 ctx 按 dying_is_enemy 决定送往哪个牌堆
- **on_play 在 set_card 之后触发**：突围等需查询自身相邻状态的效果可正确工作（旧版本是先触发后落子）
