# NSOC 重构路线与进度

> 现行规范。完整方案见仓库根目录 `重构文档.md`（评审稿，含分层禁令、反作弊设计、清理清单与验收表）。
> 本文件只记录**实时状态**，每次切片完成后更新。最后更新：中继上线腾讯云（Windows Server + NSSM）+ 修掉"一个权威进程只能服务一局"（中继释放 + 权威主动交还 + 断线重连）。

## 一句话状态

**阶段 0 完成；阶段 1/2/3 进行中，整体约完成 75~80%。**
分支 `refactor`（基线 tag `pre-refactor`），61 个提交，全部以"二十套 headless 测试全绿 + 两条黄金路径状态哈希逐位不变"作为行为不变的证据。
> **另有一条本地端到端联调**（不依赖 CI）：`powershell -File tools\ci\run_e2e_local.ps1` —— 构建并启动 Go 中继 → 启客户端探针（建房/加入/握手）→ 读房号 → 启权威进程 → 探针发意图并断言双方收到权威结果。当前结果 **E2E_RESULT PASS**。
> 哈希判据以**同一次复核中 HEAD 基线与工作树逐位一致**为准（文档里旧的字面基线 `cc675fe8…` 已证伪，见 `重构文档.md` §11 阶段 0"基线修正记录"）。

## 四阶段状态

| 阶段 | 进度 | 已完成 | 未完成 |
|---|---|---|---|
| **0 准备与安全网** | ✅ 100% | CI 三件套（分层棘轮 / 内容与注册表一致性 / 解析）；状态哈希 `StateHash`；两条黄金路径；20 套 headless 测试；`.gitignore` 补全 | — |
| **1 反作弊止血 + 权威骨架** | 🚧 ~60% | `NetProtocol`（v2 协议、服务器专属消息定义）；`BattleAuthority`（四道校验 + 私有视图 + 权威事件）；`BattleServerSession`（握手 / 伪造消息丢弃 + 审计 / 按玩家路由）；78 条断言；**Go 中继层止血**（`server/security.go`：服务器专属消息丢弃 + 房主校验 + 身份重写 + 每连接 20 条/秒限速，10 个 Go 单测）；**结算不再信任对端消息**（本端确定性推导 + 投降走显式网络消息） | **客户端接入权威路径**（`action/*` → `intent/*`）；棋盘结算移入 `BattleAuthority` |
| **2 结构归一** | ✅ ~90% | 显式注册表（4 张表 + CI 一致性校验）；目录归位（`scripts/` 根目录清零）；章节脚本三合一（−427 行）；斩断 `core→ui`（违规 181→122）；三段 bootstrap 去重 + 死信号清理；显式 `BattleMode`；行动定序去 UI 像素；规则随机源集中；多棋盘黄金路径 | `BattleSession` 类提取；~~**`main.gd` ⟷ `test_main.gd` 合一**~~ ✅ 已完成（基类 `BattleSceneBase`：18 个逐字相同函数 + 33 个公共成员上移，main 863→614 / test_main 1467→1228，净 −217 行）；UI 三胞胎收敛（3 面板管理器 / 3 轮播 / 20 份滚动物理副本） |
| **3 分层深化 + 反作弊收口 + 清理** | 🚧 ~99% | 行动定序去像素；规则随机源集中；死代码清理（45 定义 + 1 死文件，−347 行）；战斗结算与表现分离；动画等待抽象 + 瞬时模式（违规 122→87）；构建产物出库；**文档重写进 `docs/` + 6 份历史稿归档 + 删 `step8_content.txt`**；**中继层止血 + 结算去网络依赖**；**`CellData` 纯数据层 + `Cell` 退化为视图**；**无视图装配**；**无头完整攻击结算**；**权威端棋盘结算 + 回合推进 + 终局判定 + 法术 + 英雄技能 + 装备**；**客户端 v2 传输层（默认关闭）**；**权威进程与中继对接（`role=authority` + key + 意图只发权威）**；**Godot 权威进程入口（`AuthorityMain`）**；**本地端到端联调跑通（`run_e2e_local.ps1`：中继+权威+探针，E2E PASS）**；**v2 战斗客户端核心（`V2BattleClient`：意图上行 + 权威镜像）**；**权威盘面渲染件（`AuthBoardRenderer`：按 `auth/state` 重绘本地棋盘，含幻影/幂等）**；**v2 接线（`Game.enable_v2_authority()` + 出牌/结束回合/投降走 `intent/*`；默认关闭，开关关闭时五条路径哈希不变）**；**大厅派单 + 开局配置交接（待命权威 / `authoritative:true` 建房 / `authority/start_match`；无权威时静默退回 v1）**；**大厅启用 v2 + 手牌/费用/回合按钮按 `auth/state` 渲染（`HandView.replace_hand_with`）**；**细粒度逐动作事件（`board_action` 广播）**；**规则层纯数据盘验收（`RulesOnDataTest`，并修掉 `Game.play` 未接导致权威端死亡不清算的真 bug）**；**PVP 三路径 headless 冒烟（`HeadlessPvp`：真实 TestMain 场景 + 确定性远端替身；大厅载荷解析抽成 `PvpStart.resolve` 共用）**；**`main`/`test_main` 合一（基类 `BattleSceneBase`：18 个逐字相同函数 + 33 个公共成员上移，净 −217 行）**；**装备按 `auth/state` 渲染（`AuthEquipRenderer` + 装备出牌/激活走 `intent/*`）并修掉 `DeckManager` 跨对局墓地/除外残留**；**中继上线真机（腾讯云 Windows Server + NSSM，`server/deploy/`：二进制 + 启动脚本 + 计划任务脚本）**；**权威可连续服务多局**（中继房间销毁时释放回待命 + 对局结束权威主动交还 + 断线退避重连 + `Game.registry` 跨局清理；修掉"一个权威进程只能服务一局"）；**云上端到端验收脚本（`tools/ci/run_e2e_cloud.ps1`，实测跨公网 E2E PASS）** | `turn_system` 拉直 `await`；**部署与跨机验收（需要你）**；**真实 GUI 对局首次跑通（需要你）** |

