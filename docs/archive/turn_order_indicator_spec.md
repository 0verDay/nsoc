# 棋盘行动顺序指示器（Turn Order Indicator）

> **状态说明（事后补记）**：本规格**已全部实现**。
> 实现文件：`dev_gd/nsoc/scripts/ui/turn_order_indicator.gd`（195 行，`class_name TurnOrderIndicator extends Control`，
> 内含内部子类 `_Ring extends Control`）；接入文件：`dev_gd/nsoc/scripts/core/board_orchestrator.gd`
> （`_create_slot()` 内创建、`refresh_indicator_orders()`、`preview_active_pvp_slots()`、`_compute_slot_orders()`）。
> 下文已按代码回填。与原始规格的主要差异：
> ① **活跃判定不是「逐盘 `_process_cell` 点亮」**，而是 PVE「按 `phase_started` 阵营整盘点亮」+ PVP
>    「按 `pvp_active_player_id()` 预亮」（见「当前活跃判定」节）；
> ② 只新增了 `slot_action_started` 一个信号，`slot_action_ended` **不存在**，且 indicator **不监听** `slot_action_started`；
> ③ **锚点按屏幕上下半区几何判定**，不按 `faction`（见「锚点位置」节）；
> ④ `set_active(active: bool)` **无颜色参数**，颜色另走 `refresh_color()`；
> ⑤ 光环半径 22（非 40 px），编号无「9+」截断。

## 目标

为所有 BoardSlot 加可视化「行动顺序徽章」。
- 显示该盘行动序号（1,2,3...）
- 轮到该盘时显示「转圈光环」高亮 → 实装粒度是**「轮到该阵营（PVE）/ 该活跃玩家（PVP）」整批点亮**，
  而非逐盘精确到「正在行动的那一盘」（详见「当前活跃判定」）
- PVE / 1v1 PVP / 1v3 PVP / 3v3 PVP 全模式启用

非目标：替换现有顶部 `ActionOrderBar`（保留，作为多队伍 PVP 的全局昵称条）。

---

## 设计要点（用户已确认）

| 项 | 决策 | 实装情况 |
|---|---|---|
| 行动顺序定义 | 玩家主盘=1，其余按行动顺序 2/3/4... | ⚠️ 数值一致，但实现只按 `visual_x` 排序（**不看 `role`**），主盘为 1 依赖布局 |
| 视觉锚点 | 每盘 `bg_panel` 朝向屏幕中线那条边的中点 | ⚠️ 结果一致，但判据改为**屏幕上下半区几何判定**（不按 `faction`） |
| 徽章样式 | 圆形徽章 + 内嵌数字 | ✅ 一致（另加 2px `#adb5bd` 描边；**未**设粗体） |
| 高亮形式 | 动态转圈光环（rotating ring） | ✅ 一致（半径 22，非规格写的 40） |
| 更新机制 | 每个 slot 自听信号自维护 | ✅ 一致（每个 indicator 自行连接 `Game.turn.phase_started` / `turn_ended`） |

---

## 顺序号计算规则

### PVE / 1v1（1v3 / 3v3 之外的非 PVP 局）
实现在 `BoardOrchestrator._compute_slot_orders()`（`board_orchestrator.gd:557-584`），判据是
`not (Game.is_pvp and Game.pvp_action_order.size() > 0)`：

1. 收集 `faction == BoardSlot.FACTION_PLAYER` 的盘 → 按 `visual_x()`（`bg_panel.global_position.x`）**升序**编号 1..N；
2. 其余全部盘（即 `faction != FACTION_PLAYER`，没有再做细分）→ 按 `visual_x()` **降序**编号 N+1..M。

> 实装差异：**没有**采用与 `TurnSystem._iter_phase_cells` 一致的盘级排序，也没有引用 `slot_index` / `role`——
> 盘序完全由 `visual_x()` 决定。因此「玩家主盘永远是 1」并非由 `role == ROLE_MAIN_PLAYER` 保证，
> 而是依赖布局使主盘 `visual_x` 最小；`3v3` 等特殊布局下不成立（那类局走 PVP 分支）。

