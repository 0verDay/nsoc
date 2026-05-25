# NSOC (Godot 4 卡牌战棋项目) 架构与机制总结

> 当前主开发分支位于 `dev_gd/nsoc/`。仓库根的 `dev1/` 为旧版分叉，本文以 `dev_gd/nsoc/` 为准。

## 1. 项目概述

NSOC 是基于 Godot 4.6 (GDScript) 的卡牌战棋游戏。核心玩法：
- 棋盘 6 行 × 3 列，玩家半场 (row 3-5) 与敌方半场 (row 0-2) 各占 3 行
- 单位有四面血量 (top/bottom/left/right) 与单一攻击力，攻击只伤对位面
- 玩家通过手牌出牌（单位 / 法术），费用每回合 +1 上限
- 回合制驱动：玩家阶段 → 敌方刷怪 → 敌方阶段，逐 cell 推进
- 双方独立"牌堆 / 墓地 / 除外"三区，玩家区参与抽牌循环，敌方区仅累积显示
- 数据驱动：卡牌 / 关卡 / 英雄信息全部 JSON 配置
- 卡组持久化：`user://decks.json` 按英雄 key 存储
- 安卓导出已配置，目标平台移动端

## 2. 启动流程与场景拓扑

`project.godot` 设定 `main_scene = res://scenes/SplashScreen.tscn`，启动顺序：

```
SplashScreen → MainMenu → Main.tscn / TestMain.tscn（战斗）
```

二级面板均继承 `SecondaryPanel`：根 Control PRESET_FULL_RECT、自带 `BackBtn`；`back_pressed` 触发反向转场。

## 3. 战斗场景核心系统架构

### 3.1 分层装配（autoload + 子系统注入）

```
Game (autoload "game_context.gd")
├── deck      DeckManager
├── hero      HeroState
├── mana      ManaSystem
├── board     BoardModel        主棋盘
├── spawners  SpawnerSystem
├── turn      TurnSystem        支持多棋盘遍历
├── play      PlayController
└── combat    CombatSystem

Effects   (autoload) 扫描 scripts/effects/*.gd 自注册
HeroAbilities (autoload) 扫描 scripts/abilities/*.gd 自注册
QuitConfirm   (autoload) 全局退出确认弹窗
```

### 3.2 卡牌生命周期与双阵营牌堆

`DeckManager` 管理 5 个数组：玩家 draw_pile/graveyard/banished，敌方 enemy_graveyard/enemy_banished。`pile_changed` 信号驱动 UI 刷新。

### 3.3 效果注册表与多态钩子

`Effect` 基类 5 个钩子：`on_play / on_death / on_kill / resolve_destination / id+display_name+description`。

`EffectContext` 门面：`board() / combat() / turn() / banish_card / send_to_graveyard / trigger_vigilance / get_counter / inc_counter`。

### 3.4 战斗系统

`CombatSystem.attack_cells`：攻击动画 → 扣对位面血量（frail=四面同扣）→ 收集死亡 → 快照 victim → clear_card → on_kill。

`CombatSystem.move_card`：单段 sine 缓动 + 抛物 sin(π·t) 拱起。

### 3.5 回合驱动（多棋盘）

`TurnSystem.run`：玩家阶段 → 刷怪 → 敌方阶段 → reset_attack_flags（主棋盘+所有额外棋盘）。

`_run_phase(faction)` 先遍历主棋盘，再按注册顺序遍历 `_extra_board_configs`，每块棋盘调用 `_run_phase_on_board(faction, board, hero_resolver)`：
1. `charge` 且未 has_charged → `_run_charge_on_board`
2. 邻接敌方 → `attack_cells`
3. 已到 goal_row → `hero_resolver.call(not for_enemy, atk)` 打英雄
4. `steadfast` → 跳过推进
5. 否则前移一格 → `_trigger_vigilance_on_board`

**玩家前排选择机制**（仅主棋盘 row=3）：
- `front_row_action_requested(cell)` 信号暂停回合
- `FrontRowSelector` 接收信号，高亮可选棋盘，等待玩家点击
- `resolve_front_row_selection(target_id)` 恢复回合
- 若选择非本棋盘：有前排敌人 → 原地攻击；无敌人 → `move_card` 移入目标棋盘

