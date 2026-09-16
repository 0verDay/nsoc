# 联机功能移除清单（可照单恢复）

> **日期**：2026-09-16
> **决策**：把多人模式暂时"阉割"——玩家仍可进入「演武切磋」界面，但**无法创建房间、无法加入房间**；
> 同时**删除全部联机逻辑**，项目方向转为**纯本地**（战役 + 自由对战 + 演义）。
> **原则**：`git` 历史是最终备份，但下面逐条记清"删了什么、为什么、在哪里"，将来要恢复联机可以照单取回。
>
> 本文是**唯一**的恢复地图。恢复时的验收门槛见 `docs/NEXT.md` C 组。

---

## 0. 一句话总览

| 维度 | 处理方式 |
|---|---|
| 联机传输 / 协议校验 / 权威裁判 / 中继服务端 | **彻底删除** |
| 大厅（`SparringPanel`） | **保留页面外观**，删除全部联网逻辑，只显示"联机功能暂未开放" |
| autoload `Net` | **降级为空壳**（同名同签名空实现，无 socket） |
| `NetProtocol` | **降级为常量表**（保留 `VERSION` 与 `content_hash()`） |
| PVP 回合 / 队伍内核（`bootstrap_pvp` / `pvp_*` / `run_pvp_phase*` / 队伍工具） | **保留为死代码**（无入口，靠 Net 空壳维持可解析） |
| 联机测试与 CI 步骤 | **删除**（连同被测模块） |
| 文档 | 现行文档改写为本地口径；联机文档整体归档 |

---

## 1. 删除的文件（Entity 级）

### 1.1 客户端权威层（`dev_gd/nsoc/scripts/`）

| 文件 | 原来是什么 | 恢复时的依赖 |
|---|---|---|
| `net/v2_battle_client.gd`（`V2BattleClient`） | 上行意图构造 + `auth/*` 权威镜像（`board`/`hand`/`mana`/`equipments`/`turn`/`active`/`finished`） | 依赖 `NetProtocol` + `Net`；恢复需同时接回 `Game.enable_v2_authority()` |
| `net/auth_board_renderer.gd`（`AuthBoardRenderer`） | 按 `auth/state.board` 重绘本地棋盘（含幻影、幂等） | 依赖 `Cell` / `CellData` 鸭子类型 |
| `net/auth_equip_renderer.gd`（`AuthEquipRenderer`） | 按 `auth/state.you.equipments` 写 `Equipments` 单例（无变化不重写） | 依赖 `Equipments` autoload |
| `net/profile_manager.gd`（`ProfileManager`） | `user://profile.json`（uuid/昵称）+ `user://server.json`（host/port/authoritative） | 纯静态工具类，无依赖，最易恢复 |

> 还在的：`net/network_manager.gd` 改成了空壳（见 §2）。

### 1.2 服务端（权威裁判，GDScript）

| 文件 | 原来是什么 |
|---|---|
| `scripts/server/battle_authority.gd`（`BattleAuthority`） | 权威核心：身份/回合/序号/限速四道校验、卡牌费用与手牌结算、按玩家过滤的私有视图、权威事件流、`state_hash()` |
| `scripts/server/server_session.gd`（`BattleServerSession`） | 服务器会话层：消息信封、握手、伪造服务器消息丢弃 + 审计、按玩家路由、`tick()` 驱动待结算阶段 |
| `scripts/server/authority_board.gd`（`AuthorityBoard`） | 把棋盘规则引擎接进权威端的适配器（`deploy_unit()` / `state()` / 法术 / 英雄技能 / 装备 / 回合结算） |
| `server/authority_main.gd`（`AuthorityMain`） | 权威进程运行时宿主：连中继 → 注册 → 开局 → 转发玩家消息 → `tick_once()` → `flush_outbound()` |
| `server/AuthorityMain.tscn` | 权威进程入口场景 |
| `server/battle_sim_host.gd`（`BattleSimHost`） | 权威端 `CombatSystem` + `PlayController` + `TurnSystem` 宿主机（无头表现开关） |
| `dev_gd/nsoc/scripts/core/net/protocol.gd` 的**校验部分** | `validate_intent` / `is_intent` / `is_server_only` / `client_may_send` / `server_may_accept` / `_field_matches` + 四张分类表（`_INTENT_TYPES` / `_CLIENT_CONTROL_TYPES` / `_SERVER_ONLY_TYPES` / `_REQUIRED_FIELDS`） |

### 1.3 Go 中继服务端（仓库根 `server/`，整个目录）

