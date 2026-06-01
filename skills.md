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

`project.godot` 设定 `main_scene = res://scenes/VideoSplash.tscn`，启动顺序：

```
VideoSplash（OGV 开场 Logo 视频，~3s，可点击跳过）
  → SplashScreen（"SOC"标题 + 点击进入）
  → MainMenu → Main.tscn / TestMain.tscn（战斗）
```

**VideoSplash**（`scripts/video_splash.gd`）：黑色全屏底 + 居中 1080×1080 `VideoStreamPlayer`（`expand=true`），视频播完或点击触发黑色渐入 0.3s → 切 SplashScreen。视频文件不存在时直接跳过。

**过渡动画**（退出到菜单）：白色 CanvasLayer(200) 渐入 0.25s → 立即切场景；目标场景 `_ready` 检测 `Game.pending_fade_in_from_white`，接力播白色 overlay 渐隐（白→透明，0.35s）。`pending_fade_in_from_black` 保留兼容黑色入场。

**boot splash**：`splash_black.png`（1×1 纯黑 PNG）覆盖 Godot 默认 Logo，`boot_splash/fullsize=true` 拉伸全屏黑底。

二级面板均继承 `SecondaryPanel`：根 Control PRESET_FULL_RECT、自带 `BackBtn`；`back_pressed` 触发反向转场。

## 3. 战斗场景核心系统架构

### 3.1 分层装配（autoload + 子系统注入）

```
Game (autoload "game_context.gd")
├── deck      DeckManager
├── mana      ManaSystem
├── turn      TurnSystem        支持多棋盘遍历
├── registry  BoardRegistry     所有活跃 BoardSlot 的注册表
├── play      PlayController    由 main.gd 注入
└── combat    CombatSystem      由 main.gd 注入

Effects       (autoload) 扫描 scripts/effects/*.gd 自注册
HeroAbilities (autoload) 扫描 scripts/abilities/*.gd 自注册
Equipments    (autoload "equipment_manager.gd") 玩家装备实例集合
Objectives    (autoload "objective_registry.gd") 战役胜利目标注册与追踪
Actions       (autoload "action_registry.gd") 扫描 scripts/actions/*.gd 自注册，剧情动作执行器
Events        (autoload "scripted_events.gd") 剧情事件调度器，驱动 turn/unit_died/hero_hp 触发器
Dialogue      (autoload "dialogue_manager.gd") 对话气泡 FIFO 队列，CanvasLayer(z=92)
QuitConfirm   (autoload) 全局退出确认弹窗
```

**BoardSlot**（`scripts/core/board_slot.gd`）：一个棋盘的全部上下文聚合体，包含：
- `board: BoardModel` — 棋盘数据层
- `hero: HeroState` — 该盘所属英雄
- `spawners: SpawnerSystem` — 该盘刷怪系统（可为空）
- `spell_caster: SpellCasterSystem` — 该盘自动施法系统（可为空，由 `BoardSlotFactory` 按 `level_data.boards.<id>.spell_casters` 配置初始化）
- `faction`（FACTION_PLAYER / FACTION_ENEMY）、`role`（ROLE_MAIN_PLAYER / ROLE_ALLY / ROLE_MAIN_ENEMY / ROLE_ENEMY）
- `graveyard / banished` 数组 + `pile_changed` 信号 — 该盘自己的牌堆
- `allow_player_deploy` — 玩家手牌是否可落此盘
- `hero_resolver: Callable(damage)` — 英雄受击回调

**BoardRegistry**（`scripts/core/board_registry.gd`）：集中增删查 BoardSlot：
- `add(slot)` / `remove(slot_id)`
- `by_faction(faction)` / `by_role(role)` / `main_player()` / `deployable_for_player()` / `enemy_targets()`
- `sorted_by_x()` — 按视觉 x 升序排序（TurnSystem 相位遍历用）

**Game 辅助方法**：`main_player_slot()` / `player_hero()` / `enemy_main_hero()` / `enemy_main_slot()`

**BoardSlotFactory**（`scripts/core/board_slot_factory.gd`）：集中封装"建 BoardModel + 实例化 cell + 挂入 grid + 配 spawners + 摆初始单位"步骤：
- `create_main(id, faction, role, grid, bg, hero_panel, cell_scene, hero_spec, level_section, on_cell_created)` — 建标准 3×3 slot，自动入 registry
- `destroy(slot)` — 断信号 → 场上残存单位路由到主盘除外区 → 注销 registry → 释放子节点

**bootstrap() 流程**：①先解析关卡（含章节专属字段 `hero_key` / `initial_mana` / `objective`）写入 `level_data`；②从 `level.hero_key` 确定玩家英雄（空则回退 `BATTLE_HERO_KEY="A"`）读 `hero.json` → 填 `hero_specs`；③生成 `user://battle_cards.json`；④加载 `all_cards.json` 到 `card_db`；⑤发 `cards_loaded` / `level_loaded` 信号；⑥初始化 deck；⑦`mana.setup(initial_mana > 0 ? initial_mana : 1)`（章节可覆盖首回合起始费）；⑧初始化 counters；⑨`HeroAbilities.reset_turn_usage()`；⑩`Equipments.clear_all()`；⑪`turn.is_running = false; turn.turn_number = 0`；⑫`Objectives.setup_for_battle(level.objective)`；⑬`Events.setup_for_battle(level_data)`；⑭消费 `pending_chapter_config` / `pending_level_path`。

### 3.2 卡牌生命周期与多阵营牌堆

`DeckManager` 管理玩家牌堆 3 个数组：draw_pile / graveyard / banished。`pile_changed` 信号驱动 UI 刷新。

敌方阵营每个 `BoardSlot` 自持 graveyard / banished，敌方死亡牌入对应 slot 的 graveyard，`terrify` 再转入 slot.banished。`EnemySidePanelManager` / `AllySidePanelManager` 绑定具体 slot 实例展示。

**装备牌生命周期**：玩家拖拽装备牌到英雄面板 → `PlayController.handle_equip` 扣费 → `Equipments.equip(card_data)` 建 `EquipmentInstance`，**装备卡本体不入墓** → 耐久归零时 `EquipmentManager._on_inst_changed` 自动调 `Game.deck.send_to_graveyard` 并 `unequip`。

### 3.3 效果注册表与多态钩子

`Effect` 基类 5 个钩子：`on_play / on_death / on_kill / resolve_destination / id+display_name+description`。