多棋盘 API：
- `register_extra_board(board, hero_resolver)` / `unregister_extra_board(board)`
- `BoardModel.iter_cells` 已做安全校验，跳过未注册格子

### 3.6 出牌规则

`PlayController.can_play_at` 规则唯一仲裁。`handle_drop` 流程：校验 → 扣费 → 法术结算 / 单位飞入 → on_play。

### 3.7 UI 控制器（战斗场景）

**main.gd / TestMain.tscn 共用基础控制器：**
- `HandView` — 手牌渲染 + 抽牌动画
- `DetailPanelController` — 长按大图
- `SidePanelManager(center_x_offset)` — 玩家牌堆/墓地/除外，支持水平定位
- `EnemySidePanelManager(center_x_offset)` — 敌方墓地/除外，支持 `update_clip_center_x()` 动态跟随棋盘移动
- `SettingsPanelController` — 选项面板，`z_index=200` 覆盖所有 UI；参数化 resume/exit/can_open
- `ThemeFactory / EffectBadgeFactory` — 视觉工厂

**TestMain 专属控制器（已抽出独立文件，可未来迁移到 main）：**
- `FrontRowSelector` (`scripts/ui/front_row_selector.gd`)
  - `register_target(id, bg_panel, hero_state)` / `unregister_target(id)`
  - 监听 `TurnSystem.front_row_action_requested`，高亮棋盘（蓝色脉冲，以中心为 pivot），等待点击
  - 选中后结算：有敌 → 原地攻击；无敌 → `combat.move_card` 移入
- `ExtraBoardController` (`scripts/ui/extra_board_controller.gd`)
  - test/move_test 按钮管理
  - 动态创建敌方九宫格棋盘（`_build_board`）+ 独立 BoardModel + HeroState + EnemySidePanelManager
  - 棋盘滑入/滑出动画；注册到 TurnSystem + FrontRowSelector；发 `board_created / board_destroyed` 信号
  - `get_extra_board_model()` / `get_extra_enemy_side_panels()` / `is_extra_pile_button_hit(p)`
- `HeroPanelDragController` (`scripts/ui/hero_panel_drag_controller.gd`)
  - LeftSidePnl 拖拽：阈值检测 → `_apply_drag` → 边界反弹（spring tween）
  - `on_gui_input(event)` 接入 gui_input 信号；`handle_global_release()` 接入全局 _input

**注意：** `PHpPnl`（玩家血量面板）在两个场景的 tscn 里均设 `mouse_filter = 2`（IGNORE），避免遮挡 LeftSidePnl 的拖拽/长按检测。

### 3.8 数据驱动

- `all_cards.json` 卡牌原型库；`review_cards.json` 备战专用；`hero.json` 英雄表；`test_level.json` 关卡
- `data_loader.gd` 静态读 JSON → CardBase/CardUnit/CardSpell + 关卡字典 + 英雄字典

### 3.9 卡组持久化

`scripts/core/deck_storage.gd`：`user://decks.json`，接口 `load_deck / save_deck`。

## 4. 主菜单与转场

要点：导航布局 + 二级面板路由 + 面板扩展动画（size/position 而非 scale）+ 首次入场动画。`SettingsPanelController` 通过 `create_trigger_button=false` 接入。

## 5. 备战界面（PreparePanel）

HeroPnl（HeroCarousel）+ ReviewPnl（竖滚 + rubber band）+ FilterPnl + MusterPnl。手势分流：SCROLL / DRAG / 长按三态互斥。卡组持久化：切英雄前存旧卡组，tree_exiting 兜底保存。

## 6. HeroCarousel（英雄轮播）

竖向无限轮播，3 page 循环 + snap，`current_hero_changed(hero_key)` 信号。

## 7. 卡牌效果清单

