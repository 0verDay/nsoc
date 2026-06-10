# NSOC 3v3 模式开发清单

> 基线：`dev_gd/nsoc/`（已完成 1v1 + 1v3）。本文记录 3v3 增量改动。
> 所有服务端文件位于 `server/`（与 dev_gd 共用）。
> 最后更新：2026-06

---

## 锁定决策

| 维度 | 决策 |
|---|---|
| 人数 | 6 人（team_a 3 人 vs team_b 3 人） |
| 行动顺序 | A1→B1→A2→B2→A3→B3（严格队伍交替，由房主客户端生成） |
| 跨盘选择 | **所有玩家 UI 选盘**（拥有者广播 `action/cross_board`，其余 5 端消费队列） |
| 胜负 | 死一人即该队败（测试期，同 1v3） |
| 布局 | viewer 自盘居中（BottomGrid）+ 2 队友作侧盘；上方敌队 3 盘横排 |
| 落点列 | 镜像列 `target_col = COLS - 1 - src_col`（沿用 1v3） |
| 队伍命名 | `team_a` / `team_b` |
| 1v3 攻方自动跨 | **保持不变**（1v3 attacker 仍自动，3v3 两队都走 UI） |
| TeammateSidePanel | **不实现**（本轮跳过） |
| slot_index | team_a: 0/1/2，team_b: 3/4/5（大厅槽位顺序） |

---

## 文件改动清单

### A. server/room.go（纯服务端）

| # | 任务 | 改动位置 |
|---|---|---|
| A1 | `MaxPlayersForType("3v3")` 返回 6 | `MaxPlayersForType` 函数 |
| A2 | 注释更新 MatchType 枚举值 | `Room.MatchType` 字段注释 |

```go
// Before
func MaxPlayersForType(matchType string) int {
    if matchType == "1v3" { return 4 }
    return 2
}

// After
func MaxPlayersForType(matchType string) int {
    switch matchType {
    case "1v3": return 4
    case "3v3": return 6
    }
    return 2
}
```

---

### B. dev_gd/nsoc/scripts/core/game_context.gd

| # | 任务 | 改动位置 |
|---|---|---|
| B1 | 新增 `is_multi_team_pvp() -> bool` 便捷方法 | `pvp_advance_turn_skip_dead` 附近 |
| B2 | `bootstrap_pvp` 自动推断 teams_map 加 3v3 分支 | `~line 502` teams_map 推断块 |
| B3 | `pvp_end_game` winning_team 逻辑兼容 team_a/team_b | `pvp_end_game` 函数 |

**B1 新增方法**：
```gdscript
# 是否为多队伍 PVP（1v3 或 3v3）
func is_multi_team_pvp() -> bool:
    return pvp_match_type == "1v3" or pvp_match_type == "3v3"
```

**B2 teams_map 3v3 推断**（`~line 505`）：
```gdscript
# 原有
elif match_type == "1v3" and all_player_ids.size() >= 4:
    pvp_teams = {
        "defender": [all_player_ids[0]],
        "attacker": [all_player_ids[1], all_player_ids[2], all_player_ids[3]],
    }
elif match_type == "1v1" and all_player_ids.size() == 2:
    ...

# 新增在 1v3 分支之后
elif match_type == "3v3" and all_player_ids.size() >= 6:
    pvp_teams = {
        "team_a": [all_player_ids[0], all_player_ids[1], all_player_ids[2]],
        "team_b": [all_player_ids[3], all_player_ids[4], all_player_ids[5]],
    }
```

**B3 pvp_end_game winning_team**（注释说明，代码无需改动）：
- 1v3 时传 "attacker"/"defender"；3v3 时传 "team_a"/"team_b"
- 两端收到 `game/end` 后按 `local team_id == winning_team` 判胜负 → 已通用

---

### C. dev_gd/nsoc/scripts/core/board_layout_resolver.gd