| 文件 | 原来是什么 |
|---|---|
| `server/main.go` | 中继进程入口 |
| `server/hub.go` | 房间与连接中枢、`role=authority` 派单、`intent/*` 只发权威、`auth/*` 按 `to` 路由 |
| `server/room.go` | 房间模型 |
| `server/message.go` | 消息信封 |
| `server/security.go` | 反作弊止血：服务器专属消息丢弃、房主校验、身份重写、每连接 20 条/秒限速 |
| `server/client.go` | 单连接读写循环 |
| `server/security_test.go` | 10 个安全策略单测 |
| `server/authority_relay_test.go` | 中继↔权威对接单测（注册门槛 / 意图只到权威 / 身份不重写 / 崩线不残留） |
| `server/go.mod` / `server/go.sum` / `server/README.md` / `server/.gitignore` | Go 模块与说明 |
| `server/deploy/*` | 中继与权威的启动脚本、NSSM 服务安装脚本、验收采集脚本 |

### 1.4 云部署与端到端验收脚本（`tools/ci/`）

| 文件 | 原来是什么 |
|---|---|
| `tools/ci/build_authority_bundle.ps1` | 一条命令产出上云产物 `dist/authority-bundle/`（打包前刷新 `.godot` 类名缓存） |
| `tools/ci/run_e2e_local.ps1` | 本地端到端联调编排（起 Go 中继 → 起探针 → 读房号 → 起权威进程 → 断言） |
| `tools/ci/run_e2e_cloud.ps1` | 跨公网端到端验收（`-RelayHost` / `-AuthorityKey` / `-StartAuthority`） |
| `dev_gd/nsoc/tests/e2e_relay_probe.gd` + `E2ERelayProbe.tscn` | 一个进程开两条中继连接，断言双方都收到权威结果 |

### 1.5 联机测试套件（`dev_gd/nsoc/tests/`）

| 场景 + 脚本 | 覆盖 |
|---|---|
| `AuthorityTest`（46 断言） | 权威核心：身份/回合/序号/限速/私有视图/`state_hash` |
| `AuthorityBoardTest`（107+ 断言） | 权威端棋盘结算（合法/法术/技能/装备/费用/死亡清算/回合推进/终局） |
| `AuthorityMainTest`（25 断言） | 权威进程入口：注册 / 派单 / 开局配置 / 意图 / tick |
| `ServerSessionTest`（32 断言） | 服务器会话层边界（伪造消息、身份绑定、事件路由） |
| `NetV2Test` | 客户端 v2 传输层（意图构造 / `auth/*` 分发） |
| `V2WiringTest` | `Game.enable_v2_authority()` 接线 |
| `V2BattleClientTest`（30 断言） | 意图构造 + 权威镜像 |
| `AuthBoardRenderTest`（16 断言） | `AuthBoardRenderer` 按 `auth/state` 重绘 |
| `HeroRenderTest`（20 断言） | `AuthEquipRenderer` 按 `auth/state` 重建装备栏 |
| `HandRenderTest`（9 断言） | `HandView.replace_hand_with()` 按权威手牌重建 |
| `HeadlessPvp`（PVP 三路径冒烟，1v1/1v3/3v3） | 真实 `TestMain` 场景 + 确定性远端替身 |

> `HeadlessPvp` 的**脚本仍在**（`tests/headless_pvp_test.gd`），因为它是 PVP 内核（保留为死代码）的
> 回归用例；只是**不再进 CI**，也未列入 `run_headless_matrix.ps1`。

### 1.5b 新增的"入口契约"测试（守住本次阉割行为）

| 文件 | 覆盖 |
|---|---|
| `tests/sparring_panel_test.gd` + `SparringPanelTest.tscn` | **16 条断言**：`SparringPanel` 可加载可入树、四个模式按钮齐全且可切换、默认页与「加入房间」页都显示「联机功能暂未开放」、**界面上不存在任何创建/加入房间的按钮**（无"开始"/"创建"/"刷新列表"/"加入"/"准备"）、全程 `Net.is_connected_to_server()` 为 false 且房间号为空 |

> 这个测试**已接入 CI** 与 `run_headless_matrix.ps1`（`sparring-entry` 场景）。
> 它的意义：将来若有人不小心把联机入口接回来（或把提示删掉），CI 会立刻变红。


### 1.6 联机专用数据

| 文件 | 原来是什么 |
|---|---|
| `dev_gd/nsoc/data/test_multiplayer_deck.json` | 联机测试牌组（填线宝宝×3 + 鼓舞 + 测试刀 + 鸣金） |

---

## 2. 被"降级"而不是删除的文件

