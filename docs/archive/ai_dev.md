# 敌方 AI 接入设计文档（ai_dev.md）

> **状态说明（事后补记）**：本文档写于功能实现之前，属**设计稿**。截至当前代码，AI 系统**已实装**：
> - 实装文件：`dev_gd/nsoc/scripts/ai/` 下的 `ai_action.gd`、`ai_strategy.gd`、`heuristic_strategy.gd`、
>   `game_view.gd`、`ai_action_sink.gd`、`local_action_sink.gd`、`net_action_sink.gd`、`ai_agent.gd`、`ai_manager.gd`；
>   `ai_manager.gd` 已注册为 autoload `AiManager`（`dev_gd/nsoc/project.godot:33`）。
> - 场景/流程接入：`scripts/main.gd:_setup_ai_agents()`（帝国出征）、`scripts/test_main.gd:_setup_ai_agents()`
>   （非 PVP 的多盘 PVE 测试）、`scripts/core/turn_system.gd:_run_ai_phase_for_faction()`（回合时机）。
> - 与设计稿的主要差异（详见 §1、§5、§6、§7）：
>   ① 敌方资源装配落在**场景脚本**而非 `game_context.gd`，牌库为**硬编码基础牌库**（未实现 `level_data.boards[*].ai_deck`）；
>   ② AI 决策时机按阵营**分两次**插入（PLAYER 阶段前 / ENEMY 阶段前），并同时覆盖 `ROLE_ALLY` **友军盘**；
>   ③ **PVP 人机托管未落地**：`NetActionSink` 已写出但全工程无调用点；`AiAgent.on_cross_requested()` 亦未被
>      `turn_system` 调用，AI 单位跨盘仍走 `turn_system` 内置的随机选盘；
>   ④ §5 代码块是原始骨架，实装已补全算法，个别常量/签名有出入，已在对应处标注。
> 下文保留原始设计意图与决策讨论。

> 适用项目：`dev_gd/nsoc`（Godot 4 / GDScript）
> 目标：为**局内对战**引入统一的「敌方 AI」框架，同时服务 **PVE / 帝国出征**（`Main.tscn`）与 **PVP 人机托管**（`TestMain.tscn`）。
> 决策定位：**规则启发式为主，预留扩展接口**。
> AI 行动范围：**单位部署 + 法术施放 + 跨盘目标选择**（不含英雄技能 / 装备）。

---

## 1. 现状分析

### 1.1 三个对战入口

| 场景 | 脚本 | 模式 | 敌方现状 |
| --- | --- | --- | --- |
| `Main.tscn` | `scripts/main.gd` | PVE 战役章节 + 帝国出征 | **帝国出征**：`Main._setup_ai_agents()` 为每个敌方盘（含 `ROLE_ALLY` 友军盘）建独立 deck + mana + `AiAgent`（`main.gd:144,179-224`），敌方会摸牌出单位/法术；**战役章节不接 AI**（`_is_campaign` 为真时 `_setup_ai_agents` 直接 return，`main.gd:67-69,180-181`），仍由 `level_data.boards[*].initial_units` + `spawners`（填线宝宝）预置生成 |
| `TestMain.tscn` | `scripts/test_main.gd` | PVP 联机（1v1 / 1v3 / 3v3）+ 多盘 PVE 测试 | PVP 模式：敌方 = 真人，通过 `Net` 消息镜像到本端；**非 PVP（多盘 PVE 测试）模式**：`test_main.gd:181` 调 `_setup_ai_agents()`（`test_main.gd:232-275`）装配本地 AI，与 PVE 同构 |
| `EmpireTest.tscn` | `scripts/ui/empire_test.gd` | 帝国战略地图层 | 出征写入 `Game.pending_empire_battle` → 切 `Main.tscn` → `Game._bootstrap_empire()` 装配多盘战斗 |

**关键结论（已更新）**：本节写于实装前，当时确实没有任何「决策型 AI」。现在 **AI 已实装**：帝国出征与多盘 PVE 下敌方（以及 `ROLE_ALLY` 友军盘）拥有独立 `DeckManager`/`ManaSystem`，会主动摸牌、按费出单位与施法（`scripts/main.gd:_setup_ai_agents`、`scripts/test_main.gd:_setup_ai_agents`、`scripts/core/turn_system.gd:_run_ai_phase_for_faction`）。战役章节仍只靠 `turn_system` 自走棋移动 + spawner 填线。**AI 跨盘选盘**仍由 `turn_system` 的随机逻辑决定，未接 `AiStrategy.choose_cross_target`（详见 §1.2 末条）。

### 1.2 回合系统（`scripts/core/turn_system.gd`）

- PVE 单回合 `run()` 流程（`turn_system.gd:146-182`）：
  `Events 事件 → _run_ai_phase_for_faction(PLAYER) → _run_phase(PLAYER) → _run_spawn_phase → _run_ai_phase_for_faction(ENEMY) → _run_phase(ENEMY)`。
  - 两处 `_run_ai_phase_for_faction(faction)` 即新增的 AI 决策时机（AI 先出牌，再由随后的 `_run_phase` 自走棋推进）。
  - `ENEMY` 阶段只负责**已在盘上的敌方单位**自动移动 / 攻击 / 跨盘（`_iter_phase_cells` + `_process_cell`）。
- PVP 分阶段接口：
  - `run_pvp_phase(faction)`：只跑指定阵营一侧（1v1）。
  - `run_pvp_phase_for_slot(slot_id)`：只跑指定盘（1v3 / 3v3）。