| # | 任务 | 改动位置 |
|---|---|---|
| C1 | 新增 3v3 分支：按 team_id 分组，取对手队中间盘为 top，其余 2 为 extra_top，己队 2 队友为 side_slots | `resolve()` 函数末尾 |

**C1 3v3 分支**（在现有 `elif opponent_entries.size() >= 1:` 之前加）：
```gdscript
# 3v3：双方各 3 盘
elif my_team in ["team_a", "team_b"] and opponent_entries.size() >= 3:
    # 对手 3 盘：按 slot_index 排序 → 左/中/右
    top_slot_id = String(opponent_entries[1].get("slot_id", ""))  # 中（index 居中）
    extra_top_ids = [
        String(opponent_entries[0].get("slot_id", "")),  # 左
        String(opponent_entries[2].get("slot_id", "")),  # 右
    ]
    # 队友 2 盘（same team，非自身）
    for entry in slot_layout:
        var pid: String = String(entry.get("owner_pid", ""))
        if pid == viewer_pid:
            continue
        if String(entry.get("team_id", "")) == my_team:
            side_slot_ids.append(String(entry.get("slot_id", "")))
```

---

### D. dev_gd/nsoc/scripts/core/board_slot.gd

| # | 任务 | 改动位置 |
|---|---|---|
| D1 | `_on_hero_died`：支持 3v3（winner 为 team_a/team_b 对立队） | `~line 100` |

**D1 改动**：
```gdscript
# Before
if g != null and g.is_pvp and g.pvp_match_type == "1v3" and team_id != "":
    var loser_team: String = team_id
    var winner_team: String = "attacker" if loser_team == "defender" else "defender"
    g.pvp_end_game(winner_team, owner_player_id)
    return

# After
if g != null and g.is_pvp and g.is_multi_team_pvp() and team_id != "":
    g.mark_player_dead(owner_player_id)
    var loser_team: String = team_id
    # 计算获胜队：取 pvp_teams 中不是 loser_team 的第一个
    var winner_team: String = ""
    for tid in g.pvp_teams.keys():
        if tid != loser_team:
            winner_team = tid
            break
    g.pvp_end_game(winner_team, owner_player_id)
    return
```

---

### E. dev_gd/nsoc/scripts/core/turn_system.gd

| # | 任务 | 改动位置 |
|---|---|---|
| E1 | 新增 3v3 UI 跨盘分支（两队均走 owner UI + 广播） | `_process_cell` 跨盘路径分发块 `~line 430` |
| E2 | 3v3 attacker 不走 auto-cross | `is_auto_cross_candidate` 块 `~line 570` |
| E3 | `_broadcast_cross_board` 开放给 3v3 | `~line 131` |

**E1 新增 3v3 分支**（在 defender 分支之后、PVE/1v1 分支之前加）：
```gdscript
elif slot.team_id in ["team_a", "team_b"] \
        and on_home_board \
        and not enemy_slots.is_empty() \
        and _can_cross_board(cell, slot):
    # 3v3：所有玩家均走 UI 选盘 + 广播（对称，无"自动跨"）
    if owner_pid == Game.local_player_id:
        # 拥有者：UI 选盘，选定后广播给全房
        front_row_target_id = await _run_front_row_selection(cell)
        if front_row_target_id != "":
            _broadcast_cross_board(slot.id, cell.row, cell.col, front_row_target_id)
    else:
        # 远端镜像：从队列消费
        front_row_target_id = consume_cross_choice(slot.id, cell.row, cell.col)
        if front_row_target_id == "" and enemy_slots.size() > 0:
            front_row_target_id = String(enemy_slots[0].id)
            push_warning("TurnSystem: 3v3 cross_choice queue miss for %s(%d,%d); fallback %s" \
                % [slot.id, cell.row, cell.col, front_row_target_id])
```

