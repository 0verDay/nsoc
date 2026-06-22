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

AiManager     (autoload "scripts/ai/ai_manager.gd") AI 注册中心，持有 `{slot_id → AiAgent}`，供 TurnSystem 查询

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

| `pvp_match_type` | `String` | 对局类型："1v1" / "1v3" / "3v3"；空串=PVE |

| `pvp_teams` | `Dictionary` | 队伍映射：`{ team_id: [pid,...] }`（1v3: defender/attacker；3v3: team_a/team_b） |

| `pvp_dead_players` | `Array` | 本局已阵亡玩家 uuid 列表 |

| `pvp_match_type` | `String` | 对局类型："1v1" / "1v3" / "3v3"；空串=PVE |

| `pvp_teams` | `Dictionary` | 队伍映射：`{ team_id: [pid,...] }`（1v3: defender/attacker；3v3: team_a/team_b） |

| `pvp_dead_players` | `Array` | 本局已阵亡玩家 uuid 列表 |

**Game PVP 方法**：；第三参数兼容旧 Array 格式；`match_type` = "1v1" / "1v3" / "3v3" / "3v3" / "3v3"；`teams_map` = `{ team_id: [pid,...] }`；`slot_layout` = `[{slot_id, owner_pid, team_id, slot_index},...]`；缺失 pid 的 hero_key 回退 `DeckStorage.get_selected_hero()`

- `get_battle_hero_key() -> String` — 静态方法，返回 `DeckStorage.get_selected_hero()`，PVE bootstrap 通过此方法动态读取玩家携带英雄（而非硬编码 "A"）

- `pvp_active_player_id() -> String` — 当前应行动玩家 ID

- `pvp_is_my_turn() -> bool` — 当前是否轮到本端行动

- `pvp_advance_turn()` — 推进 pvp_active_idx（1v1 用，不跳过阵亡）

- `pvp_advance_turn_skip_dead()` — 推进并跳过 pvp_dead_players（1v3 / 3v3 用）

- `is_round_complete() -> bool` — 判断一整轮是否完成（pvp_active_idx 回到 0）

- `team_of_player(pid) -> String` — 返回玩家所属 team_id

- `players_of_team(team_id) -> Array` — 返回某队所有玩家

- `is_player_alive(pid) -> bool` — 玩家是否仍存活

- `mark_player_dead(pid)` — 标记玩家阵亡

- `pvp_end_game(winning_team, loser_pid)` — 广播 game/end 并本端转结算 UI（1v1 用，不跳过阵亡）

- `is_multi_team_pvp() -> bool` — 是否为多队伍 PVP（1v3 或 3v3），替代散落的 `pvp_match_type == "1v3"` 判断

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

**Game 帝国模式字段**（`scripts/core/game_context.gd`）：

| 字段 | 类型 | 说明 |
|---|---|---|
| `pending_empire_battle` | `Dictionary` | EmpireTest 进入战斗前写入；bootstrap 检测到后走 `_bootstrap_empire` 分支，消费后清空。字段：`target_id(int)` + `attackers: Array[{hero_key, hero_force, hero_display}]` |
| `empire_battle_result` | `String` | main.gd 战斗结束后写入 `"win"` 或 `"lose"`；EmpireTest._ready 消费后清空 |
| `empire_state` | `Dictionary` | EmpireTest 进入战斗前快照全图状态，场景切换后在 EmpireTest._ready 中还原并应用结果。字段：`deployed / exiled / pending_campaigns / pending_campaign_sources / faction_overrides / gold / food / current_battle_target_id` |

**`_bootstrap_empire(ctx)` 方法**：EmpireTest 触发，根据 `attackers` 数量 N（clamp 到 1–3）：
- **6-slot 布局**：N=1 仅启用主对主（player_main + enemy_main，slot 4/1）；N=2 加左翼（ally_left + enemy_left，slot 3/0）；N=3 全部 6 盘启用
- **Hero 规格**：主将（attackers[0]）hp=force，deck=EmpireDeckStorage；aux 玩家盘 hp=各自 force；所有敌方 hp=10 占位
- **Spawner**：所有启用棋盘各自底线（玩家侧 row=2/col=1，敌方侧 row=0/col=1）每回合生 1 张填线宝宝，`interval=1`
- **card_db** 仍用 all_cards.json；玩家牌组通过 `DataLoader.generate_battle_cards_from_empire` 写入 battle_cards.json
- 跳过章节 Objectives/Events；消费 pending_chapter_config / pending_level_path

**BoardSlotFactory**（`scripts/core/board_slot_factory.gd`）：集中封装"建 BoardModel + 实例化 cell + 挂入 grid + 配 spawners + 摆初始单位"步骤：

- `create_main(id, faction, role, grid, bg, hero_panel, cell_scene, hero_spec, level_section, on_cell_created)` — 建标准 3×3 slot，自动入 registry

- `destroy(slot)` — 断信号 → 场上残存单位路由到主盘除外区 → 注销 registry → 释放子节点

**bootstrap() 流程**：①先解析关卡（含章节专属字段 `hero_key` / `initial_mana` / `mana_max_cap` / `objective`）写入 `level_data`；②从 `level.hero_key` 确定玩家英雄（空则回退 `BATTLE_HERO_KEY="A"`）读 `hero.json` → 填 `hero_specs`；③生成 `user://battle_cards.json`；④加载 `all_cards.json` 到 `card_db`；⑤发 `cards_loaded` / `level_loaded` 信号；⑥初始化 deck；⑦`mana.setup(initial_mana > 0 ? initial_mana : 1, mana_max_cap > 0 ? mana_max_cap : MAX_MANA_CAP)`（章节可覆盖首回合起始费 + 永久费用上限封顶，例：街亭·王平协防 cap=5）；⑧初始化 counters；⑨`HeroAbilities.reset_turn_usage()`；⑩`Equipments.clear_all()`；⑪`turn.is_running = false; turn.turn_number = 0`；⑫`Objectives.setup_for_battle(level.objective)`；⑬`Events.setup_for_battle(level_data)`；⑭消费 `pending_chapter_config` / `pending_level_path`。

### 3.2 卡牌生命周期与多阵营牌堆

`DeckManager` 管理玩家牌堆 3 个数组：draw_pile / graveyard / banished。`pile_changed` 信号驱动 UI 刷新。新增 `signal reshuffled`（非首次 `reshuffle(false)` 末尾发射），用于 PVP 跨端镜像重洗（详见 §14.8）。`_rng_base_seed + _reshuffle_count` 决定每次重洗的确定性洗牌种子。

敌方阵营每个 `BoardSlot` 自持 graveyard / banished，敌方死亡牌入对应 slot 的 graveyard，`terrify` 再转入 slot.banished。`EnemySidePanelManager` / `AllySidePanelManager` 绑定具体 slot 实例并同时订阅 `Game.get_deck(slot.owner_player_id).pile_changed`，`_refresh_content` 取并集 `slot.graveyard ∪ owner_deck.graveyard` 展示，保证 hand-origin（写入 deck）和 spawner-origin（写入 slot）单位都能在跨端面板上完整可见。**当前 UI 入口已全面移除（§14.9）**，类与订阅链保留供将来恢复。

**装备牌生命周期**：玩家拖拽装备牌到英雄面板 → `PlayController.handle_equip` 扣费 → `Equipments.equip(card_data)` 建 `EquipmentInstance`，**装备卡本体不入墓** → 耐久归零时 `EquipmentManager._on_inst_changed` 自动调 `Game.deck.send_to_graveyard` 并 `unequip`；PVP 中同时广播 `action/equip_broken`，远端 `Game.decks[from].send_to_graveyard` 同步入墓 + 移除 `_remote_equip_insts[from]` 中的破损 inst。

### 3.3 效果注册表与多态钩子

`Effect` 基类 5 个钩子：`on_play / on_death / on_kill / resolve_destination / id+display_name+description`。

`EffectContext` 门面：`board() / combat() / turn() / banish_card / send_to_graveyard / trigger_vigilance / get_counter / inc_counter`。

### 3.4 战斗系统

`CombatSystem.attack_cells`：攻击动画 → 扣对位面血量（frail=四面同扣，通过 `Orientation.abs_to_side` 将攻击绝对方向转为 defender 的 side 后扣血）→ 收集死亡 → 快照 victim → clear_card → on_kill。

`CombatSystem.move_card`：单段 sine 缓动 + 抛物 sin(π·t) 拱起。

### 3.5 回合驱动（多棋盘）

`TurnSystem.run`：**友军 AI 出牌** → 玩家阶段 → 刷怪 → **敌方 AI 出牌** → 敌方阶段 → reset_attack_flags（主棋盘+所有额外棋盘）。

- `_run_ai_phase_for_faction(faction)` — PVE 专属；按 `faction` 过滤 `AiManager.all_agents()` 中对应阵营的 Agent，依次调 `agent.mana.start_new_turn()` + `await agent.take_turn()`；`is_pvp == true` 时跳过
  - `faction = FACTION_PLAYER`（友军 AI）在 PLAYER 阶段**之前**运行 → 本回合立即可行动
  - `faction = FACTION_ENEMY`（敌方 AI）在 ENEMY 阶段**之前**运行 → 本回合立即推进

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

| 攻方双向 | "attacker" | 任意 | `_enemy_auto_cross` 自动跨守方盘（`_can_cross_board` 覆盖"到达 front_row"和"冲锋提前到达"） |

| PVE/1v1 PLAYER | "" | PLAYER | 若 `AiManager.is_ai_slot(slot.id)` → 随机选一个敌方盘自动跨；否则 `_run_front_row_selection` UI 选盘 |

