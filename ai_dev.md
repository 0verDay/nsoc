# 敌方 AI 接入设计文档（ai_dev.md）

> 适用项目：`dev_gd/nsoc`（Godot 4 / GDScript）
> 目标：为**局内对战**引入统一的「敌方 AI」框架，同时服务 **PVE / 帝国出征**（`Main.tscn`）与 **PVP 人机托管**（`TestMain.tscn`）。
> 决策定位：**规则启发式为主，预留扩展接口**。
> AI 行动范围：**单位部署 + 法术施放 + 跨盘目标选择**（不含英雄技能 / 装备）。

---

## 1. 现状分析

### 1.1 三个对战入口

| 场景 | 脚本 | 模式 | 敌方现状 |
| --- | --- | --- | --- |
| `Main.tscn` | `scripts/main.gd` | PVE 战役章节 + 帝国出征 | 敌方单位由 `level_data.boards[*].initial_units` + `spawners`（填线宝宝）预置生成；敌方英雄 hp 占位（帝国模式固定 10）、**无手牌、无费用、无决策** |
| `TestMain.tscn` | `scripts/test_main.gd` | PVP 联机（1v1 / 1v3 / 3v3）+ 多盘 PVE 测试 | 敌方 = 真人，通过 `Net` 消息镜像到本端 |
| `EmpireTest.tscn` | `scripts/ui/empire_test.gd` | 帝国战略地图层 | 出征写入 `Game.pending_empire_battle` → 切 `Main.tscn` → `Game._bootstrap_empire()` 装配多盘战斗 |

**关键结论**：当前没有任何「决策型 AI」。PVE 敌方仅靠 `turn_system` 的自走棋移动逻辑 + spawner 填线，不会主动从牌库出牌、施法或选择跨盘目标。

### 1.2 回合系统（`scripts/core/turn_system.gd`）

- PVE 单回合 `run()` 流程：`PLAYER 阶段 → _run_spawn_phase → ENEMY 阶段`。
  - `ENEMY` 阶段只负责**已在盘上的敌方单位**自动移动 / 攻击 / 跨盘（`_iter_phase_cells` + `_process_cell`）。
- PVP 分阶段接口：
  - `run_pvp_phase(faction)`：只跑指定阵营一侧（1v1）。
  - `run_pvp_phase_for_slot(slot_id)`：只跑指定盘（1v3 / 3v3）。
- 跨盘选择相关 API（**AI 跨盘的天然挂钩**）：
  - `front_row_action_requested(cell)` 信号 + `resolve_front_row_selection(target_id)`（玩家 UI 路径）。
  - `_front_row_resolve` 回调（由场景注入，负责实际跨盘动作）。
  - `enqueue_cross_choice(payload)` / `consume_cross_choice(slot_id,row,col)`（远端镜像消费队列）。
  - 自走棋默认行为：**攻方 FACTION_ENEMY 单位到达 front_row 会自动跨盘**（PVE/1v1 无需 AI 介入即可推进）。

### 1.3 PVP 行动协议（**AI 注入点核心**）

玩家的每个原子行动都通过 `Net` 广播，远端镜像执行。这是一套天然的「行动抽象」，AI 只需扮演产出同样消息的代理即可：

| 消息 | 处理入口 | 语义 |
| --- | --- | --- |
| `action/play_card` | `PlayController.handle_remote_play_card(payload, caster_pid)` | 单位部署 / 法术施放 |
| `action/play_equip` | `handle_remote_*`（装备，本设计**不使用**） | 装备出牌 |
| `action/activate_equip` | `PlayController.handle_remote_activate_equip` | 装备激活（**不使用**） |
| `action/end_turn` | `handle_remote_end_turn()` / `run_pvp_phase_for_slot()` | 结束回合 → 跑该侧单位行动 |
| `action/cross_board` | `TurnSystem.enqueue_cross_choice()` | 跨盘目标选择 |

`action/play_card` 的 payload 结构（见 `play_controller.gd:_pvp_broadcast_play_card`）：

