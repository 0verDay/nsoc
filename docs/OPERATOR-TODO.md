# 待办：需要人工执行的事

> 本文件只列**必须由人来做**的事——上传、部署、真机验收、仓库处置。
> 代码侧待办见 `docs/NEXT.md` B 组；实时进度见 `docs/ROADMAP.md`；部署细节见 `docs/DEPLOY.md`。
> 最后更新：中继已上线并验收通过；权威进程待上云。

## 0. 现在的状态

| 组件 | 状态 |
|---|---|
| Go 中继 | ✅ 已上线 `159.75.154.122:8080`（Windows Server + NSSM 服务 `nsoc-server`），**已是新版**（权威派单 + 权威释放 + 用户伪造拦截） |
| 权威进程 | ⏳ 跑在某台**本机**，窗口必须常开 → **待办 1** |
| 客户端 | ✅ 代码就绪。默认走 v1；房主设 `NSOC_AUTHORITATIVE=1` 才走 v2 |
| 端到端链路 | ✅ 跨公网实测通过（连续两局，同一个权威进程） |
| 真实 GUI 对局 | ❌ **从未跑过** → **待办 2** |
| 仓库收尾 | `dev1/` 已删 ✅；4 个远端旧分支待确认 → **待办 4** |

权威进程是这一局的**裁判**：中继（Go）只负责转发与安全策略，**不算规则**；权威进程跑
`BattleServerSession` + `BattleAuthority` + `AuthorityBoard`（和客户端同一套 GDScript），
校验每次出牌、结算、判胜负；客户端只发 `intent/*`、照 `auth/state` 画画面。权威不在线时中继回
`authoritative=false`，客户端**静默退回 v1**（能玩，但没有反作弊）。

---

## 待办 1：把权威进程搬到中继同一台机器

**为什么要做**：现在权威跑在某个人的电脑上，那台机器必须一直开着；窗口一关，进行中的对局
就没人裁决。中继跑在 Windows Server 上，权威可以直接同机——谁都不用开电脑，反作弊永远在线，
而且权威↔中继走 `127.0.0.1`，比绕公网更快。

### 1.1 本地打包（3 条命令）

```powershell
cd C:\Users\qfwjy\Documents\GitHub\nsoc

# ① 项目源码（含 .godot 导入缓存 —— 必须带，否则所有 class_name 解析失败）
tar -a -c -f "$env:USERPROFILE\Desktop\nsoc-authority-src.zip" -C dev_gd nsoc

# ② Godot 两个可执行文件（console 版是 0.2 MB 包装器，它会去同目录找那个 172 MB 的本体）
tar -a -c -f "$env:USERPROFILE\Desktop\godot-4.7.2-win64.zip" -C "C:\D\GodotEngine" `
    Godot_v4.7.2-stable_win64.exe Godot_v4.7.2-stable_win64_console.exe
```

再把这两个脚本从仓库拿走：

- `server\deploy\authority\run-authority.cmd`
- `server\deploy\authority\install-authority-service.ps1`

> **必须用 console 版 exe。** 实测非 console 版把输出重定向到文件时一个字都不写，服务就没有日志可看。

### 1.2 上传并解压（服务器上，管理员 PowerShell）

把上面 4 个文件传到服务器（RDP 拖到桌面），然后：

```powershell
New-Item -ItemType Directory -Force -Path C:\nsoc\authority\Godot | Out-Null

tar -xf "$env:USERPROFILE\Desktop\godot-4.7.2-win64.zip" -C C:\nsoc\authority\Godot
tar -xf "$env:USERPROFILE\Desktop\nsoc-authority-src.zip" -C C:\nsoc\authority
Copy-Item "$env:USERPROFILE\Desktop\run-authority.cmd","$env:USERPROFILE\Desktop\install-authority-service.ps1" C:\nsoc\authority\
```

核对结构（四项都要 True）：

```powershell
Test-Path C:\nsoc\authority\nsoc\.godot                                    # True ← 最关键
Test-Path C:\nsoc\authority\Godot\Godot_v4.7.2-stable_win64.exe            # True
Test-Path C:\nsoc\authority\Godot\Godot_v4.7.2-stable_win64_console.exe    # True
Test-Path C:\nsoc\authority\install-authority-service.ps1                  # True
```

### 1.3 先手工跑一次（确认能起来，再装服务）

```powershell
cd C:\nsoc\authority
.\run-authority.cmd
```

看到 **`[authority] ready, waiting for room assignment`** 就成了。按 `Ctrl+C` 停掉。

> 若报一堆 `Parse Error` / `class_name` 解析不了，说明 `.godot` 没传上去。补救：
> ```powershell
> & "C:\nsoc\authority\Godot\Godot_v4.7.2-stable_win64_console.exe" --headless --path "C:\nsoc\authority\nsoc" --import
> ```

### 1.4 装成服务

```powershell
cd C:\nsoc\authority
powershell -ExecutionPolicy Bypass -File .\install-authority-service.ps1
```

脚本会：找到你已有的 `nssm.exe` → 注册服务 `nsoc-authority`（开机自启、退出 5 秒后自动重启、
日志轮转到 `authority.log`、依赖 `nsoc-server`）→ 启动并回显日志。

### 1.5 验证 + 关掉本机窗口

```powershell
Get-Service nsoc-authority                                    # Running
Get-Content C:\nsoc\authority\authority.log -Tail 10          # [authority] ready, waiting for room assignment
```

⚠️ 云上这个起来之后，**把本机那个权威窗口关掉**——两个权威同时待命会互相抢派单，
而本机那个一关就会把正在打的对局搞挂。

### 1.6 代价（须知）

服务器上跑的是**代码快照**。以后改了规则/数据（`dev_gd/nsoc/scripts/`、`data/`），要重新打包
上传 `nsoc` 目录并 `Restart-Service nsoc-authority` 才生效。中继二进制同理。
自动化打包与内容热更见 `docs/ROADMAP.md`「剩余工作」里的打包一项。

---

## 待办 2：两台电脑跑通真实 GUI 对局

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
| 1. 两端 `STATE_HASH` 一致 | ⚠️ **有障碍**：`STATE_HASH` 只有无头测试场景（`tests/headless_*.gd`）会打印，真实 GUI 对局拿不到。三条出路见下方 |
| 2. 客户端篡改消息无效 | ✅ 传输层已验（伪造 `game/end` 被丢、身份被中继重写、错误密钥 `bad_key`）；GUI 对局只需复看中继日志 |
| 3. 关掉权威建房 → 静默退回 v1 | ✅ 已验（`room/create_ok` 回 `authoritative=false`） |
| 4. 权威崩溃重启后房间不残留 | ⏳ 待验：打一局时 `Stop-Service nsoc-authority` → 重新建房，看中继是否残留旧房 |

**判据 1 的三条出路**（需要你选一条）：

- (a) 给探针加一行输出，改为比对两端收到的 `auth/state`（约 10 分钟，不改产品代码）
- (b) 给真实客户端加一行 `STATE_HASH` 打印（小切片，不影响行为哈希）
- (c) 维持现状，只在无头路径上维持该判据（`docs/ROADMAP.md` 验收表里它已是 `[x]`）

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
Get-Content C:\nsoc\authority\authority.log -Tail 30      # 权威

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
| `Failed to open user://logs/...` / `Failed to read the root certificate store` | Godot 环境级噪音（headless 无证书库 / 无 user 目录），**无害**，忽略 |
