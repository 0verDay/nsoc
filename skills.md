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
├── deck      DeckManager         （local_player_id 对应实例的别名；PVP 时与 decks[local_player_id] 同指）
├── mana      ManaSystem          （同上别名）
├── decks     Dictionary          （player_id → DeckManager，PVP 多玩家各持一份）
├── manas     Dictionary          （player_id → ManaSystem，PVP 多玩家各持一份）
├── turn      TurnSystem          支持多棋盘遍历
├── registry  BoardRegistry       所有活跃 BoardSlot 的注册表
├── play      PlayController      由 main.gd 注入
└── combat    CombatSystem        由 main.gd 注入

Effects       (autoload) 扫描 scripts/effects/*.gd 自注册
HeroAbilities (autoload) 扫描 scripts/abilities/*.gd 自注册
Equipments    (autoload "equipment_manager.gd") 玩家装备实例集合
Objectives    (autoload "objective_registry.gd") 战役胜利目标注册与追踪
Actions       (autoload "action_registry.gd") 扫描 scripts/actions/*.gd 自注册，剧情动作执行器
Events        (autoload "scripted_events.gd") 剧情事件调度器，驱动 turn/unit_died/hero_hp 触发器
Dialogue      (autoload "dialogue_manager.gd") 对话气泡 FIFO 队列，CanvasLayer(z=92)
QuitConfirm   (autoload) 全局退出确认弹窗
Net           (autoload "network_manager.gd") WebSocket 客户端网络层（PVP 专用）
```

**Game PVP 专属字段**（`scripts/core/game_context.gd`）：

| 字段 | 类型 | 说明 |
|---|---|---|
| `is_pvp` | `bool` | PVP 模式开关；`bootstrap_pvp()` 置 true，`bootstrap()` 置 false |
| `local_player_id` | `String` | 本端玩家标识（PVE 默认 `"player_main"`，PVP 为 session_id） |
| `decks` | `Dictionary` | `player_id → DeckManager`，1v1 共 2 份 |
| `manas` | `Dictionary` | `player_id → ManaSystem`，1v1 共 2 份 |
| `pvp_action_order` | `Array` | 服务器下发的行动顺序 `[uuid1, uuid2, ...]` |
| `pvp_active_idx` | `int` | 当前行动玩家在 action_order 中的索引 |
| `pvp_room_id` | `String` | 当前房间号（由 pvp_lobby 注入 Net 后取回镜像） |
| `pvp_rng_seed` | `int` | 服务器下发随机种子（0=不固定） |
| `pvp_match_type` | `String` | 对局类型："1v1" / "1v3"；空串=PVE |
| `pvp_teams` | `Dictionary` | 队伍映射：`{ team_id: [player_id,...] }`，如 `{"defender":[pid1],"attacker":[pid2,pid3,pid4]}` |
| `pvp_dead_players` | `Array` | 本局已阵亡玩家 uuid 列表 |
| `pvp_match_type` | `String` | 对局类型："1v1" / "1v3"；空串=PVE |
| `pvp_teams` | `Dictionary` | 队伍映射：`{ team_id: [player_id,...] }`，如 `{"defender":[pid1],"attacker":[pid2,pid3,pid4]}` |
| `pvp_dead_players` | `Array` | 本局已阵亡玩家 uuid 列表 |

**Game PVP 方法**：
- `bootstrap_pvp(local_pid, all_player_ids, per_player_deck_cards, all_cards_db, rng_seed, per_player_heroes, match_type, teams_map, slot_layout)` — PVP 专用初始化；第三参数兼容旧 Array 格式；`match_type` = "1v1" / "1v3"；`teams_map` = `{ team_id: [pid,...] }`；`slot_layout` = `[{slot_id, owner_pid, team_id, slot_index},...]`；缺失 pid 的 hero_key 回退 `DeckStorage.get_selected_hero()`
- `get_battle_hero_key() -> String` — 静态方法，返回 `DeckStorage.get_selected_hero()`，PVE bootstrap 通过此方法动态读取玩家携带英雄（而非硬编码 "A"）
- `pvp_active_player_id() -> String` — 当前应行动玩家 ID
- `pvp_is_my_turn() -> bool` — 当前是否轮到本端行动
- `pvp_advance_turn()` — 推进 pvp_active_idx（1v1 用，不跳过阵亡）
- `pvp_advance_turn_skip_dead()` — 推进并跳过 pvp_dead_players（1v3 用）
- `is_round_complete() -> bool` — 判断一整轮是否完成（pvp_active_idx 回到 0）
- `team_of_player(pid) -> String` — 返回玩家所属 team_id
- `players_of_team(team_id) -> Array` — 返回某队所有玩家
- `is_player_alive(pid) -> bool` — 玩家是否仍存活
- `mark_player_dead(pid)` — 标记玩家阵亡
- `pvp_end_game(winning_team, loser_pid)` — 广播 game/end 并本端转结算 UI（1v1 用，不跳过阵亡）
- `pvp_advance_turn_skip_dead()` — 推进并跳过 pvp_dead_players（1v3 用）
- `is_round_complete() -> bool` — 判断一整轮是否完成（pvp_active_idx 回到 0）
- `team_of_player(pid) -> String` — 返回玩家所属 team_id
- `players_of_team(team_id) -> Array` — 返回某队所有玩家
- `is_player_alive(pid) -> bool` — 玩家是否仍存活
- `mark_player_dead(pid)` — 标记玩家阵亡
- `pvp_end_game(winning_team, loser_pid)` — 广播 game/end 并本端转结算 UI
- `get_deck(pid) / get_mana(pid)` — 按玩家ID取对应实例
- `add_deck(pid) / add_mana(pid)` — 创建并注册新实例
- `deck_of_slot(slot) / mana_of_slot(slot)` — 按 slot.owner_player_id 路由
- `clear_extra_decks_and_manas()` — 清除全部 decks/manas（bootstrap 时调用）
- `register_selectors(target_selector, hand_picker)` — 注入交互选择器节点（`EffectContext.pick_target_async / pick_hand_card_async` 用）

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

**1v3 跨盘三分支**（`_process_cell` 跨盘块，按 `slot.team_id` + `faction` 分发）：

| 分支 | team_id | faction | 行为 |
|---|---|---|---|
| 守方拥有者 | "defender" | PLAYER | `_run_front_row_selection` 弹 3 盘 UI → 选定后 `_broadcast_cross_board(action/cross_board)` |
| 守方远端镜像 | "defender" | ENEMY  | `consume_cross_choice` 从队列取 target_slot_id（WS FIFO 保证已入队） |
| 攻方双向 | "attacker" | 任意 | `_enemy_auto_cross` 自动跨守方盘（单一目标，无 UI 无广播） |
| PVE/1v1 | "" | — | 原 UI / auto-cross 同列规则 |

**落点列镜像**（仅 1v3）：`target_col = COLS - 1 - source_col`。配合 `board_orchestrator._reverse_grid_cells` 的对手盘行/列翻转，单位"拥有者视觉同列"直线落地（不再横跨整条屏幕宽度）。PVE/1v1 仍走同 data col。

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
- `DetailPanelController` — 长按大图，支持 `start_long_press_equipment(inst)` 展示装备详情；`start_long_press_hero(name, ability_ids, hp, equip_descs=[])` 第 4 参数为已装备描述字符串数组，非空时在技能描述下方追加分隔线 + "已装备" 标题 + 每件装备一行
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

### 3.9 卡组持久化与英雄选择持久化

`scripts/core/deck_storage.gd`：`user://decks.json`，接口 `load_deck / save_deck / get_selected_hero / save_selected_hero`。

**`user://decks.json` 结构**：
```json
{
  "version": 2,
  "selected_hero": "B",
  "decks": {
    "A": { "cards": {}, "order": [], "sort_mode": "no_sort" },
    "B": { "cards": {}, "order": [], "sort_mode": "no_sort" }
  }
}
```

**`selected_hero` 字段**：玩家在备战界面退出时保存的当前英雄 key，供 Test 场景和多人游戏读取。初次启动无记录时默认 `"A"`。`PreparePanel._save_current_deck()` 合并卡组与 selected_hero 为**一次** IO 写盘，避免两次写盘之间崩溃导致状态不一致。

**API**：
- `load_all() / save_all(data)` — 全量读写
- `load_deck(hero_key) / save_deck(hero_key, cards, order, sort_mode)` — 单英雄卡组读写
- `get_selected_hero() -> String` — 读当前选中英雄，缺省 `"A"`
- `save_selected_hero(hero_key)` — 保存选中英雄

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

**PVP 装备镜像**：本端装备仅存 `Equipments` 单例；对手装备由 `test_main._remote_equip_insts` 独立镜像（不进 `Equipments`，避免战斗结算误用）。收到 `action/play_equip` 时追加 `EquipmentInstance`；收到 `action/activate_equip` 后扣耐久（归零则移除）。长按对手英雄面板时由 `_collect_remote_equip_descs()` 生成描述传入 `DetailPanelController`。

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

**退出行为**：任何离开路径（BackBtn / tree_exiting）均调 `_save_current_deck()`，一次 IO 同步写卡组 + selected_hero。退出时备战界面的当前英雄即为玩家"携带英雄"，作用于 Test 场景和多人游戏。

## 6. HeroCarousel（英雄轮播）

竖向无限轮播，3 page 循环 + snap，`current_hero_changed(hero_key)` 信号。

**英雄恢复**：`_ready` 时调 `DeckStorage.get_selected_hero()` 获取上次退出时的英雄 key，通过 `HERO_NAMES.find(key)` 定位初始页 `_current_page`，`_layout_pages()` 调用后自动刷新标签，进入备战界面直接显示上次携带的英雄。

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
| `restart` | 再起 | 科因（A） | 1 | 是 | 弃全手牌补满至 MIN_HAND_SIZE |
| `test_discard` | 测试技能 | 多人模式·测试（B） | 1 | 是 | 选一张手牌弃置并自动补 1 张；手牌为空时按钮不可用；玩家取消时退还费用并清除本回合限用标记（可重试） |
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

**英雄技能注册机制**：`scripts/abilities/<id>.gd` 文件名即 ID，`HeroAbilityRegistry` 启动期自动扫描注册，无需手动注册。

**PVP 技能同步机制**：
- `hero_action_bar.gd` 在 `_on_ability_pressed` 中：激活前拍 pre-snapshot（`restart` 专用：弃牌前的手牌名单）→ `await HeroAbilities.activate` → 激活后拍 post-snapshot（`test_discard` 专用：墓地末尾牌名）→ 仅当 `HeroAbilities.is_used_this_turn(ability_id)` 为真时广播（取消时标记已被清除，不误发）
- `test_main._handle_remote_activate_hero` 处理 `restart` / `test_discard`，将弃牌追加到对端 `enemy_main` slot.graveyard
- 新增 `HeroAbilityRegistry.clear_turn_usage(id)` 公开 API，供技能取消时清除单条记录（`test_discard` 取消后可重试）

## 9. 现有英雄

| key | display_name | battle_name | max_health | abilities | 备注 |
|---|---|---|---|---|---|
| `A` | 往日之王：科因 | 科因 | 30 | restart | 默认多人英雄之一 |
| `B` | 多人模式·测试 | 测试 | 30 | test_discard | 多人测试英雄；技能：选手牌弃置补1张 |
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

**多人模式英雄选择**：`HeroCarousel.HERO_NAMES = ["A", "B", "C"]`，玩家在备战界面滑动选择，退出时自动保存到 `DeckStorage.selected_hero`。Test 场景和多人游戏均读 `DeckStorage.get_selected_hero()` 作为当前携带英雄。

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

**PVP 战斗状态快照**：`F5` 键调 `SnapshotIO.save_to_file()` 存 `user://battle_snapshot.json`，`F9` 键调 `load_from_file()` 恢复（开发期调试用）。

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
- **Game.decks / manas 字典化**：PVE 旧代码通过 `Game.deck` / `Game.mana` 别名无感使用；PVP 模式新增 `Game.decks[player_id]` / `Game.manas[player_id]`，`deck_of_slot / mana_of_slot` 按 slot.owner_player_id 路由，避免多玩家费用串联
- **bootstrap_pvp 与 bootstrap 分支**：`bootstrap_pvp` 不走章节/关卡路径，不初始化 ScriptedEvents/SpawnerSystem，为每位玩家独立建 DeckManager + ManaSystem + HeroSpec（全为英雄A），PVP 战斗场景通过 `Game.is_pvp` 分支走 `_inject_pvp_level_data → _setup_pvp_slots` 专属路径
- **PVP 消息队列串行**：`test_main._pvp_msg_queue` + `_pvp_processing` 保证 await 消息依序处理，避免并发导致格子状态错乱
- **对手装备镜像**：本端 `Equipments` 单例只含本地玩家装备；对手装备单独维护 `_remote_equip_insts: Array`，收到 `action/play_equip` 时追加 `EquipmentInstance`，激活后按耐久扣减，归零移除；长按对手英雄面板由 `_collect_remote_equip_descs()` 生成描述
- **PVP 回合控制**：`Game.pvp_is_my_turn()` 判断行动归属；本端结束回合调 `TurnSystem.run_pvp_phase(PLAYER)` 只跑己方单位，发 `action/end_turn` 只发给对手（避免 echo）；收到 `action/end_turn` 调 `play_controller.handle_remote_end_turn()` + `Game.pvp_advance_turn()`
- **SnapshotIO 序列化基础设施**：`DeckManager.to_dict/from_dict`、`ManaSystem.to_dict/from_dict`、`BoardSlot.to_dict/from_dict`、`Equipments.to_dict/from_dict` 等；版本号字段兼容；`SnapshotIO.serialize_battle / restore_battle` 顶层封装；F5/F9 开发键本地存读档
- **SparringPanel 大厅 UI**：继承 SecondaryPanel，完全代码布局（绕开 anchor 系统，在 NOTIFICATION_RESIZED 手动设 position/size）；Mode0「我的房间」展示 2×3 槽位格 + 准备/开始按钮；Mode1「加入房间」展示房间列表 + 数字键盘直接输房号；刷新按钮 3 秒冷却倒计时；Node 销毁前自动 `_unbind_net_signals`
- **session_id 同机双开隔离**：NetworkManager._session_id = uuid + 随机4位后缀，同一台机跑两个实例时两端 session_id 不同，服务器/路由正确区分两个玩家

## 13. PVP 多人联机系统

### 13.1 网络层（NetworkManager / Net autoload）

`scripts/net/network_manager.gd`，autoload 名 `Net`。

**职责**：
1. 管理与 Go 中继服务器的 WebSocket 连接（连接/断开/重连）
2. 收到 JSON 文本后反序列化为 Dictionary 并发出 `message_received` 信号
3. 提供 `send / send_to_room / send_to_host / send_to` 便捷发送 API
4. 持有本端 `_uuid`（持久）与 `_session_id`（每次启动随机后缀，同机双开隔离）、`_nickname`

**连接 URL 格式**：`ws://host:port/ws?uuid=<session_id>&nickname=<uri_encoded>`

| 信号 | 触发时机 |
|---|---|
| `connected` | WebSocketPeer 状态变为 STATE_OPEN |
| `connection_failed(reason)` | `connect_to_url` 返回非 OK |
| `disconnected` | WebSocket 关闭（含断线） |
| `message_received(msg: Dictionary)` | 每条合法 JSON 包 |

**关键 API**：
- `connect_to_server(host="", port=0)` — 空参时读 `ProfileManager.get_server_config()`
- `disconnect_from_server()`
- `send(msg: Dictionary)` — 直发
- `send_to_room(type, room_id, payload={}, to="all")` — 自动填 room_id + to
- `send_to_host(type, room_id, payload={})` — to="host"
- `send_to(type, room_id, target_uuid, payload={})` — 发给指定 uuid
- `set_current_room_id(rid)` / `get_current_room_id()` — 战斗场景通过此字段发 action/*
- `get_session_id()` — 本次会话唯一标识（含随机后缀）
- `set_nickname(nick)` — 同步更新昵称并持久化

### 13.2 玩家身份（ProfileManager）

`scripts/net/profile_manager.gd`，`class_name ProfileManager extends RefCounted`，全静态方法，无需 autoload。

**持久化文件**：
- `user://profile.json`：`{ "uuid": "...", "nickname": "玩家甲" }`
- `user://server.json`：`{ "host": "127.0.0.1", "port": 8080 }`

**主要方法**：
- `get_or_create_uuid() -> String` — 首次生成 UUID v4（32位随机16进制）并持久化
- `get_nickname() / set_nickname(nick)` — 昵称读写
- `get_server_config() -> Dictionary` — 读服务器配置，缺省返回 `{host:"127.0.0.1", port:8080}`
- `save_server_config(host, port)`

### 13.3 战斗状态序列化（SnapshotIO）

`scripts/core/snapshot_io.gd`，`class_name SnapshotIO extends RefCounted`，全静态方法。

**设计目标（分步实现）**：
- Step 1（当前）：单玩家本地存读档原型，验证序列化边界
- Step 5+：扩展为多玩家 + 私密性过滤（按 player_id 拆 deck/hand/equipments）

**顶层 API**：
- `serialize_battle() -> Dictionary` — 序列化当前全局状态快照
- `restore_battle(snap: Dictionary)` — 从快照还原（前提：Game.bootstrap 已跑，空 BoardSlot 已建好）
- `save_to_file(path=SAVE_PATH) -> bool` — 写 `user://battle_snapshot.json`
- `load_from_file(path=SAVE_PATH) -> bool` — 读文件并还原

**快照结构**（`VERSION=1`）：
```json
{
  "version": 1,
  "turn_number": N,
  "deck": { /* DeckManager.to_dict() */ },
  "mana": { /* ManaSystem.to_dict() */ },
  "counters": { /* Game.counters */ },
  "slots": [ /* slot.to_dict() 数组 */ ],
  "equipments": { /* Equipments.to_dict() */ }
}
```

**不序列化的部分**：SpawnerSystem 配置（PVP 关闭）、SpellCasterSystem 配置（PVP 关闭）、HeroAbilityRegistry once_per_turn 状态（待加）、DialogueManager / ScriptedEvents 状态（PVP 禁用）

**开发快捷键**（`test_main._input`）：
- `F5`：`SnapshotIO.save_to_file()` — 存当前战斗状态
- `F9`：`SnapshotIO.load_from_file()` — 读文件还原战斗状态

### 13.4 大厅 UI（SparringPanel）

`scripts/ui/sparring_panel.gd`，`class_name SparringPanel extends SecondaryPanel`，场景 `res://scenes/SparringPanel.tscn`。