### PVP（1v1 / 1v3 / 3v3）
用 `Game.pvp_action_order`（uuid 数组），实现在 `board_orchestrator.gd:561-565`：
- 每个 slot 取 `Game.pvp_action_order.find(slot.owner_player_id)`，下标 +1 即序号；
- 若 `owner_player_id` 不在数组内（`find` 返回 -1）→ 序号记为 **0**（indicator 显示 "?"，见「徽章」节）；
- 同 owner 多盘（1v3 防守方多盘）→ 同号（符合原规格）；
- 仅当 `pvp_action_order` 非空时走本分支，否则回退到上一条 PVE 规则。

### 当前活跃判定（实装：**按阵营 / 按活跃玩家整盘点亮**，非逐盘精确跳转）

> ⚠️ 这里与原始规格差别最大。规格设计的「当前 `_process_cell` 所在 slot 亮」**没有**被 indicator 采用。

**TurnSystem 侧（`turn_system.gd`）**：只新增了一个信号，参数为 `BoardSlot`：
```gdscript
signal slot_action_started(slot: BoardSlot)   # turn_system.gd:28
```
- 在 `_process_cell(faction, cell, slot)` 中，**仅当 `slot != _last_active_slot` 时** emit 一次（`turn_system.gd:416-419`，含 `_last_active_slot` 缓存优化）；
- `_run_phase()` / `_run_phase_for_slot()` 开头把 `_last_active_slot` 重置为 `null`（`turn_system.gd:278,219`）；
- **没有 `slot_action_ended` 信号**，也没有在 `_process_cell` 结尾 emit（原规格所列 `slot_action_ended` 属设计稿未落地项）；
- 该信号目前**没有监听者**（全工程仅此一处 emit，indicator 未连接它）。

**indicator 侧（`turn_order_indicator.gd:140-170`）**：实际连接的是 `Game.turn.phase_started` 与 `Game.turn.turn_ended`：
- `_on_phase_started(faction)` → `set_active(_slot.faction == faction)`，即**该阶段阵营的全部盘一起亮**（PVE）；
- `_on_turn_ended()` → `set_active(_slot.faction == BoardSlot.FACTION_PLAYER)`，即**回合结束后回到「玩家盘亮」**（并非「全部熄灭」）；
- 初始状态 `_set_initial_active()`（`turn_order_indicator.gd:98-102`）：非 PVP 下 `faction == FACTION_PLAYER` 的盘亮（等待玩家出牌）；
- 以上三个回调在 `Game.is_pvp` 为真时**直接 return**，PVP 下改由 `preview_active_pvp_slots()` 全权维护。

**PVP 预亮（`board_orchestrator.gd:545-553`）**：
- `preview_active_pvp_slots()` 把 `slot.owner_player_id == Game.pvp_active_player_id()` 的所有 slot 设为 active（同 owner 多盘同亮），非 PVP 或 `Game.registry == null` 时直接返回；
- 触发点：`refresh_indicator_orders()` 在 PVP 下自身会调它（`board_orchestrator.gd:540-541`）；
  `test_main.gd:_update_pvp_turn_ui()` 末尾调用它（`test_main.gd:1405-1406`），而该函数紧跟 `Game.pvp_advance_turn()` /
  `pvp_advance_turn_skip_dead()` 之后（`test_main.gd:1375-1381`）——即实现了设计里的「回合切换后预亮」；
- `run_pvp_phase` / `run_pvp_phase_for_slot` 期间**不会**把高亮细化到「当前正在行动的盘」：`slot_action_started` 无监听者，
  PVP 光环在整个己方回合保持「我方全部盘亮」。

---

## 视觉规格

