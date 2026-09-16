> ⚠️ **【已归档 2026-09-16】本文描述的是已删除的联机功能。**
> 项目已转为纯本地（战役 + 自由对战 + 演义），中继服务端 / 权威裁判进程 / 客户端联机层
> 全部移除。本文保留仅作历史记录与恢复参考 —— 删除清单与恢复方法见
> [`multiplayer-removal.md`](multiplayer-removal.md)。
# 待办：需要人工执行的事

> 本文件只列**必须由人来做**的事——上传、部署、真机验收、仓库处置。
> 代码侧待办见 `docs/NEXT.md` B 组；实时进度见 `docs/ROADMAP.md`；部署细节见 `docs/DEPLOY.md`。
> 最后更新：权威进程已上云并与中继同机常驻；云上端到端复验 PASS。下一步是两台电脑真机 GUI 验收。

## 0. 现在的状态

| 组件 | 状态 |
|---|---|
| Go 中继 | ✅ 已上线 `159.75.154.122:8080`（Windows Server + NSSM 服务 `nsoc-server`），**已是新版**（权威派单 + 权威释放 + 用户伪造拦截） |
| 权威进程 | ✅ **已上云**，与中继同机常驻（NSSM 服务 `nsoc-authority`，开机自启、崩溃自动重启）。日志：`[authority] ready, waiting for room assignment` |
| 客户端 | ✅ 代码就绪。默认走 v1；房主设 `NSOC_AUTHORITATIVE=1` 才走 v2 |
| 端到端链路 | ✅ 云上复验 PASS（`authoritative=true`、`auth/hello`/`auth/state`/`intent/end_turn`/`auth/event` 双向到达） |
| 真实 GUI 对局 | ❌ **从未跑过** → **待办 2** |
| 仓库收尾 | `dev1/` 已删 ✅；4 个远端旧分支待确认 → **待办 4** |

权威进程是这一局的**裁判**：中继（Go）只负责转发与安全策略，**不算规则**；权威进程跑
`BattleServerSession` + `BattleAuthority` + `AuthorityBoard`（和客户端同一套 GDScript），
校验每次出牌、结算、判胜负；客户端只发 `intent/*`、照 `auth/state` 画画面。权威不在线时中继回
`authoritative=false`，客户端**静默退回 v1**（能玩，但没有反作弊）。

---

## 待办 1：把权威进程搬到中继同一台机器（✅ 已完成）

部署方式：把一份**代码快照**（项目源码 + `.godot` 导入缓存）和 Godot 4.7.2 运行时一起放到
中继那台机器的 `C:\nsoc\authority\`，用 NSSM 注册成服务。服务器上现在是这样：

```
C:\nsoc\
├─ nsoc-server.exe / relay.log / run-relay.cmd ...   ← 中继那套，别动
└─ authority\
    ├─ Godot\Godot_v4.7.2-stable_win64.exe           （172.5 MB 本体）
    ├─ Godot\Godot_v4.7.2-stable_win64_console.exe   （0.2 MB 包装器，必须有）
    ├─ nsoc\                                          （项目，含 .godot\）
    ├─ run-authority.cmd
    ├─ install-authority-service.ps1
    └─ authority.log / authority.out.log
```

### 1.1 本地打包（一条命令）

```powershell
cd <仓库路径>
powershell -NoProfile -ExecutionPolicy Bypass -File tools\ci\build_authority_bundle.ps1
```

产物在 `dist\authority-bundle\`（`dist/` 已在 `.gitignore` 里）：

| 文件 | 说明 |
|---|---|
| `nsoc-authority-src.zip` | 项目快照，含 `.godot`（导入缓存），已排除 `exports\` |
| `godot-4.7.2-win64.zip` | 两个 Godot exe，都在压缩包根目录 |
| `run-authority.cmd` | 手工试跑脚本 |
| `install-authority-service.ps1` | NSSM 服务安装脚本 |
| `SHA256SUMS.txt` / `PUT-ON-SERVER.txt` | 校验和 / 服务器端说明（不必上传） |

> **脚本会先跑一次 headless `--import` 刷新类名缓存**，并自检缓存条数（源码里有多少个
> `class_name`）。这一步不能省：旧缓存会让服务器上**所有全局类解析失败**。
> 必须用 **console 版** Godot：非 console 版把输出重定向到文件时一个字都不写。

### 1.2 上传并解压（服务器上，管理员 PowerShell）

上传上面 4 个文件到服务器（例如 `C:\nsoc`），然后：

```powershell
New-Item -ItemType Directory -Force -Path C:\nsoc\authority\Godot | Out-Null