**布局**：完全代码手动布局（在 `NOTIFICATION_RESIZED` 中手动设 position/size，绕开 anchor 系统）：
- 右侧固定宽 160px：BackBtn + 4 个模式按钮（RightActionPnl）
- 左侧主内容区（LeftContentPnl）：随大小动态填充

**4 个模式**（右侧按钮切换）：

| 索引 | 名称 | 行为 |
|---|---|---|
| 0 | 我的房间 | 自动连接服务器 → 发 room/create → 显示房间号 + 2×3 槽位格 + 准备/开始按钮 |
| 1 | 加入房间 | 连接服务器 → 拉房间列表（3s 冷却） + 数字键盘输入房号直接加入 |
| 2 | 随机匹配 | 占位（施工中） |
| 3 | 随机排位 | 占位（施工中，默认落入此页） |

**准备系统**：
- `_player_ready: Dictionary` = `uuid → bool`，所有玩家准备状态
- `_is_local_ready: bool` — 本地玩家当前准备状态
- 非房主玩家点「准备」发 `room/ready_update`；房主看到所有非房主准备完毕且 ≥2 人时「开始」按钮解锁

**数字键盘面板**（Mode 1 右侧）：
- 最多输 5 位房号；× 键清空；「加入房间」按钮发 `room/join`
- `_refresh_btn_ref` 跨帧持久，重建 UI 后协程继续更新倒计时文字

