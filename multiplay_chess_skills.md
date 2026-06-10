# NSOC 多人多棋盘开发规划（1v3 / 3v3）

> 本文记录 PVP 1v3（守方 1 vs 攻方 3）与 3v3 多棋盘模式的全部开发决策与任务清单。
> 1v3 为优先实现目标，3v3 在末尾作为后续拓展章节预设。
> 当前 1v1 PVP 已完成，本文以 `dev_gd/nsoc/` 为基线扩展。
> 最后更新：2026-06。

---

## 1. 决策锁定（1v3）

### 1.1 总体规则

| 维度 | 决策 |
|---|---|
| 优先级 | **仅 1v3**（先做最简形态），3v3 后续扩展 |
| 网络架构 | **纯中继**（沿用现 1v1 架构），客户端权威，发送方锁步 |
| 服务器改造 | `room/create` 加 `match_type` 字段；`game/start` 按 match_type 生成 action_order + slot_layout |
| 房间人数 | 4 人（1 守 + 3 攻） |
| 战前准备 | 沿用 SparringPanel 槽位 + 准备系统；房主点开始即进战斗 |

### 1.2 棋盘布局

| 维度 | 决策 |
|---|---|
| 棋盘数量 | **守方 1 盘 / 攻方 3 盘**（各人独立 6×3 棋盘） |
| 物理拓扑 | 守方盘 1 个、攻方 3 盘横排相邻；4 盘共构成"1 vs 3 横排"对峙 |
| 守方视角 | 上方 3 盘（敌方左 / 中 / 右） + 下方 1 盘（己方）|
| 攻方视角 | 上方 1 盘（敌方守方盘） + 下方 1 盘（己方），左右两位队友盘**根据大厅位置**分配显示位置 |
| 跨盘攻击 | **镜像列跨盘**（2026-06 重构）：守方→攻方任一盘（UI 选盘）落于镜像列；攻方→守方落于镜像列。落点列规则 `target_col = COLS - 1 - source_col`，保证拥有者视觉同列直线落地 |
| 队友盘 | 攻方三人之间**不可跨盘攻击**、不可放置单位 |
| 棋盘尺寸 | 6 行 × 3 列（与 PVE / 1v1 一致，不加宽） |
| 大厅位置 | 4 槽位顺序固定为：1 号守方 + 2/3/4 号攻方左/中/右；4 玩家视角下的攻方布局据此映射 |

### 1.3 行动顺序

| 维度 | 决策 |
|---|---|
| 总顺序 | **1 方先走 → 3 方依次轮转** |
| 3 方内部顺序 | 房主开始时按大厅 2/3/4 号槽位次序固定（攻方左 → 中 → 右） |
| 一轮回合 | 守方 1 次 + 攻方 3 次 = 完成一轮 |
| `turn_number` | 每完成一轮（守 + 攻 3 人）+1，所有玩家费用上限同步 +1 |
| 阵亡跳过 | 任一玩家阵亡即结束本局，无需跳过逻辑（见 §1.5） |

### 1.4 玩家资源

| 维度 | 决策 |
|---|---|
| 卡组 | **独立**，每人自带备战界面卡组（沿用 1v1 协议） |
| 费用 | **独立**，每人独立 ManaSystem 实例 |
| 手牌 | **独立**，每人独立 5 张手牌上限 |
| 英雄 | **独立**，4 人各自携带选定英雄；测试期不为守方加血 |
| 装备 | **独立**，每人独立 Equipments，本端 + 远端 dict 镜像 |
| 起手抽牌 | 同 1v1，开局抽 5 张 |

### 1.5 胜负判定

| 维度 | 决策 |
|---|---|
| 守方失败 | **守方英雄死亡 → 立即结算守方败** |
| 攻方失败 | **攻方任一玩家英雄死亡 → 立即结算攻方败**（测试期简化规则） |
| 中途退出 | 走投降流程（damage_hero(100)），按上述规则结算 |
| 断线 | 同 1v1，掉线方自残 100，按上述规则结算 |

### 1.6 效果与目标判定