## 对照四条目标要求

| 要求 | 进度 | 判定依据 |
|---|---|---|
| 1 结构健康、保留扩展性 | ~85% | 分层违规 **181→87**；目录与分层一一对应；新增扩展点（`BattleMode` / 显式注册表 / 协议层）都已落地并有 CI 守护 |
| 2 确保无法作弊 | ~100% | **服务器权威链路代码层面已闭环**：中继（待命权威池 / 派单 / 无权威静默退回 v1 / 意图与开局配置只发权威）；权威进程（待命注册、接派单、按大厅配置开局、`tick` 出站）；权威规则（落子/整侧行动/终局/法术/技能/装备/费用效果/**死亡清算**）；客户端（`Net` v2 原语 + `V2BattleClient` + `AuthBoardRenderer` + `HandView.replace_hand_with` + `Game.enable_v2_authority()` 接线 + `board_action` 逐动作事件；**装备栏按 `you.equipments` 渲染 + 出牌/激活走 `intent/*`**）；大厅（`authoritative` 建房 + `start_match` 交配置 + 进战斗前开 v2）。**剩余**：**未做真机/跨机验收**（需要部署，属人类外部动作） |
| 3 双端更新流程简单 | ~80% | 规则/数据/协议各只有一份；版本 + 内容哈希握手已实现；三件产物打包与内容热更未落地 |
| 4 删冗余文档与无用脚本 | ~95% | 代码死代码清理 + 构建产物出库已完成；根目录 6 份文档已 `git mv` 进 `docs/archive/`、`step8_content.txt` 已删、`docs/` 现行规范已建立、README 已加索引；**仅剩** `dev1/` 标注与 4 个已合并远端旧分支的处置（待你确认） |

## 剩余工作（按建议顺序）

1. **中继重新部署到腾讯云**：`server/deploy/nsoc-server.exe` 已用新代码重建（权威释放 + `room/authority_release`），线上跑的还是旧的止血版 —— 需按 `docs/DEPLOY.md` §3 重新上传并重启 NSSM 服务
2. **真实 GUI 对局首次跑通**（两台电脑，房主设 `NSOC_AUTHORITATIVE=1`）：传输链路已验，但真实出牌/法术/装备走 v2 从未跑过；判据见 `docs/NEXT.md` A1
3. **仓库收尾**：`dev1/` 标注废弃、删除 4 个已合并的远端旧分支（需你确认）
4. **分层深化收尾**：反射调用收敛（`has_method` 34 + `.call` 13）、表现依赖下沉（`Control`/`Tween`/`get_tree` 约 12 处）、`board_slot_factory` 的 `grid_cells` 类型收敛 —— 逐项做法与验收门槛见 `docs/NEXT.md` B 组
5. **打包**：一条命令产出三件产物 + `version.json`（缺无头服 preset 与打包脚本）
6. 次要：`BattleSession` 提取、UI 三胞胎收敛
7. 已完成（不再排）：`cell.gd` 数据/表现分离 ✅、客户端接入权威路径 ✅、Go 侧止血 ✅、`main`/`test_main` 合一 ✅、规则纯数据盘验收 ✅、装备按权威渲染 ✅、权威连续服务多局 ✅

## 验收标准（每阶段结束逐条勾）

- [x] CI 通过：脚本解析 / 分层规则 / 内容与注册表一致性 / 一局状态哈希
- [ ] `core/` 内 `Control|Panel|Node2D|add_child|create_tween|create_timer|get_tree()|has_method` 计数 = 0（当前 87 处，全部为既有硬骨头）
- [x] `core/` → `ui/` 的 `class_name` 引用 = 0
- [x] 篡改服务器消息被拒：伪造断线 / 判胜 / 重开 / 结果字段全部丢弃且不影响他人（`ServerSessionTest` + Go `security_test.go`）
- [x] 身份不可冒充：payload 里的 `player_id` / `uuid` 被中继层改写为连接真实 uuid（`security_test.go`）
- [x] 房间状态不被客户端消息破坏：伪造 `game/end` 不再销毁房间、任意成员不能 `game/start`（`security_test.go`）
- [x] 抓包验证：对手手牌不可见（`auth/state` 只给数量）
- [x] 同种子 + 同输入 → 状态哈希一致（跨进程、跨副本、跨分辨率、跨"瞬时/普通"模式）
- [x] 新增一张卡 = 只改 `data/all_cards.json`（+ 新效果时登记一行）
- [x] 新增一关 = 只加一个 JSON
- [ ] 一条命令产出三件产物 + `version.json`
- [x] `git ls-files` 无 `*.exe` / `*.log` / `*.pyc`
- [x] 根目录只剩 `README.md` + `重构文档.md` + 工程目录（本批归档后）
- [x] 死代码清单全部清除且无回归
- [x] 1v1 / 1v3 / 3v3 / 战役 / 演义 五条路径全流程冒烟通过（战役 ✅ 单盘黄金路径、多棋盘 PVE ✅ 第二条黄金路径、PVP 三条 ✅ `HeadlessPvp`：真实 `TestMain.tscn` + 确定性远端替身，两次运行三条哈希一致）