`EffectContext` 门面：`board() / combat() / turn() / banish_card / send_to_graveyard / trigger_vigilance / get_counter / inc_counter`。

### 3.4 战斗系统

`CombatSystem.attack_cells`：攻击动画 → 扣对位面血量（frail=四面同扣，通过 `Orientation.abs_to_side` 将攻击绝对方向转为 defender 的 side 后扣血）→ 收集死亡 → 快照 victim → clear_card → on_kill。

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
- `register_extra_board(board, hero_resolver)` / `unregister_extra_board(board)`（兼容旧 API，内部封装为 BoardSlot 加入 registry）
- `get_extra_board_configs()` 返回非主玩家盘的 `{board, hero_resolver}` 数组（兼容 FrontRowSelector）
- `BoardModel.iter_cells` 已做安全校验，跳过未注册格子

### 3.6 出牌规则

`PlayController.can_play_at` 规则唯一仲裁。`handle_drop` 流程：校验 → 扣费 → 法术结算 / 单位飞入 → on_play。

装备牌不走 `can_play_at`，走独立的 `can_equip` + `handle_equip`（拖到 LeftSidePnl/英雄面板触发）。

### 3.7 UI 控制器（战斗场景）

**main.gd / TestMain.tscn 共用基础控制器：**
- `HandView` — 手牌渲染 + 抽牌动画
- `DetailPanelController` — 长按大图，支持 `start_long_press_equipment(inst)` 展示装备详情
- `SidePanelManager(center_x_offset)` — 玩家牌堆/墓地/除外，支持水平定位
- `EnemySidePanelManager(center_x_offset)` — 绑定 BoardSlot 展示敌方墓地/除外，支持 `update_clip_center_x()` 动态跟随棋盘移动
- `AllySidePanelManager(center_x_offset)` — 绑定 BoardSlot 展示友军墓地/除外，从底部滑入；`set_slot(slot)` 运行时切换数据源
- `SettingsPanelController` — 选项面板，`z_index=200` 覆盖所有 UI；参数化 resume/exit/can_open
- `ThemeFactory / EffectBadgeFactory` — 视觉工厂
- `SideBoardUI` (`scripts/ui/side_board_ui.gd`) — 侧边棋盘视觉容器封装
- `HeroActionBar` (`scripts/ui/hero_action_bar.gd`) — 玩家英雄行动条（挂在 LeftSidePnl 内），顶部英雄技能按钮 + 下方已装备按钮列表；装备打出/耐久归零时触发三阶段面板扩展/收缩动画（渐隐→位移→渐显）；监听 `Equipments.equipment_added/removed/changed` 信号动态增删按钮
  **HeroActionBar 装备按钮**：每行改为 `HBoxContainer`（宽 `BTN_W=240`）= 黄色耐久 `Label`（`ThemeFactory.pill(#fcc419)`，固定宽 32px，显示剩余耐久数字）+ `Button`（`SIZE_EXPAND_FILL`，文字仅装备名）。`_equip_buttons` 存 HBoxContainer，`_equip_dur_labels` 存 Label，刷新时各自更新；动画遍历改为 `is Button or is HBoxContainer`。

**TestMain 专属控制器（已抽出独立文件，可未来迁移到 main）：**
- `FrontRowSelector` (`scripts/ui/front_row_selector.gd`)
  - `register_target(id, bg_panel, hero_state)` / `unregister_target(id)`
  - 监听 `TurnSystem.front_row_action_requested`，高亮棋盘（蓝色脉冲，以中心为 pivot），等待玩家点击
  - 选中后结算：有敌 → 原地攻击；无敌 → `combat.move_card` 移入
- `HeroPanelDragController` (`scripts/ui/hero_panel_drag_controller.gd`)
  - LeftSidePnl 拖拽：阈值检测 → `_apply_drag` → 边界反弹（spring tween）
  - `on_gui_input(event)` 接入 gui_input 信号；`handle_global_release()` 接入全局 _input
- `BoardOrchestrator` (`scripts/core/board_orchestrator.gd`) — 详见 §3.11

**注意：** `PHpPnl`（玩家血量面板）在两个场景的 tscn 里均设 `mouse_filter = 2`（IGNORE），避免遮挡 LeftSidePnl 的拖拽/长按检测。

### 3.8 数据驱动

- `all_cards.json` 卡牌原型库；`review_cards.json` 备战专用；`hero.json` 英雄表；`test_level.json` 默认测试关卡
- `campaigns.json` 战役表：当前 3 个战役（c1 测试·三国、c2、c3），c1 含长坂坡/威震华夏/街亭三章节；描述字段支持 **MarkupParser 自定义标记**（`{place:}` `{ally:}` `{enemy:}` `{warn:}` `{key:}` `{para}` `{break}`）→ BBCode 富文本
- `data/chapters/changbanpo.json`、`weizhenhuaxia.json` — 章节固定牌堆/关卡配置
- **章节 JSON 字段**（`DataLoader._parse_level` 解析）：
  - `hero_key: String` — 玩家专属英雄（`hero.json` key），空时回退 `BATTLE_HERO_KEY`
  - `initial_mana: int` — 首回合起始费上限（0/缺省 = 默认 1）
  - `objective: Dictionary` — 胜利目标（`{type, ...params}`，无 type 时不启用）
  - `board_events: Array` — 格式 `[{"turn":N, "add":[...], "remove":[...], "actions":[...]}]`；`add/remove` 由 `BoardOrchestrator._on_turn_started` 处理，`actions` 由 `Events` 调度
  - `triggers: Array` — 格式 `[{"id","when":{"type","n"/"threshold"/"name"/"faction"/"board",...},"once","cooldown","actions"}]`；`Events.setup_for_battle` 注册，条件类型见 §3.14