**网络消息处理**（`_on_net_message`）：

| type | 动作 |
|---|---|
| `room/create_ok` | 记录 room_id / host_uuid / players，清空 ready 状态，刷新 UI |
| `room/joined` | 同上 + 强制切回 Mode 0 |
| `room/join_rejected` | 刷新 UI |
| `room/left` | 过滤离开玩家，更新 host_uuid |
| `room/list_response` | 更新 _rooms 列表（过滤 started=true 的房间） |
| `room/expired` / `room/destroy` | 清空 room_id / players / host_uuid |
| `disconnect/notify` | 过滤断线玩家，更新 host_uuid |
| `room/ready_update` | 更新 _player_ready，刷新 UI |
| `game/start` | 调 `_handle_game_start` → 发起战斗场景跳转 |

**信号绑定生命周期**：`_apply_styles` 中 `_bind_net_signals`；`NOTIFICATION_PREDELETE` 时 `_unbind_net_signals`，防止节点销毁后信号野火。

### 13.5 PVP 战斗场景路径（test_main.gd）

`test_main._ready` 根据 `Game.is_pvp` 分叉：

**PVP 路径**：
1. `_inject_pvp_level_data()` — 向 `Game.level_data.boards` 注入本端/对端双盘元数据（hero_spec 由 `Game.hero_specs[player_id]` 取）
2. `BoardOrchestrator.boot()` — 装配两块棋盘
3. `_setup_pvp_slots()` — 按 session_id 为 player_main / enemy_main 注入 `owner_player_id`
4. `Net.message_received.connect(_on_pvp_message)` — 接入战斗消息
5. `_update_pvp_turn_ui()` — 按 `Game.pvp_is_my_turn()` 设置按钮初始状态