| ID | 名称 | 钩子 |
|---|---|---|
| `ash` | 灰烬 | on_death：除外 |
| `autophagy` | 自噬 | on_play：对己方英雄造成累计伤害 |
| `charge` | 冲锋 | TurnSystem：首次行动连步推进 |
| `empower` | 强化 | on_play：友方四维各+1 |
| `exhaust` | 除外 | resolve_destination：法术入除外 |
| `vigilance` | 警戒 | TurnSystem：敌方移入相邻格即攻击 |
| `breakout` | 突围 | on_play：相邻敌方每个提供+1攻+1四维 |
| `assault_charge` | 冲阵 | on_kill：飞入随机尸位递归攻击 |
| `frail` | 虚弱 | CombatSystem内联：受击四面同扣 |
| `steadfast` | 坚守 | TurnSystem拦截：不主动推进 |
| `terrify` | 破胆 | on_kill：击杀目标送入除外 |
| `battle_hardened` | 历战 | on_kill：攻击力+N |
| `fierce_combat` | 酣战 | on_kill：四维各+N |

## 8. 英雄技能清单

| ID | 名称 | 费用 | 每回合限用 | 描述 |
|---|---|---|---|---|
| `restart` | 再起 | 1 | 是 | 弃全手牌补满至 MIN_HAND_SIZE |

## 9. 现有英雄

| key | display_name | max_health | abilities |
|---|---|---|---|
| A | 往日之王：科因 | 30 | restart |
| B | B | 30 | — |
| C | C | 30 | — |
| `enemy_default` | 敌人 | 30 | — |

## 10. 现有卡牌

| 名称 | 类型 | 费用 | 攻击 | 四维 | 效果 |
|---|---|---|---|---|---|
| 填线宝宝 | 单位 | 1 | 1 | 1/1/1/1 | — |
| 灰烬填线宝宝 | 单位 | 2 | 2 | 2/2/2/2 | ash |
| pro哥 | 单位 | 10 | 10 | 10/10/10/10 | ash, autophagy |
| 敢死队 | 单位 | 1 | 1 | 10/1/1/1 | charge |
| 看门狗 | 单位 | 3 | 1 | 2/2/2/2 | vigilance |
| 长板·赵云 | 单位 | 1 | 1 | 6/6/6/6 | breakout, fierce_combat, assault_charge, frail |
| 长板·张飞 | 单位 | 1 | 3 | 20/1/10/10 | steadfast, terrify, battle_hardened |
| 强化 | 法术 | 1 | — | — | empower |

## 11. 工作流

**新效果**：`scripts/effects/<id>.gd` 继承 Effect，实现钩子，重启自动注册。

**新卡牌**：`all_cards.json` 加条目，引用已注册效果 ID；备战界面同步加 `review_cards.json`。

**新英雄技能**：`scripts/abilities/<id>.gd` 继承 HeroAbility，重启自动注册。

**新英雄**：`hero.json` 加 key；`HeroCarousel.HERO_NAMES` 加同名 key。

**新二级面板**：继承 SecondaryPanel，加 BackBtn，在 `MainMenu.SECONDARY_PANEL_SCENES` 注册。

**接入多棋盘**：`Game.turn.register_extra_board(board_model, hero_resolver)`，`FrontRowSelector.register_target(id, bg, hero)`，销毁时对应 unregister。

## 12. 关键设计权衡

- **配置即代码**：效果/技能通过文件名=ID 自动注册，零中央注册表
- **规则单点**：`PlayController.can_play_at` 出牌规则唯一仲裁
- **多棋盘参数化**：`_run_phase_on_board(board, hero_resolver)` 主棋盘和额外棋盘复用同一逻辑，差异仅在 hero_resolver
- **前排选择挂件化**：`FrontRowSelector` 独立文件，TestMain 装配，未来 Main 可直接引入
- **clear_card 之前快照**：on_kill 拿 victim 快照而非 cell 字段
- **EffectContext 自动路由阵营**：效果脚本只调 ctx 接口，不感知 is_enemy
- **SidePanelManager 支持 center_x_offset**：面板随棋盘水平偏移，test 按钮触发棋盘平移后调 `update_clip_center_x()` 同步
- **PHpPnl mouse_filter=IGNORE**：血量显示面板不阻挡 LeftSidePnl 的拖拽/长按事件穿透
- **SettingsOverlay z_index=200**：覆盖 LeftSidePnl(z=10) 等所有游戏 UI
- **转场用 size/position 而非 scale**：避免圆角被拉成椭圆