### 徽章
- 形状：圆形 `Panel`（StyleBoxFlat）；实装用 `sb.set_corner_radius_all(int(BADGE_SIZE / 2.0))` = **半径 16**（等效于整圆，非字面 `corner_radius=999`）
- 尺寸：32×32 px（`const BADGE_SIZE: float = 32.0`）
- 默认色：浅灰底（`#dee2e6`）+ 深灰文字（`#495057`）
- 描边（规格未列，实装新增）：2 px，颜色 `#adb5bd`
- 字号：18；**未设粗体**（`turn_order_indicator.gd:61-62` 只 override `font_size` 与 `font_color`）
- 数字：实装为 `_label.text = str(num) if num >= 1 else "?"`——**没有「10+ 显示 9+」的截断**，序号 10 就显示 "10"；
  序号 0（PVP 中 owner 不在 `pvp_action_order`）显示 "?"
- 其他层级：indicator 自身 `mouse_filter = IGNORE`、`z_index = 10`；徽章 `z_index = 1`；非 active 时徽章 `self_modulate` alpha 降到 0.75，active 时恢复 `Color.WHITE`（`set_active()`）

### 锚点位置（实装：按屏幕上下半区几何判定，不按 `faction`）

实现在 `TurnOrderIndicator._reposition()`（`turn_order_indicator.gd:119-138`）。indicator 本身是 **`bg_panel` 的子节点**
（`board_orchestrator.gd:438-443`：`bg.add_child(ind)`），因此坐标是 `bg_panel` 内的局部坐标：

```gdscript
var bw := bg.size.x
var bh := bg.size.y
var cx := bw / 2.0
var screen_h := bg.get_viewport_rect().size.y
var board_mid_y := bg.global_position.y + bh * 0.5
var at_top_half := board_mid_y < screen_h * 0.5      # 板子中心在视口上半 → 板子在上方
var cy: float = bh if at_top_half else 0.0           # 上方盘贴下沿；下方盘贴上沿
_badge.position = Vector2(cx - BADGE_SIZE / 2.0, cy - BADGE_SIZE / 2.0)
```

- 判据是 `bg_panel` 中心是否在视口上半屏，**不是** `faction`；
  代码注释明确说明这是为了兼容「3v3 友军盘视觉在下但 `faction=ENEMY`」等情形；
- 偏移量 = `BADGE_SIZE / 2 = 16`：徽章中心落在该边中点，即一半压在 `bg_panel` 内、一半溢出（与规格的「-16 px」数值一致）；
- 触发时机：`setup()` 中连接 `p_slot.bg_panel.resized` → `_reposition`，并在 `await get_tree().process_frame` 后先定位一次
  （`turn_order_indicator.gd:72-78`）——即 `bg_panel` 尺寸变化时重算，非每帧重算；
- 光环圆心与徽章一致：`_ring.position = Vector2(cx - rh, cy - rh)`，`_ring.size = Vector2(rh*2, rh*2)`，`rh = RING_RADIUS + 3`。

> 原规格中「按 `front_row_of_slot(slot)` 推断锚点边」的做法**未采用**。

### 高亮光环
- 内部子类 `_Ring extends Control`，是 indicator 的子节点、且**先于徽章 add_child**（叠在徽章背后：徽章 `z_index = 1`）
- 使用 `_draw()` 自定义绘制：
  - `const RING_RADIUS: float = 22.0`，`size = (RING_RADIUS + 3) * 2 = 50×50`；
    `_draw()` 中实绘半径 `r = size.x/2 - RING_W/2 = 25 - 1.5 = 23.5 px`（**非规格的 40 px 半径**）
  - 线宽 `const RING_W: float = 3.0`（与规格一致）
  - 弧段 `const ARC_SPAN: float = TAU * 0.75` = 270°（与规格一致）；用单次 `draw_arc(center, r, _angle, _angle + ARC_SPAN, 48, ring_color, RING_W, true)`
    （规格写的「渐变弧」实装为**纯色**弧，无透明度渐变）
  - 旋转：`_process` 中 `_angle += delta * 2.0`（起始角自增，非 `rotation` 属性）→ 一圈约 `TAU / 2.0 ≈ 3.14 s`
    （**规格写的 1.8 s/圈不成立**）；仅在 `visible` 时 `queue_redraw()`