### 2.1 `dev_gd/nsoc/scripts/net/network_manager.gd`（autoload `Net`）

**现在是空壳**：没有 `WebSocketPeer`、没有任何 socket、`is_connected_to_server()` 恒 `false`、
`send()` / `send_to_room()` / `send_intent()` 只打一条 warning，`current_room_id` 永远为空。

**保留的 API（同名同签名，供 PVP 死代码解析）**：

```
信号：connected / connection_failed / disconnected / message_received
      auth_hello / auth_state / auth_event / auth_reject / auth_verdict / auth_request_choice
常量：STATE_DISCONNECTED / STATE_CONNECTING / STATE_CONNECTED
字段：use_v2 / want_authoritative / auto_hello
方法：connect_to_server / disconnect_from_server / send / send_to_room / build_message
      build_intent / send_intent / send_client_hello / sent_log / clear_sent_log
      send_client_ping / next_intent / send_to / is_connected_to_server
      set_current_room_id / get_current_room_id / get_session_id / get_nickname / set_nickname
```

**恢复方法**：从 `git log -- dev_gd/nsoc/scripts/net/network_manager.gd` 取删除前那一版即可
（它是完整实现：连接 / 断开 / 重连、JSON 分发、`_resolve_want_authoritative()` 三级优先、
`_sent_log` 留痕、`session_id = uuid + 4 位随机后缀`）。

### 2.2 `dev_gd/nsoc/scripts/core/net/protocol.gd`（`NetProtocol`）

**现在只剩常量表**：`VERSION` + 全部消息名常量（`INTENT_*` / `CLIENT_*` / `AUTH_*` / `REJECT_*`）
+ `content_hash()`。

> ⚠️ `VERSION` 与 `content_hash()` **仍在使用**，不要一并删掉：
> `tools/ci/build_release.ps1` 用正则从本文件读 `const VERSION: int = N` 写进 `version.json` 的
> `PROTOCOL_VERSION`；`tests/ContentHashTest` 用 `content_hash()` 把构建侧 PowerShell 实现与引擎
> 实现钉死在一起。

**恢复方法**：取回校验函数与四张分类表（`_REQUIRED_FIELDS` 里 `seq` 等整数字段要接受"整数值的浮点"，
因为 **JSON 没有整数类型** —— 这是当年端到端联调才暴露的坑）。

---

## 3. 被"掏空"的现有文件（改动点逐条）

| 文件 | 删掉了什么 | 保留了什么 |
|---|---|---|
| `scripts/ui/sparring_panel.gd` | 全部联网：连接/重连、`room/create`/`join`/`leave`/`list`/`update_config`/`ready`/`game/start`、`authority/start_match`、玩家格与准备系统、数字键盘房号输入、服务器地址对话框、`_build_authority_config`、`_handle_game_start`、`_collect_deck_names`、Net 信号绑定；1533 行 → 约 230 行 | 页面外观与手动布局、四个模式按钮（我的房间 / 加入房间 / 随机匹配 / 随机排位）、`BackBtn` 转场。"我的房间"与"加入房间"改为显示**「联机功能暂未开放」** |
| `scripts/core/game_context.gd` | `v2_authority` / `v2` 字段、`enable_v2_authority()` / `disable_v2_authority()` / `_on_auth_hello` / `_on_auth_state` / `_on_auth_event` / `_on_auth_reject` / `_on_auth_verdict` | `bootstrap_pvp()`、`pvp_*` 全套回合/队伍内核、`pvp_end_game()` 里的 `Net.send_to_room`（现在是空操作） |
| `scripts/app/test_main.gd` | `auth/state` / `auth/event` 连接与 `_on_auth_state_render` / `_on_auth_event_ui`、结束回合与投降里的 v2 分支 | PVP 槽位装配（1v1/1v3/3v3）、`action/*` 锁步广播、`game/end` 兜底 |
| `scripts/core/play_controller.gd` | `handle_equip` 与 `handle_drop` 的 v2 分支、`_v2_send_play_intent()` | 本地扣费/落子、PVP `action/*` 广播 |
| `scripts/ui/hero_action_bar.gd` | `_v2_send_activate_intent()` / `_v2_send_hero_ability_intent()` 及两处调用点 | 本地技能/装备执行、PVP 广播包装 |
| `scripts/ui/hand_view.gd` | `_is_authoritative()` 及 4 处守卫、`replace_hand_with()` | 本地牌堆补位与动画（恢复成"手牌只来自本地 `Game.deck`"） |
| `scripts/ui/action_order_bar.gd`、`scripts/core/turn_system.gd`、`scripts/core/equipment_manager.gd`、`scripts/app/test_main.gd` | **未改**：其中 `Net.send_to_room(...)` / `Net.get_room_players()` 调用保留，靠空壳恒为 no-op | — |