| 维度 | 决策 |
|---|---|
| 友 / 敌判定 | **按队伍**：守方与攻方互为敌；攻方三人互为友 |
| empower / inspire | 友方单位可加 buff，跨队友盘合法（攻方三人互加） |
| destroy_unit / weaken | 全场任意敌方单位均可选 |
| 跨盘冲锋 | 仅同列跨敌盘，符合 §1.2 |
| 法术目标过滤 | `target_selector` 按 `cell.team_id != viewer.team_id` 判定敌方 |

---

## 2. 当前 1v1 实现的耦合假设（需打破）

下列假设已深度嵌入代码，必须在 1v3 改造中显式解除：

| 假设 | 主要位置 | 改造方向 |
|---|---|---|
| 全局二分 `cell.is_enemy: bool` | `cell.gd:156`、`play_controller.gd:112,114`、`effect_context.gd:81,93,99`、`turn_system.gd:267,646`、`effects/inspire.gd`、`empower.gd`、`ming_jin.gd`、`target_selector_controller.gd:65,66`、`apply_soaked_to_all.gd:30` | 保留兼容，加 `cell.team_id` + `Cell.is_hostile_to(viewer_pid)` |
| 硬编码 `player_main / enemy_main` 两 slot | `test_main.gd:_inject_pvp_level_data`、`_setup_pvp_slots`、`play_controller.gd:handle_remote_play_card` 翻转表 | 改为 `slot_<player_id>`，按 `slot_layout` 路由 |
| 坐标镜像 `(ROWS-1-row, COLS-1-col)` | `play_controller.gd:340-342` | 改为绝对坐标 + `viewer_orientation` 渲染翻转 |
| `_pvp_opponent_id()` 假设单一对手 | `play_controller.gd:314`、`test_main.gd:888`、`hero_action_bar.gd:191` | 按 sender / target_pid 路由，不再返回单值 |
| `TurnSystem.run_pvp_phase(faction)` 跑全场 | `turn_system.gd:133` | 改为 `run_pvp_phase_for_slot(slot_id)` |
| `EffectContext.send_to_graveyard` 按 is_enemy 路由 enemy_main slot | `effect_context.gd:122,141` | 按 `cell.owner_slot_id` 路由 |
| `handle_unit_death` 一律入 ROLE_MAIN_ENEMY slot | `play_controller.gd:447` | 按 `cell.owner_slot_id` 入对应 slot |
| `_remote_equip_insts: Array` 仅一个对手 | `test_main.gd:40` | 改为 `Dictionary[player_id → Array]` |
| 跨盘逻辑遍历 PLAYER 阵营盘 | `turn_system.gd:_check_cross_to_enemy_*`、`_run_front_row_selection` | 按 `team_id` + `slot_index` 决定相邻敌盘 |
| `BoardModel.front_row_of(faction)` 二分阵营 | `board_model.gd` | 增加 `front_row_of_slot(slot)` 按 team 取值 |
| `disconnect/notify` 找 ROLE_MAIN_ENEMY 自残 | `test_main.gd` | 按 payload uuid → slot_<uuid> 路由 |

---

## 3. 数据模型扩展

### 3.1 BoardSlot 扩展字段

```gdscript
# board_slot.gd 新增字段
var team_id: String = ""        # "defender" / "attacker"
var slot_index: int = 0          # 全局序号，决定行动顺序与跨盘相邻
# owner_player_id 已存在，保留
# faction 字段（FACTION_PLAYER/ENEMY）保留作为本端视角的"自/他"语义
```

`to_dict / from_dict` 同步序列化 `team_id / slot_index`。

### 3.2 Cell 扩展字段

```gdscript
# cell.gd 新增字段
var team_id: String = ""         # 继承自所在 slot.team_id
# is_enemy 字段保留（PVE 兼容），PVP 模式下新逻辑走 team_id

# 新增工具方法
func is_hostile_to(viewer_team_id: String) -> bool:
    return team_id != "" and team_id != viewer_team_id

func is_friendly_to(viewer_team_id: String) -> bool:
    return team_id != "" and team_id == viewer_team_id
```

`set_card / load_dict` 写入 team_id（从 owner_slot 反查）。

### 3.3 Game 字段扩展

```gdscript
# game_context.gd 新增字段
var pvp_match_type: String = ""    # "1v1" / "1v3"
var pvp_teams: Dictionary = {}     # { team_id: [player_id, ...] }
var pvp_dead_players: Array = []   # 阵亡玩家 uuid 列表

# 新增工具方法
func team_of_player(pid: String) -> String
func players_of_team(team_id: String) -> Array
func is_player_alive(pid: String) -> bool
func mark_player_dead(pid: String) -> void
```