tar -xf C:\nsoc\godot-4.7.2-win64.zip   -C C:\nsoc\authority\Godot
tar -xf C:\nsoc\nsoc-authority-src.zip  -C C:\nsoc\authority
Copy-Item C:\nsoc\run-authority.cmd, C:\nsoc\install-authority-service.ps1 C:\nsoc\authority\
```

核对（四项都要 True）：

```powershell
Test-Path C:\nsoc\authority\nsoc\.godot                                  # 最关键
Test-Path C:\nsoc\authority\Godot\Godot_v4.7.2-stable_win64.exe
Test-Path C:\nsoc\authority\Godot\Godot_v4.7.2-stable_win64_console.exe
Test-Path C:\nsoc\authority\install-authority-service.ps1
```

顺带确认类名缓存是最新的（应输出你项目的全局类数量，且 `has BattleMode = True`）：

```powershell
$f = "C:\nsoc\authority\nsoc\.godot\global_script_class_cache.cfg"
"cached classes = " + (Select-String -Path $f -Pattern '"class":' -AllMatches).Matches.Count
"has BattleMode = " + [bool](Select-String -Path $f -Pattern 'BattleMode' -Quiet)
```

### 1.3 先手工跑一次（确认能起来，再装服务）

```powershell
cd C:\nsoc\authority
.\run-authority.cmd
```

看到 **`[authority] ready, waiting for room assignment`** 就成了。按 `Ctrl+C` 停掉。

> 若报一堆 `Parse Error: Identifier "..." not declared in the current scope` /
> `Could not find type "..."`，说明 `.godot` 的类名缓存是旧的（或没传上去）。补救：
> ```powershell
> & "C:\nsoc\authority\Godot\Godot_v4.7.2-stable_win64_console.exe" --headless --path "C:\nsoc\authority\nsoc" --import
> ```

### 1.4 装成服务

```powershell
cd C:\nsoc\authority
powershell -ExecutionPolicy Bypass -File .\install-authority-service.ps1
```

脚本会：找到你已有的 `nssm.exe` → 注册服务 `nsoc-authority`（开机自启、退出 5 秒后自动重启、
日志轮转到 `authority.log`、`DependOnService=nsoc-server`）→ 启动并回显日志。

### 1.5 验证 + 关掉本机窗口

```powershell
Get-Service nsoc-authority                                    # Running / Automatic
Select-String -Path C:\nsoc\authority\authority*.log -Pattern 'ready|assigned|start_match|accepted|rejected'
```

> ⚠️ 云上这个起来之后，**把本机那个权威窗口关掉**——两个权威同时待命会互相抢派单，
> 而本机那个一关就会把正在打的对局搞挂。
>
> 日志有两个文件：装服务脚本把 stdout 写进 `authority.out.log`、stderr 写进 `authority.log`，
> 而 Godot 的 `print` 实测走 **stderr** —— **两个都看**。

### 1.6 代价（须知）

服务器上跑的是**代码快照**。以后改了规则/数据（`dev_gd/nsoc/scripts/`、`data/`），要重跑
打包脚本、重新上传 `nsoc` 目录并 `Restart-Service nsoc-authority` 才生效。中继二进制同理。
自动化打包与内容热更见 `docs/ROADMAP.md`「剩余工作」里的打包一项。

---

## 待办 2：两台电脑跑通真实 GUI 对局

**操作步骤见 [`docs/TWO-PC-CHECKLIST.md`](TWO-PC-CHECKLIST.md)** —— 一页清单，每步都标了
【本机】/【服务器】/【电脑 B】，含重新打包带 `state_hash` 的权威快照、判据 4 的操作与通过标准。

这是**唯一还没验过的一环**：传输链路已经用探针验过（`intent/end_turn`），但**真实 GUI 出牌走 v2
从未跑过**——`docs/ROADMAP.md` 里 v2 客户端的证据全部来自无头测试。

两台电脑都要有**当前代码**的仓库 + Godot 4.7.x（旧导出的 exe/apk 里没有 v2 代码）。

```powershell
# 电脑 A（房主）—— 只有它需要设这个环境变量
cd <仓库路径>
$env:NSOC_AUTHORITATIVE = "1"
& "C:\D\GodotEngine\Godot_v4.7.2-stable_win64_console.exe" --path dev_gd\nsoc