**PVP 消息处理（串行队列）**：
- `_pvp_msg_queue + _pvp_processing` 保证顺序
- `_handle_pvp_message` 分发：

| type | 动作 |
|---|---|
| `action/play_card` | `play_controller.handle_remote_play_card(payload)` |
| `action/play_equip` | 追加 `EquipmentInstance` 到 `_remote_equip_insts` |
| `action/activate_equip` | `play_controller.handle_remote_activate_equip` + 扣对手装备耐久 |
| `action/cross_board` | 1v3 守方跨盘选择 → `Game.turn.enqueue_cross_choice(payload)` 入队；end_turn 触发回放阶段消费 |
| `action/end_turn` | `_on_remote_end_turn` → `run_pvp_phase` + `pvp_advance_turn` |
| `action/activate_hero` | `_handle_remote_activate_hero`（仅 restart 有视觉镜像） |
| `disconnect/notify` | 对掉线玩家 `damage_hero(100,"triggered")` → 标准阵亡流程 |
| `game/end` | 未显示胜负时按 winner_id 显示胜利/退出 |

**本端结束回合（PVP）**：
1. 检查 `Game.pvp_is_my_turn()`
2. `await Game.turn.run_pvp_phase(TurnSystem.PLAYER)` — 只跑己方单位
3. `my_mana.start_new_turn()` + reset abilities/equipments
4. `Net.send_to(action/end_turn, room_id, opp_id, ...)` — 只发给对手，避免 echo
5. `Game.pvp_advance_turn()` + `_update_pvp_turn_ui()`