```text
{
  "card_name": String,
  "card_type": "单位" | "法术" | "装备",
  "slot_id":   String,          # 落子盘 id
  # 多队伍 PVP：绝对坐标
  "abs_row": int, "abs_col": int,
  # 1v1：本端坐标（接收方镜像翻转）
  "row": int, "col": int,
}
```

### 1.4 核心数据/状态接口（写骨架时复用）

- `Game`（autoload `game_context.gd`）：
  - `registry: BoardRegistry`、`turn: TurnSystem`、`deck/mana`（本地玩家别名）。
  - `decks: Dictionary` / `manas: Dictionary`（pid → 实例）、`get_deck(pid)` / `get_mana(pid)`。
  - `is_pvp`、`pvp_action_order`、`pvp_active_player_id()`、`pvp_is_my_turn()`、`is_multi_team_pvp()`。
  - `get_card(name)`、`make_effect_context()`。
- `BoardRegistry`：`get_by_id`、`by_faction(faction)`、`by_role(role)`、`enemy_targets()`、`by_team`、`by_owner`、`adjacent_enemy_slots(pid,col)`、`sorted_by_x()`。
- `BoardSlot`：`FACTION_PLAYER=0 / FACTION_ENEMY=1`、`ROLE_MAIN_ENEMY=2 / ROLE_ENEMY=3`；字段 `board / hero / hero_resolver / spawners / spell_casters / team_id / owner_player_id / allow_player_deploy`。
- `BoardModel`：`ROWS / COLS`、`get_cell(Vector2(r,c))`、`grid_cells`、`front_row_of_slot(slot)`、`back_row_of_slot(slot)`、`find_adjacent_enemies(cell,for_enemy)`。
- `cell.set_card(cname, atk, hp, enemy=false, effects=[], owner_id="", p_origin="")`、`cell.clear_card()`、`cell.has_card`。
- `DeckManager`：`draw_card()`、`setup(cards)`、`send_to_graveyard`、`banish`、`get_deck_counts()`。
- `ManaSystem`：`can_spend(n)`、`spend(n)`、`gain(n)`、`start_new_turn()`、字段 `current / maximum`。

---

## 2. 设计目标与原则

1. **统一一套 AI 框架**：PVE 与 PVP 共用同一「决策层 + 行动抽象」，只在「行动落地方式」上分流。
2. **行动抽象对齐 PVP 协议**：AI 决策结果是一串与 `action/play_card`、`action/cross_board`、`action/end_turn` 同构的 `AiAction`，复用既有镜像 / 落子路径，避免引入第二套出牌逻辑。
3. **决策与执行解耦**：决策层（`AiStrategy`）只读快照、产出行动；执行层（`AiAgent` + `AiActionSink`）负责落地。可替换策略而不动执行。
4. **PVE 敌方补齐资源**：让敌方盘拥有独立 `DeckManager` + `ManaSystem`，AI 才能像玩家一样摸牌、按费出牌。
5. **最小侵入**：注入点集中在 `turn_system`（增设 AI 决策时机）、`game_context`（敌方资源装配）、场景脚本（注册 Agent）。

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

| 模块 | 文件（建议） | 职责 |
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

### 4.4 扩展接口预留
- `AiStrategy` 为抽象接口，`HeuristicStrategy` 仅为默认。后续可挂：
  - 难度参数（摸牌量 / 出牌激进度 / 故意失误率）。
  - 行为树 / 评分搜索 / MCTS 等替换实现。
- `AiAgent` 通过依赖注入接收 `strategy`，更换策略零成本。

---

## 5. 代码骨架

> 以下为**接口骨架**，方法体留 `# TODO` 或最小实现。实际落地时按本项目风格（薄装配 + 注册表）补全。

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
    return Game.registry.get_by_id(_ai_slot_id)

# 敌对（玩家）盘集合：从 AI 视角找出对手盘
func opponent_slots() -> Array:    # Array[BoardSlot]
    # TODO: 按 faction / team_id 取对手盘
    return []

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
    # TODO
    return 0.0

var _hand: Array = []
func set_hand(cards: Array) -> void:
    _hand = cards