| PVE/1v1 ENEMY | "" | ENEMY | `_enemy_auto_cross`（修正：用 `_can_cross_board` 替代 `cell.row == front_row`；让 charge 单位在路径全空时也能跨盘，修复"对手视角下冲锋单位只移到自家前排不跨盘"的 PVP 锁步 desync） |

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

- `SidePanelManager(center_x_offset)` — 玩家牌堆/墓地/除外（本端三按钮：牌库 / 墓地 / 除外），支持水平定位

- `EnemySidePanelManager(center_x_offset)` — 绑定 BoardSlot 展示敌方墓地/除外面板。**当前 UI 入口已全面移除**（主敌方按钮在 `main.gd` / `test_main.gd._create_enemy_pile_buttons` 中删除，附盘按钮在 `board_orchestrator._create_slot` 把 `show_pile=false` 传给 `SideBoardUi.build`）。类与 `set_slot` 数据订阅链保留：在 `set_slot` 中同时监听 `slot.pile_changed` 与 `Game.get_deck(slot.owner_player_id).pile_changed`；`_refresh_content` 取并集 `slot.graveyard ∪ owner_deck.graveyard`。`PILE_TO_PANEL` 同时认 BoardSlot 的 `"banished"` 与 DeckManager 的 `"banish"`。`update_clip_center_x()` 动态跟随棋盘移动。

- `AllySidePanelManager(center_x_offset)` — 友军盘对应 manager，从底部上拉。语义/订阅与 `EnemySidePanelManager` 对称，UI 入口同样已移除。

- 附盘 hp 面板（`SideBoardUi.build`）水平拉伸至整盘宽度（`BOARD_HALF_W * 2 = 460`），与主敌方 `EnemyHpPnl` 拉伸后的布局保持一致。

- `SettingsPanelController` — 选项面板，`z_index=200` 覆盖所有 UI；参数化 resume/exit/can_open；新增 `hide_exit: bool`（传入 `config["hide_exit"]=true` 时不渲染"退回菜单"按钮，帝国出征战斗专用）

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

- `campaigns.json` 战役表：当前 3 个战役（c1 测试·三国、c2、c3），c1 含长坂坡/威震华夏/街亭三章节；街亭场景为 `Jieting.tscn`（双面板选英雄过渡，下文§4 描述）；描述字段支持 **MarkupParser 自定义标记**（`{place:}` `{ally:}` `{enemy:}` `{warn:}` `{key:}` `{para}` `{break}`）→ BBCode 富文本

- `data/chapters/changbanpo.json`、`weizhenhuaxia.json`、`jieting_masu.json`、`jieting_wangping.json` — 章节固定牌堆/关卡配置（街亭按玩家选择英雄走两份不同 config，仅 `hero_key`/`initial_mana`/`mana_max_cap`/`boards.player_main.hero` ↔ `boards.ally_left.hero` 互换 + 围山 trigger 目标 slot 不同）

- **章节 JSON 字段**（`DataLoader._parse_level` 解析）：

  - `hero_key: String` — 玩家专属英雄（`hero.json` key），空时回退 `BATTLE_HERO_KEY`

  - `initial_mana: int` — 首回合起始费上限（0/缺省 = 默认 1）

  - `mana_max_cap: int` — 本局费用永久上限封顶（0/缺省 = `MAX_MANA_CAP=10`）；与 `initial_mana` 配合实现"协防 5/5 永久不增长"等机制；ManaSystem.start_new_turn 检测 `if maximum < cap` 才 +1

  - `objective: Dictionary` — 胜利目标（`{type, ...params}`，无 type 时不启用）

  - `board_events: Array` — 格式 `[{"turn":N, "add":[...], "remove":[...], "actions":[...]}]`；`add/remove` 由 `BoardOrchestrator._on_turn_started` 处理，`actions` 由 `Events` 调度

  - `triggers: Array` — 格式 `[{"id","when":{"type","n"/"threshold"/"name"/"faction"/"board",...},"once","cooldown","actions"}]`；`Events.setup_for_battle` 注册，条件类型见 §3.14

