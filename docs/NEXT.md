# 下一步工作清单

> 本文档回答"**接下来做什么、按什么顺序、卡在哪**"。
> - 规范与设计理由：仓库根目录 `重构文档.md`（评审稿）
> - 实时状态与逐条验收：`docs/ROADMAP.md`
> - 部署与联调步骤：`docs/DEPLOY.md`
> - 最后更新：阶段 3 代码侧收尾完成（20 套 headless 全绿、两条黄金路径哈希不变）之后

## 0. 当前站位（一句话）

服务器权威链路的**代码侧已经闭环**（中继 + 权威进程 + 权威规则 + 客户端 v2 渲染 + 大厅派单），
**20 套 headless 测试全绿**、两条黄金路径状态哈希逐位不变、分层违规棘轮停在 87。
卡住的只剩**必须在真实机器上做的事**（A 组）；此外还有一批**不需要你出手、我可以直接做**的收尾（B 组）。

---

## A 组：需要你提供外部条件（阻塞项）

### A1. 部署到真实主机 + 跨机验收（要求 2 的最后一块）

代码层面能自证的部分已经用无头测试证明了；真机/跨机这一格**必须真部署一次**才算数。

**我需要你给的信息：**

| 项目 | 说明 |
|---|---|
| 主机 | 局域网还是公网？IP / 域名 |
| 端口 | 中继监听端口（环境变量 `PORT`，默认 `8080`），以及防火墙是否已放行 |
| `NSOC_AUTHORITY_KEY` | 权威进程准入密钥。**未配置时中继一律拒绝权威注册**（这是反作弊的第一道门），请给一个值（或让我生成） |
| 传输 | 是否必须 WSS（公网建议要，需要证书；局域网可直接 ws） |
| 验收机器 | 两台（一台跑中继 + 权威进程，两台各跑一个客户端）—— 单机双开只能验证到"同机两实例" |

**你不需要写代码。** 步骤全在 `docs/DEPLOY.md`：
中继启动 → 权威进程启动（`role=authority` + key）→ 两端进大厅 → 建房（`authoritative:true`）→
开打 → 采集证据。

**验收通过的标准（我会核对被你发回来的证据）：**
1. 两端**各自**的 `STATE_HASH` 一致（同种子同输入）—— ⚠️ **有障碍**：`STATE_HASH` 只有无头测试场景（`tests/headless_*.gd`）会打印，真实 GUI 对局没有这个输出，需要在客户端加一行打印、或改用 `auth/state` 逐字比对
2. 客户端篡改消息（伪造 `game/end` / 冒充他人 `player_id` / 伪造断线）**无效** —— ✅ 传输层已用外网探测验过；GUI 对局只需复看中继日志
3. 关掉权威进程后建房 → 客户端**静默退回 v1**，不炸局 —— ✅ 已验（`room/create_ok` 回 `authoritative=false`）
4. 权威进程崩溃重启后，房间不残留 —— ⏳ 待验

**已经就位的部分（2026-09 更新）：**
- 中继已在腾讯云真机上线（Windows Server + NSSM，`server/deploy/`），反作弊链路全部可用；
- 权威进程**不需要每局重启**：中继在房间销毁时释放、权威在对局结束时主动交还、断线会退避重连（见 `docs/DEPLOY.md` §4.1）；
- 可复用的云上端到端验收脚本：`powershell -File tools\ci\run_e2e_cloud.ps1 -RelayHost <IP> -AuthorityKey <key> -StartAuthority`
  （跨公网实测 `E2E_RESULT PASS`：建房 → 派单 → `start_match` → `auth/hello`/`auth/state` → `intent/end_turn` → 两端都收到 `phase_resolved`/`turn_started`）；
- 只有一个权威实例时，**同一时间只有一个房间能走 v2**（第二个房间静默退回 v1）—— 这是待命池大小为 1 的必然结果，不是缺陷。

### A2. 两条需要你点头的仓库收尾（要求 4 的尾巴）

| 事项 | 现状 | 需要你 |
|---|---|---|
| `dev1/` 目录 | ✅ 已删除（2026-09-15），记录见 `docs/ARCHIVE-INDEX.md` | — |
| 4 个已合并的远端旧分支 | `origin/branch_3v3`、`origin/multi-chessboard-branch`、`origin/multiplayer_1v3_branch`、`origin/multiplayer_branch` | 一句话确认是否删除（你之前说"先不用管"，这里只是挂着） |
| 权威进程上云 | 现在跑在某台本机，窗口必须常开 | 按 `docs/OPERATOR-TODO.md` 待办 1 操作（`server/deploy/authority/`） |