- 跨盘选择相关 API（**AI 跨盘的天然挂钩**）：
  - `front_row_action_requested(cell)` 信号 + `resolve_front_row_selection(target_id)`（玩家 UI 路径）。
  - `_front_row_resolve` 回调（由场景注入，负责实际跨盘动作）。
  - `enqueue_cross_choice(payload)` / `consume_cross_choice(slot_id,row,col)`（远端镜像消费队列）。
  - 自走棋默认行为：**攻方 FACTION_ENEMY 单位到达 front_row 会自动跨盘**（PVE/1v1 无需 AI 介入即可推进）。
  - ⚠️ 实装差异：`AiAgent.on_cross_requested()` / `AiStrategy.choose_cross_target()` / `AiActionSink.submit_cross_choice()` 虽已实现，
    但 `turn_system` **未调用**。AI 友军盘跨盘在 `turn_system.gd:498-509` 用 `randi() % enemy_slots.size()` 随机选敌队盘；
    敌方（AI）单位跨盘在 `_enemy_auto_cross()`（`turn_system.gd:722-790`）同样是随机选目标盘。即 §4.3 / §6.2 的「AI 择盘」钩子尚未接线。

### 1.3 PVP 行动协议（**AI 注入点核心**）

玩家的每个原子行动都通过 `Net` 广播，远端镜像执行。这是一套天然的「行动抽象」，AI 只需扮演产出同样消息的代理即可：

| 消息 | 处理入口 | 语义 |
| --- | --- | --- |
| `action/play_card` | `PlayController.handle_remote_play_card(payload, caster_pid)` | 单位部署 / 法术施放 |
| `action/play_equip` | **无 `handle_remote_*` 方法**；由 `test_main._on_pvp_message()` 内联处理（`test_main.gd:1260-1268`，仅登记对手装备镜像实例供详情面板展示）（装备，本设计**不使用**） | 装备出牌 |
| `action/activate_equip` | `PlayController.handle_remote_activate_equip(payload)`（`play_controller.gd:293`） | 装备激活（**不使用**） |
| `action/end_turn` | `test_main._on_remote_end_turn()`（`test_main.gd:1283-1284`）→ `handle_remote_end_turn()` / `run_pvp_phase_for_slot()` | 结束回合 → 跑该侧单位行动 |
| `action/cross_board` | `test_main._on_pvp_message()` → `TurnSystem.enqueue_cross_choice(payload)`（`test_main.gd:1285-1288`） | 跨盘目标选择 |

`action/play_card` 的 payload 结构（见 `play_controller.gd:_pvp_broadcast_play_card`）：

```text
{
  "card_name": String,
  "card_type": "单位" | "法术" | "装备",
  "slot_id":   String,          # 落子盘 id
  # 多队伍 PVP：绝对坐标（与下方 row/col 二选一，不同时出现）
  "abs_row": int, "abs_col": int,
  # 1v1：本端坐标（接收方镜像翻转）
  "row": int, "col": int,
  # 法术镜像补充字段（按需）：result_atk / result_health / result_cleared
}
```

### 1.4 核心数据/状态接口（写骨架时复用）

- `Game`（autoload `game_context.gd`）：
  - `registry: BoardRegistry`、`turn: TurnSystem`、`deck/mana`（本地玩家别名）。
  - `decks: Dictionary` / `manas: Dictionary`（pid → 实例）、`get_deck(pid)` / `get_mana(pid)`。
  - 实装补充（`game_context.gd:214-234`）：`add_deck(pid)` / `add_mana(pid)`（不存在则创建并挂到 Game 下，命中本地 pid 时同步 `deck` / `mana` 别名）；
    以及 `deck_of_slot(slot)` / `mana_of_slot(slot)`（按 `slot.owner_player_id` 反查，空则回退本地）。AI 装配即用 `add_deck` / `add_mana`。
  - `is_pvp`、`pvp_action_order`、`pvp_active_player_id()`、`pvp_is_my_turn()`、`is_multi_team_pvp()`。
  - `get_card(name)`、`make_effect_context()`。
- `BoardRegistry`：`get_by_id`、`by_faction(faction)`、`by_role(role)`、`enemy_targets()`、`by_team`、`by_owner`、`adjacent_enemy_slots(pid,col)`、`sorted_by_x()`。
- `BoardSlot`：`FACTION_PLAYER=0 / FACTION_ENEMY=1`、`ROLE_MAIN_ENEMY=2 / ROLE_ENEMY=3`；字段 `board / hero / hero_resolver / spawners / spell_casters / team_id / owner_player_id / allow_player_deploy`。
- `BoardModel`：`ROWS / COLS`、`get_cell(Vector2(r,c))`、`grid_cells`、`front_row_of_slot(slot)`、`back_row_of_slot(slot)`、`find_adjacent_enemies(cell,for_enemy)`。
- `cell.set_card(cname, atk, hp, enemy=false, effects_in=[], owner_id="", p_origin="")`、`cell.clear_card()`、`cell.has_card`。
  （实装形参名为 `effects_in`，`cell.gd:159`；此外 `cell.origin` / `cell.owner_slot_id` / `cell.slot_id` 是死亡路由的关键字段。）
- `DeckManager`：`draw_card()`、`setup(cards)`、`send_to_graveyard`、`banish`、`get_deck_counts()`。
- `ManaSystem`：`can_spend(n)`、`spend(n)`、`gain(n)`、`start_new_turn()`、字段 `current / maximum`。

---

## 2. 设计目标与原则

1. **统一一套 AI 框架**：PVE 与 PVP 共用同一「决策层 + 行动抽象」，只在「行动落地方式」上分流。
2. **行动抽象对齐 PVP 协议**：AI 决策结果是一串与 `action/play_card`、`action/cross_board`、`action/end_turn` 同构的 `AiAction`，复用既有镜像 / 落子路径，避免引入第二套出牌逻辑。
3. **决策与执行解耦**：决策层（`AiStrategy`）只读快照、产出行动；执行层（`AiAgent` + `AiActionSink`）负责落地。可替换策略而不动执行。
4. **PVE 敌方补齐资源**：让敌方盘拥有独立 `DeckManager` + `ManaSystem`，AI 才能像玩家一样摸牌、按费出牌。
5. **最小侵入**：注入点集中在 `turn_system`（增设 AI 决策时机）、`game_context`（敌方资源装配）、场景脚本（注册 Agent）。
   → 实装调整：敌方资源装配改落在**场景脚本**（`main.gd` / `test_main.gd` 的 `_setup_ai_agents()`），
   `game_context.gd` 只提供 `add_deck()` / `add_mana()` 复用（详见 §6.1）。