**E2 auto-cross 排除 3v3**：
```gdscript
# Before
elif on_home_board and slot.team_id == "attacker":
    # 1v3 攻方：自动跨守方盘
    ...

# After（新增 3v3 排除分支）
elif on_home_board and slot.team_id in ["team_a", "team_b"]:
    # 3v3：已在 UI 路径处理；不走 auto-cross
    is_auto_cross_candidate = false
    auto_cross_target_slots = []
elif on_home_board and slot.team_id == "attacker":
    # 1v3 攻方：保留自动跨
    ...
```

**E3 broadcast 开放 3v3**：
```gdscript
# Before
func _broadcast_cross_board(...) -> void:
    if Game.pvp_match_type != "1v3":
        return
    ...

# After
func _broadcast_cross_board(...) -> void:
    if not Game.is_multi_team_pvp():
        return
    ...
```

---

### F. dev_gd/nsoc/scripts/core/play_controller.gd

| # | 任务 | 改动位置 |
|---|---|---|
| F1 | 所有 `pvp_match_type == "1v3"` 改为 `is_multi_team_pvp()` | 全文 `replace_all`（约 10 处） |

> 这些检查均控制"绝对坐标 + 全房广播"两件事，3v3 行为完全相同。

---

### G. dev_gd/nsoc/scripts/core/board_orchestrator.gd

| # | 任务 | 改动位置 |
|---|---|---|
| G1 | 所有 `pvp_match_type == "1v3"` 改为 `is_multi_team_pvp()` | 全文（约 6 处） |

---

### H. dev_gd/nsoc/scripts/ui/action_order_bar.gd

| # | 任务 | 改动位置 |
|---|---|---|
| H1 | `pvp_match_type != "1v3"` 改为 `not Game.is_multi_team_pvp()` | `~line 27` |
| H2 | 3v3：6 个 label 加队伍颜色（team_a 蓝 / team_b 红） | `refresh()` 着色逻辑 |

**H2 队伍颜色**（在 `for i in range(order.size()):` 块内）：
```gdscript
# 新增：3v3 按队伍着色
var team_color: Color
if Game.pvp_match_type == "3v3" and not is_dead and not is_active:
    var pid_team: String = Game.team_of_player(pid)
    team_color = Color("#339af0") if pid_team == "team_a" else Color("#f03e3e")
    lbl.add_theme_color_override("font_color", team_color)
```

---

### I. dev_gd/nsoc/scripts/ui/sparring_panel.gd

| # | 任务 | 改动位置 |
|---|---|---|
| I1 | 模式按钮列表加 "3v3" | `_build_match_type_row` / `_build_room_list_mode_row` `~line 502 / 553` |
| I2 | `min_players` 3v3 = 6 | `~line 459` |
| I3 | `_on_start_game` 3v3 分支：action_order 交替 + slot_layout + teams_map | `~line 1273` |
| I4 | 槽位 UI：3v3 显示 6 格（房主 3 + 对方 3） | `_build_my_room` `~line 332` |

**I3 _on_start_game 3v3 分支**：
```gdscript
elif _match_type == "3v3":
    # 分两队：前 3 人 = team_a，后 3 人 = team_b（大厅加入顺序）
    var team_a_pids: Array = []
    var team_b_pids: Array = []
    for i in range(_players.size()):
        if i < 3:
            team_a_pids.append(_players[i].uuid)
        else:
            team_b_pids.append(_players[i].uuid)
    # 行动顺序：A1→B1→A2→B2→A3→B3
    for i in range(3):
        if i < team_a_pids.size():
            order.append(team_a_pids[i])
        if i < team_b_pids.size():
            order.append(team_b_pids[i])
    # slot_layout
    for i in range(team_a_pids.size()):
        slot_layout.append({
            "slot_id":    "slot_" + team_a_pids[i],
            "owner_pid":  team_a_pids[i],
            "team_id":    "team_a",
            "slot_index": i,
        })
    for i in range(team_b_pids.size()):
        slot_layout.append({
            "slot_id":    "slot_" + team_b_pids[i],
            "owner_pid":  team_b_pids[i],
            "team_id":    "team_b",
            "slot_index": 3 + i,
        })
```