---

## B 组：不需要你出手，我可以直接做（按建议顺序）

> 每一项都是**独立切片**：做完即 commit，且必须满足 C 组的验收门槛。
> 这些属于 `重构文档.md` §7 阶段 3 的"分层深化"收尾，**不影响可玩性与反作弊**，
> 因此建议顺序是：**先 A1 验收 → 再动 B**（有一个"真机可用"的基线，重构才有对照物）。

### B1. 契约层：反射调用收敛（分层棘轮最大头，34 + 13 处）

现状（`tools/ci/layer_baseline.json`，只允许减少）：

| 规则 | 处数 | 主要位置 |
|---|---|---|
| `reflection-has-method`（`has_method(...)`） | 34 | `core/effect_registry.gd` 7、`core/hero_ability_registry.gd` 5、`core/action_registry.gd` 2、`core/play_controller.gd` 2，其余散在 effects/abilities 各 1~2 |
| `reflection-call`（`.call(...)`） | 13 | `core/turn_system.gd` 6、`core/empire_state_io.gd` 2、`core/spawner_system.gd` 2、`core/board_model.gd` 1、`core/board_slot_factory.gd` 1、`actions/trigger_ability.gd` 1 |

**做法**（按收益排序）：
1. 注册表里的 `has_method` 换成**显式基类**：`Effect` / `HeroAbility` / `Action` 的基类声明
   可选钩子（空实现），子类覆盖 —— 这套"基类空钩子"模式在 `battle_scene_base.gd`
   已经验证可行（见 `重构文档.md` §11 最后两行）。
2. effects/abilities 里为兼容"纯数据盘（`CellData`）"写的 `cell.has_method("_update_hp_labels")`
   这类守卫，**已经在 `CellData` 上补齐空实现**（`RulesOnDataTest` 守着），可以直接删守卫。
3. `turn_system` 的 `.call(...)` → 换成对 `CombatSystem` / `PlayController` 的**显式方法调用**。

**收益**：棘轮 87 → 约 50；服务端无头路径不再依赖"方法名约定"，编译期就能查错。

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

`core/turn_system.gd:891` 的 `await _combat.get_tree().process_frame` 是唯一残留的
"规则层直接等引擎帧"。改成走 `Game.wait_delay()` / 表现宿主（`instant_battle` 通道已经在了），
顺带把 6 处 `.call(...)` 收掉（见 B1）。

### B4. `board_slot_factory` 的 `grid_cells` 类型收敛（14 处，单文件最大）

`core/board_model.gd` 的 `grid_cells: Dictionary` 目前**既可能是 `Cell` 节点、也可能是 `CellData`**
（`# Vector2(r,c) -> Cell 节点（客户端）或 CellData（无头/服务器）`）。
`board_slot_factory` 因此带着 6 处 `add_child` + 5 处 `queue_free` + 2 处 `Panel` + 1 处 `.call`。

**做法**：装配函数拆成两条明确入口 —— `build_data_slots()`（纯数据，服务端/无头用）与
`build_view_slots(host)`（带视图，客户端用），让"节点还是数据"由**调用点**决定而不是靠运行时判断。
客户端的节点挂载全部搬进宿主层（`dev_gd/nsoc/server/` 与 UI 层）。

### B5. 打包：一条命令产出三件产物 + `version.json`（要求 3 的最后一块，验收表里唯一没勾的工程项）

现状：
- `dev_gd/nsoc/export_presets.cfg` 只有两个 preset：`Android`、`Windows Desktop`
- **缺无头服 preset**（`NSOC-Server-Windows.exe`）
- **没有打包脚本**，`version.json` 也不存在（`git ls-files` 里没有）

**做法**：
1. 加第三个 preset（Windows，`--headless` 入口 + 不打包 UI 资源）
2. 写 `tools/ci/build_release.ps1`：导出三件 → 生成 `version.json`
   （`PROTOCOL_VERSION` / `CONTENT_HASH` / `BUILD_ID`，语义见 `重构文档.md` §5.2）
3. CI 加一步"能构建"（不必分发，产物可只在本地/手动跑）

### B6. 内容热更（可选，要求 3 的第四点）