- `data_loader.gd` 静态读 JSON → CardBase/CardUnit/CardSpell/**CardEquipment** + 关卡字典 + 英雄字典
- 卡牌 JSON health 字段以**玩家视角** top/bottom/left/right 书写；`DataLoader._parse_card` 调 `Orientation.health_player_abs_to_side` 转为 side（front/back/left/right）后存入 `CardUnit.health`
- 装备 JSON 格式：`{"type":"装备","durability":N,"once_per_turn":bool,"effects":[...]}`
- `Game.pending_chapter_config` 非空时 bootstrap 走章节固定牌堆路径；`pending_level_path` 非空时覆盖关卡 JSON 路径
- **MarkupParser**（`scripts/core/markup_parser.gd`）：静态工具类，`parse(text) -> String`，将自定义轻量标记转换为 Godot BBCode。段首缩进用透明汉字 `[color=#00000000]文字[/color]` 占位（2em 宽，可靠跨平台含 Android）。

### 3.9 卡组持久化

`scripts/core/deck_storage.gd`：`user://decks.json`，接口 `load_deck / save_deck`。

### 3.10 战役胜利目标系统

**ObjectiveRegistry**（`scripts/core/objective_registry.gd`，autoload "Objectives"）：
- 启动期扫描 `scripts/objectives/*.gd`（跳过基类 `objective.gd`）自动注册各目标类型
- `setup_for_battle(objective_data: Dictionary)` — 由 `Game.bootstrap()` 调用，激活当前关卡的目标；连接 `Game.turn.turn_ended` 信号，每回合结算后检查是否达成；`clear()` 断连信号防止跨局污染
- 达成时发射 `objective_completed` 信号；`main.gd` / `test_main.gd` 连接到 `_on_objective_completed()` → 走胜利展示路径（与击杀敌方英雄同逻辑）
- 无 `type` 字段或 type 不存在时静默忽略（旧关卡兼容）

**Objective 基类**（`scripts/objectives/objective.gd`）：
- `id() / description(params) / setup(params) / is_completed(params) -> bool`

**内置目标类型**：

| type | 文件 | 触发时机 | 达成条件 |
|---|---|---|---|
| `survive_turns` | `survive_turns.gd` | `turn_ended` | `turn_number >= turns`（每 `turn_ended` 时 turn_number 已自增） |
| `kill_enemy_hero` | `kill_enemy_hero.gd` | 击杀敌方英雄（`HeroState.died` 信号）| 指定 `slot` 英雄死亡时即达成；无 `slot` 字段则任意敌方英雄死亡均达成 |

`survive_turns` 示例（坚守 1 回合）：玩家点第 1 次"结束回合" → run() 完毕 → `turn_ended`（turn_number=1）→ `1 >= 1` → 胜利。

`kill_enemy_hero` 示例（威震华夏）：`{"type":"kill_enemy_hero","slot":"enemy_main"}` → 曹仁 hp=0 → `died` → 胜利。

### 3.11 装备系统

**卡牌类型**：`CardEquipment extends CardBase`，额外字段 `durability: int`、`once_per_turn: bool`。

**EquipmentInstance**（`scripts/core/equipment_instance.gd`）：
- 字段：`card_data: CardEquipment`、`durability_left: int`、`used_this_turn: bool`
- `can_activate()`：非回合运行中 + once_per_turn 未触发 + 耐久未归零
- `activate(ctx)`：依次调 `Effects.trigger_play(eff, card_data, ctx)` → `durability_left -= 1` → 标记 used → 发 `changed` 信号
- `reset_turn()`：清 `used_this_turn`（每回合结束由 `Equipments.reset_turn_usage()` 调用）

**EquipmentManager / Equipments autoload**（`scripts/core/equipment_manager.gd`）：
- `equip(card_data)` → 创建实例，发 `equipment_added`
- `unequip(inst)` → 移除实例，发 `equipment_removed`
- 耐久归零：`_on_inst_changed` 自动调 `Game.deck.send_to_graveyard` + `unequip`
- `reset_turn_usage()` — 由 `main.gd` 在 end_turn 后调用
- `clear_all()` — 由 `Game.bootstrap()` 调用，防上局残留
- 信号：`equipment_added(inst)` / `equipment_removed(inst)` / `equipment_changed(inst)`

**装备出牌流程**：拖拽 HandCard（type="装备"）到 LeftSidePnl → `HeroActionBar.show_equip_drag_highlight()` 高亮 → 释放 → `PlayController.handle_equip(data)` → `Equipments.equip(full)` → `hand_consumed` → `HeroActionBar._on_equipment_added` 播面板扩展动画。

### 3.12 BoardOrchestrator

`BoardOrchestrator`（`scripts/core/board_orchestrator.gd`）——关卡棋盘装配编排器：

- `setup(deps)` / `boot()` — 按 `Game.level_data.boards` 遍历 enabled=true 的盘，主棋盘用场景树容器，附盘用 `SideBoardUI.build` 动态创建 UI 容器，调 `BoardSlotFactory.create_main` 建 slot
- `add_board(id)` / `remove_board(id)` / `toggle(id)` — 运行时增删附盘，附带滑入/滑出动画（`SLIDE_DURATION=0.5s`）
- **board_events** — `level_data["board_events"]` 格式 `[{"turn":N,"add":[slot_idx,...],"remove":[...]}]`，`turn_started` 信号触发 `_on_turn_started` 自动执行
- `setup_intro_nodes(slide_distance)` — 供 TestMain 入场动画使用，返回 `{slides, fades}` 并入主场景 tween
- 附盘 ENEMY：自动挂 `EnemySidePanelManager`；附盘 ALLY：自动挂 `AllySidePanelManager`
- `_exit_tree` 自动调 `_cleanup_all` — 断信号、销毁全部 slot、清 `Game.turn` 残留状态
- 信号：`board_added(slot)` / `board_removed(slot)` / `side_panel_long_press_requested(payload)` / `side_panel_long_press_canceled`

### 3.13 Orientation（方向映射工具）

`Orientation`（`scripts/core/orientation.gd`）——side ↔ abs 映射工具：

| 概念 | 值 | 说明 |
|---|---|---|
| side（阵营领域） | front/back/left/right | 单位自身视角，CardUnit.health 存储格式 |
| abs（屏幕绝对方向） | top/bottom/left/right | 棋盘/JSON 书写视角 |

- 玩家朝上：front=top, back=bottom；敌方朝下：front=bottom, back=top
- `health_player_abs_to_side(hp)` — DataLoader 读 JSON 后调用，转换 top→front / bottom→back
- `abs_to_side(abs_dir, is_enemy)` — CombatSystem 扣血时用，保证攻击方向正确命中 defender 面
- `side_to_abs(side, is_enemy)` — 反向转换（UI 显示用）

### 3.14 剧情事件系统（ScriptedEvents + ActionRegistry + DialogueManager）

#### ActionRegistry（autoload "Actions"）

`scripts/core/action_registry.gd`：启动期扫描 `scripts/actions/*.gd` 自注册，duck-typing（`id() / run(params, ctx)`），支持 `await`。

**内置 Action 四类：**

| id | 文件 | 功能 |
|---|---|---|
| `spawn_unit` | `actions/spawn_unit.gd` | 向指定盘召唤单位；`strategy: any_empty`（随机空格）/ `fixed`（指定 row/col） |
| `cast_spell` | `actions/cast_spell.gd` | 向 `target_strategy` 目标施放法术卡所有效果（走 `Effects.trigger_play`） |
| `damage_hero` | `actions/damage_hero.gd` | 对指定 `slot` 英雄造成固定 `amount` 伤害（走标准 `slot.damage_hero` 路径） |
| `show_dialogue` | `actions/show_dialogue.gd` | 推入 `Dialogue` 气泡队列（非阻塞，立即返回）；可选 `board` 参数指定气泡定位 board |
| `add_board` | `actions/add_board.gd` | 动态添加附盘（含滑入动画），params: `{"slot": slot_id}` |
| `remove_board` | `actions/remove_board.gd` | 动态移除附盘（含滑出动画），params: `{"slot": slot_id}` |
| `set_counter` | `actions/set_counter.gd` | 设置 `Game.counters[key] = value`，params: `{"key", "value"}` |
| `set_hero_flag` | `actions/set_hero_flag.gd` | 设置指定 slot 英雄的 flag，params: `{"slot", "flag", "value"}` |
| `trigger_ability` | `actions/trigger_ability.gd` | 按脚本路径动态加载能力脚本并调用其静态方法，params: `{"ability": stem, "method": "trigger/trigger_start/add_charge/release/..."}` |
| `apply_soaked_to_all` | `actions/apply_soaked_to_all.gd` | 给指定阵营所有单位施加 `soaked`；可选 `require_effect` 字段：若场上不存在含此 effect 的单位则不执行 |

**新增 Action 工作流**：`scripts/actions/<id>.gd` 继承 `RefCounted`，实现 `id() / run(params, ctx)`，重启自动注册；章节 JSON 在 `board_events.actions` 或 `triggers.actions` 中用 `{"type":"<id>",...}` 调用。

#### ScriptedEvents（autoload "Events"）

`scripts/core/scripted_events.gd`：

- `setup_for_battle(level_data)` — 由 `Game.bootstrap()` 末尾调用；清空旧状态，解析 `board_events[].actions` 和 `triggers[]`，连接 `turn_started`
- `set_orchestrator(orch)` — `BoardOrchestrator.boot()` 后注入自身，供 `add_board / remove_board` action 使用
- `notify_unit_died(snap)` — 由 `PlayController.handle_unit_death` 调用，触发 `unit_died` 类 trigger

**Trigger 条件类型：**

| when.type | 额外字段 | 触发时机 |
|---|---|---|
| `turn_eq` | `n: int` | 回合数 == n（`turn_started` 时判定） |
| `turn_gte` | `n: int` | 回合数 >= n（每轮 `turn_started` 持续检查） |
| `hero_hp_below` | `slot: String, threshold: int` | 指定盘英雄血量 <= threshold（每轮检查，支持 `cooldown`） |
| `unit_died` | `name?`, `faction?`（0=玩家/1=敌方）, `board?` | 匹配条件的单位死亡时（`notify_unit_died` 调用时判定） |
| `game_started` | — | 战斗入场动画完成时，`Events.notify_game_started()` 手动触发一次 |
| `hero_died` | `slot?`, `name?` | 指定 slot 英雄死亡（`BoardSlot._on_hero_died` → `Events.notify_hero_died`）；`slot`/`name` 均为可选过滤条件 |
| `counters_all_set` | `keys: Array[String]` | `Game.counters` 中所有指定 key 的值 >= 1 时触发（每回合检查一次） |

**Trigger 控制字段**：`once: bool`（首次触发后禁用）、`cooldown: int`（最短间隔回合数）。

**ScriptedEvents 新增方法**：
- `notify_game_started()` — 入场动画完成后调用，触发 `game_started` 类 trigger
- `notify_hero_died(snap)` — `BoardSlot._on_hero_died` 调用（非主玩家盘），触发 `hero_died` 类 trigger；`snap = {slot_id, hero_name}`
- `run_turn_events_and_wait(current_turn)` — `TurnSystem.run()` 在 `turn_started.emit()` 后立即 `await`，顺序执行 `board_events.actions`（支持 add_board 滑入动画）与 turn 类 triggers，确保所有棋盘就位后再处理单位行动

#### TargetResolver（静态工具类）

`scripts/core/target_resolver.gd`（`RefCounted`，全静态方法）：

- `resolve_cell(strategy, params)` — Cell 策略：`frontmost_player_unit / frontmost_enemy_unit / random_player_unit / random_enemy_unit / fixed_cell`
- `resolve_empty_cell(board_id)` — 随机空格（`spawn_unit` 用）
- `resolve_hero(strategy)` — Hero 策略：`player_hero / enemy_hero`
- **前排评分**：玩家单位 row 越小分越高（朝向敌方）；敌方单位 row 越大分越高；跨盘入侵单位额外 +3 偏移，确保比本方盘同阵营单位优先被选

#### SpellCasterSystem

`scripts/core/spell_caster_system.gd`（挂于 BoardSlot 同级）：

- JSON 配置：`level_data.boards.<id>.spell_casters[]: {spell, interval, target_strategy}`
- `setup(configs)` — `BoardSlotFactory` 调用，解析配置
- `advance()` — 每回合敌方阶段开始时由 `TurnSystem` 调用，按 `interval` 计数，到期调 `_cast`
- `_cast`：从 `card_db` 取卡 → `TargetResolver.resolve_cell(target_strategy)` → 目标格闪红 0.3s → 触发卡牌所有效果（`await Effects.trigger_play`）

#### DialogueManager（autoload "Dialogue"）

`scripts/core/dialogue_manager.gd`：

- `push(speaker, text, side="enemy")` — 加入 FIFO 队列；`side = "enemy"`（敌方半场顶部）或 `"player"`（玩家半场第二排~后排区域）；`_show_scheduled` 标志防止同帧多次 `push` 触发双调度（会导致两个气泡同时出现互相覆盖）
- `clear_queue()` — 退出战斗时调用，同时重置 `_show_scheduled`，防残留气泡出现
- **纵向定位**：
  - `enemy` 侧：`anchor_rect.position.y + BUBBLE_OFFSET_Y`（棋盘顶边，row 0 前排）
  - `player` 侧：`anchor_rect.position.y + anchor_rect.size.y / 3 + BUBBLE_OFFSET_Y`（跳过 row 0 前排，落在 row 1 第二排～row 2 后排区域）
- 坐标来源：`Game.registry` 对应 slot 的 `bg_panel.get_global_rect()`；回退 enemy→`Rect2(190,30,830,480)`，player→`Rect2(190,570,830,480)`

**DialogueBubble**（`scripts/ui/dialogue_bubble.gd`，`PanelContainer`，全代码构建）：
- 布局：`VBox`（英雄名称 Label + `HBox`（头像 60×60 + `RichTextLabel`））；样式白底 + 主蓝描边（`ThemeFactory.panel`）
- 显示时长：`clamp(1.5 + 字数 × 0.06, 2.0, 6.0)` 秒；点击气泡提前关闭
- 动画：从上方 40px 滑入 + 淡入（`EASE_OUT`）；关闭时向下 40px 滑出 + 淡出（`EASE_IN`）；结束后 `queue_free` 并发 `dismissed` 信号
- `CanvasLayer(z=92)` — 叠于战斗 UI 之上，结算面板(z=100)之下

## 4. 主菜单与转场

要点：导航布局 + 二级面板路由 + 面板扩展动画（size/position 而非 scale）+ 首次入场动画。`SettingsPanelController` 通过 `create_trigger_button=false` 接入。

**CampaignPanel**（`scenes/CampaignPanel.tscn` + `scripts/ui/campaign_panel.gd`）：战役选择面板。
- `CampaignCarousel`（`scripts/ui/campaign_carousel.gd`）：横向无限轮播战役，`current_campaign_changed` 信号；点击章节后写入 `Game.pending_chapter_config` 并切换到对应场景。
- 章节场景列表来自 `campaigns.json`，由 `DataLoader` 静态读取。

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
| `empower` | 强化 | on_play：对目标友方单位四维各+1（注：代码只加 health 不加 attack） |
| `exhaust` | 除外 | resolve_destination：法术入除外 |
| `vigilance` | 警戒 | TurnSystem：敌方移入相邻格即攻击 |
| `breakout` | 突围 | on_play：相邻敌方每个提供+1攻+1四维 |
| `assault_charge` | 冲阵 | on_kill：飞入随机尸位递归攻击 |
| `frail` | 虚弱 | CombatSystem内联：受击四面同扣 |
| `steadfast` | 坚守 | TurnSystem拦截：不主动推进、不跨盘 |
| `terrify` | 破胆 | on_kill：击杀目标送入除外 |
| `battle_hardened` | 历战 | on_kill：攻击力+N |
| `fierce_combat` | 酣战 | on_kill：四维各+N |
| `gain_mana_1` | 增益 | on_play：获得 1 点费用（`Game.mana.gain(1)`），装备"测试刀"用 |
| `inspire` | 鼓舞 | on_play：对目标友方单位攻击力 +1 |
| `discard_hand_card` | 弃手牌 | on_play：弹出手牌选择器（`pick_hand_card_async`），弃选中牌入墓，再补 1 张；玩家取消时返回 false（装备耐久不扣） |
| `love_people` | 爱民 | on_death：对英雄「长坂坡·刘备」造成 1 点伤害（走 `ctx.damage_hero_by_name`），然后走默认入墓 |
| `destroy_unit` | 消灭 | on_play：目标敌方单位走完整死亡流程（动画→`handle_unit_death`→`clear_card`）；玩家取消目标选择时返回 false |
| `weaken` | 放箭 | on_play：对目标单位（`ctx.target_cell`）四维各 -1；任意一面 ≤0 则走标准死亡流程（闪烁动画 → `handle_unit_death` → `clear_card`）；由 `SpellCasterSystem` / `cast_spell` action 调用 |
| `soaked` | 浸水 | CombatSystem内联：受到任意伤害后立即强制四面归零（一次性，触发后从 effects 移除）；可被 `flood_strategy_hero` 技能 / `apply_soaked_to_all` action / `jue_di` 效果 / `flood_strategy_unit` turn_started 触发施加 |
| `flood_strategy_unit` | 水攻 | 无代码钩子（元数据）；实际逻辑由 `apply_soaked_to_all` action（`require_effect="flood_strategy_unit"`）在每回合 trigger 中驱动：若场上存在此效果单位，则给全场敌方单位施加 `soaked` |
| `awe` | 威震 | on_kill：每击杀一个敌方单位，对该单位原属盘英雄造成 1 点 triggered 伤害（穿透死守） |
| `ming_jin` | 鸣金 | on_play：选一个友方单位放回牌库顶（调 `deck.add_to_draw_pile`，不走墓地），并设 `counters["ming_jin_used"] += 1`；TurnSystem 回合开始抽牌时检查此计数跳过抽牌 |
| `jue_di` | 决堤 | on_play：① 永久剥夺 enemy_main 英雄 `die_hard` flag + 从 abilities 移除 `die_hard_display`；② 全场敌方单位施加 `soaked`；③ 使 ROLE_ALLY 英雄 hp 归零（触发 `died` 信号 → Events 接管退场结算） |
| `gua_gu_liao_du` | 刮骨疗毒 | on_play：若玩家除外区有「樊城·关羽」，将其从除外区移到牌库顶（`deck.add_to_draw_pile`）；否则无效 |

> **Effect.on_play 异步修复**：`EffectRegistry.trigger_play` 已加 `await inst.on_play()`，`PlayController._play_spell` / `_trigger_unit_play_effects` 也均改用 `await Effects.trigger_play()`，保证含 `await` 的效果（discard_hand_card、destroy_unit 等）正确执行。

> **浸水（soaked）内联逻辑**：`CombatSystem.attack_cells` 扣血后、死亡判定前，若 `defender.effects.has("soaked")`，强制将四面血量设为 0，从 effects 数组 erase，确保当帧死亡判定成立。

## 8. 英雄技能清单

| ID | 名称 | 所属英雄 | 费用 | 每回合限用 | 描述 |
|---|---|---|---|---|---|
| `restart` | 再起 | 科因 | 1 | 是 | 弃全手牌补满至 MIN_HAND_SIZE |
| `yi_yong_jun` | 义勇军 | 长坂坡·刘备 | 2 | 是 | 消灭 player_main 半场所有敌方单位；随后在所有空格召唤「乡勇」并追加 ash；origin="ability" 入除外区 |
| `caocao_archery` | 箭阵 | 长坂坡·曹操 | — | — | 纯展示被动，`can_activate` 返回 false；实际由 `SpellCasterSystem` 每回合对最前方玩家单位施放「放箭」 |
| `flood_strategy_hero` | 水攻（英雄） | 威震华夏·关羽 | 2 | 否 | 选一个敌方单位格，施加 `soaked`（浸水）；玩家取消则退费 |
| `flood_dam_ability` | 水淹七军 | 水坝 | — | — | 被动（`can_activate=false`）；静态 `add_charge(game)` 每回合给 ally stacks["flood_charge"] +1；静态 `release(game)` 退场时每1层蓄水对 enemy_main 造成1点 triggered 伤害，每5层封锁 spawner 1 回合 |
| `die_hard_display` | 死守 | 樊城·曹仁 | 0 | — | 纯展示被动，cost=0，`can_activate=false`；实际免伤由 `BoardSlot.damage_hero` 检查 `HeroState.flags["die_hard"]` 实现；`jue_di` 效果 / 决堤法术可永久剥夺 |
| `aid_fancheng_ability` | 援樊 | 庞德/于禁/徐晃（共用） | — | — | 被动；静态 `trigger(game)`，对 enemy_main（曹仁）造成 10 点 triggered 伤害；由 `hero_died` trigger 触发 |
| `surrender_ability` | 受降 | 樊城·于禁 | — | — | 被动；静态 `trigger(game)`，关羽英雄满血 + 玩家侧所有单位四维恢复初始值（`cell.max_health`） |
| `reinforce_camp_ability` | 屯扎 | 樊城·于禁 | — | — | 被动；静态 `trigger(game)`，全场 ENEMY 阵营所有单位四维各 +1 |
| `straight_in_ability` | 直入 | 樊城·徐晃 | — | — | 被动；静态 `trigger_start(game)`，回合开始时全场敌方单位（含已跨盘者）获得 `charge`；steadfast 单位免疫 |
| `first_arrow_ability` | 先射 | 樊城·庞德 | — | — | 被动；静态 `trigger(game)`，回合开始时若「樊城·关羽」在场，对其 front 面造成 4 点伤害，若任意面≤0 则走标准死亡流程 |

## 9. 现有英雄

| key | display_name | battle_name | max_health | abilities | 备注 |
|---|---|---|---|---|---|
| `A` | 往日之王：科因 | 科因 | 30 | restart | — |
| `B` | B | B | 30 | — | — |
| `C` | C | C | 30 | — | — |
| `liubei` | 长坂坡·刘备 | 刘备 | 30 | yi_yong_jun | 长坂坡章节玩家英雄 |
| `guanyu_wei` | 威震华夏·关羽 | 关羽 | 30 | flood_strategy_hero | 威震华夏章节玩家英雄 |
| `dam` | 水坝 | 水坝 | 5（章节覆盖20） | flood_dam_ability | 友方附盘英雄；`stacks["flood_charge"]` 每回合+1 |
| `caoren_fan` | 樊城·曹仁 | 曹仁 | 30 | die_hard_display | 威震华夏主敌英雄；初始 `flags["die_hard"]=true`，决堤后剥夺 |
| `pangde_fan` | 樊城·庞德 | 庞德 | 15（章节覆盖1） | aid_fancheng_ability, first_arrow_ability | 威震华夏 enemy_left |
| `yujin_fan` | 樊城·于禁 | 于禁 | 10（章节覆盖1） | aid_fancheng_ability, surrender_ability, reinforce_camp_ability | 威震华夏 enemy_right |
| `xuhuang_fan` | 樊城·徐晃 | 徐晃 | 20 | aid_fancheng_ability, straight_in_ability | 威震华夏 enemy_xuhuang；庞德+于禁死后 add_board |
| `caocao` | 曹操（长坂坡） | 曹操 | 100 | caocao_archery（被动，SpellCasterSystem 驱动） | 长坂坡主敌英雄 |
| `enemy_default` | 敌人 | 敌人 | 30 | — | 无专属章节时回退 |

**hero.json boards 字段 `flags`**：chapter JSON boards 的 hero 节点可含 `"flags": ["die_hard"]` 数组，`BoardSlotFactory` 解析后调 `HeroState.set_flag(k, true)` 初始化。

**HeroState 新字段 / 方法（§3 补充）**：
- `stacks: Dictionary` — 通用英雄计数器（如 `flood_charge`）：`get_stack / add_stack / set_stack`
- `flags: Dictionary` — 通用英雄标志（如 `die_hard`）：`has_flag / set_flag`
- `heal(amount)` — 恢复指定血量，不超 max_health
- `heal_full()` — 回满血量

## 10. 现有卡牌

| 名称 | 类型 | 费用 | 攻击 | 四维 | 效果 |
|---|---|---|---|---|---|
| 测试刀 | 装备 | 1 | — | — | gain_mana_1（耐久2，每回合限用1次） |
| 填线宝宝 | 单位 | 1 | 1 | 1/1/1/1 | — |
| 灰烬填线宝宝 | 单位 | 2 | 2 | 2/2/2/2 | ash |
| pro哥 | 单位 | 10 | 10 | 10/10/10/10 | ash, autophagy |
| 敢死队 | 单位 | 1 | 1 | 10/1/1/1 | charge |
| 看门狗 | 单位 | 3 | 1 | 1/2/2/2 | vigilance |
| 长板·赵云 | 单位 | 1 | 1 | 6/6/6/6 | breakout, fierce_combat, assault_charge, frail |
| 长板·张飞 | 单位 | 1 | 3 | 20/1/10/10 | steadfast, terrify, battle_hardened |
| 强化 | 法术 | 1 | — | — | empower |
| 乡勇 | 单位 | 1 | 1 | 1/1/1/1 | love_people（被击败后对长坂坡·刘备造成 1 伤） |
| 鼓舞 | 法术 | 2 | — | — | inspire（目标友方单位攻+1） |
| 仁之剑 | 装备 | 5 | — | — | destroy_unit（耐久5，不限每回合次数；点击后目标选择消灭一个敌方单位） |
| 义之剑 | 装备 | 5 | — | — | discard_hand_card（耐久5，不限每回合次数；激活后从手牌选一张弃置并补1张） |
| 放箭 | 法术 | 1 | — | — | weaken（敌方 SpellCasterSystem 专用；对目标单位四维各-1，任意一面≤0即死） |
| 樊城·关羽 | 单位 | 5 | 1 | 5/5/5/5 | flood_strategy_unit, awe, ash（水攻+威震+灰烬） |
| 樊城·满宠 | 单位 | 0 | 2 | 10/10/10/10 | steadfast, vigilance（威震华夏主敌盘初始单位） |
| 鸣金 | 法术 | 1 | — | — | ming_jin（选友方单位放回牌库顶，本回合不抽牌） |
| 决堤 | 法术 | 1 | — | — | jue_di（剥夺曹仁死守 + 全场敌方浸水 + 水坝退场） |
| 刮骨疗毒 | 法术 | 1 | — | — | gua_gu_liao_du（若除外区有「樊城·关羽」，放回牌库顶） |

> 四维列为玩家视角 top/bottom/left/right 顺序（JSON 书写规约），实际存储为 front/back/left/right（side 视角）。

## 11. 工作流

**新效果**：`scripts/effects/<id>.gd` 继承 Effect，实现钩子，重启自动注册。

**新卡牌**：`all_cards.json` 加条目，引用已注册效果 ID；备战界面同步加 `review_cards.json`。

**新装备**：`all_cards.json` 加 `{"type":"装备","cost":N,"durability":N,"once_per_turn":true/false,"effects":[...]}` 条目；确保 effects 对应的 `on_play` 钩子已实现（装备激活调 `on_play`）。

**新英雄技能**：`scripts/abilities/<id>.gd` 继承 HeroAbility，重启自动注册。被动技能：`can_activate` 返回 false，实现静态 `trigger(game_node)` / `trigger_start` / `release` 等方法，由 `trigger_ability` action 调用。

**新英雄**：`hero.json` 加 key（含 `abilities` / `skill_text`，可选 `flags` 数组）；`HeroCarousel.HERO_NAMES` 加同名 key。章节专属英雄在章节 JSON 的 `boards.<id>.hero` 节点写 `"abilities"` / `"flags"`，bootstrap 自动读取。

**新胜利目标类型**：`scripts/objectives/<type>.gd` 继承 Objective，实现 `id / description / setup / is_completed`，重启自动注册；章节 JSON 写 `"objective": {"type":"<type>","<param>":val}` 即可。

**新战役章节**：`campaigns.json` 加 chapter 条目（描述支持 MarkupParser 标记），新建 `scenes/chapters/<Name>.tscn` 和 `data/chapters/<name>.json`（含 cards / boards / hero_key / initial_mana / objective / board_events / triggers 等），在章节场景写入 `Game.pending_chapter_config` 后切场景。boards 下每个 entry 可含 `faction / role / slot_index / enabled / hero / initial_units / spawners / spell_casters`。

**新剧情 Action**：`scripts/actions/<id>.gd` 继承 `RefCounted`，实现 `id() / run(params, ctx)`，重启自动注册；章节 JSON `triggers[].actions` / `board_events[].actions` 直接引用 `{"type":"<id>",...}`。

**新 Trigger**：直接在章节 JSON 的 `triggers[]` 数组写条件字典，无需代码修改；条件类型参见 §3.14。`hero_died` / `game_started` 还需确认对应 `Events.notify_*` 调用路径已接入。

**新被动能力触发链**（威震华夏范式）：英雄死亡 → `BoardSlot._on_hero_died` → `Events.notify_hero_died` → `hero_died` trigger → `trigger_ability` action → 静态方法。回合开始被动 → `turn_gte` trigger → `trigger_ability` action。

**新二级面板**：继承 SecondaryPanel，加 BackBtn，在 `MainMenu.SECONDARY_PANEL_SCENES` 注册。

**接入多棋盘**：`Game.turn.register_extra_board(board_model, hero_resolver)`，`FrontRowSelector.register_target(id, bg, hero)`，销毁时对应 unregister；也可直接向 `Game.registry` add/remove `BoardSlot`。或用 `BoardOrchestrator.add_board(id)` / `remove_board(id)` / `toggle(id)` 运行时增删附盘。

**SpawnerSystem.pause_for_turns(n)**：封锁 spawner N 回合（可叠加），`advance()` 期间 `pause_turns > 0` 则跳过本回合生成并递减，由 `flood_dam_ability.release()` 在蓄水退场时按"蓄水/5"回合数调用。

## 12. 关键设计权衡

- **配置即代码**：效果/技能/目标/action 通过文件名=ID 自动注册，零中央注册表
- **规则单点**：`PlayController.can_play_at` 出牌规则唯一仲裁；`can_equip` 装备规则唯一仲裁
- **BoardRegistry + BoardSlot**：取代旧 `Game.board/hero/spawners` 单例，所有棋盘上下文聚合为 BoardSlot，统一增删查；`TurnSystem` / `FrontRowSelector` 通过 registry 遍历，主棋盘与额外棋盘复用同一逻辑
- **BoardSlotFactory**：把"建 board + cell + hero + spawners + 入 registry"封装为单一静态调用，`destroy` 保证完整清理；`BoardOrchestrator` 在工厂之上编排 UI 容器与动画
- **BoardOrchestrator**：取代旧 SideBoardController，根据 `level_data.boards` 装配全部盘（主棋盘用场景树容器，附盘动态 `SideBoardUI.build`）；`add_board/remove_board/toggle` 带滑入/滑出动画；`board_events` 按回合编号触发增删盘；`_exit_tree` 自动 `_cleanup_all`
- **章节专属英雄与起始费**：`chapter.json` 写 `hero_key` / `initial_mana`；bootstrap 先解析关卡再确定玩家英雄，`mana.setup(initial_mana)` 覆盖默认值；不影响无此字段的旧关卡
- **ObjectiveRegistry + turn_ended 检查**：目标类型自动注册；bootstrap 按关卡配置激活；`turn_ended` 信号检查（回合完整结算后才判定），`objective_completed` 信号触发胜利；旧关卡无 objective 字段时静默忽略
- **kill_enemy_hero 目标**：`scripts/objectives/kill_enemy_hero.gd`，监听指定 `slot`（或任意敌方盘）的 `HeroState.died` 信号，死亡即触发 `objective_completed`；与 `survive_turns` 共用 `ObjectiveRegistry` 自注册范式
- **MarkupParser**：JSON 文本中用 `{tag:text}` / `{para}` / `{break}` 标记，运行时一次 `parse()` 转 BBCode；透明汉字占位（`[color=#00000000]文字[/color]`）解决 Android BBCode 模式前导空白折叠问题
- **Orientation 工具类**：side（front/back/left/right）↔ abs（top/bottom/left/right）映射；JSON 以玩家视角 abs 书写，`DataLoader` 调 `health_player_abs_to_side` 转为 side；`CombatSystem` 扣血时再做 `abs_to_side` 转换，避免阵营反向导致扣错面
- **每盘自持牌堆**：敌方 BoardSlot 自带 graveyard/banished + pile_changed 信号，取代旧 `DeckManager.enemy_graveyard/enemy_banished` 字段；EnemySidePanelManager / AllySidePanelManager 绑定具体 slot
- **装备系统 autoload**：`Equipments` autoload 持有 `EquipmentInstance[]`；装备卡打出时转化为实例（不入墓/除外），耐久归零时自动入墓 + unequip；`bootstrap` 调 `Equipments.clear_all()` 防上局残留；`HeroActionBar` 监听信号动态显示/隐藏装备按钮（黄色耐久指示器 + 名称按钮）并驱动面板扩展动画
- **装备激活 is_running 顺序**：`HeroActionBar._on_equip_btn_pressed` 选目标前设 `is_running=true`，选完后立即 reset 为 false，再调 `activate()`，避免 `can_activate()` 的 is_running 检查误拦截
- **trigger_play 全面 await**：`EffectRegistry.trigger_play` 和所有调用处均加 `await`，保证含异步逻辑的效果（destroy_unit / discard_hand_card）正确执行和返回值正确
- **警戒跨盘触发修复**：`TurnSystem._process_cell` 中 `if handled: if crossed_cell:` 的 `else` 分支（普通非冲锋跨盘落地）补充了 vigilance 触发；原代码将触发逻辑误放在 `handled=false` 分支（永远无 landed_cell，死代码）
- **结算界面 CanvasLayer**：`_show_game_over` 改用 `CanvasLayer(layer=100)`，不受游戏内元素 z_index 影响，完整覆盖棋子/英雄面板；点击空白处调 `_on_exit_to_menu()` 退回菜单
- **退出过渡白→切→白淡出**：移除白→黑段；`_on_exit_to_menu` 白色 CanvasLayer(200) 渐入后立即 `change_scene`；目标场景检测 `pending_fade_in_from_white` 接力白色 overlay 渐隐，无黑闪
- **前排选择挂件化**：`FrontRowSelector` 独立文件，TestMain 装配，未来 Main 可直接引入
- **clear_card 之前快照**：on_kill 拿 victim 快照而非 cell 字段
- **EffectContext 自动路由阵营**：效果脚本只调 ctx 接口，不感知 is_enemy；`_owner_slot_of` 以 `cell.owner_slot_id` 优先于 `cell.slot_id` 路由跨盘死亡牌归属盘
- **SidePanelManager 支持 center_x_offset**：面板随棋盘水平偏移，test 按钮触发棋盘平移后调 `update_clip_center_x()` 同步
- **PHpPnl mouse_filter=IGNORE**：血量显示面板不阻挡 LeftSidePnl 的拖拽/长按事件穿透
- **SettingsOverlay z_index=200**：覆盖 LeftSidePnl(z=10) 等所有游戏 UI
- **转场用 size/position 而非 scale**：避免圆角被拉成椭圆
- **bootstrap pending_* 一次性消费**：`pending_chapter_config` / `pending_level_path` 用后即清，防止返回主菜单后脏读
- **ActionRegistry + ScriptedEvents**：同效果/技能/目标的自注册范式扩展到剧情动作；`Events` 解析 `board_events.actions` 和 `triggers`，通过 `turn_started` / `notify_unit_died` 驱动，`BoardOrchestrator` 注入 orchestrator 引用，做到 JSON 全驱动零硬编码
- **Trigger 条件解耦**：`turn_eq / turn_gte / hero_hp_below / unit_died / game_started / hero_died / counters_all_set` 七类条件纯 JSON 配置，`once + cooldown` 控制触发频率；新条件类型在 `run_turn_events_and_wait` / `notify_*` 中加 match 分支
- **run_turn_events_and_wait + await**：TurnSystem 在 `turn_started.emit()` 后立即 await Events 执行完本回合全部 board_events.actions 与 turn 类 triggers（含 add_board 滑入动画），保证所有棋盘就位后再处理单位行动，消除旧 _on_turn_started 双跑问题
- **SpellCasterSystem**：敌方自动施法挂于 BoardSlot 同级，`advance()` 由 TurnSystem 驱动；JSON 配置 `spell / interval / target_strategy`，与玩家出牌路径完全隔离，不占用 `PlayController`
- **SpawnerSystem.pause_for_turns**：蓄水结算时按"stacks/5"向下取整封锁 spawner N 回合，模拟洪水滞留效果；可叠加，advance() 内按回合递减
- **TargetResolver 静态化**：无状态、可直接调用，供 `SpellCasterSystem` / `cast_spell` / `spawn_unit` 共用；`_frontmost_unit` 跨盘扫全 registry 并用推进分算法保证跨盘单位优先
- **HeroState stacks + flags**：通用英雄计数器（蓄水层数等）与标志（死守等）；flags 可在 chapter JSON 的 `boards.<id>.hero.flags` 数组中初始化，`jue_di` 效果可运行时动态剥夺
- **BoardSlot.damage_hero source 语义**：`""` 不拦截；`"unit_direct"` / `"spell_direct"` 被 die_hard 拦截；`"triggered"` 穿透死守，供援樊/蓄水/威震等触发型效果使用
- **被动能力触发链（威震华夏范式）**：英雄死亡 → `BoardSlot._on_hero_died` → `Events.notify_hero_died` → `hero_died` trigger → `trigger_ability` action → 静态方法（援樊/受降/蓄水退场/直入/先射/屯扎）；避免将触发逻辑耦合进 GDScript，全部由 JSON trigger 链驱动
- **apply_soaked_to_all + require_effect**：`flood_strategy_unit` 效果不含代码钩子，水攻触发由 `turn_gte` trigger 每回合调 `apply_soaked_to_all`（`require_effect="flood_strategy_unit"`）—— 场上若无此效果单位则不执行；保证效果存在性检查与施加逻辑完全解耦
- **DialogueManager FIFO + CanvasLayer(92)**：叠于战斗 UI 之上、结算面板之下；`clear_queue()` 退出战斗时清空防残留；气泡全代码构建，显示时长自适应字数，点击可提前关闭
- **威震华夏章节异步预加载**：`weizhenhuaxia.gd` 入场动画与 `Main.tscn` 后台 `load_threaded_request` 并行；加载完毕进度条滑出 → "点击开始"呼吸动效 → 点击 `change_scene_to_packed`（直接用已加载 packed，秒切无延迟）