**I4 6 格槽位 UI**：
```gdscript
# min_players
var min_players: int
if _match_type == "1v3": min_players = 4
elif _match_type == "3v3": min_players = 6
else: min_players = 2
```

---

### J. dev_gd/nsoc/scripts/test_main.gd

| # | 任务 | 改动位置 |
|---|---|---|
| J1 | 入口分支加 3v3 路径（布局 resolver + main_ui 字典构建） | `~line 121` |
| J2 | 新增 `_inject_3v3_level_data()` | `_inject_1v3_level_data` 之后 |
| J3 | 新增 `_build_default_3v3_layout()` | `_build_default_1v3_layout` 之后 |
| J4 | 新增 `_setup_pvp_slots_3v3()` | `_setup_pvp_slots_1v3` 之后 |
| J5 | `_setup_pvp_slots` 分发：加 3v3 → `_setup_pvp_slots_3v3()` | `~line 1009` |
| J6 | `action/cross_board` 消息处理：3v3 同 1v3（已通用，无需改动） | `~line 1176` |
| J7 | `game/end` 结算逻辑：按 `local team_id == winning_team` 判 → 已通用 | `~line 1211` |
| J8 | `pvp_advance_turn_skip_dead()` 调用处：3v3 也走此函数（skip_dead 已够用，因为死一人即比赛结束） | `~line 1230` |
| J9 | 多处 `pvp_match_type == "1v3"` 改为 `is_multi_team_pvp()` | 全文（约 15 处） |
| J10 | ActionOrderBar setup：`pvp_match_type != "1v3"` 已改由 H1 处理，无需改 | — |

**J1 3v3 layout resolver 入口**：
```gdscript
# 原有 1v3 分支后加
elif Game.is_pvp and Game.pvp_match_type == "3v3":
    var resolver := BoardLayoutResolver.new()
    var layout: Array = []
    if Game.level_data.has("pvp_slot_layout"):
        var raw = Game.level_data["pvp_slot_layout"]
        if typeof(raw) == TYPE_ARRAY:
            layout = raw
    if layout.is_empty():
        layout = _build_default_3v3_layout()
    resolver.resolve(Game.local_player_id, layout)
    orchestrator_resolver = resolver
    orchestrator_main_ui = {}
    if resolver.local_slot_id != "":
        orchestrator_main_ui[resolver.local_slot_id] = {
            "grid": bottom_grid, "bg": $BottomGridBg, "hero_panel": $LeftSidePnl/PHpPnl,
        }
    if resolver.top_slot_id != "":
        orchestrator_main_ui[resolver.top_slot_id] = {
            "grid": top_grid, "bg": $TopGridBg, "hero_panel": $EnemyHpPnl,
        }
```

**J2 `_inject_3v3_level_data()`**：
```gdscript
func _inject_3v3_level_data() -> void:
    var layout: Array = []
    if Game.level_data.has("pvp_slot_layout"):
        var raw = Game.level_data["pvp_slot_layout"]
        if typeof(raw) == TYPE_ARRAY:
            layout = raw
    if layout.is_empty():
        layout = _build_default_3v3_layout()
    var boards: Dictionary = {}
    for entry in layout:
        var sid: String = String(entry.get("slot_id", ""))
        if sid != "":
            boards[sid] = {"faction": 0, "role": 0}
    Game.level_data["boards"] = boards
    Game.level_data["pvp_slot_layout"] = layout
```

**J3 `_build_default_3v3_layout()`**：
```gdscript
func _build_default_3v3_layout() -> Array:
    # 从 pvp_action_order(A1,B1,A2,B2,A3,B3) + pvp_teams 重建 slot_layout
    var layout: Array = []
    var team_a: Array = Game.players_of_team("team_a")
    var team_b: Array = Game.players_of_team("team_b")
    for i in range(team_a.size()):
        layout.append({
            "slot_id":    "slot_" + String(team_a[i]),
            "owner_pid":  String(team_a[i]),
            "team_id":    "team_a",
            "slot_index": i,
        })
    for i in range(team_b.size()):
        layout.append({
            "slot_id":    "slot_" + String(team_b[i]),
            "owner_pid":  String(team_b[i]),
            "team_id":    "team_b",
            "slot_index": 3 + i,
        })
    return layout
```