### 3.4 BoardRegistry 扩展

```gdscript
# board_registry.gd 新增方法
func by_team(team_id: String) -> Array          # 取该队所有 slot
func by_owner(player_id: String) -> BoardSlot   # 按玩家取盘（1v3 一人一盘）
func adjacent_enemy_slots(viewer_pid: String, col: int) -> Array
    # 返回该列上 viewer 视角下所有敌队盘（用于跨盘攻击候选）
```

---

## 4. 网络协议扩展

### 4.1 game/start payload

```json
{
  "type": "game/start",
  "payload": {
    "match_type": "1v3",
    "rng_seed": 12345,
    "action_order": [pid_def, pid_atk_l, pid_atk_m, pid_atk_r],
    "teams": {
      "defender": [pid_def],
      "attacker": [pid_atk_l, pid_atk_m, pid_atk_r]
    },
    "per_player_heroes": { pid: hero_key, ... },
    "per_player_decks":  { pid: [card_name, ...], ... },
    "slot_layout": [
      {"slot_id": "slot_<pid_def>",   "owner_pid": pid_def,   "team_id": "defender", "slot_index": 0},
      {"slot_id": "slot_<pid_atk_l>", "owner_pid": pid_atk_l, "team_id": "attacker", "slot_index": 1},
      {"slot_id": "slot_<pid_atk_m>", "owner_pid": pid_atk_m, "team_id": "attacker", "slot_index": 2},
      {"slot_id": "slot_<pid_atk_r>", "owner_pid": pid_atk_r, "team_id": "attacker", "slot_index": 3}
    ]
  }
}
```

### 4.2 action/play_card payload 扩展

- 现有 `sender_slot_id` 字段保留
- 接收端不再用硬编码翻转表，改查 `slot_layout`：发送方 slot_id → 接收方根据本端视角同名渲染（坐标改用绝对坐标 + 视角翻转）

### 4.3 action/end_turn

- 改为广播 `to: "all"`，所有客户端按 `pvp_action_order` 推进
- 取消 1v1 时点对点路由

### 4.4 disconnect/notify payload

```json
{ "type": "disconnect/notify", "payload": { "dead_player_id": "uuid" } }
```

接收端按 dead_player_id → `slot_<uuid>` → damage_hero(100)。

### 4.5 game/end payload 扩展

```json
{
  "type": "game/end",
  "payload": {
    "winning_team": "defender",   // "defender" / "attacker"
    "loser_pid": "uuid"           // 触发结算的死亡玩家
  }
}
```

### 4.6 SparringPanel 大厅协议

- 4 人房支持：现槽位 UI 已为 2×3，仅启用前 4 槽
- `room/create` payload 加 `match_type: "1v3"`
- 服务器约束加入人数 ≤ 4
- 槽位与队伍绑定：1 号 = defender，2/3/4 号 = attacker（左 / 中 / 右）

---

## 5. 回合控制流改造

### 5.1 TurnSystem 新增按 slot 推进的 API

```gdscript
# turn_system.gd 新增
func run_pvp_phase_for_slot(slot_id: String) -> void:
    is_running = true
    var slot: BoardSlot = _registry().get_by_id(slot_id)
    if slot != null:
        await _run_phase_for_slot(slot)
    if _registry() != null and is_instance_valid(slot.board):
        slot.board.reset_attack_flags()
    is_running = false

func _iter_phase_cells_of_slot(slot: BoardSlot) -> Array
```

旧 `run_pvp_phase(faction)` 在 1v3 路径下不再调用，但保留兼容 1v1。

### 5.2 行动玩家推进

```gdscript
# game_context.gd
func pvp_advance_turn() -> void:
    if pvp_action_order.is_empty():
        return
    var n: int = pvp_action_order.size()
    for i in range(n):
        pvp_active_idx = (pvp_active_idx + 1) % n
        if not pvp_dead_players.has(pvp_action_order[pvp_active_idx]):
            return  # 找到下一个存活玩家
    # 全部阵亡，理论上 game/end 已先发，不应到此

# 仅守方完成一轮（守 + 3 攻）后递增 turn_number
func is_round_complete() -> bool:
    return pvp_active_idx == 0  # 回到守方位
```