- `data_loader.gd` 静态读 JSON → CardBase/CardUnit/CardSpell/**CardEquipment** + 关卡字典 + 英雄字典；新增常量 `EMPIRE_CARDS_JSON = "res://data/empire_cards.json"` 与静态方法 `generate_battle_cards_from_empire(hero_key: String)`（从 `EmpireDeckStorage.load_deck(hero_key)` 取卡组配置，反查 `empire_cards.json` 原型库，写入 `user://battle_cards.json`；与 `generate_battle_cards` 并行但走独立存档路径）

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

- 附盘墓地/除外面板：UI 按钮已全面取消（`show_pile=false` 传给 `SideBoardUi.build`，`grave_btn` / `banished_btn` 在 dict 中为 null）；`_create_slot` 内的 `_setup_side_enemy_panel` / `_setup_side_ally_panel` 入口条件改为 `side_ui_dict.get("grave_btn") != null`，按钮 null → 跳过 panel manager 创建。`_side_panels` dict 长期为空，`is_pile_button_hit` / `any_side_panel_open` / `is_side_panel_hit` 全部 no-op。

- 附盘 hp 面板水平拉伸至整盘宽度（`BOARD_HALF_W * 2`），与主敌方 hp 面板对齐。

- 面板管理器选择（保留为将来恢复 UI 入口的占位）：原按 `slot.faction` 区分，已改为按"上下位置"判定（与 `side_top` 同语义）。多队伍 PVP 用 `team_id == local_team` 判定（队友 → AllySidePanelManager 底部上拉），PVE/1v1 回退 `slot.faction`；修复 3v3 队友盘 `faction=ENEMY` 但视觉位于底部时面板会错配到顶部下拉的 bug。

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

| `spawn_unit` | `actions/spawn_unit.gd` | 向指定盘召唤单位；`strategy: any_empty`（随机空格）/ `fixed`（指定 row/col）/ `snap_origin`（用上游 `unit_died` 等事件 snap 中的 `slot_id` + `row` + `col` 在死亡盘的死亡格生成；owner_slot_id 仍取 action.board，跨盘死亡时 ownership 归属召唤者所在盘，墓地路由不出错） |

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

| `unit_died` | `name?`, `name_not?`（单值或数组，命中即排除）, `faction?`（0=玩家/1=敌方）, `board?` | 匹配条件的单位死亡时（`notify_unit_died` 调用时判定）；`name_not` 用于"任一非 X 的单位死亡"语义（如街亭巧变排除疑兵自循环）；trigger 触发时 snap（含 `card_name / is_enemy / owner_slot_id / slot_id / row / col`）会透传到 action ctx，`spawn_unit snap_origin` 等可读 |

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

**主菜单二级面板路由**（`main_menu.gd`）：`SECONDARY_PANEL_SCENES` 字典将按钮名映射到对应场景；`JourneyBtn` → `YanyiPanel.tscn`（演义）。

**跨场景返回机制**（`class_name MainMenu`）：

| 静态变量 | 类型 | 说明 |
|---|---|---|
| `pending_open_btn` | `String` | 场景切回前写入目标按钮名；`_maybe_auto_open()` 在 `_setup_transition` 完成后触发对应面板 |
| `pending_open_instant` | `bool` | `true` 时跳过展开动画，直接呈现展开态 + 挂载二级面板（`_apply_expanded_instant`）；用于从子场景（如 EmpireMain）无动画返回 |

`_maybe_auto_open` 在 `_ready` 中 `call_deferred("_setup_transition")` 之后 `call_deferred("_maybe_auto_open")` 以保证 layout 稳定。

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

| `autophagy` | 自噬 | on_play：对己方英雄造成累计伤害（`damage_player_hero` 解析 `target_cell.owner_slot_id` 对应盘的 hero，跨端一致；不再用 viewer-relative 的 `Game.main_player_slot()`） |

| `charge` | 冲锋 | TurnSystem：首次行动连步推进 |

| `empower` | 强化 | on_play：对目标友方单位四维各+1（注：代码只加 health 不加 attack） |

| `exhaust` | 除外 | resolve_destination：法术入除外 |

| `vigilance` | 警戒 | TurnSystem：敌方移入相邻格即攻击 |

| `breakout` | 突围 | on_play：相邻敌方每个提供+1攻+1四维 |

| `assault_charge` | 冲阵 | on_kill：飞入随机尸位递归攻击 |

| `frail` | 虚弱 | CombatSystem内联：受击四面同扣 |

| `steadfast` | 坚守 | TurnSystem拦截：不主动推进、不跨盘 |

| `terrify` | 破胆 | on_kill：击杀目标送入除外。受害者按 `v_owner_id → owner_player_id` 取对应玩家 deck（`Game.get_deck(pid)`）做 `erase + banish`，与 `handle_unit_death` 入墓路径一致；旧路径写死 `ctx.game.deck`（caster 本地）会让 PVP 中击杀对方手牌部署单位时除外去向错乱 |

| `battle_hardened` | 历战 | on_kill：攻击力+N |

| `fierce_combat` | 酣战 | on_kill：四维各+N |

| `gain_mana_1` | 增益 | on_play：获得 1 点费用（`Game.mana.gain(1)`），装备"圣杯"用 |

| `inspire` | 鼓舞 | on_play：对目标友方单位攻击力 +1 |

| `discard_hand_card` | 弃手牌 | on_play：弹出手牌选择器（`pick_hand_card_async`），弃选中牌入墓，再补 1 张；玩家取消时返回 false（装备耐久不扣） |

| `love_people` | 爱民 | on_death：对英雄「长坂坡·刘备」造成 1 点伤害（走 `ctx.damage_hero_by_name`），然后走默认入墓 |

| `destroy_unit` | 消灭 | on_play：目标敌方单位走完整死亡流程（动画→`handle_unit_death`→`clear_card`）；玩家取消目标选择时返回 false |

| `weaken` | 放箭 | on_play：对目标单位（`ctx.target_cell`）四维各 -1；任意一面 ≤0 则走标准死亡流程（闪烁动画 → `handle_unit_death` → `clear_card`）；由 `SpellCasterSystem` / `cast_spell` action 调用 |

| `soaked` | 浸水 | CombatSystem内联：受到任意伤害后立即强制四面归零（一次性，触发后从 effects 移除）；可被 `flood_strategy_hero` 技能 / `apply_soaked_to_all` action / `jue_di` 效果 / `flood_strategy_unit` turn_started 触发施加 |

| `flood_strategy_unit` | 水攻 | 无代码钩子（元数据）；实际逻辑由 `apply_soaked_to_all` action（`require_effect="flood_strategy_unit"`）在每回合 trigger 中驱动：若场上存在此效果单位，则给全场敌方单位施加 `soaked` |

| `yi_bing` | 疑兵 | 无独立钩子，由 CombatSystem 与 TurnSystem 内联检测：①TurnSystem `_process_cell` 先攻分支检 `effects.has("yi_bing")` 跳过近战，goal_row 命中走 `_self_destruct_yi_bing`（播死亡动画 → handle_unit_death → clear_card，不调 hero_resolver）；②CombatSystem `attack_cells` 扣血后，若 defender 含 yi_bing → 强制四面归零 + attacker 四面 HP 各 -2 + attacker 同步纳入 dead_cells；③巧变 trigger 用 `name_not: "疑兵"` 防自循环 |

| `awe` | 威震 | on_kill：每击杀一个敌方单位，对该单位原属盘英雄造成 1 点 triggered 伤害（穿透死守） |

| `ming_jin` | 鸣金 | on_play：选一个友方单位放回牌库顶（按 `cell.owner_slot_id → owner_player_id` 反查 `Game.get_deck(pid).add_to_draw_pile`，3v3 中正确写到目标单位拥有者 deck 而非 caster 本地 deck），并设 `counters["ming_jin_used"] += 1`（当前无消费方，保留语义） |

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

| `weishan_ability` | 围山 | 街亭遗恨·马谡 | — | — | 纯展示被动；免单位/法术直伤走 `flags["die_hard"]`；"友方单位死亡 -1HP" 由 chapter `unit_died` trigger（`faction:0`）调 `damage_hero source=triggered` 穿透 die_hard 实现 |

| `xiefang_ability` | 协防 | 街亭遗恨·王平 | — | — | 纯展示被动；起始 5 费 + 上限永久封顶 5 由 chapter `initial_mana=5` + `mana_max_cap=5` 在 bootstrap 时一次性设到 ManaSystem |

| `qiaobian_ability` | 巧变 | 街亭遗恨·张郃 | — | — | 纯展示被动；"任一非疑兵的己方单位死亡 → 在死亡格生成疑兵" 由 chapter `unit_died` trigger（`faction:1, board:enemy_main, name_not:疑兵`）调 `spawn_unit strategy=snap_origin` 实现 |

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

| `masu_jt` | 街亭遗恨·马谡 | 马谡 | 20 | weishan_ability | 街亭章节玩家英雄之一；初始 `flags["die_hard"]=true`（围山免直伤）；ally case 占 ally_left |

| `wangping_jt` | 街亭遗恨·王平 | 王平 | 20 | xiefang_ability | 街亭章节玩家英雄之一；协防 = chapter 注入 mana 5/5 永久封顶；ally case 占 ally_left（无 mana 影响） |

| `zhanghe_jt` | 街亭遗恨·张郃 | 张郃 | 30 | qiaobian_ability | 街亭主敌英雄；巧变 = chapter trigger 在 unit_died 时 spawn_unit snap_origin 召出疑兵 |

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

| 圣杯 | 装备 | 1 | — | — | gain_mana_1（耐久2，每回合限用1次） |

| 填线宝宝 | 单位 | 1 | 1 | 1/1/1/1 | — |

| 灰烬填线宝宝 | 单位 | 2 | 2 | 2/2/2/2 | ash |

| pro哥 | 单位 | 10 | 10 | 10/10/10/10 | ash, autophagy |

| 敢死队 | 单位 | 1 | 1 | 10/1/1/1 | charge |

| 看门狗 | 单位 | 3 | 1 | 1/2/2/2 | vigilance |

| 长板·赵云 | 单位 | 1 | 1 | 6/6/6/6 | breakout, fierce_combat, assault_charge, frail |

| 长板·张飞 | 单位 | 1 | 3 | 20/1/10/10 | steadfast, terrify, battle_hardened |

| 强化 | 法术 | 1 | — | — | empower |

| 乡勇 | 单位 | 1 | 1 | 1/1/1/1 | love_people（被击败后对长坂坡·刘备造成 1 伤） |

| 疑兵 | 单位 | 2 | 2 | 2/2/2/2 | yi_bing（无法主动攻击；到达敌方底线自爆；被攻击时自爆 + 攻击者四面 HP 各 -2）；街亭张郃巧变 spawn_origin 召出 |

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

**新战役章节**：`campaigns.json` 加 chapter 条目（描述支持 MarkupParser 标记），新建 `scenes/chapters/<Name>.tscn` 和 `data/chapters/<name>.json`（含 cards / boards / hero_key / initial_mana / mana_max_cap / objective / board_events / triggers 等），在章节场景写入 `Game.pending_chapter_config` 后切场景。boards 下每个 entry 可含 `faction / role / slot_index / enabled / hero / initial_units / spawners / spell_casters`。**双 config 模式**（街亭范式）：玩家在过渡面板选英雄分支不同 chapter config（`<chapter>_<heroX>.json` / `<chapter>_<heroY>.json`），仅 hero_key/initial_mana/mana_max_cap/boards 主友互换 + slot 相关 trigger 调整；`scripts/ui/jieting.gd` 是模板。

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

- **章节专属英雄与起始费**：`chapter.json` 写 `hero_key` / `initial_mana` / `mana_max_cap`；bootstrap 先解析关卡再确定玩家英雄，`mana.setup(initial_mana, mana_max_cap)` 覆盖默认值；不影响无此字段的旧关卡（cap 缺省走 `MAX_MANA_CAP=10`）

- **章节双 config 选英雄模式**（街亭范式）：`Jieting.tscn` 双面板（马谡 / 王平）选中后写不同 `pending_chapter_config`（`jieting_<key>.json`）；config 间 hero_key、initial_mana、mana_max_cap、boards.player_main.hero ↔ boards.ally_left.hero 互换 + 部分 trigger slot 调整；过渡面板用 panel.gui_input 信号 + PASS/IGNORE 分层让"整面板任意位置点击"都能选中

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

- **unit_died 通知用 call_deferred**：`PlayController._notify_events_unit_died` 改 `Events.call_deferred("notify_unit_died", snap)`，把 trigger 触发推迟到当前帧末。combat_system / turn_system 对死亡 cell 是"先 handle_unit_death 再 clear_card"的顺序，若同步触发 `spawn_unit snap_origin` 等"在死亡格生成"trigger 会撞上仍 `has_card == true` 的 cell 而被拒；deferred 后 cell 已清空，原位生成成功

- **snap 透传到 action ctx**：scripted_events `_fire_trigger / _run_actions / _run_actions_async` 全链路加可选 `snap: Dictionary` 默认 `{}`；上游 `notify_unit_died(snap)` 调 `_fire_trigger(trig, snap)` → 注入 ctx；`spawn_unit snap_origin` / 未来其它依赖死亡 row/col/slot 的 action 可读；旧 callsite 0 改动

- **name_not 过滤防自循环**：`_match_unit_died` 加 `name_not`（单值或数组）过滤；街亭巧变 `unit_died → spawn_unit("疑兵")` 用 `name_not: "疑兵"` 排除自身死亡触发，防 spawn → die → spawn 死循环

- **疑兵战斗 hook**：`yi_bing` effect 不实现 Effect 钩子，由 CombatSystem / TurnSystem 内联检测：①`turn_system._process_cell` 先攻分支检 `effects.has("yi_bing")` 跳过近战；②`goal_row` 命中走 `_self_destruct_yi_bing`（`Game.play.handle_unit_death` + `clear_card`，不调 hero_resolver，不打英雄）；③`combat_system.attack_cells` 扣血后若 defender 含 yi_bing → 强制四面归零 + attacker 四面 HP 各 -2 + attacker 同步纳入 dead_cells（攻击者反伤致死自动跳过 handle_kills，因第 119 行 `attacker.has_card == false` 守卫）

- **DialogueManager FIFO + CanvasLayer(92)**：叠于战斗 UI 之上、结算面板之下；`clear_queue()` 退出战斗时清空防残留；气泡全代码构建，显示时长自适应字数，点击可提前关闭

- **威震华夏章节异步预加载**：`weizhenhuaxia.gd` 入场动画与 `Main.tscn` 后台 `load_threaded_request` 并行；加载完毕进度条滑出 → "点击开始"呼吸动效 → 点击 `change_scene_to_packed`（直接用已加载 packed，秒切无延迟）

- **章节过渡面板 detail panel 默认左滑**：`changbanpo.gd` / `weizhenhuaxia.gd` / `jieting.gd` 安装 `DetailPanelController` 时不再调 `attach_to_rect(review_pnl)`，改用默认 `LEFT_WIDE` 锚 + 464px 宽，从场景左侧滑出（与游玩场景一致），不再覆盖检阅区

- **main.gd `_input` null 守卫**：`_ready` 内 `await _apply_editor_window_scale()` 期间 `_input` 已激活，`side_panels` / `enemy_side_panels` / 三个 pile button / `detail_panel` 还未建好；press 与 release 分支均加 nil 早退，避免 jieting → main 切场景的窗口期撞 `Nil.has_open_panel()` 报错

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

2. `_wire_pvp_deck_reshuffle_sync()` — 连 `Game.deck.reshuffled` → `_on_local_deck_reshuffled` 广播 `action/deck_reshuffle`；让远端代理 deck 同步重洗，避免代理 graveyard 永不清空

3. `BoardOrchestrator.boot()` — 装配两块棋盘

4. `_setup_pvp_slots()` — 按 session_id 为 player_main / enemy_main 注入 `owner_player_id`

5. `Net.message_received.connect(_on_pvp_message)` — 接入战斗消息

6. `_update_pvp_turn_ui()` — 按 `Game.pvp_is_my_turn()` 设置按钮初始状态

**PVP 消息处理（串行队列）**：

- `_pvp_msg_queue + _pvp_processing` 保证顺序

- `_handle_pvp_message` 分发：

| type | 动作 |

|---|---|

| `action/play_card` | `play_controller.handle_remote_play_card(payload, from)` —— 法术分支末尾按 `from` 路由到 `Game.decks[caster_pid].send_to_graveyard / banish` 同步代理 deck（`Effects.resolve_destination` 与本端一致） |

| `action/play_equip` | 追加 `EquipmentInstance` 到 `_remote_equip_insts[from]` |

| `action/activate_equip` | `play_controller.handle_remote_activate_equip` + 扣对手装备耐久 |

| `action/equip_broken` | `Game.decks[from].send_to_graveyard(card)` 同步入墓 + 从 `_remote_equip_insts[from]` 移除破损 inst |

| `action/cross_board` | 1v3 守方 / 3v3 owner 跨盘选择 → `Game.turn.enqueue_cross_choice(payload)` 入队；end_turn 触发回放阶段消费 |

| `action/end_turn` | `_on_remote_end_turn` → `run_pvp_phase`（1v1）或 `run_pvp_phase_for_slot`（多队伍）+ `pvp_advance_turn(_skip_dead)` |

| `action/deck_reshuffle` | `Game.decks[player_id].reshuffle(false)` 同步代理 graveyard 清空（双端 `_reshuffle_count` 确定性递增） |

| `action/activate_hero` | `_handle_remote_activate_hero(payload, from)`：`restart` / `test_discard` 把弃牌路由到 `Game.decks[from].send_to_graveyard`（与法术/单位入墓走同一 proxy deck，重洗时一并清空） |

| `disconnect/notify` | 对掉线玩家 `damage_hero(100,"triggered")` → 标准阵亡流程 |

| `game/end` | 未显示胜负时按 `winning_team`（多队伍）/ `winner_id`（1v1 旧字段）显示胜利或退出 |

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

| `action/play_card` | 任一 → all/对手 | 出牌，含 card_name / slot_id / cell；法术含 `result_atk` / `result_health` / `result_cleared`（ming_jin 等放回手牌型） |

| `action/play_equip` | 任一 → 对手 | 出装备，含 card_name |

| `action/activate_equip` | 任一 → 对手 | 激活装备（仅白名单 effect，如 `destroy_unit`），含 equip_name + 效果参数 |

| `action/equip_broken` | 任一 → all | 装备耐久归零广播；远端 `Game.decks[from].send_to_graveyard` + 移除 `_remote_equip_insts` 中破损 inst（与 caster 本端 `_on_inst_changed` 入墓配对） |

| `action/activate_hero` | 任一 → 对手 | 激活英雄技能，含 ability_id + 相关参数（`restart` / `test_discard` 含 `discarded` 列表，远端按 `from` 路由到 caster 的 proxy `Game.decks[from].graveyard`） |

| `action/end_turn` | 任一 → 对手（非 all） | 结束回合，含 player_id / turn_number |

| `action/cross_board` | 任一 → all | 多队伍 PVP 跨盘选择广播；其余端入 `_pending_cross_choices` 队列，`run_pvp_phase_for_slot` 期间 FIFO consume |

| `action/deck_reshuffle` | 任一 → all | 本地 `Game.deck.reshuffle(false)` 后由 `signal reshuffled` 触发广播；远端 `Game.decks[player_id].reshuffle(false)` 同步代理 graveyard 清空（`_reshuffle_count` 双端确定性递增） |

| `game/end` | 任一 → all | 战斗结束，含 `winning_team`（多队伍 PVP）/ `winner_id`（1v1 旧字段兼容） |

- **Game.decks / manas 字典化**：PVE 旧代码通过 `Game.deck` / `Game.mana` 别名无感使用；PVP 模式新增 `Game.decks[player_id]` / `Game.manas[player_id]`，`deck_of_slot / mana_of_slot` 按 slot.owner_player_id 路由，避免多玩家费用串联

- **bootstrap_pvp 与 bootstrap 分支**：`bootstrap_pvp` 不走章节/关卡路径，不初始化 ScriptedEvents/SpawnerSystem，为每位玩家独立建 DeckManager + ManaSystem + HeroSpec（全为英雄A），PVP 战斗场景通过 `Game.is_pvp` 分支走 `_inject_pvp_level_data → _setup_pvp_slots` 专属路径

- **PVP 消息队列串行**：`test_main._pvp_msg_queue` + `_pvp_processing` 保证 await 消息依序处理，避免并发导致格子状态错乱

- **对手装备镜像**：本端 `Equipments` 单例只含本地玩家装备；对手装备单独维护 `_remote_equip_insts: Array`，收到 `action/play_equip` 时追加 `EquipmentInstance`，激活后按耐久扣减，归零移除；长按对手英雄面板由 `_collect_remote_equip_descs()` 生成描述

- **PVP 回合控制**：`Game.pvp_is_my_turn()` 判断行动归属；本端结束回合调 `TurnSystem.run_pvp_phase(PLAYER)` 只跑己方单位，发 `action/end_turn` 只发给对手（避免 echo）；收到 `action/end_turn` 调 `play_controller.handle_remote_end_turn()` + `Game.pvp_advance_turn()`

- **SnapshotIO 序列化基础设施**：`DeckManager.to_dict/from_dict`、`ManaSystem.to_dict/from_dict`、`BoardSlot.to_dict/from_dict`、`Equipments.to_dict/from_dict` 等；版本号字段兼容；`SnapshotIO.serialize_battle / restore_battle` 顶层封装；F5/F9 开发键本地存读档

- **SparringPanel 大厅 UI**：继承 SecondaryPanel，完全代码布局（绕开 anchor 系统，在 NOTIFICATION_RESIZED 手动设 position/size）；Mode0「我的房间」展示 2×3 槽位格 + 准备/开始按钮；Mode1「加入房间」展示房间列表 + 数字键盘直接输房号；刷新按钮 3 秒冷却倒计时；Node 销毁前自动 `_unbind_net_signals`

- **session_id 同机双开隔离**：NetworkManager._session_id = uuid + 随机4位后缀，同一台机跑两个实例时两端 session_id 不同，服务器/路由正确区分两个玩家

## 14. 多队伍 PVP 系统（1v3 / 3v3）

> 详细规格见 `multiplay_chess_skills.md`（1v3 规格）与 `dev3v3.md`（3v3 开发清单）。

### 14.1 核心数据扩展

| 类 / 文件 | 新增字段 / 方法 |
|---|---|
| `BoardSlot` | `team_id: String`（1v3: "defender"/"attacker"；3v3: "team_a"/"team_b"）；`slot_index: int`；`_on_hero_died` 按 `pvp_teams.keys()` 动态计算 winner |
| `Cell` | `team_id: String`；`is_hostile_to(viewer_team_id)`；`is_friendly_to(viewer_team_id)` |
| `BoardRegistry` | `by_team(team_id)`；`by_owner(player_id)`；`adjacent_enemy_slots(viewer_pid, col)` |
| `GameContext` | `pvp_match_type`；`pvp_teams`；`pvp_dead_players`；`is_multi_team_pvp()`；`pvp_advance_turn_skip_dead`；`is_round_complete`；队伍工具方法；`pvp_end_game` |
| `BoardModel` | `front_row_of_slot / back_row_of_slot / step_of_slot`：`team_id != ""` 统一处理，不再硬编码 defender/attacker |
| `server/room.go` | `MaxPlayersForType("3v3")` → 6；`MaxPlayersForType("1v3")` → 4 |

### 14.2 布局路由（BoardLayoutResolver）

`scripts/core/board_layout_resolver.gd`：输入 viewer_pid + slot_layout，输出：
- `local_slot_id`：本端盘 → 屏幕下方中央（BottomGrid）
- `top_slot_id`：主对手盘 → 屏幕上方中央（TopGrid）
- `extra_top_ids`：1v3 守方另外 2 个攻方盘 / 3v3 另外 2 个对手盘 → 上方左/右附盘
- `side_slot_ids`：1v3 攻方队友盘 / 3v3 己方 2 队友 → 下方两侧附盘

### 14.3 跨盘逻辑（TurnSystem 分支）

`_process_cell` 按 `slot.team_id` 分路：

| 分支 | 条件 | 行为 |
|---|---|---|
| 1v3 守方拥有者 | `"defender"` + PLAYER faction | UI 选目标盘 → `_broadcast_cross_board` |
| 1v3 守方远端 | `"defender"` + ENEMY faction | `consume_cross_choice` 取队列 |
| 1v3 攻方 | `"attacker"` | `_enemy_auto_cross`（确定性，单一目标=守方盘） |
| 3v3 所有玩家 | `"team_a"` / `"team_b"` | UI 选盘（owner）→ 广播；远端消费队列 |
| PVE/1v1 PLAYER | `team_id == ""` + PLAYER | UI 选盘 |
| PVE/1v1 ENEMY | `team_id == ""` + ENEMY | `_enemy_auto_cross`（修正：用 `_can_cross_board` 替代 `cell.row == front_row`，与 attacker 分支一致，让 charge 单位在路径全空时也能跨盘，修复"对手视角下冲锋单位只移到自家前排"的锁步 desync） |

**镜像列**：`dst_col = COLS - 1 - src_col`（`cell.team_id != ""` 时启用）

**`_iter_phase_cells_of_slot`**：`slot.team_id != ""` 时统一 row 0→ROWS-1（前排先走）。**主盘分支已加 `owner_slot_id` 过滤**（`cell.owner_slot_id != "" and != slot.id` 时跳过），避免对方"跨入到本盘"的单位被误归入本端 phase；与 cross-board 分支的 `owner_slot_id == slot.id` 共同保证迭代器输出严格属于 phase slot。

**`_process_cell` 多队伍跨盘分支**（`team_id != ""` 路径）：跨盘单位 `is_my_unit` 直接置 `true`（信任迭代器过滤），不再依赖 `cell.is_enemy == for_enemy`——后者在不同 viewer 视角下是 viewer-relative，会导致同队队友视角误判 `is_enemy=false / for_enemy=true` 不匹配，单位拒绝行动。

### 14.4 跨盘选择同步（action/cross_board）

- 1v3 守方 owner / 3v3 所有 owner：UI 选盘 → 广播 `action/cross_board`
- 其余端入 `_pending_cross_choices` 队列；`run_pvp_phase_for_slot` 期间 FIFO consume
- `_broadcast_cross_board` 守卫：`is_multi_team_pvp()`

### 14.5 回合推进

| 模式 | 行动顺序 | 推进函数 |
|---|---|---|
| 1v1 | A ↔ B | `pvp_advance_turn()` |
| 1v3 | 守方 → 攻方1 → 攻方2 → 攻方3 | `pvp_advance_turn_skip_dead()` |
| 3v3 | A1→B1→A2→B2→A3→B3 | `pvp_advance_turn_skip_dead()` |

- 每位玩家独立 `run_pvp_phase_for_slot(my_slot_id)` 跑本盘单位
- `is_round_complete()` → pvp_active_idx == 0 → turn_number +1

### 14.6 胜负判定

- `BoardSlot._on_hero_died`：`pvp_teams.keys()` 动态取 winner（兼容 defender/attacker 及 team_a/team_b）
- 测试期：死一人即该队败；`pvp_end_game` 广播 `game/end` 含 `winning_team` + `loser_pid`
- 断线：`disconnect/notify` → `by_owner(disc_uuid).damage_hero(100, "triggered")`

### 14.7 SparringPanel 大厅

| 模式 | 最小人数 | 槽位格 | slot_layout 生成规则 |
|---|---|---|---|
| 1v1 | 2 | 2 格 | 随机 action_order |
| 1v3 | 4 | 4 格（守/攻标注） | 房主=defender，其余随机 attacker |
| 3v3 | 6 | 6 格（A/B 队标注） | 随机分两队；A1→B1→A2→B2→A3→B3 |

### 14.8 跨端墓地与卡牌数据同步

PVP 锁步下每端各跑一套 `Game.decks[pid]` / 各盘 `slot.graveyard`，必须保证多端最终一致。当前同步路径：

| 入墓来源 | caster 本端 | 远端镜像路径 |
|---|---|---|
| 单位（origin="hand"）死亡 | `Game.decks[owner_pid].graveyard`（`PlayController.handle_unit_death`） | 锁步同步：每端 `handle_unit_death` 都按 `cell.owner_slot_id → owner_player_id` 路由到对应 proxy `Game.decks[pid]` |
| 单位（spawner / initial / ability）死亡 | `slot.graveyard`（按 `_resolve_owner_slot`） | 同左，`slot.id` 跨端一致 |
| 法术（spell）打出 | `Game.deck.send_to_graveyard(spell)`（`_play_spell` 末尾） | `handle_remote_play_card` 法术分支末尾追加 `Game.get_deck(caster_pid).send_to_graveyard(card)`，destination 走 `Effects.resolve_destination` 与本端一致 |
| 装备耐久归零 | `Game.deck.send_to_graveyard(card_data)`（`equipment_manager._on_inst_changed`） | caster 广播 `action/equip_broken { equip_name }` → 远端 `Game.decks[from].send_to_graveyard` + 从 `_remote_equip_insts[from]` 移除破损 inst |
| 再起 / test_discard 弃牌 | `hand_view.discard_*` 调 `Game.deck.send_to_graveyard` | `_handle_remote_activate_hero` restart/test_discard 分支按 `from`（caster pid）路由 `Game.decks[from].send_to_graveyard(c)`，与法术/单位入墓走同一 proxy deck，重洗时一并清空 |
| Deck 重洗（draw_pile 空时触发） | `Game.deck.reshuffle(false)` 内部清空 graveyard | 新增 `signal reshuffled` 由本地 deck 发射 → `_on_local_deck_reshuffled` 广播 `action/deck_reshuffle { player_id }` → 远端 `Game.decks[player_id].reshuffle(false)`，proxy graveyard 同步清空 |
| terrify on_kill 除外受害者 | 按 `v_owner_id → owner_player_id` 取受害者 deck | 锁步：每端取自家对应 proxy deck `erase` + `banish`，保证除外结果一致（修复前 caster 错改本地 deck） |
| ming_jin 单位回牌库顶 | 按 `cell.owner_slot_id` 取目标单位 owner deck `add_to_draw_pile` | 锁步：每端各取对应 proxy deck（修复前 3v3 队友单位会被错放回 caster 本地 deck） |
| autophagy 自噬伤害己方英雄 | `damage_player_hero(amount)` → 解析 `target_cell.owner_slot_id` 对应盘的 hero | 锁步：每端用同一 slot id 解析 hero，保证伤害落点一致（修复前用 `Game.main_player_slot()` 是 viewer-relative） |

**展示层**：`EnemySidePanelManager` / `AllySidePanelManager` 在 `set_slot` 同时订阅 `slot.pile_changed` 和 `Game.get_deck(slot.owner_player_id).pile_changed`，`_refresh_content` 取 `slot.graveyard ∪ owner_deck.graveyard` 并集，避免 spawner-origin 与 hand-origin 单位分别落在两处导致单端只见其一。`PILE_TO_PANEL` 同时认 BoardSlot 的 `"banished"` 与 DeckManager 的 `"banish"` 两种 pile 名拼写。

**附盘墓地/除外面板归属**（之前的 viewer-relative bug）：`_create_slot` 选择 `EnemySidePanelManager`(顶部下拉) 或 `AllySidePanelManager`(底部上拉) 不再按 `slot.faction`，改为与 `side_top` 同语义（多队伍 PVP 用 `team_id == local_team` 判定，PVE/1v1 回退 `slot.faction`）。修复前 3v3 队友盘 `faction=ENEMY` 但视觉位于底部，会错配到顶部下拉面板。

### 14.9 UI 简化（已完成）

- 移除主敌方"墓地 / 除外"按钮（`main.gd` / `test_main.gd`）；`EnemyHpPnl` 横向拉伸至整盘宽度（`BOARD_HALF_W * 2`）。
- 移除全部附盘"墓地 / 除外"按钮（`board_orchestrator._create_slot` 把 `show_pile = false` 传给 `SideBoardUi.build`）；附盘 hp 面板同样横向拉伸至整盘宽度。
- `_setup_side_enemy_panel` / `_setup_side_ally_panel` 入口条件改为 `side_ui_dict.get("grave_btn") != null`（按钮 null → 跳过 panel mgr 创建，避免无入口的孤儿 UI）。
- `EnemySidePanelManager` / `AllySidePanelManager` 类与 `set_slot` 数据订阅逻辑保留，未来如恢复 UI 入口可直接复用；当前数据同步链不依赖这些面板存在。

### 14.10 待完成（P1）

- [ ] `TeammateSidePanel`：队友公开信息面板（1v3 / 3v3 均未建）
- [ ] 含 await 效果加 result 字段广播（`destroy_unit` / `weaken` / `flood_strategy_hero`）
- [ ] `assault_charge` 迁移 `is_hostile_to`（当前仍用 `is_enemy`，3v3 同队相邻可能误判）
- [ ] 法术 payload 增补 `effects` 数组（当前 PVP 法术不修改 effects，将来防御）
- [ ] 装备非白名单激活也广播 `action/activate_equip`（让远端 `_remote_equip_insts` 耐久也能逐次同步，目前仅 broken 时点同步）
- [ ] 主动英雄技能（`yi_yong_jun` / 等）远端 mirror 协议设计

## 15. 帝国模式（Empire Mode）

帝国模式是独立于战役/多人对战的**大战略层**原型。入口场景 `scenes/EmpireTest.tscn`，脚本 `scripts/ui/empire_test.gd`（`extends Control`）。当前版本已完成可交互大地图骨架与**出征战斗系统**（将领拖入敌方/中立相邻地点 → 回合结算 → 进入多棋盘 PVE 战斗 → 胜负占领/撤退）。

---

### 15.1 地图系统

**数据格式**（`data/empire_maps/test_map.json`）：

| 键 | 类型 | 说明 |
|---|---|---|
| `factions[]` | 数组 | `{id, name, color(#rrggbb)}`；id=0 固定为"中立"（灰色，不可删） |
| `shapes[]` | 数组 | 地点节点，每项含 `id, kind, x, y, name, gold, food, faction, category?` |
| `connections[]` | 数组 | `{from, to}`（地点 id），决定相邻关系；同时用于行棋合法性校验 |

加载时在 `empire_test.gd` 内建立两张索引：`_connections_data: Array`（原始数组）、`_id_to_node: Dictionary`（`node_id → _MapShapeNode`），供相邻判断与命中测试使用。

**地点类型**（`kind`）：`triangle`（关隘）/ `circle`（村镇）/ `square`（城市，`category` 子类型：1=大都市、2=商业、3=农业、4=军事）。

**地图渲染**（`_MapShapeNode extends Control` 内嵌类）：
- 三种形状各自用 `_draw()` 绘制；选中时描边变为金黄 `#ffe066`
- `pivot_offset = size * 0.5`，缩放以节点中心为枢轴
- `_LineLayer extends Node2D`：按 `connections[]` 绘制连接线（蓝色 `#7ec8e3`，2px）
- 支持鼠标/触屏平移、滚轮/双指捏合缩放；`_clamp_pan` 防止地图出界
- **行棋期间平移禁用**：`_drag_active=true` 时 `_input` 优先处理拖拽，跳过平移逻辑

**玩家势力**：`PLAYER_FACTION_ID = 1`（Ap）；`_faction_color / _faction_name` 按 `factions[]` 查表。

---

### 15.2 资源与回合系统

InfoPanel 实时展示资金（每回合 += 己方地点 `gold` 之和）与粮草（己方地点 `food` 快照合计）。

"**结束回合**"按钮执行：
1. `_commit_pending_moves()` — 提交当回合所有待生效移动（虚影变实，英雄新位置写入 `_deployed_heroes`）
2. 资源结算（`_calc_player_gold_income_runtime()` / `_calc_total_food_runtime()`，按运行时 `_shape_nodes._faction_id` 计算，支持战斗后占领动态更新）
3. 若 `_pending_campaigns` 非空 → `_enter_battle_select_mode()`（见 §15.13）
4. 全量回合结束后（所有出征结算完毕）按钮恢复可点

---

### 15.3 将领系统（EmpireCarousel + EmpireTalentPanel）

将领数据（`data/empire_hero.json`）：`display_name / skill_text / command / force / intelligence / charisma / level / current_exp / next_level_exp / background`。目前三个占位将领（A/B/C）。

**`EmpireCarousel`**（`scripts/ui/empire_carousel.gd`）：竖向无限滑动轮播，读独立的 `empire_hero.json`，使用 `EmpireDeckStorage`，发信号 `current_hero_changed(hero_key)`。
- **动态过滤**：持有 `_hero_names: Array`（默认 `["A","B","C"]`），`set_alive_pool(arr)` 注入后只轮播未流放将领；`goto_hero(hero_key)` 直接定位
- **统帅显示**：卡页英雄名右侧（左 62% / 右 38% 分割）展示"统帅 N"标签（棕橙色）
- `set_alive_pool` / `goto_hero` 均支持在 `_apply_styles` 延迟前被调用（节点直访兜底）

**`EmpireTalentPanel`**（`scripts/ui/empire_talent_panel.gd`）：左侧轮播 + 中间 `_DiamondChart`（菱形四维雷达图）+ 属性列表 + 等级/经验 + 背景文案；右侧"**部署**"/"**流放**"按钮（文案按部署状态切换）。发信号 `deploy_requested(hero_key)` / `recall_requested(hero_key)`；`set_deployed_state(dict)` / `set_alive_pool(arr)` / `goto_hero(hero_key)` 由 EmpireTest attach 后注入。

**训练/升级/招募按钮**：`_apply_styles` 末尾一律 `disabled=true`（功能待实现）；部署/流放按钮不受影响。

**面板初始位置**：`_talent_last_hero` 存最后查看的 hero_key（运行时内存）。首次打开 → 定位第一个未流放将领；再次打开 → 恢复上次位置（若上次对象已流放则退化到第一个未流放者）。关闭时由 `_trigger_reverse` 开头记录当前 hero_key。

---

### 15.4 军队面板（EmpireArmyPanel）

继承 `SecondaryPanel`；卡池 `data/empire_cards.json`；`_calc_global_taken()` 全局共享牌池；持久化 `EmpireDeckStorage`（`user://empire_decks.json`）。

**empire_cards.json 格式**：每个条目除基础字段外可含 `"quantity": N`，`_init_card_pool()` 优先读此字段（原始 JSON 单独解析为 qty_map），缺省退回 `TOTAL_PER_CARD=10`。当前牌池：填线宝宝（×20）+ 放箭（×10）。

**统帅上限**：`_current_command()` 读 `_hero_db[hero_key]["command"]`；`_add_to_muster()` 在总张数 ≥ 统帅值时拒绝点兵；`_refresh_muster_list()` 将点兵标题更新为"**点兵 N/M**"（当前/上限）。

---

### 15.5 卡组持久化（EmpireDeckStorage）

`scripts/core/empire_deck_storage.gd`，路径 `user://empire_decks.json`，与主菜单 `DeckStorage` 完全独立。接口：`load_all / save_all / load_deck / save_deck / get_selected_hero / save_selected_hero`。

---

### 15.6 部署系统

点"**部署**"→ 反向转场 → 己方地点呼吸缩放（scale 1.0↔1.18，SINE 循环 0.9s）→ 点己方地点部署（人才唯一）/ 点空白轻点取消。

**`_HeroIconBtn extends Control`**（内嵌类，定义于 `empire_test.gd` 末尾）：
- 36×36px；颜色：normal 白 / hover 蓝白 / selected `#ffe066` / pressed 橙
- 点击沿父链查找 `EmpireTest._on_hero_icon_clicked(hero_key)`
- press+release 均 `set_input_as_handled()`，防止事件冒泡到 `_MapShapeNode`
- **拖拽支持**：`_gui_input` 记录按下坐标；`_input`（全局）检测移动距离超 `DRAG_START_THRESHOLD=8px` 后沿父链调 `EmpireTest._on_hero_drag_start`
- **虚影态**（`_is_ghost=true`）：半透明（`modulate.a=0.45`），`_is_ghost` 为 true 时禁止拖拽；拖拽发起后清除 pressing 状态，release 时不 fire click

**`_MapShapeNode.set_deployed_icons(hero_keys, textures, ghost_flags=[])`**：重建头像横排；`ghost_flags[i]=true` 时对应图标调 `set_ghost(true)`（半透明，不可拖）。

**`_MapShapeNode.set_hero_icon_ghost(hero_key, bool)`**：临时虚化/实化某将领头像（拖拽过程中使用）。

**`_MapShapeNode.set_hero_icon_selected(hero_key, bool)`**：duck-typing 遍历 `_deploy_icon_row` 子节点，调 `set_selected_state`。

**`_refresh_deploy_icons_for(node)`**：
- 实体图标：`_deployed_heroes[k] == node` 且 `k` 不在 `_pending_moves` 中，且不在任何 `_pending_campaigns` 列表中
- 虚影图标：`_pending_moves[k] == node`，或 `_pending_campaigns[node._id]` 列表包含 k（多个出征 hero 全部显示为虚影）
- 两组合并排序后调用 `set_deployed_icons(keys, textures, ghost_flags)`

**选中互斥**：点地点/点头像/进二级面板，均先清除对方选中态再建立新选中，保证地图上同时只有一个选中框。

---

### 15.7 流放系统

点"**流放**"（`EmpireTalentPanel`）→ 触发 `recall_requested(hero_key)`：

1. **守门**：当前 alive 池 ≤1 时拒绝（不可流放最后一人；按钮在 `_refresh_deploy_btn` 中相应 `disabled=true`）
2. 从地图抹去该将领（`_deployed_heroes.erase`，图标重绘）
3. 加入 `_exiled_heroes` 运行时流放名单（重启后复现）
4. 清空 `EmpireDeckStorage` 中该将领卡组（`save_deck(key, {})` = 下属单位放回公共牌池）
5. 若被流放者是当前 `selected_hero`，切到首个未流放将领
6. 触发 `_trigger_reverse()` 关闭二级人才面板，退回大地图

**轮播过滤时序**（`_apply_styles` 由 `call_deferred` 延迟一帧问题）：
- `EmpireTest.set_alive_pool` 使用节点直访 (`get_node_or_null`) 兜底，同步注入 carousel
- `_apply_styles` 中 carousel setup 末尾再次调用 `set_alive_pool(_alive_pool)` 补传
- `EmpireArmyPanel` 另设 `_alive_pool_pending`，`_install_deck_persistence` 赋值 carousel 后立即补传

---

### 15.8 行棋（将领移动）系统

每回合，已部署将领可被拖拽至相邻（1跳）地点：

**拖拽流程**：
1. 鼠标按下图标，移动 > 8px → `_on_hero_drag_start(hero_key, source_node, pos)`
2. 起点图标变虚（`set_hero_icon_ghost`）；相邻地点呼吸高亮；创建跟随鼠标的虚影图标（`_drag_ghost`，`top_level=true`，`z_index=1000`，`modulate.a=0.7`）
3. 鼠标释放 → `_on_hero_drag_end(global_pos)`：
   - 命中测试（`get_global_transform().affine_inverse() * pos`，兼容地图缩放）
   - **同势力相邻节点**：写入 `_pending_moves[hero_key] = target_node`；起点图标消失，目标显示虚影；该将领本回合不可再拖
   - **异势力/中立相邻节点（出征）**：容量校验（`CAMPAIGN_CAPACITY_BY_KIND`：square=3 / circle=2 / triangle=1）→ 未超容 → 写入 `_pending_campaigns[target_id]`（按追加顺序，第一项为主控将领）；记录 `_pending_campaign_sources[hero_key] = source_id`；起点显示虚影，目标显示攻方虚影（可多个）
   - 否则：取消，起点图标恢复
4. `_remove_hero_from_all_pending(hero_key)` 在重新拖拽前自动清除旧约定（`_pending_moves` + 所有 `_pending_campaigns` 列表 + `_pending_campaign_sources`）

**提交**：`_on_end_turn` 开头调 `_commit_pending_moves()`（仅提交普通行棋，不提交出征）；出征结果由战斗胜负决定落点。

**全局输入拦截**（`_input` 内）：`_drag_active` 期间 LMB press/release/motion 均优先处理并 `return`，防止同时触发地图平移；`_on_hero_drag_start` 开头重置 `_pan_active = false` 消除过渡帧微跳。

**驻军计算**（用于地点详情面板）：`_compute_garrison_for(node)` 返回在该节点且不在 `_pending_moves` 中的将领列表（虚影中的将领，无论起点终点，均不计入驻军）。

---

### 15.9 地点详情面板（EmpireLocationPanel）

`scripts/ui/empire_location_panel.gd`，左侧滑入（360px），与人才面板互斥：顶栏地点名+势力、Badge 类型、资源面板、**驻军面板**。**特化按钮**：己方地点（`faction_id==1`）可用，否则隐藏。`_add_res_row` 为 `static` 工具方法，供 EmpireHeroDetailPanel 复用。

**`show_for(node, heroes: Array=[])`**：`heroes` 由 EmpireTest 通过 `_compute_garrison_for` 计算传入，每项 `{name: String, level: int}`。

**驻军列表**（ScrollContainer + VBox）：每行 = display_name（左，展开填充）+ `Lv.N` 紫色圆角 Badge（右，12pt 白字）；无驻军时显示"（无）"。仅显示实体将领（已剔除所有虚影）。

---

### 15.10 人才详情面板（EmpireHeroDetailPanel）

`scripts/ui/empire_hero_detail_panel.gd`，左侧滑入：顶栏人才名+所在地点势力、`Lv.X` Badge（紫 `#7b68ee`）、四维属性面板（统帅橙/武力红/智力蓝/魅力紫）、**配属部队面板**、**训练按钮**（置灰）。接口同 `EmpireLocationPanel`：`show_for / refresh_for / hide_panel`。

**配属部队列表**（ScrollContainer + VBox）：`_refresh_troops(hero_key)` 读 `EmpireDeckStorage.load_deck(hero_key)` 按 `order` 渲染"卡名 x 数量"行（16pt，灰色）；空卡组显示"（无）"。每次 `_refresh_content` 末尾刷新（面板开着切换将领时也同步更新）。

---

### 15.11 地图编辑器工具

`tools/empire_map_tool/empire_map_editor.py`，独立 Python/Tkinter 工具，可视化编辑地点节点与连接线并导出 JSON。详见 `tools/empire_map_tool/README.md`。

---

### 15.12 剧本选择流程（YanyiPanel → EmpireScenarioView → EmpireTest）

#### 入口

`MainMenu` → 右下 `JourneyBtn`（"演义"）→ 面板展开 → `YanyiPanel`（二级面板）：

- 右侧 `RightActionPnl`：帝国 / 游历两个模式按钮（`ModeBtn0 / ModeBtn1`）
- 左侧 `LeftContentPnl`：主内容区，当前选中模式的内容
- 帝国模式下：左上标题 + 右侧「载入 / 开始 / 继续」操作按钮列

#### 进入剧本选择（点击「开始」）

`YanyiPanel._on_empire_start_pressed()`：

1. 淡出 `right_action_pnl` + `left_content_pnl`（0.3s），完成后 `hide()` 防止透明节点拦截鼠标
2. 实例化 `EmpireScenarioView.tscn`，填满 YanyiPanel（PRESET_FULL_RECT），`move_child(view, 0)` 置底层
3. 淡入剧本视图；`_in_scenario_view = true`

**递层返回**：`back_btn.pressed` 接管为 `_on_back_btn_pressed`：
- `_in_scenario_view == true` → `_exit_scenario_view()`（淡出剧本视图 → 重建帝国内容 → 淡入旧面板）
- `false` → `back_pressed.emit()`（返回主菜单）

#### EmpireScenarioView（`scripts/ui/empire_scenario_view.gd`，`scenes/EmpireScenarioView.tscn`）

填满 YanyiPanel 全区域（无额外底板）；内含：

| 子面板 | 位置 | 内容 |
|---|---|---|
| `MapThumbPnl` | 右半顶区，顶部避让 BackBtn（BACKBTN_H + GAP） | `_MapThumbnail` 内嵌类，从地图 JSON 绘制缩略图 |
| `DescPnl` | 全宽，顶区下方 | 剧本描述文字（左上对齐） |
| `CarouselPnl` | 全宽，描述下方 | `_ElasticHScroll` 水平弹性轮播（rubber band + 0.28s 回弹） |

**剧本加载**：扫描 `res://data/empire_maps/`，读取含 `scenario` 键的 JSON，按 `scenario.id` 升序排列，生成对应数量的轮播按钮（文字 = 剧本名）。

**选择交互**：
- 首次点击 → 选中（蓝色高亮），更新 DescPnl 文字 + MapThumbPnl 缩略图
- 再次点击已选中 → `_enter_map(idx)`：写 `EmpireTest.pending_map_path`，`change_scene_to_file(EmpireTest.tscn)`

#### EmpireTest 接入

`class_name EmpireTest`，新增：

| 静态变量 | 说明 |
|---|---|
| `static var pending_map_path: String` | 进入前写入目标地图路径；`_load_map()` 读取后立即清空；空串则回退默认 `test_map.json` |

玩家默认 Ap 势力（`PLAYER_FACTION_ID = 1`，已硬编码）。

#### 地图 JSON 格式（含剧本字段）

```json
{
  "scenario": {
    "id": 1,
    "name": "囊关之战",
    "description": "剧本描述文字..."
  },
  "factions": [...],
  "shapes": [...],
  "connections": [...]
}
```

---

#### 15.12.1 出征意向（`_pending_campaigns`）

| 数据结构 | 说明 |
|---|---|
| `_pending_campaigns: Dictionary` | `target_node_id(int) → Array[hero_key]`；按拖入顺序，第一项为本场主控将领 |
| `_pending_campaign_sources: Dictionary` | `hero_key → source_node_id`；记录出征前的驻扎位置，失败时将领保留在此 |
| `CAMPAIGN_CAPACITY_BY_KIND` | `{triangle:1, circle:2, square:3}`；仅对敌方/中立目标生效，决定最多几名将领可同时出征该地点 |

**容量校验**（`_on_hero_drag_end`）：`_pending_campaigns[target_id].size() < cap` 才允许追加；同一 hero 重拖视为幂等（容量=已占时允许）。

**多线出征**：一回合内玩家可对任意数量的不同异势力地点分别设置出征意向（各自遵循容量上限）。

#### 15.12.2 战斗选择模式（`_battle_select_mode`）

结束回合按钮按下后：
1. `_commit_pending_moves()` — 提交当回合所有普通行棋
2. 资源结算
3. 若 `_pending_campaigns` 非空 → `_enter_battle_select_mode()`：按钮置灰，所有出征目标节点显示**红色外框方块 + 呼吸缩放**（`_CampaignFrame`，±14px margin，`#ff5555`，1.12 缩放，1s 周期）

`_on_shape_clicked` 在 `_battle_select_mode` 期间：仅点击 `_pending_campaigns.has(node_id)` 的节点触发 `_launch_empire_battle(target_id)`。

`_exit_battle_select_mode()`：所有出征结算完毕后调用，关闭所有方框，恢复按钮可点。

#### 15.12.3 战斗启动（`_launch_empire_battle(target_id)`）

1. 从 `_pending_campaigns[target_id]` + `_empire_hero_db` 组装 `attacker_payload`
2. 调 `_save_empire_state(target_id)` → 序列化全图状态写入 `Game.empire_state`
3. 写 `Game.pending_empire_battle = {target_id, attackers}`
4. `get_tree().call_deferred("change_scene_to_file", "res://scenes/Main.tscn")`（延迟切场景，避免 `_gui_input` 链路 viewport 提前销毁崩溃）

#### 15.12.4 战斗内部结构（`_bootstrap_empire`）

| N（出征人数） | 启用棋盘 |
|---|---|
| 1 | player_main(slot=4) + enemy_main(slot=1) |
| 2 | + ally_left(slot=3) + enemy_left(slot=0) |
| 3 | + ally_right(slot=5) + enemy_right(slot=2) |

- **主将**（attackers[0]）：player_main，hp=force，卡组=EmpireDeckStorage，可出牌
- **辅助将**（attackers[1..]）：对应 ally 盘，hp=各自 force，不参与出牌，仅 spawner 出单位
- **敌方所有 hero**：hp=10 占位，无技能
- **Spawner**：全部启用棋盘各自底线每回合 1 张填线宝宝（玩家盘 row=2/col=1；敌方盘 row=0/col=1，interval=1）
- **胜负**：仅 player_main hero 死 = 失败；enemy_main hero 死 = 胜利

#### 15.12.5 战斗结果回流

战斗结束 → `_on_exit_to_menu`：检测 `not Game.empire_state.is_empty()` → 跳转 EmpireTest.tscn（代替 MainMenu）。

**`_restore_empire_state_if_any()`**（`_build_map` 末尾）：
1. 按 `faction_overrides` 恢复节点势力
2. 恢复 `_deployed_heroes / _pending_campaigns / _pending_campaign_sources / exiled / gold / food`
3. `_apply_battle_result(current_battle_target_id)`：**胜** → target 势力变玩家 + 列表内所有 hero 进驻；**败** → 所有 hero 留原位；双向均移除该 target 出 `_pending_campaigns`
4. 若 `_pending_campaigns` 仍非空 → `_enter_battle_select_mode()`（续灯剩余目标）；否则 `_exit_battle_select_mode()`（自动进入下回合）
5. 清空 `Game.empire_state / empire_battle_result`

#### 15.12.6 选项面板适配

帝国战斗期间 `Game.empire_state.is_empty() == false`；`main.gd` setup SettingsPanelController 传 `"hide_exit": true`，不渲染"返回菜单"按钮；胜负叠层点击为唯一退出路径。

---

### 15.13 地图编辑器工具

`tools/empire_map_tool/empire_map_editor.py`，独立 Python/Tkinter 工具，可视化编辑地点节点与连接线并导出 JSON。详见 `tools/empire_map_tool/README.md`。

### 15.15 当前完成度

| 模块 | 状态 |
|---|---|
| 地图渲染、平移、缩放 | ✅ |
| 势力 / 资源 / 回合结算 | ✅（运行时 faction 计算，含占领影响） |
| 将领轮播 / 属性 / 统帅显示 | ✅ |
| 卡组配置（军队面板）/ 统帅上限 | ✅ |
| 部署 / 流放 / 图标交互 | ✅ |
| 将领行棋（普通移动 + 回合提交） | ✅ |
| 出征意向（多线 / 容量限制） | ✅ |
| 战斗选择模式（外框呼吸方块） | ✅ |
| 出征战斗（Main.tscn 多棋盘 PVE） | ✅（测试占位逻辑） |
| 战斗状态快照 / 场景切换回流 | ✅ |
| 战斗结果占领 / 将领失败回原位 | ✅ |
| 多场出征逐场独立结算 | ✅ |
| 地点详情面板 / 驻军列表 | ✅ |
| 人才详情面板 / 配属部队列表 | ✅ |
| 剧本选择界面（YanyiPanel 二级） | ✅（扫描 empire_maps/ 自动读取剧本） |
| 地图缩略图（从 JSON 运行时绘制） | ✅ |
| 剧本轮播（水平弹性滚动） | ✅ |
| 剧本进入战斗（EmpireTest.pending_map_path） | ✅ |
| 方略面板 | ❌ 占位 |
| AI / 敌方回合 | ✅ 战斗场景已接入（见 §16）|
| 升级 / 训练 / 招募 | ❌ 占位按钮置灰 |

---

## 16. AI 对战系统

### 16.1 架构总览

```text
scripts/ai/
├── ai_action.gd          # AiAction：行动数据载体（PLAY_UNIT / PLAY_SPELL / CROSS_BOARD / END_TURN + 工厂方法）
├── game_view.gd          # AiGameView：只读棋局快照（手牌 / 费用 / 己方盘 / 对手盘 / 威胁值 / is_own_unit / is_target_unit）
├── ai_strategy.gd        # AiStrategy：决策抽象接口（decide / choose_cross_target）
├── heuristic_strategy.gd # HeuristicStrategy：默认规则启发式（见 §16.4）
├── ai_action_sink.gd     # AiActionSink：落地抽象接口（apply / submit_cross_choice）
├── local_action_sink.gd  # LocalActionSink：PVE 落地（含飞牌动画）
├── net_action_sink.gd    # NetActionSink：PVP 骨架（P5 待实现）
├── ai_agent.gd           # AiAgent：单盘回合驱动（摸牌 → decide → apply → STEP_DELAY）
└── ai_manager.gd         # AiManager（autoload）：注册中心 {slot_id → AiAgent}
```

**AiManager autoload** — 全局持有所有 Agent，`_exit_tree` 后由各场景调 `clear()` 清理。

### 16.2 接入场景

| 场景 | 文件 | AI 初始化时机 | 覆盖棋盘 |
|---|---|---|---|
| 标准测试战斗 | `main.gd` | `board_orchestrator.boot()` 后 `_setup_ai_agents()` | 全部 FACTION_ENEMY + ROLE_ALLY 盘 |
| TestMain 多棋盘测试 | `test_main.gd` | 同上（`is_pvp == false` 分支） | 同上（enemy_left / enemy_main / enemy_right / ally_left / ally_right）|
| 帝国出征战斗 | `main.gd` (同) | 同上（`_bootstrap_empire` 装配的盘 N=1/2/3） | 按启用盘数量 |

**英雄面板（飞牌源节点）查找优先级**：
1. `board_orchestrator._main_ui[slot_id].get("hero_panel")`
2. `board_orchestrator._side_ui[slot_id].get("hp_panel")`
3. fallback `$EnemyHpPnl`

### 16.3 回合驱动（TurnSystem.run 新流程）

```
_run_ai_phase_for_faction(FACTION_PLAYER)   ← 友军 AI 出牌（出牌后立即参与本回合 PLAYER 阶段）
_run_phase(PLAYER)
_run_spawn_phase()
_run_ai_phase_for_faction(FACTION_ENEMY)    ← 敌方 AI 出牌（出牌后立即参与本回合 ENEMY 阶段）
_run_phase(ENEMY)
```

每个 Agent 执行流：`mana.start_new_turn()` → `agent.take_turn()`。

`take_turn()`：摸 1 张牌（上限 `MAX_HAND_SIZE=5`）→ `strategy.decide(view)` → 顺序 `await sink.apply(action)` + `STEP_DELAY=0.3s` 间隔。

### 16.4 HeuristicStrategy 决策逻辑

**decide() 流程**：
1. `mana >= 2`：先施法（高费优先，不重复选同格目标）
2. 出单位：高费优先，每次选最优空格
3. 剩余 1 费再补 1 张法术

**`_best_deploy_cell` 评分**（阵营感知，ENEMY/ALLY 均正确）：

| 评分项 | 权重 |
|---|---|
| 行流水线：该行越空越优先（分散到各行，持续输出）| ×3 |
| 前排加成：`dist_to_front_row` 越小越好（ENEMY front=row2，PLAYER/ALLY front=row0）| ×1 |
| 净空列：对手该列无单位 → 直通英雄 | +6 |
| 列分散：该列己方单位越少越好 | ×1.5 |
| 本回合同列已落子 | -3 |

**法术目标**：`_most_advanced_target(excluded)` — 对手盘中推进最深（`dist_to_opp_front` 最小）且 `excluded` 中未锁定的单位；友军 AI 用 `is_target_unit(cell)` 正确识别敌方单位（`cell.is_enemy == true`）。

**阵营感知** — `AiGameView.is_own_unit(cell)` / `is_target_unit(cell)` 按 `own_slot.faction` 判断，敌方 AI 与友军 AI 均正确：

| 阵营 | own unit | target unit |
|---|---|---|
| 敌方 AI（FACTION_ENEMY） | `cell.is_enemy == true` | `cell.is_enemy == false`（玩家单位）|
| 友军 AI（FACTION_PLAYER）| `cell.is_enemy == false` | `cell.is_enemy == true`（敌方单位）|

### 16.5 LocalActionSink

**`_place_unit`**：取 slot.faction 决定 `place_as_enemy`（敌方=true，友军=false）→ `cell.set_card(...)` → `cell.owner_slot_id = slot.id` → `await Effects.trigger_play` 逐 eff 异步链。

**`_cast_spell`**：`await _animate_card_to_cell` → **动画后重验证目标**（`has_card == false` 且 `target != ""` → 放弃施法入墓）→ `await Effects.trigger_play` → `ai_deck.send_to_graveyard / banish`。

**飞牌动画（`_animate_card_to_cell`）**：从 `_source_node`（AI 英雄面板）中心飞 `Panel(80×56)` + `Label(card_name)` 到目标格中心，`FLY_DURATION=1.2s` Quad 缓动，落地前 30% 时间淡出；`_source_node == null` 时跳过动画但仍正常落子。

### 16.6 AI 资源装配（_setup_ai_agents）

所有场景均从 `Game.card_db` 直接拼 AI 牌库（无单独 JSON），当前默认：

```
5× 填线宝宝 + 5× 放箭
```

每个 AI slot 独立 `DeckManager` + `ManaSystem`（`setup(1, 5)` — 起始费 1，上限 5），`owner_player_id = "ai_" + slot_id`，单位死亡通过 `handle_unit_death` → `owner_slot.owner_player_id` → `Game.decks["ai_xxx"].graveyard` 入对应 AI 墓地。

### 16.7 跨盘处理

- **敌方 AI 盘**：FACTION_ENEMY + team_id="" 时走旧"自动跨盘"路径（`_enemy_auto_cross`），无需额外介入
- **友军 AI 盘**：到达 front_row 时检查 `AiManager.is_ai_slot(slot.id)` → 随机选一个 `enemy_slots` 作为目标，不弹玩家 UI

### 16.8 已实现 / 待实现

| 阶段 | 内容 | 状态 |
|---|---|---|
| P0 | 骨架（9个文件）| ✅ |
| P1 | PVE Deck+Mana 装配 + AiManager | ✅ |
| P2 | TurnSystem 双阶段接入 + LocalActionSink 单位部署 + 飞牌动画 | ✅ |
| P3 | HeuristicStrategy 单位评分 + 法术施放 + 目标去重 | ✅ |
| P4 | 友军 AI 跨盘随机选目标 | ✅ |
| P5 | NetActionSink + PVP 人机托管 | ❌ 骨架存在，逻辑未实现 |
| P6 | 难度参数化（spell_value_threshold / 故意失误率 / 策略工厂）| ❌ 接口预留，未配置 |
| — | 帝国专属牌库（按守军节点区分 AI 牌组）| ❌ 未实现 |
| — | 多盘 ENEMY 跨盘 `on_cross_requested` 智能择盘 | ❌ 未实现 |