- 颜色（`_get_ring_color()`，`turn_order_indicator.gd:104-113`）——与规格一致：
  - 按 `slot.team_id`：`team_a`=`#339af0` / `team_b`=`#f03e3e` / `defender`=`#fab005` / `attacker`=`#f76707`
  - 兜底：`faction == FACTION_PLAYER` → `#4dabf7`；否则 `#fa5252`
  - 颜色在 `setup()` 与 `BoardOrchestrator.refresh_indicator_orders()` 调 `refresh_color()` 时重新应用
    （即 PVP 队伍信息变化后需要一次 refresh 才换色）
- 非 active 时光环 `visible=false`（`set_active(false)`）；**没有独立的 `_is_active` 字段**（规格列的 `var _is_active` 未实装，
  实际以 `_ring.visible` 表达）

---

## 文件改动（实装清单）

### 新增 1 个文件 ✅
**`dev_gd/nsoc/scripts/ui/turn_order_indicator.gd`（195 行）**
```gdscript
class_name TurnOrderIndicator
extends Control

const BADGE_SIZE: float = 32.0
const RING_RADIUS: float = 22.0

var _slot:  BoardSlot = null     # 实装为私有；无公开 slot 字段
var _badge: Panel = null
var _label: Label = null
var _ring:  _Ring = null         # 内部子类 _Ring extends Control（自绘转圈光环）
# 实装无 _is_active 字段（以 _ring.visible 表达）

func setup(p_slot: BoardSlot) -> void        # 内含 await get_tree().process_frame 后再定位 + 置初态
func set_order(num: int) -> void             # num < 1 → "?"
func set_active(active: bool) -> void        # ⚠️ 无 color 参数（规格写 set_active(active, color)）
func refresh_color() -> void                 # 实装新增：按 team_id / faction 重取光环颜色
# 内部：_set_initial_active / _get_ring_color / _apply_ring_color / _reposition /
#       _connect_signals / _disconnect_signals / _on_phase_started(faction) / _on_turn_ended / _exit_tree
# 监听：Game.turn.phase_started + Game.turn.turn_ended（**不监听** phase_ended / slot_action_started）
# 锚点：bg_panel.resized 时重算（非每帧）
```

### 改动 1 个文件 ✅
**`dev_gd/nsoc/scripts/core/board_orchestrator.gd`**（实装函数名与规格不同）
- 在 `_create_slot()`（**规格写的 `_build_slot` 不存在**）末尾挂 indicator：`bg.add_child(ind); ind.setup(slot)`，并记入 `_indicators[id]`（`board_orchestrator.gd:437-443`）
- 序号计算与刷新：`refresh_indicator_orders()`（**规格写的 `_refresh_all_indicators()` 不存在**，`board_orchestrator.gd:530-541`），内部调 `_compute_slot_orders()` 并对每个 indicator `set_order()` + `refresh_color()`；PVP 下额外调 `preview_active_pvp_slots()`
- 刷新触发点（实装）：
  - `boot()` 末尾 `call_deferred("refresh_indicator_orders")`（`board_orchestrator.gd:179`，延一帧等 `visual_x` 就绪）
  - `add_board()` 末尾（`board_orchestrator.gd:274`）
  - `remove_board()` 末尾（`board_orchestrator.gd:314`），并在移除时 `queue_free` 对应 indicator + `_indicators.erase(id)`（`:290-294`）
  - `_cleanup_all()` 释放全部 indicator（`:98-101`）
- PVP 预亮：`preview_active_pvp_slots()`（`:545-553`）；
  **注意实装并非「`bootstrap_pvp` / `pvp_advance_turn` 后触发 refresh」**——`board_orchestrator` 不监听这两者，
  而是由 `test_main._update_pvp_turn_ui()` 主动调用（见下）