### 5.3 PlayController 出牌权限

```gdscript
# play_controller.gd
func can_play(...) -> bool:
    if Game.is_pvp and not Game.pvp_is_my_turn():
        return false
    # ...

func can_play_at(cell, ...) -> bool:
    # 旧：cell.is_enemy 二分；新：必须放在自己 slot
    if Game.is_pvp:
        var my_slot: BoardSlot = Game.registry.by_owner(Game.local_player_id)
        if cell.slot_id != my_slot.id:
            return false
    # ...
```

### 5.4 EndTurn 流程

```gdscript
# test_main.gd _on_end_turn_pressed
func _on_end_turn_pressed() -> void:
    if not Game.pvp_is_my_turn():
        return
    # 跑本端自己 slot 的 phase
    await Game.turn.run_pvp_phase_for_slot(_my_slot_id())
    # 广播给所有人
    Net.send_to_room("action/end_turn", Net.get_current_room_id(),
                     {"sender_pid": Game.local_player_id}, "all")
    Game.pvp_advance_turn()
    # 若回到第一位（守方）则 turn_number +1，所有玩家 mana +1
    if Game.is_round_complete():
        Game.turn.turn_number += 1
        for m in Game.manas.values():
            m.start_turn()
```

---

## 6. UI 装配与布局

### 6.1 _inject_pvp_level_data 重构

```gdscript
# test_main.gd
func _inject_pvp_level_data() -> void:
    var match_type: String = Game.pvp_match_type
    if match_type == "1v3":
        _inject_1v3_level_data()
    else:
        _inject_1v1_level_data()  # 旧逻辑保留

func _inject_1v3_level_data() -> void:
    # 按 slot_layout 生成 4 盘 boards 字典
    # 每盘 hero / faction / team_id / slot_index 按 layout 填充
    # initial_units / spawners / spell_casters 全部空（PVP 无 NPC）
```

### 6.2 视角与盘位映射

引入 viewer-relative 渲染：

| 本端身份 | 屏幕上方 | 屏幕下方 |
|---|---|---|
| 守方 | 攻方 3 盘横排（按大厅 2/3/4 号 → 左/中/右） | 自己盘 |
| 攻方左 | 守方盘（居中） | 自己盘 + 队友中/右盘（左右位） |
| 攻方中 | 守方盘（居中） | 自己盘居中 + 左/右队友盘 |
| 攻方右 | 守方盘（居中） | 自己盘 + 左/中队友盘 |

实现要点：
- 新增 `BoardLayoutResolver`：输入 viewer_pid + slot_layout，输出每盘的屏幕位置（top/bottom，left/center/right）
- `BoardOrchestrator.boot()` 调用 resolver 决定盘的 anchor

### 6.3 SidePanel 多盘装配

- `EnemySidePanelManager`：现支持 set_slot 切数据源；1v3 中守方有 3 个敌盘，需要 3 个独立 panel 实例（左中右各一）
- `AllySidePanelManager`：攻方需要为 2 个队友盘各起 panel（仅显示对方手牌数 / 牌堆 / 墓地等公开信息）
- 新增组件 `TeammateSidePanel`：仅显示队友公开信息，不显示具体手牌

### 6.4 行动顺序指示器

新建 `scripts/ui/action_order_bar.gd`：
- 顶部状态条，按 `pvp_action_order` 显示 4 玩家昵称
- 高亮当前 `pvp_active_player_id()`
- 阵亡玩家划掉
- 提示当前应走玩家 slot 位置（"守方回合" / "攻方左回合" 等）

### 6.5 HeroActionBar 远端装备扩展

```gdscript
# test_main.gd
var _remote_equip_insts: Dictionary = {}  # { player_id: Array[EquipmentInstance] }

func _add_remote_equip(pid: String, inst): ...
func _remove_remote_equip(pid: String, inst): ...
func _get_remote_equips(pid: String) -> Array: ...

# detail_panel_controller 长按对方英雄面板时按 slot.owner_player_id 取
```

---

## 7. 跨盘逻辑改造

> 2026-06 更新：完成镜像列重构。源盘 col c → 目标盘 col (COLS-1-c)，配合 `board_orchestrator._reverse_grid_cells` 的视觉翻转，使单位"视觉同列"直线落地。
> 守方拥有者 UI 选目标盘，攻方自动跨守方盘（单一目标），均使用同一镜像列规则。

