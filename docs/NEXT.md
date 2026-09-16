# 下一步工作清单

> 本文档回答"**接下来做什么、按什么顺序、卡在哪**"。
> - 规范与设计理由：仓库根目录 `重构文档.md`（评审稿，含联机历史设计，原样保留）
> - 实时状态与逐条验收：`docs/ROADMAP.md`
> - 联机功能删除清单与恢复方法：`docs/archive/multiplayer-removal.md`
> - 最后更新：**联机移除（项目转为纯本地）之后**

## 0. 当前站位（一句话）

项目已转为**纯本地**（战役 + 自由对战 + 演义）；联机层、中继服务端与权威裁判进程**全部删除**
（清单见 `docs/archive/multiplayer-removal.md`）。本地规则内核与测试网保持完整：
Godot `--import` 无解析错误、分层棘轮 75 未涨、内容检查通过、
**11 个本地 headless 场景全绿且两条黄金路径哈希逐位不变**。

剩下的工作**全部是本地侧**：一批分层收尾（B 组，不需要外部条件）＋ 需要你在服务器上收尾的
一件事（A 组）。

---

## A 组：需要你出手（只剩一件）

### A1. 停掉云上的两个残留服务

代码里的联机已经删干净，但腾讯云那台机器上的两个 NSSM 服务（`nsoc-server` / `nsoc-authority`）
不会自己停。客户端现在**不可能**再连上任何服务器（`Net` 是空壳、大厅无入口），但建议停掉：

```powershell
# 【服务器】管理员 PowerShell —— 先停用
Stop-Service nsoc-server, nsoc-authority
Set-Service nsoc-server, nsoc-authority -StartupType Manual
Get-Service nsoc-server, nsoc-authority | Select-Object Name, Status, StartType

# 彻底卸载（不再需要的话）
Stop-Service nsoc-server, nsoc-authority
sc.exe delete nsoc-server
sc.exe delete nsoc-authority
Remove-Item -Recurse -Force C:\nsoc
```

详见 `docs/archive/multiplayer-removal.md` §6。**这是唯一的阻塞项，且不需要写代码。**

### A2. 仓库收尾（可选）

| 事项 | 现状 | 需要你 |
|---|---|---|
| `dev1/` 目录 | ✅ 已删除（2026-09-15），记录见 `docs/ARCHIVE-INDEX.md` | — |
| 4 个已合并的远端旧分支 | `origin/branch_3v3`、`origin/multi-chessboard-branch`、`origin/multiplayer_1v3_branch`、`origin/multiplayer_branch` | 一句话确认是否删除（这些分支承载的联机功能已从 `main` 移除，只是一直挂着） |
| `dist/` 里的联机产物 | `dist/authority-bundle/`、`dist/client-fixed/` 等是历史构建产物（`.gitignore` 内，不入库） | 本地磁盘清理可自行决定 |

---

## B 组：不需要你出手，可以直接做（按建议顺序）

> 每一项都是**独立切片**：做完即 commit，且必须满足 C 组的验收门槛。
> **全部是本地重构**，与联机无关。

### B1. 契约层：反射调用收敛（分层棘轮最大头）— 🟡 已完成 12/47

**已完成**：`effect_registry` 7 处 + `hero_ability_registry` 5 处（`reflection-has-method` 探测）。
**棘轮 87 → 75**，两条黄金路径哈希逐位不变。

为什么这 12 处是"死代码"而不是"行为改变"：全部效果脚本都 `extends Effect`（32/32）、全部技能脚本都
`extends HeroAbility`（15/15），而这两个基类**本来就为每个可选钩子声明了默认实现**
（`id/display_name/description/target/on_play/on_death/on_kill/resolve_destination`、
`cost/once_per_turn/can_activate/on_activate`）。既然方法一定存在，`has_method()` 恒为真。

**剩余 35 处（按收益排序）**：

