# NSOC (Godot 4 卡牌战棋项目) 架构与机制总结

> 当前主开发分支位于 `dev_gd/nsoc/`。仓库根的 `dev1/` 为旧版分叉，本文以 `dev_gd/nsoc/` 为准。

## 1. 项目概述

NSOC 是基于 Godot 4.6 (GDScript) 的卡牌战棋游戏。核心玩法：
- 棋盘 6 行 × 3 列，玩家半场 (row 3-5) 与敌方半场 (row 0-2) 各占 3 行
- 单位有四面血量 (top/bottom/left/right) 与单一攻击力，攻击只伤对位面
- 玩家通过手牌出牌（单位 / 法术），费用每回合 +1 上限
- 回合制驱动：玩家阶段 → 敌方刷怪 → 敌方阶段，逐 cell 推进
- 双方独立"牌堆 / 墓地 / 除外"三区，玩家区参与抽牌循环，敌方区仅累积显示
- 数据驱动：卡牌 / 关卡 / 英雄信息全部 JSON 配置（`data/all_cards.json` 原型库、`data/review_cards.json` 备战图鉴、`data/hero.json` 英雄表、`data/test_level.json` 关卡）
- 卡组持久化：`user://decks.json` 按英雄 key 存储；战斗启动按当前英雄从原型库筛出 `user://battle_cards.json` 作为本局牌池
- 安卓导出已配置，目标平台移动端（已加触摸拖动滚动支持）

## 2. 启动流程与场景拓扑

`project.godot` 设定 `main_scene = res://scenes/SplashScreen.tscn`，启动顺序：

```
SplashScreen (点击进入 → 后台预加载 + 整体淡出)
  └─ MainMenu (主菜单，5 左侧导航 + 3 右下导航 + 左上 ProfilePnl + 右上选项)
        ├─ 点击导航按钮 → 该按钮所在面板扩展为全屏 → 实例化对应二级面板
        │     ├─ GrowPanel / FriendPanel / CollectionPanel / CustomPanel
        │     ├─ CampaignPanel / JourneyPanel / SparringPanel
        │     ├─ ProfileSubPanel（点 ProfilePnl 触发）
        │     └─ PreparePanel（备战，HeroCarousel + Review 网格 + Muster 列表）
        └─ 右下"开打"或"对战"等流程 → Main.tscn (战斗主场景)
```

二级面板均继承 `SecondaryPanel`：根 Control PRESET_FULL_RECT、自带 `BackBtn`，挂入扩展后的面板内淡入；`back_pressed` 信号触发反向转场 + `detach_with_fade` 同步淡出。整棵子树 `transition_skip` 元数据，绕过主菜单按钮淡出收集器。

`QuitConfirm` (autoload) 拦 Android `NOTIFICATION_WM_GO_BACK_REQUEST`、主菜单"退出游戏"按钮；显示半透 overlay + 居中大面板，点面板 = 真退，点 overlay = 取消。`project.godot` 关 `quit_on_go_back` 让本拦截先于引擎默认行为生效。

## 3. 战斗场景核心系统架构

### 3.1 分层装配（autoload + 子系统注入）

```
Game (autoload "game_context.gd")
├── deck      DeckManager       玩家+敌方双方牌堆/墓地/除外
├── hero      HeroState         双英雄血量与名字 + abilities 列表
├── mana      ManaSystem        费用系统
├── board     BoardModel        棋盘抽象 + 邻接查询
├── spawners  SpawnerSystem     敌方刷怪（支持多 positions 共享一份配置）
├── turn      TurnSystem        回合驱动
├── play      PlayController    出牌规则唯一仲裁 + 击杀回调中心
├── combat    CombatSystem      战斗动画 / 伤害结算
└── card_db   Dictionary        name → CardBase 主表（载自 all_cards.json）

Effects (autoload "effect_registry.gd")
              启动期扫描 res://scripts/effects/*.gd 自注册
              兼容 .gd / .gdc / .remap (适配安卓导出 mode=2)

HeroAbilities (autoload "hero_ability_registry.gd")
              启动期扫描 res://scripts/abilities/*.gd 自注册
              同样兼容 .gd / .gdc / .remap
              管理英雄主动技能：费用 / 每回合限用 / 激活分发

QuitConfirm (autoload "quit_confirm.gd")
              全局退出确认弹窗（拦 Android 返回键 + 主菜单退出按钮）
```