### 7.1 BoardModel.front_row_of_slot

```gdscript
# board_model.gd
static func front_row_of_slot(slot: BoardSlot) -> int:
    # 默认按 faction 取（PVE 兼容）
    if slot.team_id == "":
        return front_row_of(slot.faction)
    # 1v3：守方/攻方均向 row=0 推进（朝中线对面盘）
    return 0
```

`back_row_of_slot` 同理统一返回 `ROWS - 1`；`step_of_slot` 返回 `-1`。所有 1v3 单位都从自家 row=2（hero 侧）向 row=0（前排）推进，跨入对面盘后继续向该盘 row=2（对方 hero）推进，此时 `on_home_board=false`，step 由 `_process_cell` 推导为 `+1`。

### 7.2 跨盘候选筛选

```gdscript
# board_registry.gd
func adjacent_enemy_slots(viewer_pid: String, _col: int) -> Array:
    var viewer_team := Game.team_of_player(viewer_pid)
    var out := []
    for slot in slots:
        if slot.team_id != "" and slot.team_id != viewer_team:
            out.append(slot)
    return out
    # 守方→攻方：返回 3 盘；攻方→守方：返回 1 盘
```

参数 `_col` 当前未参与筛选（1v3 不限同列，全列均可跨）；保留参数签名以便后续 3v3 扩展。

### 7.3 落点列：镜像规则

源盘 col c 的单位跨入目标盘后落于 col `(COLS-1-c)`。
- 拥有者视觉上对面盘是翻转的（`_reverse_grid_cells` 同时反转行+列子节点），镜像 col 后单位"视觉位置不变"地从自家盘跨到对面盘。
- 三端独立按相同公式计算，无需广播列。

实现位置：
- `turn_system.gd:_enemy_auto_cross`：`dst_col = COLS - 1 - cell.col`（仅 cell.team_id 与目标盘 team_id 均非空时启用；PVE/1v1 保持同列）
- `front_row_selector.gd:_on_target_chosen`：同上规则

### 7.4 跨盘路径分发（_process_cell 三分支）

| 分支 | slot.team_id | faction | 行为 |
|---|---|---|---|
| 守方拥有者 | "defender" | PLAYER | `_run_front_row_selection` UI 弹 3 盘候选 → 选定后 `_broadcast_cross_board` |
| 守方远端镜像 | "defender" | ENEMY  | `consume_cross_choice(source_slot_id,row,col)` 取 target_slot_id |
| 攻方（双向） | "attacker" | 任意 | `_enemy_auto_cross` 自动跨（单一目标=守方盘，镜像列） |
| PVE/1v1 | "" | — | 旧 UI / 旧 auto-cross 路径，同列规则 |

守方 UI 三盘候选：`_run_front_row_selection` 弹出选择器（蓝色脉冲高亮 3 个攻方盘），玩家点击选定 target_slot_id；攻方完全跳过 UI，逻辑确定性。

### 7.5 跨盘选择广播（action/cross_board）

守方拥有者完成 UI 选择后立即广播，远端镜像消费：

```gdscript
# turn_system.gd
func _broadcast_cross_board(source_slot_id, row, col, target_slot_id):
    if Game.pvp_match_type != "1v3": return
    Net.send_to_room("action/cross_board", Game.pvp_room_id, {
        "source_slot_id": source_slot_id,
        "row": row, "col": col,
        "target_slot_id": target_slot_id,
    }, "all")

# test_main.gd _handle_pvp_message
"action/cross_board":
    Game.turn.enqueue_cross_choice(payload)
```

`TurnSystem._pending_cross_choices: Array` 队列。`enqueue_cross_choice` 入队；`consume_cross_choice(source_slot_id,row,col)` 按键值匹配取出并 remove。

**同步保证**：WS FIFO + 服务器纯中继 → 守方依次广播 cross_board#1..N → end_turn；远端在 end_turn 触发 `run_pvp_phase_for_slot` 前队列已就绪，consume 时无需 await。`_iter_phase_cells_of_slot` 顺序确定，三端键值匹配一致。

**兜底**：远端 consume 返回 "" 时，取 `enemy_slots[0]` 并 `push_warning`，避免卡死。生产中此分支不应触发。