| 目标 | 处数 | 做法 | 风险 |
|---|---|---|---|
| `turn_system.gd` 的 `.call(...)` | 6 | 换成对 `CombatSystem` / `PlayController` 的**显式方法调用** | 中：需确认被调方法签名 |
| effects/* 里的 `cell.has_method("_update_hp_labels")` 守卫 | 8 | `CellData` 已补空实现（`RulesOnDataTest` 守着），可直接删守卫 | 低，但散布 8 个文件 |
| `action_registry.gd` 的 `has_method` | 2 | 需先引入 `Action` 基类（10 个 action 脚本目前是 duck-typing） | 中：要先改 10 个文件加 `extends Action` |
| `play_controller.gd` / `trigger_ability.gd` / `board_model.gd` / `spawner_system.gd` / `empire_state_io.gd` / `board_slot_factory.gd` 的 `.call` | 9 | 逐个看目标类型后显式化 | 中 |

**当前计数**（`tools/ci/layer_baseline.json`，只允许减少；已从 87 降到 75）：

| 规则 | 处数 | 主要位置 |
|---|---|---|
| `reflection-has-method`（`has_method(...)`） | 34 → **22** | `core/effect_registry.gd` 7 ✅、`core/hero_ability_registry.gd` 5 ✅、`core/action_registry.gd` 2、`core/play_controller.gd` 2，其余散在 effects/abilities 各 1~2 |
| `reflection-call`（`.call(...)`） | 13 | `core/turn_system.gd` 6、`core/empire_state_io.gd` 2、`core/spawner_system.gd` 2、`core/board_model.gd` 1、`core/board_slot_factory.gd` 1、`actions/trigger_ability.gd` 1 |

**收益**：棘轮 87 → 约 50；不再依赖"方法名约定"，编译期就能查错。

### B2. 表现依赖下沉：`Control` / `Tween` / `get_tree`（约 12 处）

| 位置 | 现状 |
|---|---|
| `core/play_controller.gd` | `Control` 4、`add_child` 1、`create_tween` 1、`get_tree()` 1、`queue_free` 1 |
| `core/combat_system.gd` | `Control` 2、`add_child` 1、`create_tween` 1、`get_tree()` 1、`queue_free` 1 |
| `core/game_context.gd` | `add_child` 6、`queue_free` 2、`create_timer` 1、`get_tree()` 1 |

**做法**：把"挂节点 / 播动画 / 等一帧"抽成一个**表现宿主接口**（`PresentationHost`），
core 只调用接口；有 UI 的场景注入真实现（沿用现有 `presentation_enabled=false` 的开关），
无头环境注入空实现。`game_context` 的 `add_child` 是 deck/mana 实例挂载 —— 同样走宿主。

### B3. `turn_system` 拉直 `await`（1 处 + 6 处 `.call`）

`core/turn_system.gd` 里 `await _combat.get_tree().process_frame` 是唯一残留的
"规则层直接等引擎帧"。改成走 `Game.wait_delay()` / 表现宿主（`instant_battle` 通道已经在了），
顺带把 6 处 `.call(...)` 收掉（见 B1）。

### B4. `board_slot_factory` 的 `grid_cells` 类型收敛（14 处，单文件最大）

`core/board_model.gd` 的 `grid_cells: Dictionary` 目前**既可能是 `Cell` 节点、也可能是 `CellData`**
（`# Vector2(r,c) -> Cell 节点（客户端）或 CellData（无头）`）。
`board_slot_factory` 因此带着 6 处 `add_child` + 5 处 `queue_free` + 2 处 `Panel` + 1 处 `.call`。

**做法**：装配函数拆成两条明确入口 —— `build_data_slots()`（纯数据，无头用）与
`build_view_slots(host)`（带视图，客户端用），让"节点还是数据"由**调用点**决定而不是靠运行时判断。

### B5. 打包：一条命令产出三件产物 + `version.json` — 🟡 版本三件套已完成

**已完成**：
- `tools\ci\build_release.ps1`：产出 `version.json`（`PROTOCOL_VERSION` / `CONTENT_HASH` / `BUILD_ID`）
  + `content_manifest.json` + `RELEASE.txt`（缺预设/模板时**优雅跳过**并写进 `RELEASE.txt`）。
  `-SkipExport` 为纯版本生成（不需要 Godot）。
- `tests\ContentHashTest.tscn`：把构建侧 PowerShell 的 `CONTENT_HASH` 与引擎 GDScript 的
  `NetProtocol.content_hash()` 钉死在一起（5 条断言）。
- CI 加了两步：先 `build_release.ps1 -SkipExport` 生成产物，再跑 `ContentHashTest`。
- `.gitignore`：`version.json` / `content_manifest.json` / `content_hash_check.json` 是派生产物，不入库。

> ⚠️ 联机移除后 `NetProtocol` 只剩常量表，但 **`VERSION` 与 `content_hash()` 仍在用**，
> 不要顺手删掉（见 `docs/archive/multiplayer-removal.md` §2.2）。

**仍缺**：
- **Android release 需要发布密钥库**：预设里 `package/signed=true` 但 `keystore/release` 为空，
  导出会走到最后一步才失败（`找不到发布密钥库，无法导出`），甚至可能留下一个未签名的
  `exports/NSOC.apk`。**Android debug 导出实测可用**（用 Godot 自带调试签名）。
  三种处理方式见 `docs/HANDOFF.md` §4。
- 预设 `package/unique_name="com.example.$genname"`，正式发版前建议改成自己的包名。
- `Windows Desktop` 已验证 **release 导出通过**（126.8 MB 单文件、内嵌 pck）。

> 导出的两个坑（都踩过）：① **导出路径要相对项目目录**（`exports/xxx.exe`），写
> `dist/xxx.exe` 会报"给定的导出路径不存在"；② **导出的 exe 不能用命令行指定场景**
> （模板编译时关了 path overrides），验导出产物只能跑 `main_scene`。

### B6. 内容热更（可选）

因为卡/关卡/剧本全在 `data/`，内容变更理论上不必重发客户端；设计见 `重构文档.md` §5.4。
前置是 B5 的 `CONTENT_HASH` 落地。**优先级最低**。

---

## C 组：每一步的验收门槛（做 B 组时不许破）

每一个切片完成后**必须同时满足**：

1. **本地 headless 矩阵全绿**（11 个场景，清单与 `.github/workflows/ci.yml` 一致）：

   | 场景 | 说明 |
   |---|---|
   | `HeadlessBattle` | 单盘战役 3 回合（冒烟 + 逐回合哈希 + 确定性） |
   | `HeadlessTestBattle` | 多棋盘 PVE（6 盘 + AI） |
   | `RulesTest` | 规则层纯逻辑 |
   | `RulesOnDataTest` | 规则层跑在纯数据盘上 |
   | `SparringPanelTest` | **演武切磋入口契约**：可进入、四模式页可切、创建/加入均不可用且无入口（16 条） |
   | `HeadlessBoardTest` | 无头棋盘 |
   | `HeadlessSetupTest` | 无视图装配 |
   | `HeadlessCombatTest` | 无头完整攻击结算 |
   | `CellViewTest` | `CellData` 转发属性 |
   | `SceneLoadTest` | 全部 `.tscn` 可 load + instantiate |
   | `ContentHashTest` | 构建侧 vs 引擎内容哈希（无产物时 SKIP 并通过） |

   一条命令：`powershell -File tools\ci\run_headless_matrix.ps1`（输出 `MATRIX_RESULT PASS`）
2. **两条黄金路径哈希逐位不变**：
   - 战役单盘 `652a3ef286eca42605d10065f817b3cf955ffcfab238417348729a3398331df8`
   - 多棋盘 PVE `0576fcc90d28747719b68bcb9cb40d79fbc25d08f780a7dda19fb1828995e0ce`
3. 分层棘轮**只减不增**（当前 75，共 9 条规则 / 42 个文件）
4. `tools/ci/check_content.py` 通过
5. `godot --headless --path dev_gd/nsoc --import` 无 `Parse Error` / `SCRIPT ERROR`
6. 不留红的提交：任何一步做不完就 amend，不把半成品提交留在基线里

**本地一条命令跑验证：**

```powershell
# 单盘黄金路径（战役；默认 turns=3）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\ci\run_headless_smoke.ps1
# 多棋盘黄金路径（**必须 -Turns 2**，否则哈希不是基线值 0576fcc9…）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\ci\run_headless_smoke.ps1 -Scene res://tests/HeadlessTestBattle.tscn -Turns 2
# 规则层纯数据盘
powershell -NoProfile -ExecutionPolicy Bypass -File tools\ci\run_headless_smoke.ps1 -Scene res://tests/RulesOnDataTest.tscn
# 两个守卫
py tools\ci\check_layers.py
py tools\ci\check_content.py
# 版本三件套 + 内容哈希一致性（构建侧 vs 引擎）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\ci\build_release.ps1 -SkipExport
powershell -NoProfile -ExecutionPolicy Bypass -File tools\ci\run_headless_smoke.ps1 -Scene res://tests/ContentHashTest.tscn
# 一次跑完整矩阵
powershell -NoProfile -ExecutionPolicy Bypass -File tools\ci\run_headless_matrix.ps1
```

> 注意：新加的 `.gd` 文件必须让 `--import` 先跑一遍（两个脚本默认都会做），
> 否则 `class_name` 全解析不了；GDScript 的坑记在 `tools/ci/run_headless_smoke.ps1` 末尾。

---

## D 组：已经做完、不用再排的（免得重复劳动）

- 阶段 0/1/2 的**本地部分**全部；
- `CellData` 地基 + `Cell` 视图化 + 规则纯数据盘验收；
- 无视图装配、无头完整攻击结算；
- `main`/`test_main` 合一（净 −217 行）；
- 文档归档与索引；
- **联机功能整体移除**（客户端 + 服务端 + 部署链 + 测试 + CI 步骤），清单见
  `docs/archive/multiplayer-removal.md`。

### D2. 已废弃、不要再排的（联机相关，随模块删除）

- ~~权威端棋盘结算 / 回合推进 / 终局判定 / 法术 / 英雄技能 / 装备~~
- ~~客户端 v2（意图上行 + 镜像 + 盘面/手牌/费用/回合按钮/装备栏渲染）~~
- ~~权威进程入口 + 中继对接 + 大厅派单与开局配置交接~~
- ~~细粒度逐动作事件（`board_action`）~~
- ~~跨机 / 跨公网部署与验收（A1-B、判据 1~4）~~
- ~~Go 中继与权威进程上云~~

---

## E 组：什么时候必须停下来找你

只有这几种情况（其余我自己决策并继续）：

1. 需要**真实主机**才能做的事（当前只剩"停掉云上残留服务"，见 A1）
2. 需要你**确认删除**仓库里的东西（A2）
3. 需要**改变对外契约**（产物名、目录布局对外可见的部分）
4. 需要**真机 GUI 验证**才能继续判断

---

## 一句话建议顺序

```
A1 停云上服务（你 2 分钟）
  → B1 反射收敛 → B3 turn_system → B2 表现宿主 → B4 board_slot_factory → B5 打包 → B6 热更
```