`Game.bootstrap()` 战斗启动：
1. `DataLoader.get_hero(BATTLE_HERO_KEY)` 取玩家英雄数据（display_name / battle_name / max_health / abilities / skill_text）
2. `DataLoader.get_enemy_default()` 取敌方默认数据
3. `hero.setup(...)` 同时存 display 名 + battle 名 + abilities
4. `DataLoader.generate_battle_cards(BATTLE_HERO_KEY)`：读 `decks.json[hero_key].cards`，从 `all_cards.json` 复制原型并写入 count，输出到 `user://battle_cards.json`
5. `card_db` 由 `all_cards.json` 全量装载（关卡刷怪、initial_units 按 name 反查），玩家牌组只装本局 battle_cards
6. 加载关卡 + 初始化 deck/mana/counters

`main.gd` 是薄装配器：实例化所有子模块、注入引用、连接信号、路由全局输入（点击外部关侧栏）。业务全部委托给 `Game.*` + `Effects.*` + UI 控制器。

### 3.2 卡牌生命周期与双阵营牌堆

`DeckManager` 管理 5 个数组：
- 玩家：`draw_pile` / `graveyard` / `banished`，参与抽牌循环（牌堆抽空时回收墓地洗回）
- 敌方：`enemy_graveyard` / `enemy_banished`，仅累积显示，不参与抽牌

`pile_changed` 信号统一驱动 UI 刷新（"draw"/"graveyard"/"banish"/"enemy_graveyard"/"enemy_banish"）。

`PlayController.handle_unit_death` 按 `cell.is_enemy` 路由到对应阵营牌堆；效果脚本通过 `EffectContext.banish_card / send_to_graveyard` 自动按 `dying_is_enemy` 字段路由，无需感知阵营。

### 3.3 效果注册表与多态钩子

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

### 3.4 战斗系统

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

### 3.5 回合驱动

`TurnSystem.run` 三阶段：玩家 → 敌方刷怪 → 敌方。

`_run_phase(faction)` 每个 cell 行动顺序：
1. `has_card && !has_attacked && 是己方阵营` 才行动
2. 含 `charge` 且未 has_charged → `_run_charge`（一次性扫描终点 + 弧线移动 + 警戒哨 + 终点结算）
3. 邻接敌方 → `attack_cells`
4. 已到 goal_row → 直接攻击对方英雄
5. 含 `steadfast`（坚守）→ 跳过推进
6. 否则前移一格 → 移动后触发 `_trigger_vigilance(target, for_enemy)`

警戒哨实现：扫 entered_cell 四邻找含 `vigilance` 的敌方单位，依次发起攻击；mover 死亡后立即停止。

### 3.6 出牌规则

`PlayController.can_play_at(cell, data)` 是规则唯一仲裁：
- 回合运行中禁止
- 费用不足禁止
- 单位：cell 必须为空 + row > PLAYER_DEPLOY_MIN_ROW（玩家半场）
- 法术：按 `target` 字段判定（`""` 任意、`friendly_unit`、`enemy_unit`、`any_unit`）

`handle_drop` 流程：
1. 二次校验 → 扣费 → 标记手牌占位为已消耗
2. 法术：直接结算 `_play_spell`（按 `resolve_destination` 决定去向）
3. 单位：飞入动画 → `cell.set_card` → `_trigger_unit_play_effects` 触发 on_play（此时 ctx.target_cell = 落点，"突围" 等效果可正确读取相邻状态）

### 3.7 UI 控制器（战斗场景）

- `HandView` 手牌渲染 + 抽牌动画（含"虚空"占位卡逻辑）
- `DetailPanelController` 长按看大图（备战界面也复用同一实现）
- `SidePanelManager` 玩家右侧栏（牌堆 / 墓地 / 除外）右拉
- `EnemySidePanelManager` 敌方面板（墓地 / 除外）顶部下拉，按钮挂在 EnemyHpPnl 左右
- `SettingsPanelController` 设置（参数化：`create_trigger_button / resume_label / exit_label / exit_action / can_open`，主菜单与战斗共用）
- `EffectBadgeFactory / ThemeFactory` 视觉工厂
- `DragScrollHelper` 给 ScrollContainer 加触摸拖动滚动（移动端）；列表按钮 `mouse_filter = PASS` 让事件冒泡

UI 锚点 / 阴影 / 圆角统一通过 `ThemeFactory` 派生，全局风格一致。

### 3.8 数据驱动