---

## 8. 效果系统改造

### 8.1 含 await 选目标效果

涉及效果（搜索 `_target_selector` / `_hand_picker`）：
- `destroy_unit`、`empower`、`inspire`、`flood_strategy_hero`、`weaken`（敌方 SpellCaster 用）等

改造原则：
- **仅激活方客户端弹选择器 UI**，按 `cell.is_hostile_to(self_team)` 过滤候选
- 选择结果通过 `result_target_row / result_target_col / result_target_slot_id` 字段广播
- 远端镜像执行时跳过选择 UI，按 result 字段直接定位

现有 `play_card` payload 已有 `result_atk / result_health` 直写机制，扩展同思路。

### 8.2 友 / 敌动态判定

改写所有 `cell.is_enemy` 检查（见 §2 列表）：

```gdscript
# 旧
if cell.is_enemy != activator.is_enemy: ...

# 新
var activator_team: String = activator.team_id  # 或从 effect ctx 取
if cell.is_hostile_to(activator_team): ...
```

PVE 模式下 cell.team_id 为空，`is_hostile_to` 返回 false，需额外回退 `is_enemy` 判定（保留兼容路径）。

### 8.3 EffectContext 路由

```gdscript
# effect_context.gd send_to_graveyard
# 旧：is_pvp + cell.is_enemy → enemy_main slot
# 新：按 cell.owner_slot_id 路由
func send_to_graveyard(cell: Node) -> void:
    var slot_id: String = cell.owner_slot_id if cell.owner_slot_id != "" else cell.slot_id
    var slot: BoardSlot = game.registry.get_by_id(slot_id)
    if slot != null:
        slot.graveyard.append(...)
        slot.pile_changed.emit("graveyard")
```

### 8.4 单位死亡路由

```gdscript
# play_controller.gd handle_unit_death
# 旧：is_pvp + cell.is_enemy → enemy_main slot.graveyard
# 新：cell.owner_slot_id → 对应 slot.graveyard
```

---

## 9. 阵亡与胜负

### 9.1 BoardSlot 英雄死亡处理

```gdscript
# board_slot.gd _on_hero_died 信号已存在
# 新增：按 team_id 判定胜负
func _on_hero_died() -> void:
    if Game.is_pvp:
        Game.mark_player_dead(owner_player_id)
        var loser_team: String = team_id
        # 1v3 简化规则：任一方死即结束
        var winner_team: String = "attacker" if loser_team == "defender" else "defender"
        Game.pvp_end_game(winner_team, owner_player_id)
        return
    # PVE 旧逻辑保留
```

### 9.2 game/end 广播

```gdscript
# game_context.gd
func pvp_end_game(winning_team: String, loser_pid: String) -> void:
    Net.send_to_room("game/end", pvp_room_id, {
        "winning_team": winning_team,
        "loser_pid": loser_pid,
    }, "all")
    # 本端转结算 UI
```

所有客户端收到 `game/end` 后：
- 关闭战斗场景
- 显示"胜利 / 失败"提示（按本端 team_id == winning_team 判定）
- 返回 SparringPanel

### 9.3 投降 / 退出

- `_on_pvp_surrender`：damage_hero(100)，触发 §9.1 流程
- `_on_exit_to_menu`：先走投降流程，等 game/end 后再切场景

### 9.4 断线处理

```gdscript
# 收到 disconnect/notify
func _on_disconnect_notify(payload: Dictionary) -> void:
    var dead_pid: String = String(payload.get("dead_player_id", ""))
    if dead_pid == "":
        return
    var slot: BoardSlot = Game.registry.by_owner(dead_pid)
    if slot != null and slot.hero != null:
        slot.hero.damage(100, "disconnect")
    # damage 触发 _on_hero_died → §9.1
```

---

## 10. 工作量分解与推进路径

### 10.1 阶段 A：基础数据模型（1-2 天）

| 任务 | 文件 |
|---|---|
| BoardSlot 加 team_id / slot_index | `board_slot.gd` |
| Cell 加 team_id + is_hostile_to / is_friendly_to | `cell.gd` |
| Game 加 match_type / teams / dead_players + 工具方法 | `game_context.gd` |
| BoardRegistry 加 by_team / by_owner / adjacent_enemy_slots | `board_registry.gd` |
| BoardModel.front_row_of_slot | `board_model.gd` |