---

## 3. 总体架构

```text
┌─────────────────────────────────────────────────────────────┐
│                        AiAgent (驱动层)                        │
│  持有：所属 slot 身份 / DeckManager / ManaSystem / Strategy   │
│  take_turn(): 摸牌 → 循环[决策→执行] → 结束                    │
└───────────────┬───────────────────────────┬──────────────────┘
                │ 读快照                      │ 应用行动
                ▼                            ▼
        ┌──────────────┐            ┌─────────────────────┐
        │ AiStrategy   │            │   AiActionSink      │
        │ (决策层/接口) │            │   (执行接口)        │
        │ HeuristicStrategy(默认)    │  LocalSink (PVE)    │
        │ → 产出 [AiAction]          │  NetSink   (PVP托管) │
        └──────────────┘            └─────────────────────┘
                                              │
                          ┌───────────────────┴────────────────┐
                          ▼                                     ▼
            PVE: 直接落子 enemy slot                 PVP: Net.send_to_room
            + Effects.trigger_play 本地执行          ("action/play_card"...)
            + turn_system 跨盘队列                    复用 handle_remote_* 镜像
```

### 3.1 模块职责

| 模块 | 文件（实际） | 职责 |
| --- | --- | --- |
| `AiAction` | `scripts/ai/ai_action.gd` | 行动数据载体（play_unit / play_spell / cross_board / end_turn） |
| `AiStrategy` | `scripts/ai/ai_strategy.gd` | 决策接口；输入只读快照，输出 `Array[AiAction]` |
| `HeuristicStrategy` | `scripts/ai/heuristic_strategy.gd` | 默认规则启发式实现 |
| `GameView` | `scripts/ai/game_view.gd` | 给策略层的只读棋局快照 + 查询工具（封装 registry / 手牌 / 费用） |
| `AiActionSink` | `scripts/ai/ai_action_sink.gd` | 行动落地接口 |
| `LocalActionSink` | `scripts/ai/local_action_sink.gd` | PVE：直接落子 + 本地跑效果 + 跨盘队列 |
| `NetActionSink` | `scripts/ai/net_action_sink.gd` | PVP 托管：复用 `Net` 广播协议 |
| `AiAgent` | `scripts/ai/ai_agent.gd` | 一个 AI 玩家的回合驱动器；绑定 slot + deck + mana + strategy + sink |

---

## 4. 决策策略（HeuristicStrategy）

启发式默认实现，目标是「能出就出、压前排、法术打高价值目标」。每条规则给出**评分**，按分排序贪心执行，直到费用耗尽或无可行动作。

### 4.1 单位部署
1. 候选：手牌中费用 ≤ 当前 mana 的单位牌；目标格 = 敌方盘空格。
2. 落点优先级（评分）：
   - 优先填**自家底线 / 前推列**（让单位下回合即可推进 / 跨盘）。
   - 优先补**前排空缺**（与敌方单位同列对位，争取先攻交换）。
   - 高攻单位放能最快接战的列；高血单位放需要顶线的列。
3. 费用规划：先出**高费大体型**（避免卡手），再用碎费补小怪填线。

### 4.2 法术施放
1. 候选：手牌法术牌（`CardSpell.target` 决定合法目标）。
2. 目标评分：
   - `enemy_unit` 伤害 / 控制类 → 选**威胁值最高**的玩家单位（攻高、含 charge/突围等关键词、或快到线的）。
   - `friendly_unit` 增益类 → 选**收益最大**的己方单位（前排、即将交战）。
   - 无目标（`""`）→ 直接施放。
3. 仅当「期望收益 ≥ 阈值」才出，避免无意义浪费（阈值可配置）。

### 4.3 跨盘目标选择
仅在多盘（帝国多线 / 1v3 / 3v3）且存在多个敌队盘时需要 AI 决策；PVE/1v1 单一敌方盘走 `turn_system` 既有自动跨盘逻辑。
- 评分：优先攻击**英雄血量最低**或**防守最空虚**的敌方盘；其次保持兵力集中（避免分散跨盘）。
- 落地：通过 `AiActionSink.cross_board(...)` →（PVE）`turn_system.enqueue_cross_choice` /（PVP）`Net action/cross_board`。
- ⚠️ **实装状态**：评分函数已落地为 `HeuristicStrategy.choose_cross_target()`（`score = -hero.health + (3 - 该盘单位数)`），
  `AiAction.Kind.CROSS_BOARD` 在 `LocalActionSink` / `NetActionSink` 中也有落地分支；
  但 `HeuristicStrategy.decide()` **不产出** CROSS_BOARD 行动，`turn_system` 也**不调用**该钩子
  ——实际跨盘选盘由 `turn_system` 的 `randi()` 完成（见 §1.2、§6.2）。

### 4.4 扩展接口预留
- `AiStrategy` 为抽象接口，`HeuristicStrategy` 仅为默认。后续可挂：
  - 难度参数（摸牌量 / 出牌激进度 / 故意失误率）。
  - 行为树 / 评分搜索 / MCTS 等替换实现。
- `AiAgent` 通过依赖注入接收 `strategy`，更换策略零成本。

---

## 5. 代码骨架

> 以下为**原始接口骨架**，方法体当时留 `# TODO` 或最小实现。
> **实装现状**：本节的 9 个文件已全部落地于 `scripts/ai/`，`# TODO` 均已补全为真实算法；实际签名/常量与骨架有少量出入，
> 已在各条目标注「实装差异」。其中 `NetActionSink` 与 `AiAgent.on_cross_requested()` 属**已写出但全工程无调用点**。

### 5.1 `scripts/ai/ai_action.gd`