# 电脑 B（加入方）
cd <仓库路径>
& "C:\D\GodotEngine\Godot_v4.7.2-stable_win64_console.exe" --path dev_gd\nsoc
```

大厅里 A 建房 → 房号给 B → B 加入 → 房主开始。

**第一局走最小路径**：各出一张单位卡 → 结束回合，确认两端画面一致，再逐步试法术 / 装备 /
英雄技能。

**盯三处**：

| 看哪 | 期望 |
|---|---|
| 权威日志 | `assigned room=xxxxx` → `start_match players=[...]` → 每次操作 `accepted=true/false reason=...` |
| 两个客户端 | 盘面 / 手牌 / 费用 / 回合按钮都跟着权威走 |
| 打完一局再开一局 | 权威日志重新出现 `assigned room=`（现在不需要重启权威） |

> **没看到 `assigned room` = 你在打 v1**，说明房主的 `NSOC_AUTHORITATIVE=1` 没生效。
> 权威日志里出现 `accepted=false` 时，把那一行贴给开发，按 `reason=` 定位。

---

## 待办 3：A1 验收判据（做完待办 1+2 后核对）

| 判据 | 现状 |
|---|---|
| 1. 两端状态一致 | ✅ **已落地**：选 (b)+——权威进程每次状态变化打印 `[authority] state_hash <sha256> turn=N active=<pid>`（`BattleAuthority.state_hash()`），真机验收只需 grep 这一行，见下方说明 |
| 2. 客户端篡改消息无效 | ✅ 传输层已验（伪造 `game/end` 被丢、身份被中继重写、错误密钥 `bad_key`）；GUI 对局只需复看中继日志 |
| 3. 关掉权威建房 → 静默退回 v1 | ✅ 已验（`room/create_ok` 回 `authoritative=false`） |
| 4. 权威崩溃重启后房间不残留 | ⏳ **真机待验**（服务化部署 + 自动重启那一层，操作见 [`docs/TWO-PC-CHECKLIST.md`](TWO-PC-CHECKLIST.md) 判据 4）。**中继侧语义已有单测**：`server/authority_relay_test.go` 的 `TestAuthorityCrashDoesNotLeakIntoNextMatch`（崩溃 → 旧房间不再挂权威 → 重启注册回待命 → 新局仍能派单 → 旧房间不被新权威接管） |

### 判据 1 怎么用（2026-09-16 落地）

原判据要求"两端各自 `STATE_HASH` 一致"，但 `STATE_HASH` 只在无头测试场景打印，真实 GUI 对局没有。
**现在改为由权威进程打印自己那份状态的哈希** —— 这比"两端各算一遍再比对"更强：

- v2 下客户端**只镜像** `auth/state`（服务器给什么就画什么），本来就不可能各自算出不同状态；
- 权威是唯一算规则的一端，它的哈希不变式是"服务器只持有一份真相，且双方拿到的是同一份"；
- `state_hash()` = 对**全部玩家各自的过滤视图**（按 pid 排序）取规范化 JSON 的 sha256，
  所以它同时覆盖"手牌/牌堆/费用/英雄血量/盘面/装备"和"暗牌过滤"。

真机验收（两台电脑打完一局后，在服务器上执行）：

```powershell
Select-String -Path C:\nsoc\authority\authority*.log -Pattern 'state_hash'
# 期望形如：
# [authority] state_hash 6150a14b...  turn=1 active=e2e-p1
# [authority] state_hash 3f9c...      turn=2 active=e2e-p2
```

判读：每回合至少一行、`turn=` 随回合递增即证明权威在持续结算；同一局内若某回合状态没变，
则不会重复打印（有意去重，避免刷屏）。`tests/AuthorityBoardTest.gd` 守着它的三条性质
（定长 64 位十六进制 / 同种子同输入跨会话一致 / 状态变了必变）。

> 被否决的另外两条出路：(a) 只比对两端收到的 `auth/state`——比权威自哈希弱，且要走探针不是真机；
> (c) 只在无头路径维持——真机这一格仍然是空的。

---

## 待办 4：仓库收尾

| 事项 | 状态 |
|---|---|
| `dev1/`（旧 JS 原型，7 个条目） | ✅ **已删除**（2026-09-15）。记录见 `docs/ARCHIVE-INDEX.md`「已删除（未归档）」 |
| 4 个已合并的远端旧分支 | ⏳ 待你确认是否删除：`origin/branch_3v3`、`origin/multi-chessboard-branch`、`origin/multiplayer_1v3_branch`、`origin/multiplayer_branch` |

删远端分支（确认后执行）：

```bash
git push origin --delete branch_3v3 multi-chessboard-branch multiplayer_1v3_branch multiplayer_branch
```

> 这是**共享远端**上的操作，删掉后本地 `git branch -r` 不再显示，但已合并的提交都在 `main` 历史里，可恢复。

---

## 附录：常用运维命令

两个服务都在中继那台机器上，都用 NSSM 托管。

```powershell
# 状态
Get-Service nsoc-server, nsoc-authority | Select-Object Name, Status, StartType