### 10.2 阶段 B：网络协议扩展（1 天）

| 任务 | 文件 |
|---|---|
| game/start payload 扩展（match_type / slot_layout / teams） | `bootstrap_pvp` 调用方 |
| action/play_card 改用绝对坐标 + slot_layout 路由 | `play_controller.gd` |
| action/end_turn 改广播 to=all | `play_controller.gd` / `test_main.gd` |
| disconnect/notify payload 加 dead_player_id | `network_manager.gd` 协议层 |
| game/end payload 加 winning_team / loser_pid | `game_context.gd` |
| Go 服务端：room/create 加 match_type 校验、game/start 生成 slot_layout | `server/` |

### 10.3 阶段 C：回合控制（1 天）

| 任务 | 文件 |
|---|---|
| TurnSystem.run_pvp_phase_for_slot | `turn_system.gd` |
| pvp_advance_turn 跳过阵亡 | `game_context.gd` |
| is_round_complete + turn_number 推进 | `game_context.gd` / `test_main.gd` |
| can_play / can_play_at 改 slot 归属判定 | `play_controller.gd` |

### 10.4 阶段 D：跨盘逻辑（1-2 天）

| 任务 | 文件 |
|---|---|
| 跨盘候选改 adjacent_enemy_slots | `turn_system.gd:_check_cross_*` |
| _run_front_row_selection 按候选数量决定 UI | `turn_system.gd` / `front_row_selector.gd` |
| 自动跨盘逻辑改 team 判定 | `turn_system.gd` |

### 10.5 阶段 E：UI 布局（2-3 天）

| 任务 | 文件 |
|---|---|
| _inject_1v3_level_data | `test_main.gd` |
| BoardLayoutResolver（viewer-relative 屏幕位置） | 新建 `scripts/core/board_layout_resolver.gd` |
| BoardOrchestrator 按 resolver 装配 | `board_orchestrator.gd` |
| TeammateSidePanel（队友公开信息面板） | 新建 `scripts/ui/teammate_side_panel.gd` |
| ActionOrderBar（行动顺序指示器） | 新建 `scripts/ui/action_order_bar.gd` |
| _remote_equip_insts 改 dict | `test_main.gd` |

### 10.6 阶段 F：效果路由（2-3 天）

| 任务 | 文件 |
|---|---|
| 所有 cell.is_enemy 检查改 is_hostile_to | 见 §2 列表 |
| EffectContext.send_to_graveyard 按 owner_slot_id 路由 | `effect_context.gd` |
| handle_unit_death 按 owner_slot_id 路由 | `play_controller.gd` |
| 含 await 效果加 result 字段广播（destroy_unit/empower/inspire/...） | `effects/*.gd` |

### 10.7 阶段 G：胜负与结算（1 天）

| 任务 | 文件 |
|---|---|
| _on_hero_died 按 team_id 判胜负 | `board_slot.gd` |
| pvp_end_game 广播 game/end | `game_context.gd` |
| game/end 接收：按本端 team 显示胜负 UI | `test_main.gd` |
| disconnect 处理改按 dead_player_id 路由 | `test_main.gd` |

### 10.8 阶段 H：大厅与匹配（1-2 天）

| 任务 | 文件 |
|---|---|
| SparringPanel 加 match_type 选择 UI | `sparring_panel.gd` |
| 4 人房槽位约束（启用 1+3 槽） | `sparring_panel.gd` |
| 服务器 room/create 加 match_type 校验 | `server/` |
| 服务器按 match_type 生成 slot_layout / action_order | `server/` |

### 10.9 阶段 I：回归与联调（1-2 天）

| 任务 |
|---|
| 1v1 路径回归（确保 match_type==1v1 走旧逻辑） |
| PVE 路径回归（确保 cell.team_id 空值不破坏 is_enemy 判定） |
| 4 端联机调试：守方 1 vs 攻方 3 完整对局 |
| 跨盘攻击 / 法术目标 / 装备激活全场景验证 |
| 阵亡结算 / 断线 / 投降三种结束路径验证 |

**总预估：10-15 个工作日**

---

## 11. 待办清单（优先级排序）

### P0（阻塞 1v3 跑通）—— 已完成 ✅