---

## 4. CI 与工具链改动

| 文件 | 改动 |
|---|---|
| `.github/workflows/ci.yml` | 删除 `go-server` job（Go 中继）；删除 `headless-smoke` 里 pvp / hero-render / authority / authority-board / v2-wiring / v2-battle-client / authority-main / net-v2 / server-session / 手牌渲染 共 10 个步骤；**新增**「演武切磋入口冒烟」步骤（`SparringPanelTest`）；上传产物清单同步收缩 |
| `tools/ci/run_headless_matrix.ps1` | 场景表从 21 个缩到 **11 个**本地场景（含新增的 `sparring-entry`）；`_RESULT` 识别正则与基线注释同步更新 |
| `tools/ci/run_headless_smoke.ps1` | `_RESULT` 识别正则去掉 `AUTHORITY`/`PVP`/`HRENDER`；回显的用例行改成规则层 |
| `tools/ci/check_layers.py` | 删除层登记 `("server", SCRIPTS/"server")` 与 `("host", PROJECT/"server")`（目录已不存在），`SHARED_LAYERS` 去掉 `"server"`；违规计数不变（基线只统计 core/rules 层） |
| `.gitignore` | `/dist/` 的注释改成不再引用已删除的 `build_authority_bundle.ps1` |

### 4.1 产物与部署残留清理（第二批，2026-09-16）

代码删完后，磁盘上还留着**历史产物**，按"项目里不该有服务器/联机的东西"的要求一并清掉：

| 路径 | 原来是什么 | 体积 |
|---|---|---|
| `dist/` | 整个目录：`authority-bundle/`（上云产物包 + Godot 运行时 + 权威源码 zip）、`client-fixed/` 与 `NSOC-client-win64-FIXED7/`（旧导出客户端）、`NSOC-client-win64-FIXED7.zip`、`collect-acceptance.ps1`（云上验收采集脚本）、`matrix/`（无头矩阵日志）、`release/`（历史版本三件套） | **440 MB** |
| `dev_gd/nsoc/exports/` | 全部导出产物：`NSOC.exe` / `NSOC.console.exe` / `NSOC.apk`（含 `.idsig`）/ `NSOC.zip` / 联机移除后我导的 `NSOC-fresh.*` | **348 MB** |

清理后 `exports/` 为**空目录**（保留目录本身，因为 `export_presets.cfg` 的
`export_path` 指向 `exports/NSOC.exe` 与 `exports/NSOC.apk`），由使用者在引擎里手动导出。

同时把两个会往仓库写产物的脚本默认值挪到系统临时目录，避免以后再长出 `dist/`：

| 脚本 | 原默认输出 | 现默认输出 |
|---|---|---|
| `tools/ci/run_headless_matrix.ps1` | `<repo>\dist\matrix` | `%TEMP%\nsoc_matrix`（`-OutDir` 可覆盖） |
| `tools/ci/build_release.ps1` | `<repo>\dist\release\<BUILD_ID>` | `%TEMP%\nsoc_release\<BUILD_ID>`（`-OutDir` 可覆盖；CI 本来就显式传 `$RUNNER_TEMP`） |

---

## 5. 文档改动

| 文件 | 改动 |
|---|---|
| `README.md` | 文档表移除 4 份联机文档的链接；新增 2026.9.16 变更条目 |
| `docs/ARCHITECTURE.md` | 目录树 / 分层表 / 子系统表 / 扩展点 / 模式表 / 测试表全部改为**本地口径**；`PVP` 模式标注为死代码；新增"删 autoload 会连锁炸解析"的陷阱 |
| `docs/NEXT.md` | 删除 A1（部署 + 跨机验收）、A2 里的权威上云、B 组里所有联机项（v2 接线 / 权威端 / 中继对接 / E2E）；C 组验收门槛改为**本地 PVE 场景表** |
| `docs/ROADMAP.md` | 阶段 1/2 标注为"已废弃（联机移除）"；当前站位改为本地 |
| `docs/HANDOFF.md` | 从"服务端上云之后还剩什么"改写为"转为纯本地之后还剩什么" |
| `docs/PROTOCOL.md` | → `docs/archive/PROTOCOL.md`（联机协议 v2 设计稿） |
| `docs/DEPLOY.md` | → `docs/archive/DEPLOY.md`（中继 + 权威 + 客户端部署清单） |
| `docs/TWO-PC-CHECKLIST.md` | → `docs/archive/TWO-PC-CHECKLIST.md`（两台电脑真机验收） |
| `docs/OPERATOR-TODO.md` | → `docs/archive/OPERATOR-TODO.md`（权威上云与运维待办） |
| `docs/ARCHIVE-INDEX.md` | 补记 4 份归档文档与本次移除 |
| `重构文档.md` | **未改**：评审稿含大量联机设计，作为历史记录原样保留（正文已明确它是评审稿） |