- `data_loader.gd` 静态读 JSON → CardBase / CardUnit / CardSpell + 关卡字典 + 英雄字典
- `all_cards.json` 卡牌原型库（图鉴），`generate_battle_cards(hero_key)` 据此 + decks.json 输出 `user://battle_cards.json`
- `review_cards.json` 备战界面专用（含占位卡），与战斗牌池分离，避免调试卡污染
- `hero.json` `{version, heroes: {key: {display_name, battle_name, max_health, abilities, skill_text}}, enemy_default: {...}}`
- `test_level.json` 关卡：`initial_units` 初始摆放、`spawners` 刷怪表（支持 `positions` 数组共享 timer/interval，向后兼容单数 `position` 字段）

### 3.9 卡组持久化（DeckStorage）

`scripts/core/deck_storage.gd` 静态门面，文件 `user://decks.json`：

```
{
  "version": 1,
  "decks": { "<hero_key>": { "cards": { "<card_name>": <count>, ... } }, ... }
}
```

接口：`load_all() / save_all(data) / load_deck(hero_key) / save_deck(hero_key, cards)`。全量读写 + IO 失败 push_warning 静默退化。`PreparePanel` 切英雄/退出时按 `_current_hero_key` 调 `save_deck`；`Game.bootstrap` 通过 `DataLoader.generate_battle_cards` 读取并落到 battle_cards.json。

## 4. 主菜单与转场（MainMenu）

`main_menu.gd` 装配主菜单 + 转场动画。要点：

- **导航布局**：左侧 `LeftNavPnl`（GrowBtn / PrepareBtn / FriendBtn / CollectionBtn / CustomBtn）、右下 `RightSidePnl`（CampaignBtn / JourneyBtn / SparringBtn）、左上 `ProfilePnl`（自身作为按钮，套透明 ClickArea 接管点击）、右上动态创建 `OptionsBtn`
- **二级面板路由**：`SECONDARY_PANEL_SCENES` 把按钮 name → PackedScene；`ProfilePnl` 用面板自身节点名作 key
- **设置面板复用**：`SettingsPanelController` 通过 `create_trigger_button=false` 接入主菜单的 OptionsBtn；`exit_action` 走 `QuitConfirm.request_quit`
- **正向转场**：被点中按钮所在面板内全部按钮淡出 + 其余面板/按钮水平滑出 + 该面板以中心扩大 + Tween size/position/pivot（避免 scale 把圆角拉成椭圆）；扩展终态四周留 `EXPANDED_MARGIN` 让边框可见。完成后 `_spawn_secondary_panel` 把对应场景挂入并淡入
- **冻结子控件**：扩展期间面板内子控件 `top_level=true` + 锁 global_position/size，避免被父布局拉伸；反向时还原 `top_level=false`
- **反向转场**：`SecondaryPanel.back_pressed` → `_trigger_reverse` → 所有节点 Tween 回 `_initial_state` + 二级面板同步 `detach_with_fade`；面板内按钮 alpha 延迟到面板收缩接近完成时才淡入（与正向"未完全覆盖前按钮就透明"对称）
- **首次入场动画**：SplashScreen 设 `Engine.set_meta("play_main_menu_intro", true)`；MainMenu `_setup_transition` 末尾消费 meta 触发 `_play_intro_animation`（节点水平外推 + alpha=0 → Tween 回归）
- **状态机锁**：`_is_transitioning` / `_is_expanded` 防重入，转场期间禁用 OptionsBtn / ProfilePnl hover/press 反馈

## 5. 备战界面（PreparePanel）

`scripts/ui/prepare_panel.gd` 继承 `SecondaryPanel`，4 子面板布局：

- **HeroPnl**（左 1/3，整高）：透明裁剪容器，挂 `HeroCarousel`
- **ReviewPnl**（中 1/3，整高）：自定义 `Viewport` + `Content(MarginContainer)` + `Grid(GridContainer)`，竖向滚动 + rubber band 越界回弹；卡面来自 `review_cards.json`，按 `(cost 升, name 字典序升)` 排列；`_relayout_review_grid` 动态算 `h_separation`/`margin_left/right` 让"卡间距 == 卡到边间距"
- **FilterPnl**（右 1/3 顶部，与 BackBtn 等高）：透明，仅承载排序按钮（NO_SORT / COST_ASC / COST_DESC 循环）
- **MusterPnl**（右 1/3 底部）：灰底点兵列表，VBox + 每条记录 `{card, count}`

**手势分流**（`GestureMode { NONE, SCROLL, DRAG }`）：
- 按下 → 启长按计时（DetailPanel）+ 命中卡放大 1.1×
- 竖直位移 ≥ `SCROLL_THRESHOLD_PX (18)` 先到 → SCROLL：取消详情 + 还原缩放，永久退出按下卡
- 水平位移 ≥ `DRAG_START_PX (40)` 先到（且按下命中卡） → DRAG：创建 preview 跟随鼠标，**保留**详情显示 + 卡片缩放（按需求拖拽时不撤详情）；松开后判定落点是否在 MusterPnl → `_add_to_muster`