**J4 `_setup_pvp_slots_3v3()`**（与 `_setup_pvp_slots_1v3` 逻辑相同，直接复用）：
```gdscript
func _setup_pvp_slots_3v3() -> void:
    _setup_pvp_slots_by_layout()   # 抽出公共函数，或直接复制 1v3 实现
```

> **注**：`_setup_pvp_slots_1v3` 内部按 slot_layout 遍历注入 owner_player_id + team_id，逻辑完全通用。可抽出公共函数 `_setup_pvp_slots_from_layout()` 供 1v3/3v3 共用。

---

### K. dev_gd/nsoc/scripts/ui/front_row_selector.gd

| # | 任务 | 改动位置 |
|---|---|---|
| K1 | 镜像列条件：`pvp_match_type == "1v3"` 改为 `is_multi_team_pvp()` | `~line 154` |

```gdscript
# Before
if Game.pvp_match_type == "1v3":
    dst_col = BoardModel.COLS - 1 - cell.col

# After
if Game.is_multi_team_pvp():
    dst_col = BoardModel.COLS - 1 - cell.col
```

---

### L. dev_gd/nsoc/scripts/effects/assault_charge.gd（附加修复）

| # | 任务 | 改动位置 |
|---|---|---|
| L1 | `find_adjacent_enemies` 调用改用 `is_hostile_to(local_team)` 避免 3v3 队友误判 | 实际调用处 |

> **注**：若 `assault_charge.gd` 在 3v3 中不触发跨盘冲锋，此 bug 影响有限；可联调期发现再补。

---

## 开发进度（2026-06-10）

### 已完成

| 任务 | 文件 | 状态 |
|---|---|---|
| A1 MaxPlayersForType 3v3=6 | `server/room.go` | ✅ |
| B1 is_multi_team_pvp() | `game_context.gd` | ✅ |
| B2 bootstrap_pvp 3v3 teams 推断 | `game_context.gd` | ✅ |
| C1 BoardLayoutResolver 3v3 分支 | `board_layout_resolver.gd` | ✅ |
| D1 board_slot _on_hero_died 3v3 | `board_slot.gd` | ✅ |
| E1 turn_system 3v3 UI 跨盘分支 | `turn_system.gd` | ✅ |
| E2 turn_system auto-cross 排除 3v3 | `turn_system.gd` | ✅ |
| E3 _broadcast_cross_board 开放 3v3 | `turn_system.gd` | ✅ |
| F1 play_controller 广播 3v3 | `play_controller.gd` | ✅ |
| G1 board_orchestrator 3v3 | `board_orchestrator.gd` | ✅ |
| H1/H2 action_order_bar 3v3 + 队伍颜色 | `action_order_bar.gd` | ✅ |
| I1 sparring_panel 加 3v3 按钮 | `sparring_panel.gd` | ✅ |
| I2 min_players=6 | `sparring_panel.gd` | ✅ |
| I3 _on_start_game 3v3 slot_layout + action_order | `sparring_panel.gd` | ✅ |
| J1 test_main 入口 3v3 resolver | `test_main.gd` | ✅ |
| J2 _inject_3v3_level_data | `test_main.gd` | ✅ |
| J3 _build_default_3v3_layout | `test_main.gd` | ✅ |
| J4 _setup_pvp_slots_3v3 | `test_main.gd` | ✅ |
| J5 _setup_pvp_slots 分发 | `test_main.gd` | ✅ |
| J8/J9 多处 pvp_match_type == "1v3" → is_multi_team_pvp() | `test_main.gd` | ✅ |
| K1 front_row_selector 镜像列 3v3 | `front_row_selector.gd` | ✅（已通用，注释更新） |

### 待联调