```gdscript
class_name AiAction
extends RefCounted

enum Kind { PLAY_UNIT, PLAY_SPELL, CROSS_BOARD, END_TURN }

var kind: int = Kind.END_TURN
var card_name: String = ""          # PLAY_UNIT / PLAY_SPELL
var slot_id: String = ""            # 目标盘
var row: int = -1
var col: int = -1
var target_slot_id: String = ""     # CROSS_BOARD：进攻的敌方盘
var source_row: int = -1            # CROSS_BOARD：发起跨盘的单位坐标
var source_col: int = -1

static func play_unit(p_card: String, p_slot: String, p_row: int, p_col: int) -> AiAction:
    var a := AiAction.new()
    a.kind = Kind.PLAY_UNIT
    a.card_name = p_card; a.slot_id = p_slot; a.row = p_row; a.col = p_col
    return a

static func play_spell(p_card: String, p_slot: String, p_row: int, p_col: int) -> AiAction:
    var a := AiAction.new()
    a.kind = Kind.PLAY_SPELL
    a.card_name = p_card; a.slot_id = p_slot; a.row = p_row; a.col = p_col
    return a

static func cross_board(p_slot: String, p_row: int, p_col: int, p_target: String) -> AiAction:
    var a := AiAction.new()
    a.kind = Kind.CROSS_BOARD
    a.slot_id = p_slot; a.source_row = p_row; a.source_col = p_col
    a.target_slot_id = p_target
    return a

static func end_turn() -> AiAction:
    var a := AiAction.new(); a.kind = Kind.END_TURN; return a
```

> 实装：`ai_action.gd`（45 行）与骨架完全一致——同样的 `Kind` 枚举与 4 个静态构造器。

### 5.2 `scripts/ai/game_view.gd`（只读快照）

```gdscript
class_name AiGameView
extends RefCounted

# 封装给策略层的只读查询，避免策略直接耦合 registry 细节。
var _ai_slot_id: String
var _deck: DeckManager
var _mana: ManaSystem

func setup(ai_slot_id: String, deck: DeckManager, mana: ManaSystem) -> void:
    _ai_slot_id = ai_slot_id
    _deck = deck
    _mana = mana

func current_mana() -> int:
    return _mana.current if _mana != null else 0

# AI 当前可用的「手牌」。PVE 敌方没有 UI 手牌，这里用一只虚拟手牌缓冲（见 AiAgent）。
func hand_cards() -> Array:        # Array[CardBase]
    return _hand

func own_slot() -> BoardSlot:
    return Game.registry.get_by_id(_ai_slot_id)   # 实装：先判 /root/Game 与 Game.registry 非空，再做查询

# 敌对（玩家）盘集合：从 AI 视角找出对手盘
func opponent_slots() -> Array:    # Array[BoardSlot]
    # 实装（game_view.gd:28-38）：遍历 Game.registry.slots，取 faction != own.faction 的盘
    # 注意：按 faction 判定，未使用 team_id（多队伍 PVP 不参与 AI）
    var out: Array = []
    for s in Game.registry.slots:
        if s.faction != own.faction:
            out.append(s)
    return out

func empty_cells_of(slot: BoardSlot) -> Array:   # Array[cell]
    var out: Array = []
    if slot == null or slot.board == null:
        return out
    for c in slot.board.grid_cells.values():
        if is_instance_valid(c) and not c.has_card:
            out.append(c)
    return out

# 威胁值评估：单位攻、关键词、距离己方英雄行数
func threat_of(cell) -> float:
    # 实装（game_view.gd:64-76）：attack + 关键词权重
    #   charge / assault_charge / breakout +3.0；steadfast / vigilance +1.5；flood_strategy_unit / awe +4.0
    var score: float = float(cell.attack)
    for eff in cell.effects:
        match String(eff):
            "charge", "assault_charge", "breakout": score += 3.0
            "steadfast", "vigilance":            score += 1.5
            "flood_strategy_unit", "awe":        score += 4.0
    return score

var _hand: Array = []
func set_hand(cards: Array) -> void:
    _hand = cards
```

> 实装追加（骨架未列）：`is_own_unit(cell)` / `is_target_unit(cell)`——从本 AI 视角按
> `own.faction == BoardSlot.FACTION_ENEMY` 与 `cell.is_enemy` 的异同判断敌我（`game_view.gd:49-61`）。

### 5.3 `scripts/ai/ai_strategy.gd`（决策接口）+ 默认实现

```gdscript
class_name AiStrategy
extends RefCounted

# 输入只读快照，产出按执行顺序排列的行动序列（末尾隐含 END_TURN，可省略）。
# 实装（ai_strategy.gd:5-11）：默认返回 [AiAction.end_turn()]，并含默认 choose_cross_target()
func decide(view: AiGameView) -> Array:   # Array[AiAction]
    return [AiAction.end_turn()]
```