### 改动 2 个文件（轻量）—— ⚠️ 与规格描述不同
- **`dev_gd/nsoc/scripts/test_main.gd`**：**没有** `refresh_turn_indicators()` / `_refresh_turn_indicators()` 调用。
  实装是在 `_update_pvp_turn_ui()` 末尾（`test_main.gd:1402-1406`）：
  ```gdscript
  if is_instance_valid(_action_order_bar):
      _action_order_bar.refresh()
  if is_instance_valid(board_orchestrator):
      board_orchestrator.preview_active_pvp_slots()
  ```
  该函数紧跟 `Game.pvp_advance_turn()` / `pvp_advance_turn_skip_dead()` 调用（`test_main.gd:1375-1381`）。
- **`dev_gd/nsoc/scripts/main.gd`**：**完全没有** indicator 相关调用（0 行改动）；PVE 侧序号刷新全部由
  `board_orchestrator` 的 boot / add_board / remove_board 内部完成。

---

## 信号 / 数据流（实装）

```
PVE（Game.is_pvp == false）：
  TurnSystem.phase_started(faction) ──→ TurnOrderIndicator._on_phase_started(faction)
                                          set_active(_slot.faction == faction)   # 整阵营亮/灭

  TurnSystem.turn_ended            ──→ TurnOrderIndicator._on_turn_ended()
                                          set_active(_slot.faction == PLAYER)    # 回到玩家盘亮（不是全灭）

  setup() 完成时（非 PVP）          ──→ _set_initial_active()
                                          PLAYER 盘亮

  TurnSystem.slot_action_started(slot)     # turn_system.gd:416-419，仅在 slot 切换时 emit
      → **无监听者**（indicator 未连接；规格设计的「逐盘点亮」未采用）

PVP（Game.is_pvp == true）：
  phase_started / turn_ended 回调直接 return（不干预）
  pvp_advance_turn / pvp_advance_turn_skip_dead   （test_main.gd:1375-1381）
      → test_main._update_pvp_turn_ui()           （test_main.gd:1386）
          → BoardOrchestrator.preview_active_pvp_slots()   （test_main.gd:1405-1406）
              → 每个 indicator: set_active(_slot.owner_player_id == Game.pvp_active_player_id())
```

序号刷新时机（仅序号 + 光环颜色，不含 active 状态）——实装触发点：
- **装配完毕**：`BoardOrchestrator.boot()` 末尾 `call_deferred("refresh_indicator_orders")`（`board_orchestrator.gd:179`）
- **动态加盘**：`add_board()` 末尾（`board_orchestrator.gd:274`）
- **动态减盘**：`remove_board()` 末尾（`board_orchestrator.gd:314`）
- **PVP `pvp_action_order` 变化时**：实装**没有**直接监听该变化；序号在 boot（及上述增删盘）时算定。
  若 `pvp_action_order` 在 boot 之后变化，需要外部再调一次 `refresh_indicator_orders()` 才会更新
  （`test_main._update_pvp_turn_ui()` 只调 `preview_active_pvp_slots()`，**不重算序号**）。

---

## 验证清单（按代码核对的预期行为；本机无 Godot，未实机验证）

- [x] PVE 长坂坡：玩家盘=1、敌盘=2（PLAYER 阵营按 `visual_x` 升序，ENEMY 降序）；**光环是整个阵营一起亮**
      （PLAYER 阶段玩家盘蓝光环 `#4dabf7`；ENEMY 阶段敌盘红光环 `#fa5252`），**不是**随当前行动 cell 在盘内/盘间跳转
- [x] PVE 威震华夏（多盘）：序号 1/2/3...；光环按 `phase_started` 阵营整批切换；`turn_ended` 后回到 PLAYER 盘亮
- [x] 1v1 PVP：序号按 `pvp_action_order` 下标 +1（玩家=1 / 对手=2）；
      高亮由 `preview_active_pvp_slots()` 按 `pvp_active_player_id()` 整回合维护（我方回合我方盘亮，对方回合对方盘亮，**非逐 cell**）