**胜负判定**：
- 英雄死亡（己方或对方）→ `_on_hero_died(is_enemy)` → 若 `Game.is_pvp` 发 `game/end` → `_show_game_over`
- 投降：`_on_pvp_surrender` → `damage_hero(100, "triggered")` → 走标准阵亡流程 → 自动触发 `_on_player_hero_died` → `game/end`
- 退出战斗：`_on_exit_to_menu` → `Net.disconnect_from_server()` + 清 PVP 状态

### 13.6 网络消息协议（客户端 ↔ 服务器）

消息格式（JSON 文本）：
```json
{
  "type":    "action/play_card",
  "to":      "all",            // "all" | "host" | "<uuid>"
  "from":    "<session_id>",   // 服务器填入，客户端可不填
  "room_id": "12345",
  "payload": { ... }
}
```

**房间管理消息**（大厅用）：

| type（客→服） | 说明 |
|---|---|
| `room/create` | 创建新房间（服务器随机5位数字号） |
| `room/join` | 加入指定 room_id 的房间 |
| `room/leave` | 离开当前房间 |
| `room/list` | 请求公开房间列表 |
| `room/ready_update` | 广播本玩家准备状态 |

| type（服→客） | 说明 |
|---|---|
| `room/create_ok` | 创建成功，含 room_id / host_uuid / players |
| `room/joined` | 有玩家加入（含更新后的 players 列表） |
| `room/join_rejected` | 加入失败（已开战/已满） |
| `room/left` | 有玩家离开，含 new_host_uuid |
| `room/list_response` | 房间列表，含 started 字段（客户端过滤） |
| `room/expired` / `room/destroy` | 房间销毁 |
| `disconnect/notify` | 有玩家掉线，含 uuid / new_host_uuid |
| `game/start` | 服务器下发行动顺序 + 随机种子，触发场景切换 |

