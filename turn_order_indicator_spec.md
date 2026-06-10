# 棋盘行动顺序指示器（Turn Order Indicator）

## 目标

为所有 BoardSlot 加可视化「行动顺序徽章」。
- 显示该盘行动序号（1,2,3...）
- 轮到该盘时显示「转圈光环」高亮
- PVE / 1v1 PVP / 1v3 PVP / 3v3 PVP 全模式启用

非目标：替换现有顶部 `ActionOrderBar`（保留，作为多队伍 PVP 的全局昵称条）。

---

## 设计要点（用户已确认）

| 项 | 决策 |
|---|---|
| 行动顺序定义 | 玩家主盘=1，其余按行动顺序 2/3/4... |
| 视觉锚点 | 每盘 `bg_panel` 朝向屏幕中线那条边的中点 |
| 徽章样式 | 圆形徽章 + 内嵌数字 |
| 高亮形式 | 动态转圈光环（rotating ring） |
| 更新机制 | 每个 slot 自听信号自维护 |

---

## 顺序号计算规则

### PVE / 1v1
按盘的 **行动顺序** 排序：
1. **PLAYER 阵营盘** 先走（玩家主盘 → 友军盘按 `slot_index` / `visual_x` 升序）
2. **ENEMY 阵营盘** 再走（按 `_iter_phase_cells(ENEMY)` 顺序：先玩家侧已跨入盘，后敌方侧；x 降序）

实现采用与 `TurnSystem._iter_phase_cells` 一致的盘级排序，直接产出 `Array[BoardSlot]`，下标 +1 即序号。

> 玩家主盘永远是 1（`role == ROLE_MAIN_PLAYER` 在 PLAYER 阵营且 `slot_index=0`）。

### PVP（1v1 / 1v3 / 3v3）
用 `Game.pvp_action_order`（uuid 数组）。
- 每个 slot 找 `slot.owner_player_id` 在数组中的下标 +1
- 同 owner 多盘（3v3 队员可能不会出现，但 1v3 防守方可能多盘）→ 同号

### 当前活跃判定（逐盘点亮）

统一采用 **「当前 `_process_cell` 所在 slot 亮」** 方案。

**TurnSystem 新增信号**：
```gdscript
signal slot_action_started(slot: BoardSlot)
signal slot_action_ended(slot: BoardSlot)
```
在 `_process_cell(faction, cell, slot)` 开头/结尾各 emit 一次（或仅在 slot 切换时 emit 节省开销）。

**indicator 行为**：
- 收到 `slot_action_started(s)` → `self.slot == s` 则 active=true，否则 false
- 收到 `phase_ended` → 全部 active=false（清光环，等下一阶段）
- 收到 `turn_ended` → 全部 active=false

**PVP 复用同一信号**：`run_pvp_phase` / `run_pvp_phase_for_slot` 也走 `_process_cell`，自动复用。
另外 `pvp_advance_turn` 切换行动玩家时（PVP 回合切换、本端尚未开始 run）需要一个「预亮」状态：
- `test_main` / `play_controller` 在 `pvp_advance_turn` 后调用 `BoardOrchestrator.preview_active_pvp_slots()`
- 该方法把 `slot.owner_player_id == Game.pvp_active_player_id()` 的所有 slot 设为 active（等 `_process_cell` 起来后再细化到具体 slot）

---

## 视觉规格

### 徽章
- 形状：圆形 `Panel`（StyleBoxFlat，corner_radius=999）
- 尺寸：32×32 px
- 默认色：浅灰底（`#dee2e6`）+ 深灰文字（`#495057`）
- 字号：18，粗体
- 数字：1-9，10+ 显示 "9+"（冗余防御）

### 锚点位置
按盘的 `faction` 决定贴合 `bg_panel` 的哪条边的中点：
- `FACTION_PLAYER`（玩家盘，视觉在下方）→ `bg_panel` **上沿中点**（朝中线）
- `FACTION_ENEMY`（敌方盘，视觉在上方）→ `bg_panel` **下沿中点**（朝中线）

徽章中心对齐边的中点，向中线方向偏移 -16 px（让徽章一半压在 bg_panel 内、一半溢出）。

> 多队伍 1v3/3v3 中所有盘统一以 row=0 为前排，"朝中线"方向按 `BoardModel.front_row_of_slot(slot)` 推断 → 前排对应那条边即为锚点。具体落实用 `bg_panel.size` + `front_row_of_slot` 计算。

### 高亮光环
- 单独 `Control` 子节点，铺在徽章背后
- 使用 `_draw()` 自定义绘制：
  - 外环 40 px 半径，宽 3 px
  - 渐变弧（高亮色 → 透明），覆盖 270° 弧段
  - `_process` 中 `rotation += delta * 2.0`（约 1.8s/圈）