- [x] BoardSlot / Cell 加 team_id / slot_index
- [x] Game 加 match_type / teams / dead_players
- [x] BoardRegistry 加 by_team / by_owner / adjacent_enemy_slots
- [x] game/start payload 扩展 + bootstrap_pvp 解析 1v3 配置
- [x] _inject_1v3_level_data + slot_id 改 slot_<pid>
- [x] action/play_card 改绝对坐标 + slot_layout 路由
- [x] TurnSystem.run_pvp_phase_for_slot
- [x] pvp_advance_turn 跳过阵亡 + is_round_complete
- [x] EffectContext.send_to_graveyard / handle_unit_death 改 owner_slot_id 路由
- [x] _on_hero_died 按 team_id 判胜负 + pvp_end_game
- [x] BoardLayoutResolver + 4 盘屏幕布局
- [x] 跨盘候选 adjacent_enemy_slots
- [x] 服务器 match_type 校验 + slot_layout 生成
- [x] **跨盘逻辑镜像列重构 + action/cross_board 广播**（2026-06，见 §7.3 / §7.5）

### P1（体验完善）

- [x] ActionOrderBar 行动顺序指示器
- [ ] TeammateSidePanel 队友公开信息面板
- [x] _remote_equip_insts 改 dict（攻方 3 人各装备镜像）
- [ ] 含 await 效果加 result 字段广播（destroy_unit / weaken / flood_strategy_hero）
- [x] SparringPanel 加 match_type 选择 UI
- [部分] 所有 cell.is_enemy 检查迁移到 is_hostile_to（assault_charge 等遗留）

### P2（后续 / 可后置）

- [ ] 守方加血补偿（血量平衡）
- [ ] 阵亡玩家逐个退场（不立即结束局，攻方多人耐力）
- [ ] 队伍消除制（替代"死一人即败"）
- [ ] 攻方共享视野 / 部分手牌可见
- [ ] 守方"先攻"buff 平衡机制

---

## 12. 3v3 拓展（后续章节预设）

> 1v3 完成后，3v3 在其上做以下增量：

### 12.1 决策预设

| 维度 | 预设决策 |
|---|---|
| 棋盘数量 | 6 盘（队 A 3 盘 + 队 B 3 盘） |
| 物理拓扑 | 上下两队各 3 盘横排 |
| 行动顺序 | 队 A 1 → 队 B 1 → 队 A 2 → 队 B 2 → 队 A 3 → 队 B 3（严格队伍交替） |
| 跨盘攻击 | 仅同列跨敌队任一盘；同队互不可跨 |
| 胜负 | 任一队全员阵亡 → 该队败（或测试期沿用"死一人即败"） |
| 玩家资源 | 全独立（同 1v3） |

### 12.2 1v3 → 3v3 增量改造

| 任务 | 说明 |
|---|---|
| BoardLayoutResolver 加 3v3 布局 | 上下各 3 盘横排，viewer 自盘居中、队友左右 |
| pvp_advance_turn 改"队伍交替" | 当前简单环形 → 队 A / 队 B 交替取队内下一人 |
| 跨盘候选返回 3 盘（敌队） | adjacent_enemy_slots 已支持，仅返回数量变化 |
| ActionOrderBar 显示 6 玩家 + 队伍颜色 | 蓝队 / 红队分组高亮 |
| SparringPanel 加 3v3 槽位 | 启用全部 6 槽，分两队 |
| 队伍消除制（如启用） | _on_hero_died 改判该队是否全员阵亡 |

### 12.3 3v3 阶段新增风险点

- 同列跨盘 6 盘混排时的"撞色"判定（哪盘优先）
- 队友盘 buff 跨盘传递的视觉一致性（empower 加 buff 视觉同步）
- 大厅匹配等待 6 玩家齐人的体验问题
- 移动端屏幕装下 6 盘的可视性（cell 需缩放至更小）

3v3 详细设计延至 1v3 完成后再细化。

---

## 13. 文档维护

- 本文与 `multiplay_dev_list_skills.md`（1v1 历史）并列，1v1 决策不再覆盖
- 实施过程中如调整决策，回写本文 §1 锁定表
- 每完成一个阶段，§10 / §11 相应任务划掉
- 1v3 验收后开新分支补 3v3 详细设计章节
