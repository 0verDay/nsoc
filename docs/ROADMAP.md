# NSOC 重构路线与进度

> 现行规范。完整方案见仓库根目录 `重构文档.md`（评审稿，含分层禁令、反作弊设计、清理清单与验收表）。
> 本文件只记录**实时状态**，每次切片完成后更新。
> **最后更新：联机功能整体移除（项目转为纯本地）之后 —— 2026-09-16。**

## 一句话状态

**阶段 0 完成；阶段 1/2 的本地部分完成；阶段 3 本地收尾进行中（约 95%）。**
项目已转为**纯本地**（战役 + 自由对战 + 演义）：联机层、中继服务端、权威裁判进程、
部署与端到端验收脚本、全部联机测试与 CI 步骤已**删除**；PVP 回合/队伍内核保留为死代码。
删除清单与恢复方法见 [`docs/archive/multiplayer-removal.md`](archive/multiplayer-removal.md)。

行为不变的证据线仍是：**本地 headless 矩阵全绿 + 两条黄金路径状态哈希逐位不变**
（战役单盘 `652a3ef2…`、多棋盘 PVE `0576fcc9…`）。
哈希判据以**同一次复核中 HEAD 基线与工作树逐位一致**为准
（文档里旧的字面基线 `cc675fe8…` 已证伪，见 `重构文档.md` §11 阶段 0"基线修正记录"）。

## 四阶段状态

| 阶段 | 进度 | 已完成 | 未完成 |
|---|---|---|---|
| **0 准备与安全网** | ✅ 100% | CI（分层棘轮 / 内容与注册表一致性 / 解析）；状态哈希 `StateHash`；两条黄金路径；本地 headless 测试套件；`.gitignore` 补全 | — |
| **1 反作弊止血 + 权威骨架** | ⛔ **已废弃（联机移除）** | 曾经的 `NetProtocol` 校验、`BattleAuthority`、`BattleServerSession`、Go 中继止血 —— **代码已全部删除**，设计记录留在 `docs/archive/PROTOCOL.md` 与 `重构文档.md` | — |
| **2 结构归一** | ✅ ~90% | 显式注册表（4 张表 + CI 一致性校验）；目录归位（`scripts/` 根目录清零）；章节脚本三合一（−427 行）；斩断 `core→ui`（违规 181→122）；三段 bootstrap 去重 + 死信号清理；显式 `BattleMode`；行动定序去 UI 像素；规则随机源集中；多棋盘黄金路径；**`main.gd` ⟷ `test_main.gd` 合一**（基类 `BattleSceneBase`，净 −217 行） | `BattleSession` 类提取；UI 三胞胎收敛（3 面板管理器 / 3 轮播 / 20 份滚动物理副本） |
| **3 分层深化 + 清理** | 🚧 ~95% | 行动定序去像素；规则随机源集中；死代码清理（45 定义 + 1 死文件，−347 行）；战斗结算与表现分离；动画等待抽象 + 瞬时模式（违规 122→87）；构建产物出库；**文档重写进 `docs/` + 历史稿归档**；**`CellData` 纯数据层 + `Cell` 退化为视图**；**无视图装配**；**无头完整攻击结算**；**规则层纯数据盘验收（`RulesOnDataTest`，并修掉 `Game.play` 未接导致死亡不清算的真 bug）**；**版本三件套（`build_release.ps1` + `ContentHashTest`，构建侧与引擎内容哈希钉死）**；**反射收敛首切片（12 处死 `has_method`，违规 87 → 75）**；**联机功能整体移除**（客户端 + 服务端 + 部署链 + 测试 + CI 步骤；`Net` 降级空壳、`NetProtocol` 降级常量表、PVP 内核保留为死代码） | `turn_system` 拉直 `await`；反射收敛余下 35 处；表现依赖下沉；`board_slot_factory` 类型收敛；**停掉云上残留服务（需要你）**；可用的导出 preset |

## 对照四条目标要求