**战斗中消息**（战斗场景用）：

| type | 发送方 | 说明 |
|---|---|---|
| `action/play_card` | 房主 → 对手 | 出牌，含 card_name / slot_id / cell 等 |
| `action/play_equip` | 房主 → 对手 | 出装备，含 card_name |
| `action/activate_equip` | 房主 → 对手 | 激活装备，含 equip_name + 效果参数 |
| `action/activate_hero` | 任一 → 对手 | 激活英雄技能，含 ability_id + 相关参数 |
| `action/end_turn` | 任一 → 对手（非 all） | 结束回合，含 player_id / turn_number |
| `game/end` | 房主 → all | 战斗结束，含 winner_id / reason |

- **Game.decks / manas 字典化**：PVE 旧代码通过 `Game.deck` / `Game.mana` 别名无感使用；PVP 模式新增 `Game.decks[player_id]` / `Game.manas[player_id]`，`deck_of_slot / mana_of_slot` 按 slot.owner_player_id 路由，避免多玩家费用串联
- **bootstrap_pvp 与 bootstrap 分支**：`bootstrap_pvp` 不走章节/关卡路径，不初始化 ScriptedEvents/SpawnerSystem，为每位玩家独立建 DeckManager + ManaSystem + HeroSpec（全为英雄A），PVP 战斗场景通过 `Game.is_pvp` 分支走 `_inject_pvp_level_data → _setup_pvp_slots` 专属路径
- **PVP 消息队列串行**：`test_main._pvp_msg_queue` + `_pvp_processing` 保证 await 消息依序处理，避免并发导致格子状态错乱
- **对手装备镜像**：本端 `Equipments` 单例只含本地玩家装备；对手装备单独维护 `_remote_equip_insts: Array`，收到 `action/play_equip` 时追加 `EquipmentInstance`，激活后按耐久扣减，归零移除；长按对手英雄面板由 `_collect_remote_equip_descs()` 生成描述
- **PVP 回合控制**：`Game.pvp_is_my_turn()` 判断行动归属；本端结束回合调 `TurnSystem.run_pvp_phase(PLAYER)` 只跑己方单位，发 `action/end_turn` 只发给对手（避免 echo）；收到 `action/end_turn` 调 `play_controller.handle_remote_end_turn()` + `Game.pvp_advance_turn()`
- **SnapshotIO 序列化基础设施**：`DeckManager.to_dict/from_dict`、`ManaSystem.to_dict/from_dict`、`BoardSlot.to_dict/from_dict`、`Equipments.to_dict/from_dict` 等；版本号字段兼容；`SnapshotIO.serialize_battle / restore_battle` 顶层封装；F5/F9 开发键本地存读档
- **SparringPanel 大厅 UI**：继承 SecondaryPanel，完全代码布局（绕开 anchor 系统，在 NOTIFICATION_RESIZED 手动设 position/size）；Mode0「我的房间」展示 2×3 槽位格 + 准备/开始按钮；Mode1「加入房间」展示房间列表 + 数字键盘直接输房号；刷新按钮 3 秒冷却倒计时；Node 销毁前自动 `_unbind_net_signals`
- **session_id 同机双开隔离**：NetworkManager._session_id = uuid + 随机4位后缀，同一台机跑两个实例时两端 session_id 不同，服务器/路由正确区分两个玩家