```gdscript
class_name HeuristicStrategy
extends AiStrategy

# 可调参数（后续做难度时外部注入）
var spell_value_threshold: float = 1.0
# 实装差异：骨架中的 prefer_front_row 未实现（无此字段）；落点偏好改由 _best_deploy_cell 内部评分决定

func decide(view: AiGameView) -> Array:
    var actions: Array = []
    var mana_left: int = view.current_mana()
    var own := view.own_slot()
    if own == null:
        # 实装：返回 [AiAction.end_turn()]（heuristic_strategy.gd:10-11），非空数组
        return actions

    # 1) 法术：高价值目标优先（在部署前评估，避免目标被自己挤占）
    #    实装差异（heuristic_strategy.gd:13-30）：仅当 mana_left >= 2 才进入本段；
    #    新增 targeted_cells 去重（两张箭不打同一目标）；目标坐标直接取 tgt.row / tgt.col / tgt.slot_id。
    var targeted_cells: Array = []
    if mana_left >= 2:
        for card in _spells_sorted(view):
            if mana_left < card.cost:
                continue
            var tgt = _best_spell_target(view, card, targeted_cells)
            if tgt == null and String(card.target) != "":
                continue
            if _spell_value(view, card, tgt) < spell_value_threshold:
                continue
            actions.append(AiAction.play_spell(card.name,
                String(tgt.slot_id) if tgt != null else own.id,
                tgt.row if tgt != null else -1,
                tgt.col if tgt != null else -1))
            if tgt != null:
                targeted_cells.append(tgt)
            mana_left -= card.cost

    # 2) 单位部署：高费优先，按落点评分贪心
    #    实装差异（heuristic_strategy.gd:32-44）：额外回传 placed_cols / placed_cells，供同回合内去重
    var placed_cols: Array = []
    var placed_cells: Array = []
    for card in _units_sorted_by_cost_desc(view):
        if mana_left < card.cost:
            continue
        var cell = _best_deploy_cell(view, card, own, placed_cols, placed_cells)
        if cell == null:
            continue
        actions.append(AiAction.play_unit(card.name, own.id, cell.row, cell.col))
        placed_cols.append(cell.col)
        placed_cells.append(cell)
        mana_left -= card.cost

    # 3) 实装新增（heuristic_strategy.gd:46-61）：剩余 >= 1 费时补一张法术，只补一张后 break
    actions.append(AiAction.end_turn())
    return actions

# 跨盘单点决策：由 AiAgent 在 turn_system 询问时即时调用
# 实装（heuristic_strategy.gd:66-84）：对手盘得分 score = -hero.health + (3 - 该盘单位数)，取最高分盘 id。
# ⚠️ 但 turn_system 目前并未调用该钩子（见 §1.2 末条），AI 跨盘仍走随机选盘。
func choose_cross_target(view: AiGameView, cell) -> String:
    var best_id := ""
    var best_score := -INF
    for s in view.opponent_slots():
        if not is_instance_valid(s):
            continue
        var hp: float = float(s.hero.health) if s.hero != null else 9999.0
        var unit_count: int = 0
        if s.board != null:
            for c in s.board.grid_cells.values():
                if is_instance_valid(c) and c.has_card:
                    unit_count += 1
        var score: float = -hp + float(3 - unit_count)
        if score > best_score:
            best_score = score; best_id = s.id
    return best_id

# ── 内部评分（骨架当时为 TODO，实装均已补全）────────────────
# 实装签名（heuristic_strategy.gd:88-230）：
#   _spells_sorted(view) / _units_sorted_by_cost_desc(view)              → 按 cost 降序排序手牌
#   _best_spell_target(view, card, excluded)                             → 按 card.target 分支（""/enemy_unit/friendly_unit/any_unit）
#   _spell_value(view, card, tgt)                                        → tgt==null 时 2.0，否则 threat_of(tgt) + 0.5
#   _best_deploy_cell(view, card, own_slot, placed_cols, placed_cells)    → 行流水线 + 前排加成 + 净空列 + 列分散 + 同列惩罚
#   _most_advanced_target(view, excluded) / _best_own_unit(view)          → 目标筛选辅助；后者用 owner_slot_id 识别已跨盘单位
# 骨架中的 _cross_score / _slot_of / _row_of / _col_of 未实装（逻辑已内联或改用 cell.row / cell.col / cell.slot_id）。
```

### 5.4 `scripts/ai/ai_action_sink.gd` + 两个实现

```gdscript
class_name AiActionSink
extends RefCounted

# 落地一个行动。返回是否成功执行（用于 Agent 决定是否继续）。
func apply(_action: AiAction) -> bool:
    return false

# 跨盘即时询问的落地（turn_system 走到 AI 单位 front_row 时调用）
func submit_cross_choice(_slot_id: String, _row: int, _col: int, _target_slot_id: String) -> void:
    pass
```

```gdscript
class_name LocalActionSink   # PVE / 帝国出征
extends AiActionSink

# 实装新增（local_action_sink.gd:12-15）：装配入口
#   setup(p_slot_id, p_root = null, p_source_node = null)
#   _slot_id 用于落子 + 路由墓地；_root / _source_node 用于飞牌动画（FLY_DURATION = 1.2s）

# 直接在本端把单位 / 法术落到敌方盘，复用与 handle_remote_play_card 相同的落子路径。
# 实装（local_action_sink.gd:17-26）：PLAY_UNIT / PLAY_SPELL 分支均 `await`（协程），CROSS_BOARD 走 _enqueue_cross。
func apply(action: AiAction) -> bool:
    match action.kind:
        AiAction.Kind.PLAY_UNIT:
            return await _place_unit(action)
        AiAction.Kind.PLAY_SPELL:
            return await _cast_spell(action)
        AiAction.Kind.CROSS_BOARD:
            Game.turn.enqueue_cross_choice({
                "source_slot_id": action.slot_id,
                "row": action.source_row, "col": action.source_col,
                "target_slot_id": action.target_slot_id,
            })
            return true
        _:
            return true

# 实装（local_action_sink.gd:28-33）：先判 /root/Game 存在再入队。
# ⚠️ 该接口全工程无调用点（turn_system 未在 AI 单位跨盘时回调 sink）。
func submit_cross_choice(slot_id: String, row: int, col: int, target_slot_id: String) -> void:
    Game.turn.enqueue_cross_choice({
        "source_slot_id": slot_id, "row": row, "col": col,
        "target_slot_id": target_slot_id,
    })

func _place_unit(action: AiAction) -> bool:
    # 实装（local_action_sink.gd:37-58）：
    if not Engine.get_main_loop().root.has_node("/root/Game") or Game.registry == null:
        return false
    var slot: BoardSlot = Game.registry.get_by_id(action.slot_id)
    if slot == null or slot.board == null:
        return false
    var cell = slot.board.get_cell(Vector2(action.row, action.col))
    if cell == null or cell.has_card:
        return false
    var card = Game.get_card(action.card_name)
    if card == null:
        return false
    await _animate_card_to_cell(action.card_name, cell)      # 实装新增：AI 英雄面板 → 目标格飞牌动画
    # 实装差异：is_enemy 由**盘阵营**决定（敌方盘 true / 友军盘 false），骨架固定写 true；
    # 且直接传 card.effects（未 duplicate）。origin="hand" 保证死亡入 AI 牌库墓地。
    var place_as_enemy: bool = (slot.faction == BoardSlot.FACTION_ENEMY)
    cell.set_card(action.card_name, card.attack, card.health, place_as_enemy, card.effects, "", "hand")
    cell.owner_slot_id = slot.id
    var ctx := Game.make_effect_context()
    ctx.target_cell = cell
    for eff in card.effects:
        await Effects.trigger_play(String(eff), card, ctx)   # 注意 await，Agent 需配合
    return true

func _cast_spell(action: AiAction) -> bool:
    # 实装（local_action_sink.gd:60-95）——骨架的 TODO 已完成：
    #   取 action.slot_id + (row,col) 的目标格 → 播飞牌动画 → 若动画期间目标格已空且 card.target != "" 则放弃施法直接入 AI 墓地；
    #   否则 make_effect_context()（ctx.caster_is_enemy 按施法盘阵营）→ Effects.resolve_destination 决定去处 →
    #   Effects.trigger_play → 按 destination 入 ai_deck.banish / send_to_graveyard。
    #   AI 墓地由 _get_ai_deck() 经 slot.owner_player_id → Game.get_deck(pid) 取得。
    return true
```