# 日志
Get-Content C:\nsoc\relay.log -Tail 30                    # 中继（stdout/stderr 都在这）
Get-Content C:\nsoc\authority\authority.out.log -Tail 30  # 权威 stdout
Get-Content C:\nsoc\authority\authority.log -Tail 30      # 权威 stderr（Godot 的 print 走这里）

# 一条命令搜权威的关键行（两个日志都覆盖）
Select-String -Path C:\nsoc\authority\authority*.log -Pattern 'ready|assigned|start_match|accepted|rejected'

# 重启（改完规则/数据后）
Restart-Service nsoc-authority
Restart-Service nsoc-server

# 停 / 起
Stop-Service nsoc-authority ; Start-Service nsoc-authority

# 健康检查
curl.exe http://127.0.0.1:8080/health                     # ok
```

**密钥**：`NSOC_AUTHORITY_KEY` 必须在中继与权威两侧完全一致（已分别写在 `run-relay.cmd`
与 `install-authority-service.ps1` 的默认值里）。不一致时权威日志会出现
`authority/rejected{reason:"bad_key"}`，中继日志会出现 `SECURITY authority join rejected (bad key)`。

**关键日志行对照**：

| 日志 | 含义 |
|---|---|
| `authority registration enabled (key length=64)` | 中继已启用权威注册（少了这句说明 `NSOC_AUTHORITY_KEY` 没设，反作弊等于关闭） |
| `authority ready ... (waiting for assignment)` | 权威已进待命池，可以被派单 |
| `authority assigned room=xxxxx` | 派单成功，这一局走 v2 |
| `authority released room=xxxxx reason=... -> standby` | 一局结束、权威回到待命，可接下一局 |
| `[authority] state_hash <sha256> turn=N active=<pid>` | **权威状态哈希**（状态变化时打印一行）。判据 1 的真机证据行，见待办 3 |
| `Failed to open user://logs/...` / `Failed to read the root certificate store` | Godot 环境级噪音（headless 无证书库 / 无 user 目录），**无害**，忽略 |