```

### 5.3 `scripts/ai/ai_strategy.gd`（决策接口）+ 默认实现

```gdscript
class_name AiStrategy
extends RefCounted

# 输入只读快照，产出按执行顺序排列的行动序列（末尾隐含 END_TURN，可省略）。
func decide(view: AiGameView) -> Array:   # Array[AiAction]
    return []
```

```gdscript
class_name HeuristicStrategy
extends AiStrategy

# 可调参数（后续做难度时外部注入）
var spell_value_threshold: float = 1.0
var prefer_front_row: bool = true

func decide(view: AiGameView) -> Array:
    var actions: Array = []
    var mana_left: int = view.current_mana()
    var own := view.own_slot()
    if own == null:
        return actions

    # 1) 法术：高价值目标优先（在部署前评估，避免目标被自己挤占）
    for card in _spells_sorted(view):
        if card.cost > mana_left:
            continue
        var tgt = _best_spell_target(view, card)
        if tgt == null and card.target != "":
            continue
        if _spell_value(view, card, tgt) < spell_value_threshold:
            continue
        actions.append(AiAction.play_spell(card.name, _slot_of(tgt, own), _row_of(tgt), _col_of(tgt)))
        mana_left -= card.cost

    # 2) 单位部署：高费优先，按落点评分贪心
    for card in _units_sorted_by_cost_desc(view):
        if card.cost > mana_left:
            continue
        var cell = _best_deploy_cell(view, card, own)
        if cell == null:
            continue
        actions.append(AiAction.play_unit(card.name, own.id, cell.row, cell.col))
        mana_left -= card.cost

    actions.append(AiAction.end_turn())
    return actions

# 跨盘单点决策：由 AiAgent 在 turn_system 询问时即时调用
func choose_cross_target(view: AiGameView, cell) -> String:
    var best_id := ""
    var best_score := -INF
    for s in view.opponent_slots():
        var score := _cross_score(view, s)
        if score > best_score:
            best_score = score; best_id = s.id
    return best_id

# ── 内部评分（TODO 实现）────────────────────────────────
func _spells_sorted(_v) -> Array: return []
func _units_sorted_by_cost_desc(_v) -> Array: return []
func _best_spell_target(_v, _card): return null
func _spell_value(_v, _card, _tgt) -> float: return 0.0
func _best_deploy_cell(_v, _card, _own): return null
func _cross_score(_v, _slot) -> float: return 0.0
func _slot_of(_cell, _own) -> String: return _own.id
func _row_of(_cell) -> int: return 0
func _col_of(_cell) -> int: return 0
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

# 直接在本端把单位 / 法术落到敌方盘，复用与 handle_remote_play_card 相同的落子路径。
func apply(action: AiAction) -> bool:
    match action.kind:
        AiAction.Kind.PLAY_UNIT:
            return _place_unit(action)
        AiAction.Kind.PLAY_SPELL:
            return _cast_spell(action)
        AiAction.Kind.CROSS_BOARD:
            Game.turn.enqueue_cross_choice({
                "source_slot_id": action.slot_id,
                "row": action.source_row, "col": action.source_col,
                "target_slot_id": action.target_slot_id,
            })
            return true
        _:
            return true

func submit_cross_choice(slot_id: String, row: int, col: int, target_slot_id: String) -> void:
    Game.turn.enqueue_cross_choice({
        "source_slot_id": slot_id, "row": row, "col": col,
        "target_slot_id": target_slot_id,
    })

func _place_unit(action: AiAction) -> bool:
    var slot: BoardSlot = Game.registry.get_by_id(action.slot_id)
    if slot == null or slot.board == null:
        return false
    var cell = slot.board.get_cell(Vector2(action.row, action.col))
    if cell == null or cell.has_card:
        return false
    var card = Game.get_card(action.card_name)
    if card == null:
        return false
    var effs: Array = card.effects.duplicate() if "effects" in card else []
    # is_enemy=true：玩家视角下敌方单位；origin="hand" 保证死亡入 AI 牌库墓地
    cell.set_card(action.card_name, card.attack, card.health, true, effs, "", "hand")
    cell.owner_slot_id = slot.id
    var ctx := Game.make_effect_context()
    ctx.target_cell = cell
    for eff in effs:
        await Effects.trigger_play(eff, card, ctx)   # 注意 await，Agent 需配合
    return true