```gdscript
class_name NetActionSink   # PVP 人机托管（AI 扮演某 pid；实装文件头注释仍标注「P5 阶段实现」）
extends AiActionSink

var pid: String = ""   # AI 所扮演的玩家 uuid

func apply(action: AiAction) -> bool:
    match action.kind:
        AiAction.Kind.PLAY_UNIT, AiAction.Kind.PLAY_SPELL:
            var payload := {
                "card_name": action.card_name,
                "card_type": "单位" if action.kind == AiAction.Kind.PLAY_UNIT else "法术",
                "slot_id": action.slot_id,
                "abs_row": action.row, "abs_col": action.col,
            }
            Net.send_to_room("action/play_card", Game.pvp_room_id, payload, "all")
            return true
        AiAction.Kind.CROSS_BOARD:
            Net.send_to_room("action/cross_board", Game.pvp_room_id, {
                "source_slot_id": action.slot_id,
                "row": action.source_row, "col": action.source_col,
                "target_slot_id": action.target_slot_id,
            }, "all")
            return true
        AiAction.Kind.END_TURN:
            Net.send_to_room("action/end_turn", Game.pvp_room_id, {
                "player_id": pid, "turn_number": Game.turn.turn_number,
            }, "all")
            return true
    return false
```

> 实装状态：`net_action_sink.gd`（33 行）与骨架**逐行一致并已写出**，但**全工程没有任何注册/调用点**
> （`main.gd` / `test_main.gd` 均只 new `LocalActionSink`）。§6.3 的 PVP 托管因此**未落地**。

### 5.5 `scripts/ai/ai_agent.gd`（驱动层）

```gdscript
class_name AiAgent
extends Node

var slot_id: String = ""
var deck: DeckManager = null
var mana: ManaSystem = null
var strategy: AiStrategy = null
var sink: AiActionSink = null
var view: AiGameView = null

const DRAW_PER_TURN: int = 1
const STEP_DELAY: float = 0.3       # 实装为 0.3（骨架写 0.35）；出牌间隔，给玩家观察节奏
const MAX_HAND_SIZE: int = 5        # 实装新增：手牌缓冲上限

func setup(p_slot_id: String, p_deck: DeckManager, p_mana: ManaSystem,
        p_strategy: AiStrategy, p_sink: AiActionSink) -> void:
    slot_id = p_slot_id
    deck = p_deck
    mana = p_mana
    strategy = p_strategy
    sink = p_sink
    view = AiGameView.new()
    view.setup(slot_id, deck, mana)

# 一个 AI 回合：摸牌 → 决策 → 顺序执行。由 turn_system 在对应阵营阶段前调用。
# 实装（ai_agent.gd:28-57）：Agent 在 apply 前先扣费并移除手牌；`await sink.apply(action)`
# 统一 await 协程；apply 失败时**回滚费用（mana.gain）并把牌塞回手牌缓冲**；
# 每步检查 is_inside_tree()（场景切换时 Agent 可能先于动画结束被销毁）；
# 成功路径才 sleep STEP_DELAY。
func take_turn() -> void:
    _draw(DRAW_PER_TURN)
    view.set_hand(_current_hand())
    var actions: Array = strategy.decide(view)
    for action in actions:
        if not is_inside_tree():
            break
        if action.kind == AiAction.Kind.END_TURN:
            break
        var cost: int = 0
        if action.card_name != "":
            cost = _cost_of(action.card_name)
            if not mana.can_spend(cost):
                continue
            mana.spend(cost)
            _remove_from_hand(action.card_name)
        var ok = await sink.apply(action)
        if not is_inside_tree():
            break
        if not ok and action.card_name != "":
            mana.gain(cost)                     # 回滚费用
            var refund_card = Game.get_card(action.card_name)
            if refund_card != null:
                _hand_buf.append(refund_card)   # 回滚手牌
        else:
            await get_tree().create_timer(STEP_DELAY).timeout
            if not is_inside_tree():
                break

# 跨盘即时回调：turn_system 走到本 AI 单位 front_row 时调用
# ⚠️ 实装状态：方法已实现，但 turn_system **从未调用**（AI 跨盘走 randi() 随机选盘，见 §1.2）。
func on_cross_requested(cell) -> String:
    return strategy.choose_cross_target(view, cell)

# ── 手牌缓冲（PVE 敌方没有 UI 手牌，用内存数组模拟）──────────
var _hand_buf: Array = []
func _draw(n: int) -> void:
    # 实装（ai_agent.gd:65-71）：摸到 MAX_HAND_SIZE(5) 即停
    for _i in range(n):
        if _hand_buf.size() >= MAX_HAND_SIZE:
            break
        var c = deck.draw_card()
        if c != null:
            _hand_buf.append(c)
func _current_hand() -> Array: return _hand_buf.duplicate()
func _remove_from_hand(name: String) -> void:
    for i in range(_hand_buf.size()):
        if _hand_buf[i].name == name:
            _hand_buf.remove_at(i); return
func _cost_of(name: String) -> int:
    var c = Game.get_card(name); return int(c.cost) if c != null else 0
```