## 14. 1v3 多棋盘 PVP 系统

> 详细规格见 `multiplay_chess_skills.md`。本节仅记录关键架构点。

### 14.1 核心数据扩展

| 类 / 文件 | 新增字段 / 方法 |
|---|---|
| `BoardSlot` | `team_id: String`（"defender"/"attacker"）；`slot_index: int`；`_on_hero_died` 按 team_id 判胜负 |
| `Cell` | `team_id: String`；`is_hostile_to(viewer_team_id)`；`is_friendly_to(viewer_team_id)` |
| `BoardRegistry` | `by_team(team_id)`；`by_owner(player_id)`；`adjacent_enemy_slots(viewer_pid, col)` |
| `GameContext` | `pvp_match_type`；`pvp_teams`；`pvp_dead_players`；`pvp_advance_turn_skip_dead`；`is_round_complete`；队伍工具方法；`pvp_end_game` |

### 14.2 布局路由（BoardLayoutResolver）

`scripts/core/board_layout_resolver.gd`：输入 viewer_pid + slot_layout，输出：
- `local_slot_id`：本端盘 → 屏幕下方
- `top_slot_id`：主对手盘 → 屏幕上方中央
- `extra_top_ids`：守方时额外 2 个攻方盘 → 上方左/右附盘
- `side_slot_ids`：攻方时 2 个队友盘 → 侧面附盘

### 14.3 跨盘逻辑（TurnSystem 三分支）

`_process_cell` 按 `slot.team_id + faction` 分三路：

| 分支 | 条件 | 行为 |
|---|---|---|
| 守方拥有者 | defender + PLAYER faction | UI 选目标盘 → `_broadcast_cross_board` |
| 守方远端 | defender + ENEMY faction | `consume_cross_choice` 取队列 |
| 攻方（双向） | attacker | `_enemy_auto_cross`（确定性，单一目标=守方盘） |
| PVE/1v1 | team_id == "" | 旧逻辑不变 |

**镜像列规则**：`dst_col = COLS - 1 - src_col`（配合 `_reverse_grid_cells` 视觉翻转，单位视觉同列落地）。

### 14.4 跨盘选择同步（action/cross_board）

- 守方 owner 完成 UI 选择后广播 `action/cross_board` → 所有远端入 `_pending_cross_choices` 队列
- 远端在 end_turn 触发 `run_pvp_phase_for_slot` 期间按 FIFO consume
- WebSocket FIFO + Go 纯中继保证三端队列一致，无需 await

### 14.5 回合推进（1v3）

- 每位玩家独立 `TurnSystem.run_pvp_phase_for_slot(slot_id)` 跑本盘单位
- 结束回合广播 `action/end_turn` 给 `to="all"`（1v3 改为全员广播，不再只发对手）
- `pvp_advance_turn_skip_dead()` 跳过阵亡玩家；`is_round_complete()` 判断一整轮完成后 turn_number +1