- [x] 1v3 PVP：守方=1，攻方三盘=2/3/4（若同 owner 多盘则同号）；高亮为「当前活跃玩家的**全部**盘一起亮」
- [x] 3v3 PVP：六盘按 `pvp_action_order` 编号；team 颜色区分（`team_a` 蓝 / `team_b` 红）
- [x] 动态 `add_board` 后新盘正确编号（`add_board()` 末尾 `refresh_indicator_orders()`）
- [x] 退出到菜单 indicator 安全释放：`remove_board()` 逐个 `queue_free`，`_cleanup_all()` 释放全部
- [x] 跨盘选择高亮（`front_row_selector`）期间：该组件改的是 `bg_panel` 的 **stylebox override + scale 脉冲**，
      indicator 作为 `bg_panel` 子节点会**跟随 scale 一起缩放**（不会改变序号/颜色，但视觉上会同步脉动）
- [x] `turn_ended` 后：PVE 下所有 **PLAYER 阵营**盘亮、ENEMY 盘灭（**不是全灭**）；
      `phase_ended` **未被监听**，不产生任何效果

> 未实现/不可验证项：规格中的「逐盘点亮（当前 `_process_cell` 所在盘亮）」在实装中**不存在**，
> 因此「光环在盘间精确跳转」类验收目标不适用。

---

## 风险 / 未决项（按实装更新）

1. **光环与 `bg_panel` 高亮冲突** —— 前提与结论都已改：
   - 实装 indicator **不是**独立兄弟节点，而是挂在 `bg_panel` **内部**（`board_orchestrator.gd:438-441`）；
   - `front_row_selector` 实际改的是 `bg_panel` 的 **`add_theme_stylebox_override`（换边框/底色）+ `scale` 脉冲**
     （`front_row_selector.gd:84-93`），**并未**改 `self_modulate`（规格描述不准）；
   - 结论：stylebox 变化不影响子节点，徽章/光环**不会被染色**；但 `scale` 会作用于子节点渲染，
     跨盘选择期间徽章与光环会**随盘一起脉动**（`pivot_offset = bg.size * 0.5`，1.015 倍）。这是当前唯一可见交互，未做规避。
2. **逐盘点亮的信号开销** —— 已不适用：`turn_system` 确实缓存了 `_last_active_slot` 并只在 slot 变化时 emit
   （`turn_system.gd:416-419`），但 indicator **没有监听**该信号，因此不存在逐盘 emit 的渲染开销；
   代价是失去了「逐盘精确高亮」的能力（见「当前活跃判定」节与验证清单）。
3. **PVP 阶段切换间隙的预亮** —— ✅ 已实现：`BoardOrchestrator.preview_active_pvp_slots()`（`board_orchestrator.gd:545-553`），
   由 `test_main._update_pvp_turn_ui()` 在 `pvp_advance_turn` 之后调用（`test_main.gd:1375-1381,1405-1406`），
   使 PVP 下光环在整个己方回合持续点亮，无视觉断流。
4. **（新增风险）PVP 序号不随 `pvp_action_order` 变化自动刷新**：`refresh_indicator_orders()` 只在 boot / add_board / remove_board
   被调用；`_update_pvp_turn_ui()` 只调 `preview_active_pvp_slots()`，不重算序号。若对局中 `pvp_action_order` 变化，
   序号会保持 boot 时的值。

---

## 工作量（实装统计）

| 项 | 规格估算 | 实际 |
|---|---|---|
| `turn_order_indicator.gd` 新建 | ~150 行 | **195 行**（含内部 `_Ring` 类） |
| `board_orchestrator.gd` 接入 | ~40 行 | **约 70 行**（`_indicators` 字段 / `_create_slot` 挂载 / 释放 / `refresh_indicator_orders` / `preview_active_pvp_slots` / `_compute_slot_orders`） |
| `test_main.gd` / `main.gd` 触发点 | ~5 行 × 2 | `test_main.gd` **约 5 行**（`_update_pvp_turn_ui()` 末尾调 `preview_active_pvp_slots()`）；`main.gd` **0 行** |
| 总计 | ~200 行 | **约 270 行** |

> 功能已实装完毕（规格中的「逐盘点亮」方案未采用，见「当前活跃判定」节）。