> 实装文件本体为 84 行；`ai_agent.gd` 与骨架同类的接口（`setup` / `take_turn` / `on_cross_requested` /
> `_draw` / `_current_hand` / `_remove_from_hand` / `_cost_of`）一致，差异集中在上面标注的常量与
> 失败回滚、`is_inside_tree()` 存活检查。

---

## 6. 注入点与改动清单

### 6.1 给 PVE 敌方装配 Deck + Mana —— ✅ 已落地（位置在**场景脚本**，不是 `game_context.gd`）
实装位置：`scripts/main.gd:_setup_ai_agents(is_campaign)`（`main.gd:179-224`，由 `main.gd:144` 调用）与
`scripts/test_main.gd:_setup_ai_agents()`（`test_main.gd:232-275`，由 `test_main.gd:181` 在非 PVP 分支调用）。流程：
- 遍历 `Game.registry.slots`，命中条件为 `faction == FACTION_ENEMY` **或**（`faction == FACTION_PLAYER` 且 `role == ROLE_ALLY`）
  ——**友军盘也接 AI**，骨架只写了敌方盘；
- `ai_pid = "ai_" + slot.id`，写回 `slot.owner_player_id = ai_pid`；
- `Game.add_deck(ai_pid)` / `Game.add_mana(ai_pid)`（`game_context.gd:214-234`，即存入 `decks` / `manas` 字典）；
- `ai_deck.setup(ai_proto_cards.duplicate())`；`ai_mana.setup(1, 5)`（cap=5，避免后期爆费）；
- 建 `LocalActionSink`（注入场景为 root、英雄面板为动画源）+ `AiAgent`（`add_child` 到场景）+ `AiManager.register(slot_id, agent)`；
- 场景 `_exit_tree()` 调 `AiManager.clear()`（`main.gd:226-227`、`test_main.gd:277-278`）。

与设计的差异（**未落地**部分）：
- 牌库**硬编码**为 `填线宝宝 ×5 / 放箭 ×5 / 鼓舞 ×5`（从 `Game.card_db` 取，空则 `push_warning` 后不建 Agent）；
  **未实现** `level_data.boards[*].ai_deck` 字段，也**不是**由出征目标的「守军配置」决定；
- **战役章节不接 AI**：`main.gd:180-181` 在 `Game.is_pvp or _is_campaign` 时直接 return（`_is_campaign` 定义见 `main.gd:67-69`）。

### 6.2 在 ENEMY 阶段前插入「AI 决策时机」（`turn_system.gd`）—— ✅ 已落地（接口名与位置和设计不同）
- 实装接口是 `_run_ai_phase_for_faction(faction: int)`（`turn_system.gd:900-921`），**不是** `_run_ai_deploy_phase()`；
  且**按阵营调用两次**：`run()` 中 `_run_ai_phase_for_faction(FACTION_PLAYER)` 在 `_run_phase(PLAYER)` 之前、
  `_run_ai_phase_for_faction(FACTION_ENEMY)` 在 `_run_spawn_phase()` 之后 / `_run_phase(ENEMY)` 之前（`turn_system.gd:154,166`）。
  → AI 友军盘与敌方盘同回合「先出牌、再行动」，比设计稿多覆盖了 PLAYER 阵营。
- 函数内部：`AiManager.all_agents()` 逐个过滤 `slot.faction == faction`，先 `agent.mana.start_new_turn()`，再 `await agent.take_turn()`，
  每步检查 `_combat.aborted`（`turn_system.gd:909-921`）。`Game.is_pvp` 时整段跳过。
- AI 出的单位落在盘上后，随即由既有 `PLAYER` / `ENEMY` 阶段自走棋逻辑移动 / 攻击 / 跨盘 → **零额外移动 AI**（与设计一致）。
- ⚠️ **跨盘即时询问未接线**：设计中的「把 `_front_row_resolve` 对 AI 单位的分支接到 `agent.on_cross_requested(cell)`」**没有实现**。
  实际是 `turn_system.gd:498-509` 对 AI 友军盘用 `randi() % enemy_slots.size()` 随机选目标盘；
  敌方 AI 单位跨盘走 `_enemy_auto_cross()`（`turn_system.gd:722-790`），内部同样 `randi()` 随机选候选。

### 6.3 PVP 托管（`test_main.gd`）—— ❌ **未落地**
- `NetActionSink` 已写出（`scripts/ai/net_action_sink.gd`）但**全工程无注册/调用点**；
- `test_main.gd:177-181` 只在 `else`（非 PVP）分支调 `_setup_ai_agents()`，PVP 分支走真人 `Net` 镜像；
- 因此「真人掉线托管 / 纯人机 PVP 房间」目前**没有实现**，`Game.pvp_active_player_id()` 也不参与任何 AI 触发。
- 设计意图（房主侧跑 AI、其余复用 `_on_pvp_message` / `handle_remote_*`）保留，作为后续阶段。

### 6.4 AI 注册中心 —— ✅ 已落地（autoload `AiManager`）
- `scripts/ai/ai_manager.gd`（26 行，无 `class_name`）已注册为 autoload：`project.godot:33` → `AiManager="*res://scripts/ai/ai_manager.gd"`；
- 接口：`register(slot_id, agent)` / `get_agent(slot_id)` / `all_agents()`（过滤已 free 节点）/ `is_ai_slot(slot_id)` / `clear()`；
- `turn_system` 通过 `has_node("/root/AiManager")` + `AiManager.is_ai_slot(slot.id)` / `all_agents()` 查询，未硬编码 AI 引用（符合设计目标）。

---

## 7. 分期落地计划