**rubber band 公式**：`f(x) = (x * c * d) / (d + c * x)`，`c = OVERSCROLL_RESISTANCE (0.55)`、`d = viewport.size.y`；越界量 → 衰减位移，永远不超过可视高。

**卡组持久化接入**：
- `_install_deck_persistence` 拿 `HeroCarousel.current_hero_changed` 信号
- 切英雄前先 `_save_current_deck()` 存旧的；切完 `_load_deck_for(new_key)` 重建 `_muster_entries` 并刷新
- `tree_exiting` + 重写 `detach_with_fade` 兜底保存（覆盖任何销毁路径）

## 6. HeroCarousel（英雄轮播）

`scripts/ui/hero_carousel.gd`，竖向无限轮播：

- 自身 clip_contents，内部 `Track` 节点 + 3 个 page（prev/current/next，分别承载 `_current_page-1 / _current_page / _current_page+1`）
- track 平时位移 `-step (= _page_h + PAGE_GAP_PX)`，让 `_pages[1]` 居中
- 拖动 ≥ `DRAG_THRESHOLD_PX (8)` 进入拖拽态，实时改 track.position.y
- 释放：`|delta| ≥ SNAP_RATIO * page_h (0.25)` → tween 整页 snap + `_current_page += ±1` + 翻完后重置 track 位移（无缝循环）；否则回弹原位
- 数据：`HERO_NAMES = ["A","B","C"]` 占位 key；`_load_hero_db()` 从 `hero.json` 装入 `_hero_display_names` / `_hero_skills`，缺失时回落
- 每 page 视觉：`ThemeFactory.panel` 白底圆角 + 底部 25% 自绘 `SkillMask`（带顶点色的圆角多边形：上 95% 白渐到下灰，对齐 page 圆角 20）；遮罩内顶部 42% = 大字号英雄名，下方 = 自动换行技能文案
- 翻页完成发 `current_hero_changed(hero_key)` 信号；`current_hero_key()` 返回当前页对应 HERO_NAMES 元素

## 7. 卡牌效果清单（已实现）

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
| `fierce_combat` | 酣战 | on_kill | 击杀后本单位四维各 +N（N = 本次击杀数）；与 battle_hardened 对称（一个堆攻、一个堆血） |

## 8. 英雄技能清单（已实现）

英雄技能与卡牌效果是两套独立系统。技能由 `HeroAbility` 基类驱动，文件名 = ID，扫描注册到 `HeroAbilities` autoload。基类钩子：`id / display_name / description / cost / once_per_turn / can_activate / on_activate`。激活流程：`HeroAbilities.activate(id, ctx)` → 校验 `can_activate` → `Game.mana.spend(cost)` → 写每回合占用标记 → 发 `ability_used` 信号 → `await on_activate(ctx)`。新回合需 `main.gd` 在 `mana.start_new_turn` 后调 `HeroAbilities.reset_turn_usage()`。

`HeroState.player_abilities / enemy_abilities` 来自 `hero.json[hero_key].abilities`，UI 按钮按列表生成。

| ID | 名称 | 费用 | 每回合限用 | 描述 |
|---|---|---|---|---|
| `restart` | 再起 | 1 | 是 | 弃置全部手牌进墓地，再补齐至 MIN_HAND_SIZE（ctx 需提供 `hand_view`） |

## 9. 现有英雄（hero.json）

| key | display_name | battle_name | max_health | abilities | skill_text |
|---|---|---|---|---|---|
| A | 往日之王：科因 | 科因 | 30 | restart | 再起：消耗 1 费用，弃置所有手牌，然后重新补满 5 张。 |
| B | B | B | 30 | — | — |
| C | C | C | 30 | — | — |
| `enemy_default` | 敌人 | 敌人 | 30 | — | — |

`BATTLE_HERO_KEY` 当前硬编码为 "A"（见 `game_context.gd`），后续接入"主菜单选英雄"时由调用方注入。

## 10. 现有卡牌（all_cards.json）