---

## 6. 云上残留（**需要人工处理**）

代码删干净了，但**云上的进程不会自己停**。之前部署在腾讯云（Windows Server + NSSM）的两个服务：

| 服务 | 作用 | 建议操作 |
|---|---|---|
| `nsoc-server` | Go 中继（`159.75.154.122:8080`） | 停用并卸载 |
| `nsoc-authority` | Godot 权威裁判进程 | 停用并卸载 |

**停用命令**（在服务器上以管理员 PowerShell 执行，二选一）：

```powershell
# 暂时停用（保留服务定义，将来可能恢复）
Stop-Service nsoc-server, nsoc-authority
Set-Service nsoc-server, nsoc-authority -StartupType Manual

# 彻底卸载
Stop-Service nsoc-server, nsoc-authority
sc.exe delete nsoc-server
sc.exe delete nsoc-authority
Remove-Item -Recurse -Force C:\nsoc
```

> 客户端现在**不可能**再连上任何服务器（`Net` 是空壳、大厅无入口），所以即使服务继续跑着
> 也不会有客户端请求过去；但为了省资源和避免误判，还是建议停掉。
> 原来的安装/运维命令见 `docs/archive/OPERATOR-TODO.md` 与 `docs/archive/DEPLOY.md`。

---

## 7. 恢复联机的建议顺序（将来真要做）

1. **取回协议与传输**：`protocol.gd` 全文 + `network_manager.gd` 全文 + `profile_manager.gd`；
2. **取回客户端权威件**：`v2_battle_client.gd` + `auth_board_renderer.gd` + `auth_equip_renderer.gd`；
   把 `Game.enable_v2_authority()` 与 `test_main` 的 `auth/state` 渲染、`play_controller` /
   `hero_action_bar` 的 v2 分支按 §3 表逐条接回；
3. **取回服务端**：`scripts/server/` + `dev_gd/nsoc/server/` + 根 `server/`（Go 中继）+
   `tools/ci/build_authority_bundle.ps1` 与两个 `run_e2e_*.ps1`；
4. **重写大厅**：`sparring_panel.gd` 的联网部分（房间列表 / 准备 / 开局 / 服务器地址对话框）
   与 `_build_authority_config()`；
5. **取回测试**：§1.5 的 10 个场景 + `E2ERelayProbe`，并接回 `ci.yml` 与 `run_headless_matrix.ps1`；
   （§1.5b 的 `SparringPanelTest` 是**反向**契约，恢复联机时应连同它一起改写或删除）
6. **验收**：`docs/archive/PROTOCOL.md` 的消息表 + `docs/archive/DEPLOY.md` 的部署步骤 +
   两条黄金路径哈希逐位不变（`652a3ef2…` / `0576fcc9…`）。

---

## 8. 本次改动后的验证结果

| 检查 | 结果 |
|---|---|
| `godot --headless --path dev_gd/nsoc --import` | ✅ 0 条 `Parse Error` / `SCRIPT ERROR` |
| `py tools/ci/check_layers.py` | ✅ 通过（违规 75，与移除前一致，棘轮未涨） |
| `py tools/ci/check_content.py` | ✅ 通过（17 条既有警告：`ceshi_map.json` 关卡名为空） |
| `powershell tools/ci/run_headless_matrix.ps1` | ✅ **MATRIX_RESULT PASS 11/11** |
| 战役单盘 `STATE_HASH` | ✅ `652a3ef2…` 逐位不变 |
| 多棋盘 PVE `STATE_HASH` | ✅ `0576fcc9…` 逐位不变 |
| `ContentHashTest` | ✅ PASS（5 条）—— `NetProtocol.VERSION` / `content_hash()` 保留正确 |
| 导出链路 | ✅ `Windows Desktop` **release 导出通过**（126.8 MB 单文件内嵌 pck）；`Android` **debug 导出通过**（49.7 MB）；Android **release** 因缺发布密钥库而失败（配置问题，非环境问题，见 `docs/HANDOFF.md` §4） |