| 阶段 | 内容 | 验收 | 实装状态 |
| --- | --- | --- | --- |
| P0 | 建 `scripts/ai/` 骨架（本文件 5.x 全部接口，方法 TODO） | 编译通过、无业务逻辑 | ✅ 已完成并已补全算法 |
| P1 | PVE 敌方 Deck+Mana 装配 + `AiManager` 注册 | 敌方盘有牌库 / 费用，可被查询 | ✅ 已完成（装配落在 `main.gd` / `test_main.gd`，非 `game_context.gd`；牌库硬编码） |
| P2 | `turn_system` 接入 AI 决策阶段 + `LocalActionSink` 单位部署 | 帝国出征中敌方会主动出单位 | ✅ 已完成（`_run_ai_phase_for_faction`，且覆盖友军盘） |
| P3 | `HeuristicStrategy` 单位评分 + 法术施放（`_cast_spell`） | 敌方会按费贪心铺场、合理施法 | ✅ 已完成（评分含行流水线 / 净空列 / 列分散；`_cast_spell` 含目标失效与墓地/除外路由） |
| P4 | 跨盘目标选择（多盘）接 `on_cross_requested` | 多线战斗 AI 会择盘进攻 | ⚠️ **部分**：`HeuristicStrategy.choose_cross_target()` 已实现，但 `turn_system` **未调用**，实际跨盘仍 `randi()` 随机选盘 |
| P5 | `NetActionSink` + PVP 托管接入 | 人机 PVP / 掉线托管可用 | ❌ **未落地**：sink 已写出，但无注册/调用点；`test_main` PVP 分支不建 AI |
| P6 | 难度参数化、策略可替换接口完善 | 可配置强度 / 可换策略实现 | ⚠️ **部分**：依赖注入可换策略已具备（`AiAgent.setup(..., strategy, sink)`）；难度参数（摸牌量 / 激进度 / 失误率）未实现，仅剩 `spell_value_threshold` |

---

## 8. 风险与注意事项

1. **`set_card` 与 effect 的 `await`**：`LocalActionSink._place_unit` 中 `Effects.trigger_play` 是异步，`AiAgent.take_turn` 必须 `await`，否则出牌动画 / 入场效果会错乱。骨架中 `apply` 的同步/异步返回需统一约定（建议 `apply` 一律为协程，Agent 一律 `await`）。
   → **已解决**：`AiActionSink` 注释即约定「调用方统一 await」（`ai_action_sink.gd:4`），`LocalActionSink.apply` 对单位/法术分支 `await`，`AiAgent.take_turn` 用 `var ok = await sink.apply(action)`（`ai_agent.gd:44`）。
2. **死亡去向**：AI 单位用 `origin="hand"` 落子，死亡应入 **AI 自己的牌库墓地**，而非盘墓地。需确认 `handle_unit_death` 对敌方 `origin="hand"` 的路由（当前按 `Game.deck` 走本地玩家牌库，多实例下要改成按 `owner` 取对应 deck）。
   → **已解决**：`PlayController.handle_unit_death`（`play_controller.gd:516-527`）对 `origin == "hand"` 改为按 `_resolve_owner_slot(cell)` → `owner_slot.owner_player_id` → `Game.decks.get(pid)` 入对应 deck 墓地；仅无归属时才兜底到本地 `Game.deck`。AI 落子时写入了 `cell.owner_slot_id = slot.id`。
3. **费用扣减一致性**：PVE 由 `AiAgent` 直接扣 `mana`；PVP 托管由 `NetActionSink` 广播，费用扣减发生在镜像端 `handle_remote_*`，两条路径不要重复扣。
   → **PVE 路径已落地**（`ai_agent.gd:37-53`，且 apply 失败会 `mana.gain(cost)` 回滚）；**PVP 路径未落地**（`NetActionSink` 无调用点），该一致性风险暂时不存在。
4. **节奏控制**：`STEP_DELAY` 决定敌方出牌观感；过快玩家看不清，过慢拖沓。
   → **已定值**：`AiAgent.STEP_DELAY = 0.3`（`ai_agent.gd:12`，设计稿写 0.35），且仅在 `apply` 成功时 sleep；另有飞牌动画常量 `LocalActionSink.FLY_DURATION = 1.2`（`local_action_sink.gd:10`）。
5. **跨盘队列时序**：PVE 用 `enqueue_cross_choice` 必须在该单位行动**之前**入队（在 `take_turn` 阶段预判，或用即时回调 `on_cross_requested`）。
   → **当前不适用**：`on_cross_requested` 与 `submit_cross_choice` 均无调用点；AI 跨盘由 `turn_system` 在单位行动当刻用 `randi()` 现场选盘，无需预入队。
6. **法术目标合法性**：`HeuristicStrategy._best_spell_target` 必须复用 `PlayController._spell_target_valid` 的同款规则（friendly/enemy/any），避免 AI 出非法目标导致镜像端拒绝。
7. **确定性**：PVP 双端镜像依赖一致状态，AI 决策只应在「行动方本端」执行一次并广播，**不可双端各自决策**。

---

## 9. 目录结构建议 —— ✅ 已按此结构实装

实际文件与行数（`dev_gd/nsoc/scripts/ai/`，共 9 个文件，均已存在）：

```text
dev_gd/nsoc/scripts/ai/
├── ai_action.gd            # 行动数据（45 行）
├── ai_strategy.gd          # 决策接口（11 行）
├── heuristic_strategy.gd   # 默认规则启发式（230 行）
├── game_view.gd            # 只读棋局快照（77 行）
├── ai_action_sink.gd       # 执行接口（9 行）
├── local_action_sink.gd    # PVE 落地（170 行，含飞牌动画）
├── net_action_sink.gd      # PVP 托管落地（33 行，已写出但无调用点）
├── ai_agent.gd             # 单 AI 回合驱动（84 行）
└── ai_manager.gd           # AI 注册中心（26 行，已注册为 autoload "AiManager"）
```

> 差异：`ai_manager.gd` 不再是「可选 autoload」，而是**已实装 autoload**（`dev_gd/nsoc/project.godot:33`）。