func _cast_spell(action: AiAction) -> bool:
    # TODO：参考 play_controller._play_spell，对 target_cell 跑 effect 后入墓/除外
    return true
```

```gdscript
class_name NetActionSink   # PVP 人机托管（AI 扮演某 pid）
extends AiActionSink

var pid: String       # AI 所扮演的玩家 uuid

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

### 5.5 `scripts/ai/ai_agent.gd`（驱动层）

```gdscript
class_name AiAgent
extends Node

var slot_id: String
var deck: DeckManager
var mana: ManaSystem
var strategy: AiStrategy
var sink: AiActionSink
var view: AiGameView

const DRAW_PER_TURN: int = 1
const STEP_DELAY: float = 0.35      # 出牌间隔，给玩家观察节奏

func setup(p_slot_id: String, p_deck: DeckManager, p_mana: ManaSystem,
        p_strategy: AiStrategy, p_sink: AiActionSink) -> void:
    slot_id = p_slot_id
    deck = p_deck
    mana = p_mana
    strategy = p_strategy
    sink = p_sink
    view = AiGameView.new()
    view.setup(slot_id, deck, mana)

# 一个 AI 回合：摸牌 → 决策 → 顺序执行。由 turn_system / 场景在 ENEMY 阶段前调用。
func take_turn() -> void:
    _draw(DRAW_PER_TURN)
    view.set_hand(_current_hand())
    var actions: Array = strategy.decide(view)
    for action in actions:
        if action.kind == AiAction.Kind.END_TURN:
            break
        if action.card_name != "":
            if not mana.can_spend(_cost_of(action.card_name)):
                continue
            mana.spend(_cost_of(action.card_name))
            _remove_from_hand(action.card_name)
        var ok = sink.apply(action)
        if ok is bool == false:   # apply 含 await 时返回值处理
            await ok
        await get_tree().create_timer(STEP_DELAY).timeout

# 跨盘即时回调：turn_system 走到本 AI 单位 front_row 时调用
func on_cross_requested(cell) -> String:
    return strategy.choose_cross_target(view, cell)

# ── 手牌缓冲（PVE 敌方没有 UI 手牌，用内存数组模拟）──────────
var _hand_buf: Array = []
func _draw(n: int) -> void:
    for _i in range(n):
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

---

## 6. 注入点与改动清单

### 6.1 给 PVE 敌方装配 Deck + Mana（`game_context.gd`）
当前 `_bootstrap_empire()` / `bootstrap()` 只给本地玩家建 `deck` / `mana`。新增：为每个 AI 控制的敌方盘建独立 `DeckManager` + `ManaSystem`，存入 `Game.decks[ai_pid]` / `Game.manas[ai_pid]`（复用既有多实例字典与 `get_deck/get_mana`）。
- 帝国模式：敌方牌库可由出征目标的「守军配置」决定（默认给一套基础牌库）。
- 战役章节：可选地在 `level_data.boards[*]` 增加 `ai_deck` 字段；缺省则沿用纯 spawner（不接 AI）。

### 6.2 在 ENEMY 阶段前插入「AI 决策时机」（`turn_system.gd`）
- `run()` 中，`_run_spawn_phase()` 之后、`_run_phase(ENEMY)` 之前，新增 `await _run_ai_deploy_phase()`：遍历已注册的 `AiAgent`，依次 `await agent.take_turn()`。
- AI 出的单位落在敌方盘后，随即由既有 `ENEMY` 阶段自走棋逻辑移动 / 攻击 / 跨盘 → **零额外移动 AI**。
- 跨盘即时询问：把 `_front_row_resolve` 对 AI 单位的分支接到 `agent.on_cross_requested(cell)`（或预先 `enqueue_cross_choice`）。

### 6.3 PVP 托管（`test_main.gd`）
- 注册一个 `AiAgent`，`sink = NetActionSink(pid = 被托管玩家 uuid)`。
- 当 `Game.pvp_active_player_id() == 被托管 pid` 时触发 `agent.take_turn()`，其余完全复用现有 `_on_pvp_message` / `handle_remote_*` 同步链路——对其它客户端而言，AI 与真人无差别。
- 适用：真人掉线托管、或纯人机 PVP 房间（房主侧跑 AI）。

### 6.4 AI 注册中心（建议）
新增 autoload 或场景内 `AiManager` 持有所有 `AiAgent`，供 `turn_system` 查询「某 slot 是否 AI 控制」「取对应 agent」。避免 `turn_system` 直接硬编码 AI 引用。

---

## 7. 分期落地计划

| 阶段 | 内容 | 验收 |
| --- | --- | --- |
| P0 | 建 `scripts/ai/` 骨架（本文件 5.x 全部接口，方法 TODO） | 编译通过、无业务逻辑 |
| P1 | PVE 敌方 Deck+Mana 装配 + `AiManager` 注册 | 敌方盘有牌库 / 费用，可被查询 |
| P2 | `turn_system` 接入 AI 决策阶段 + `LocalActionSink` 单位部署 | 帝国出征中敌方会主动出单位 |
| P3 | `HeuristicStrategy` 单位评分 + 法术施放（`_cast_spell`） | 敌方会按费贪心铺场、合理施法 |
| P4 | 跨盘目标选择（多盘）接 `on_cross_requested` | 多线战斗 AI 会择盘进攻 |
| P5 | `NetActionSink` + PVP 托管接入 | 人机 PVP / 掉线托管可用 |
| P6 | 难度参数化、策略可替换接口完善 | 可配置强度 / 可换策略实现 |

---

## 8. 风险与注意事项

1. **`set_card` 与 effect 的 `await`**：`LocalActionSink._place_unit` 中 `Effects.trigger_play` 是异步，`AiAgent.take_turn` 必须 `await`，否则出牌动画 / 入场效果会错乱。骨架中 `apply` 的同步/异步返回需统一约定（建议 `apply` 一律为协程，Agent 一律 `await`）。
2. **死亡去向**：AI 单位用 `origin="hand"` 落子，死亡应入 **AI 自己的牌库墓地**，而非盘墓地。需确认 `handle_unit_death` 对敌方 `origin="hand"` 的路由（当前按 `Game.deck` 走本地玩家牌库，多实例下要改成按 `owner` 取对应 deck）。
3. **费用扣减一致性**：PVE 由 `AiAgent` 直接扣 `mana`；PVP 托管由 `NetActionSink` 广播，费用扣减发生在镜像端 `handle_remote_*`，两条路径不要重复扣。
4. **节奏控制**：`STEP_DELAY` 决定敌方出牌观感；过快玩家看不清，过慢拖沓。
5. **跨盘队列时序**：PVE 用 `enqueue_cross_choice` 必须在该单位行动**之前**入队（在 `take_turn` 阶段预判，或用即时回调 `on_cross_requested`）。
6. **法术目标合法性**：`HeuristicStrategy._best_spell_target` 必须复用 `PlayController._spell_target_valid` 的同款规则（friendly/enemy/any），避免 AI 出非法目标导致镜像端拒绝。
7. **确定性**：PVP 双端镜像依赖一致状态，AI 决策只应在「行动方本端」执行一次并广播，**不可双端各自决策**。

---

## 9. 目录结构建议

```text
dev_gd/nsoc/scripts/ai/
├── ai_action.gd            # 行动数据
├── ai_strategy.gd          # 决策接口
├── heuristic_strategy.gd   # 默认规则启发式
├── game_view.gd            # 只读棋局快照
├── ai_action_sink.gd       # 执行接口
├── local_action_sink.gd    # PVE 落地
├── net_action_sink.gd      # PVP 托管落地
├── ai_agent.gd             # 单 AI 回合驱动
└── ai_manager.gd           # AI 注册中心（可选 autoload）
```