| 要求 | 进度 | 判定依据 |
|---|---|---|
| 1 结构健康、保留扩展性 | ~92% | 分层违规 **181 → 87 → 75**；目录与分层一一对应；新增扩展点（`BattleMode` / 显式注册表）都有 CI 守护；**联机移除后删掉了一整层（`scripts/server/` + `server/`）与一处跨机契约** |
| 2 确保无法作弊 | — **不再适用** | 联机已移除（无对手、无网络、无服务端），反作弊链路整体删除。原设计记录见 `docs/archive/PROTOCOL.md` |
| 3 双端更新流程简单 | — **不再适用** | 只剩单机：规则/数据各一份，内容变更靠重发客户端。版本三件套仍保留（`version.json` / `content_manifest.json` / `RELEASE.txt`） |
| 4 删冗余文档与无用脚本 | ✅ ~99% | 代码死代码清理 + 构建产物出库已完成；根目录文档已 `git mv` 进 `docs/archive/`、`dev1/` 已删、`docs/` 现行规范已建立、README 已加索引；**本次又归档 4 份联机文档（PROTOCOL / DEPLOY / TWO-PC-CHECKLIST / OPERATOR-TODO）+ 删除联机部署链**；**仅剩** 4 个已合并远端旧分支的处置（待你确认） |

## 剩余工作（按建议顺序）

1. **停掉云上残留服务**（唯一需要你动手的事，约 2 分钟）：`nsoc-server` / `nsoc-authority`
   两个 NSSM 服务不会自己停。命令见 `docs/HANDOFF.md` §2① 与
   `docs/archive/multiplayer-removal.md` §6。
2. **本地验证矩阵已跑通**：`powershell -File tools\ci\run_headless_matrix.ps1` 输出
   `MATRIX_RESULT PASS`（**11/11**：10 个既有本地场景 + 新增的演武切磋入口契约测试）；
   两条黄金路径哈希逐位不变（`652a3ef2…` / `0576fcc9…`）。
3. **仓库收尾**：删除 4 个已合并的远端旧分支（需你确认；`dev1/` 已删 ✅）
4. **分层深化收尾**：反射调用收敛（`has_method` 22 + `.call` 13）、表现依赖下沉
   （`Control`/`Tween`/`get_tree` 约 12 处）、`board_slot_factory` 的 `grid_cells` 类型收敛 ——
   逐项做法与验收门槛见 `docs/NEXT.md` B 组
5. **打包**：🟡 版本三件套已完成（`tools\ci\build_release.ps1` + `ContentHashTest`）；
   **仍缺**可用的 export preset 与导出模板安装（见 `docs/NEXT.md` B5）
6. 次要：`BattleSession` 提取、UI 三胞胎收敛

## 验收标准（逐条勾）

- [x] CI 通过：脚本解析 / 分层规则 / 内容与注册表一致性
- [ ] `core/` 内 `Control|Panel|Node2D|add_child|create_tween|create_timer|get_tree()|has_method` 计数 = 0（当前 75 处，全部为既有硬骨头）
- [x] `core/` → `ui/` 的 `class_name` 引用 = 0
- [x] 本地四类对局路径冒烟通过（战役单盘黄金路径 ✅、多棋盘 PVE ✅、演义出征 ✅、自由对战 ✅）
- [x] 同种子 + 同输入 → 状态哈希一致（跨进程、跨副本、跨分辨率、跨"瞬时/普通"模式）
- [x] 新增一张卡 = 只改 `data/all_cards.json`（+ 新效果时登记一行）
- [x] 新增一关 = 只加一个 JSON
- [x] 一条命令产出 `version.json` + `content_manifest.json` + `RELEASE.txt`（导出预设仍缺，脚本会优雅跳过）
- [x] `git ls-files` 无 `*.exe` / `*.log` / `*.pyc`
- [x] 根目录只剩 `README.md` + `重构文档.md` + 工程目录
- [x] 死代码清单全部清除且无回归
- [x] **联机入口可用但不可用性明确**：主菜单「演武切磋」可进入，四模式页可切换，创建/加入房间均不可用且给出明确提示
- [x] **仓库内已无联机实现**：无 WebSocket 连接、无中继、无权威进程、无联网调用（`git grep` 可核）
- [ ] 云上 `nsoc-server` / `nsoc-authority` 两个服务已停用（**待你操作**）

### 已废弃、不再验收的（联机相关，随模块删除）

- ~~篡改服务器消息被拒 / 身份不可冒充 / 房间状态不被破坏~~（无服务端）
- ~~抓包验证对手手牌不可见~~（无对手）
- ~~1v1 / 1v3 / 3v3 的 PVP 三路径哈希~~（PVP 内核保留为死代码，但无入口）
- ~~跨机 / 跨公网部署与验收（判据 1~4）~~