| 名称 | 类型 | 费用 | 攻击 | 四维 (T/B/L/R) | 效果 |
|---|---|---|---|---|---|
| 填线宝宝 | 单位 | 1 | 1 | 1/1/1/1 | — |
| 灰烬填线宝宝 | 单位 | 2 | 2 | 2/2/2/2 | ash |
| pro哥 | 单位 | 10 | 10 | 10/10/10/10 | ash, autophagy |
| 敢死队 | 单位 | 1 | 1 | 10/1/1/1 | charge |
| 看门狗 | 单位 | 3 | 1 | 2/2/2/2 | vigilance |
| 长板·赵云 | 单位 | 1 | 1 | 6/6/6/6 | breakout, fierce_combat, assault_charge, frail |
| 长板·张飞 | 单位 | 1 | 3 | 20/1/10/10 | steadfast, terrify, battle_hardened |
| 强化 | 法术 | 1 | — | — | empower (target=friendly_unit) |
| 占位牌#1..N | 单位 | 1+ | 1+ | 1+/.../1+ | — （备战图鉴占位） |

`review_cards.json` 是备战界面专用副本，含占位卡用于 UI 调试。

## 11. 添加新卡牌 / 新效果 / 新英雄的工作流

**新效果**：
1. 在 `scripts/effects/` 新建 `<id>.gd`，继承 `Effect`，实现 `id() / display_name() / description()`
2. 按需重写 `on_play / on_death / on_kill / resolve_destination` 中之一或多个
3. 重启游戏，注册表自动扫描挂入 `Effects` 单例；徽章 / 详情面板自动渲染元数据

**新卡牌**：
1. `all_cards.json` 增条目（name / type / cost / health / attack / effects / target?）
2. 引用上面已注册的效果 ID 即可
3. 备战界面要见到则同步加进 `review_cards.json`

**新关卡刷怪点**：
1. `test_level.json` 的 `spawners` 加配置（`positions` 数组共享一份 interval / timer）

**新英雄技能**：
1. 在 `scripts/abilities/` 新建 `<id>.gd`，继承 `HeroAbility`，实现 `id() / display_name() / description() / cost()`
2. 按需重写 `once_per_turn()`（默认 false）、`can_activate(ctx)`（默认走基类的回合状态 + 费用 + 限次校验）、`on_activate(ctx)`
3. ctx 由调用方（通常 main.gd / UI 按钮）按技能需要拼出（例 `restart` 需要 `hand_view`）
4. 重启游戏，`HeroAbilities` 自动扫描挂入；UI 按钮通过 `HeroAbilities.activate(id, ctx)` 触发

**新英雄**：
1. `hero.json.heroes` 加一个 key 条目（display_name / battle_name / max_health / abilities / skill_text）
2. `HeroCarousel.HERO_NAMES` 加同名 key（或后续改为运行时从 hero.json 排序生成）
3. 在备战界面切到该英雄编卡组 → 自动落 `decks.json[key]`；战斗时把 `BATTLE_HERO_KEY` 切到该 key 即可

**新二级面板**：
1. 在 `scripts/ui/` 或就地新建 `.tscn`，根 Control 挂继承 `SecondaryPanel` 的脚本，添加 `BackBtn`（自动套蓝色风格）
2. 重写 `_apply_styles()` 应用子面板样式
3. 在 `MainMenu.SECONDARY_PANEL_SCENES` 注册 `按钮name → preload(场景)` 映射

## 12. 关键设计权衡

- **配置即代码**：效果 / 技能脚本通过文件名 = ID 自动注册，避免中央注册表的同步成本
- **规则单点**：`PlayController.can_play_at` 是出牌规则唯一来源，cell 仅询问不仲裁
- **战斗与移动统一动画**：`move_card` / `attack_cells` 复用，确保冲锋、冲阵、普通推进视觉一致
- **clear_card 之前快照**：on_kill 拿不到 cell 上的 card_name 等字段，combat_system 显式快照 victim 数据传入
- **EffectContext 自动路由阵营**：效果脚本只调 `ctx.banish_card`，由 ctx 按 dying_is_enemy 决定送往哪个牌堆
- **on_play 在 set_card 之后触发**：突围等需查询自身相邻状态的效果可正确工作（旧版本是先触发后落子）
- **战斗牌池与图鉴分离**：`all_cards.json`（原型库）→ `decks.json`（玩家选择）→ `user://battle_cards.json`（本局快照），避免备战调试卡污染战斗
- **二级面板模板化**：`SecondaryPanel` 基类 + `transition_skip` 元数据 + `attach/detach_with_fade`，所有子面板共享 BackBtn 风格与淡入淡出节奏
- **转场用 size/position 而非 scale**：避免圆角被拉成椭圆；冻结子控件 top_level 防被父布局拉伸
- **rubber band + 手势分流**：备战 ReviewPnl 同时支持竖向滚动 + 水平拖卡 + 长按详情，按"先达阈值的方向"独占手势模式