### 14.6 胜负判定

- `BoardSlot._on_hero_died` 按 team_id 判：守方死 → 攻方胜；攻方任一死 → 守方胜（测试期简化）
- `pvp_end_game(winning_team, loser_pid)` 广播 `game/end` 含 `winning_team` + `loser_pid`
- 断线：`disconnect/notify` 含 `dead_player_id` → 按 `registry.by_owner(dead_pid)` 路由 `damage_hero(100)`

### 14.7 待完成（P1）

- [ ] `TeammateSidePanel`：队友公开信息面板（未建）
- [ ] 含 await 效果加 result 字段广播（`destroy_unit` / `weaken` / `flood_strategy_hero`）
- [ ] `assault_charge` 迁移 `is_hostile_to`（当前仍用 `is_enemy`）


## 14. 1v3 多棋盘 PVP 系统

> 详细规格见 `multiplay_chess_skills.md`。本节仅记录关键架构点。

### 14.1 核心数据扩展

| 类 / 文件 | 新增字段 / 方法 |
|---|---|
| `BoardSlot` | `team_id: String`（"defender"/"attacker"）；`slot_index: int`；`_on_hero_died` 按 team_id 判胜负 |
| `Cell` | `team_id: String`；`is_hostile_to(viewer_team_id)`；`is_friendly_to(viewer_team_id)` |
| `BoardRegistry` | `by_team(team_id)`；`by_owner(player_id)`；`adjacent_enemy_slots(viewer_pid, col)` |
| `GameContext` | `pvp_match_type`；`pvp_teams`；`pvp_dead_players`；`pvp_advance_turn_skip_dead`；`is_round_complete`；队伍工具方法；`pvp_end_game` |

### 14.2 布局路由（BoardLayoutResolver）

`scripts/core/board_layout_resolver.gd`：输入 viewer_pid + slot_layout，输出：
- `local_slot_id`：本端盘 → 屏幕下方
- `top_slot_id`：主对手盘 → 屏幕上方中央
- `extra_top_ids`：守方时额外 2 个攻方盘 → 上方左/右附盘
- `side_slot_ids`：攻方时 2 个队友盘 → 侧面附盘

### 14.3 跨盘逻辑（TurnSystem 三分支）

`_process_cell` 按 `slot.team_id + faction` 分三路：

| 分支 | 条件 | 行为 |
|---|---|---|
| 守方拥有者 | defender + PLAYER faction | UI 选目标盘 → `_broadcast_cross_board` |
| 守方远端 | defender + ENEMY faction | `consume_cross_choice` 取队列 |
| 攻方（双向） | attacker | `_enemy_auto_cross`（确定性，单一目标=守方盘） |
| PVE/1v1 | team_id == "" | 旧逻辑不变 |

**镜像列规则**：`dst_col = COLS - 1 - src_col`（配合 `_reverse_grid_cells` 视觉翻转，单位视觉同列落地）。

### 14.4 跨盘选择同步（action/cross_board）

- 守方 owner 完成 UI 选择后广播 `action/cross_board` → 所有远端入 `_pending_cross_choices` 队列
- 远端在 end_turn 触发 `run_pvp_phase_for_slot` 期间按 FIFO consume
- WebSocket FIFO + Go 纯中继保证三端队列一致，无需 await

### 14.5 回合推进（1v3）

- 每位玩家独立 `TurnSystem.run_pvp_phase_for_slot(slot_id)` 跑本盘单位
- 结束回合广播 `action/end_turn` 给 `to="all"`（1v3 改为全员广播，不再只发对手）
- `pvp_advance_turn_skip_dead()` 跳过阵亡玩家；`is_round_complete()` 判断一整轮完成后 turn_number +1

### 14.6 胜负判定

- `BoardSlot._on_hero_died` 按 team_id 判：守方死 → 攻方胜；攻方任一死 → 守方胜（测试期简化）
- `pvp_end_game(winning_team, loser_pid)` 广播 `game/end` 含 `winning_team` + `loser_pid`
- 断线：`disconnect/notify` 含 `dead_player_id` → 按 `registry.by_owner(dead_pid)` 路由 `damage_hero(100)`

### 14.7 待完成（P1）

- [ ] `TeammateSidePanel`：队友公开信息面板（未建）
- [ ] 含 await 效果加 result 字段广播（`destroy_unit` / `weaken` / `flood_strategy_hero`）
- [ ] `assault_charge` 迁移 `is_hostile_to`（当前仍用 `is_enemy`）