| 任务 | 备注 |
|---|---|
| I4 SparringPanel 6 格槽位 UI | 当前 6 格已存在，显示 3v3 时仅需验证布局 |
| L1 assault_charge is_hostile_to 迁移 | 3v3 队友相邻可能误判，联调发现再补 |
| T1-T9 完整联调测试 | 见下方测试场景 |

---



```
Phase 1（必须先做）
  A1  server/room.go MaxPlayersForType 加 3v3
  B1  is_multi_team_pvp() 方法
  B2  bootstrap_pvp 3v3 teams 推断
  I1  sparring_panel 加 3v3 按钮
  I2  min_players = 6
  I3  _on_start_game 3v3 slot_layout + action_order

Phase 2（让 6 端连上跑一局）
  C1  board_layout_resolver 3v3 分支
  J1  test_main 入口 3v3 resolver
  J2  _inject_3v3_level_data
  J3  _build_default_3v3_layout
  J4  _setup_pvp_slots_3v3（复用 1v3 实现）
  J5  _setup_pvp_slots 分发

Phase 3（逻辑与 UI 完整）
  D1  board_slot _on_hero_died 3v3
  E1  turn_system 3v3 UI 跨盘分支
  E2  turn_system auto-cross 排除 3v3
  E3  _broadcast_cross_board 开放 3v3
  F1  play_controller 广播 3v3
  G1  board_orchestrator 3v3
  H1  action_order_bar pvp_match_type 3v3
  H2  3v3 队伍颜色
  K1  front_row_selector 镜像列 3v3
  J9  test_main 多处 1v3→is_multi_team_pvp

Phase 4（联调）
  I4  sparring_panel 6 格槽位 UI
  L1  assault_charge 迁移 is_hostile_to（可选）
```

---

## 测试场景

| # | 场景 | 预期 |
|---|---|---|
| T1 | 房主创建 3v3 房间 → 6 人加入 → 开始 | 6 端进入战斗场景，各见 6 盘（底部自盘居中 + 2 队友侧盘，顶部敌队 3 盘） |
| T2 | ActionOrderBar | 6 个昵称按 A1/B1/A2/B2/A3/B3 排列，队伍颜色区分，当前行动者高亮 |
| T3 | A1 出牌后点结束 | 轮到 B1，ActionOrderBar 高亮移动 |
| T4 | A2 前排单位到达前线 → 弹目标盘 UI | 高亮敌队 3 盘，点击命中后单位以镜像列落地 |
| T5 | 其余 5 端镜像 A2 跨盘 | 远端单位在对应敌盘 `COLS-1-src_col` 位置落地 |
| T6 | A1 英雄死亡 → team_a 即败 | 6 端均弹胜负 UI（team_a 全部"失败"，team_b 全部"胜利"） |
| T7 | 1v3 回归测试 | 1v3 对局行为不变（攻方仍自动跨，无 UI 弹窗） |
| T8 | B2 断线 | `disconnect/notify` → damage_hero(100) → team_b 即败 |
| T9 | PVE 回归测试 | PVE 单机对局不受影响 |

---

## 已通用（无需改动）

| 模块 | 原因 |
|---|---|
| `BoardRegistry.adjacent_enemy_slots` | 按 team_id 通用，自动返回对方 3 盘 |
| `BoardOrchestrator` 侧盘 team 位置判断 | 已按 `team_id != viewer team` 决定上/下，3v3 直接生效 |
| `action/cross_board` 消息队列 | FIFO 通用，只要 owner_pid 守卫正确即可 |
| `bootstrap_pvp` deck/mana 创建 | 按 all_player_ids 遍历，6 人自动创建 |
| `pvp_advance_turn_skip_dead` | 3v3 死一人即全队败，实战不会触发跳过；逻辑已通用 |
| `game/end` 结算显示 | 按 `local team_id == winning_team` 判，3v3 直接生效 |
| `CombatSystem` | 无 match_type 依赖 |
| `EffectContext` 友敌判定 | 已用 team_id 通用逻辑 |