因为卡/关卡/剧本全在 `data/`，内容变更理论上不必重发客户端；设计见 `重构文档.md` §5.4。
前置是 B5 的 `CONTENT_HASH` 落地。**优先级最低**，建议等 A1 之后再排。

---

## C 组：每一步的验收门槛（做 B 组时不许破）

每一个 B 切片完成后**必须同时满足**（和本轮 4 个提交同一套纪律）：

1. `20 套 headless 全绿`（16 套单测 + 两条黄金路径 + PVP 三路径 + 装备渲染；清单见下）
2. **两条黄金路径哈希逐位不变**：
   - 战役单盘 `652a3ef286eca42605d10065f817b3cf955ffcfab238417348729a3398331df8`
   - 多棋盘 PVE `0576fcc90d28747719b68bcb9cb40d79fbc25d08f780a7dda19fb1828995e0ce`
3. **PVP 三条路径哈希**：1v1 `d3fb9484…`；1v3 / 3v3 用当前基线（`6cea9182…` / `b5b9353f…`，3 轮）。
   若某个切片**有意**改变了它们，必须在 `重构文档.md` §11 写明"有意重基线 + 原因"
4. 分层棘轮**只减不增**（当前 87，共 9 条规则 / 27 个文件；B1~B4 覆盖了其中的反射与场景树两大类，
   做完应大幅下降）
5. `tools/ci/check_content.py` 通过
6. 不留红的提交：任何一步做不完就 amend，不把半成品提交留在基线里

**本地一条命令跑验证：**

```powershell
# 单盘黄金路径（战役；默认 turns=3，哈希见 C 组第 2 条）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\ci\run_headless_smoke.ps1
# 多棋盘黄金路径（**必须 -Turns 2**，否则哈希不是基线值 0576fcc9…）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\ci\run_headless_smoke.ps1 -Scene res://tests/HeadlessTestBattle.tscn -Turns 2
# PVP 三路径（1v1 / 1v3 / 3v3）
powershell -NoProfile -ExecutionPolicy Bypass -File tools\ci\run_headless_smoke.ps1 -Scene res://tests/HeadlessPvp.tscn -Turns 3
# 装备按 auth/state 渲染 + 规则层纯数据盘
powershell -NoProfile -ExecutionPolicy Bypass -File tools\ci\run_headless_smoke.ps1 -Scene res://tests/HeroRenderTest.tscn
powershell -NoProfile -ExecutionPolicy Bypass -File tools\ci\run_headless_smoke.ps1 -Scene res://tests/RulesOnDataTest.tscn
# 两个守卫
py tools\ci\check_layers.py
py tools\ci\check_content.py
```

> 注意：新加的 `.gd` 文件必须让 `--import` 先跑一遍（`run_headless_smoke.ps1` 默认会做），
> 否则 `class_name` 全解析不了；另有两条 GDScript 坑记在 `tools/ci/run_headless_smoke.ps1` 末尾的踩坑日志里。

---

## D 组：已经做完、不用再排的（免得重复劳动）

- 阶段 0/1/2 全部；阶段 3 除 B 组之外的全部：定序、随机源集中、结算与表现分离、
  中继止血四策略、结算去网络依赖、`CellData` 地基 + `Cell` 视图化 + 规则纯数据盘验收、
  无视图装配、无头完整攻击结算、权威端棋盘结算（合法/法术/技能/装备/费用/死亡清算）、
  客户端 v2（意图上行 + 镜像 + 盘面/手牌/费用/回合按钮/**装备栏**渲染）、
  权威进程入口 + 中继对接 + 大厅派单与开局配置交接、细粒度逐动作事件（`board_action`）、
  `main`/`test_main` 合一（净 −217 行）、PVP 三路径 headless 冒烟、文档归档与索引。

## E 组：什么时候必须停下来找你

只有这几种情况（其余我自己决策并继续）：

1. 需要**真实主机 / 端口 / 密钥 / 证书**（A1）
2. 需要你**确认删除**仓库里的东西（A2）
3. 需要**改变对外契约**（协议版本号、产物名、目录布局对外可见的部分）
4. 需要**真机验证**才能继续判断（例如跨机 timing 问题）

---

## 一句话建议顺序

```
A1 部署 + 跨机验收（你出机器和密钥，我给命令和判据）
  → A2 仓库收尾（你一句话确认）
  → B1 反射收敛 → B3 turn_system → B2 表现宿主 → B4 board_slot_factory  → B5 打包 → B6 热更
```