- 颜色：
  - PVP：按 `team_id` 着色（team_a=`#339af0` 蓝 / team_b=`#f03e3e` 红 / defender=`#fab005` 金 / attacker=`#f76707` 橙）
  - PVE：玩家阵营=`#4dabf7`，敌方阵营=`#fa5252`
- 非 active 时光环 `visible=false`

---

## 文件改动

### 新增 1 个文件
**`dev_gd/nsoc/scripts/ui/turn_order_indicator.gd`**
```gdscript
class_name TurnOrderIndicator
extends Control

# 单 slot 的行动顺序徽章 + 转圈光环
var slot: BoardSlot
var _badge: Panel
var _label: Label
var _ring: Control          # 自绘转圈光环
var _is_active: bool = false

func setup(p_slot: BoardSlot) -> void
func set_order(num: int) -> void
func set_active(active: bool, color: Color) -> void
# 内部：监听 Game.turn.phase_started / phase_ended、Game 的 pvp 活跃变化
# 锚点：每帧或 bg_panel resized 时重算位置
```

### 改动 1 个文件
**`dev_gd/nsoc/scripts/core/board_orchestrator.gd`**
- 在 `_build_slot` 完成后挂 `TurnOrderIndicator` 到 slot
- 装配完成后调用 `_refresh_all_indicators()` 计算 PVE 盘序号
- PVP 模式下由 `bootstrap_pvp` / `pvp_advance_turn` 后触发 refresh

### 改动 2 个文件（轻量）
- **`test_main.gd`** / **`main.gd`**：
  - 装配末尾调 `BoardOrchestrator.refresh_turn_indicators()`
  - 现有 `_action_order_bar.refresh()` 调用点旁边加一行 `_refresh_turn_indicators()`

---

## 信号 / 数据流

```
PVE / PVP 通用：
  TurnSystem._process_cell(cell, slot):
    emit slot_action_started(slot)  ──→ TurnOrderIndicator
    [攻击 / 移动 / 跨盘 ...]              检查 self.slot == s
    emit slot_action_ended(slot)         切 active 状态

  TurnSystem.phase_ended / turn_ended ─→ 全部 active=false

PVP 阶段切换（无 _process_cell 触发的间隙）：
  pvp_advance_turn → test_main/play_controller →
    BoardOrchestrator.preview_active_pvp_slots()
      （把 owner_player_id == active_pid 的 slot 预亮，
        待 run_pvp_phase 启动 _process_cell 后细化）
```

序号刷新时机（仅序号，不含光环）：
- 装配完毕（slot 全部加入 registry 后）
- 动态加盘 `add_board` action 后
- 动态减盘 `remove_board` 后
- PVP `pvp_action_order` 变化时

---

## 验证清单

- [ ] PVE 长坂坡：玩家盘=1（蓝光环 PLAYER 阶段、随当前行动 cell 所在盘亮），敌盘=2（红光环 ENEMY 阶段亮）
- [ ] PVE 威震华夏（多盘）：序号 1/2/3...，光环随 `_process_cell` 在盘间精确跳转
- [ ] 1v1 PVP：玩家=1（自己回合每个 cell 处理时亮），对手=2（对方回合亮）
- [ ] 1v3 PVP：守方=1，攻方三盘=2/3/4，光环按当前行动 slot 精确切换
- [ ] 3v3 PVP：六盘按行动顺序 1-6，team 颜色区分
- [ ] 动态 `add_board` 后新盘正确编号
- [ ] 退出到菜单 indicator 安全 `queue_free`（slot 释放时连带）
- [ ] 跨盘选择高亮（front_row_selector）期间不与光环冲突
- [ ] `phase_ended` / `turn_ended` 后所有光环熄灭

---

## 风险 / 未决项

1. **光环与 `bg_panel.self_modulate` 冲突**：`front_row_selector` 会临时改 `bg_panel` 高亮。光环作为独立 `Control` 兄弟节点（不挂在 bg_panel 内），互不影响。
2. **逐盘点亮的信号开销**：`_process_cell` 每格调一次 emit，多盘多单位时频次较高。优化：缓存 last_active_slot，只在 slot 变化时 emit（默认实现采用此策略）。
3. **PVP 阶段切换间隙的预亮**：`pvp_advance_turn` 后到 `_process_cell` 启动前的几帧需要 `preview_active_pvp_slots()` 提前点亮，避免视觉断流。

---

## 工作量估算

| 项 | 行数 |
|---|---|
| `turn_order_indicator.gd` 新建 | ~150 行 |
| `board_orchestrator.gd` 接入 | ~40 行 |
| `test_main.gd` / `main.gd` 触发点 | ~5 行 × 2 |
| 总计 | ~200 行 |

预期实现时间：1-2 小时。
