> ⚠️ **【已归档 2026-09-16】本文描述的是已删除的联机功能。**
> 项目已转为纯本地（战役 + 自由对战 + 演义），中继服务端 / 权威裁判进程 / 客户端联机层
> 全部移除。本文保留仅作历史记录与恢复参考 —— 删除清单与恢复方法见
> [`multiplayer-removal.md`](multiplayer-removal.md)。
# 两台电脑验收 · 一页清单（A1 最后一块）

> 每一步都标了**在哪台机器上执行**。别把【服务器】的命令粘到【本机】，也别反过来
> （上次就是这么踩的：`cd C:\Users\yy197\...` 在服务器上不存在）。
>
> 现状：中继 + 权威都在云上常驻 ✅；云上端到端探针 PASS ✅；**真实 GUI 对局从未跑过** ❌。
> 本文就是把它跑通并采集证据的最小步骤。判据定义见 `docs/NEXT.md` A1、`docs/OPERATOR-TODO.md` 待办 2/3。

机器代号：

| 代号 | 是什么 |
|---|---|
| **服务器** | 腾讯云 Windows Server，跑中继（`nsoc-server`）与权威（`nsoc-authority`） |
| **电脑 A** | 你的主力机，房主；仓库在 `C:\Users\yy197\Documents\GitHub\nsoc` |
| **电脑 B** | 第二台机器，加入方；需要**当前代码**的仓库 + Godot 4.7.x |

---

## 第 0 步【本机】确认权威快照（已经替你打好了）

快照**已经生成好，直接可用**，不用再跑打包命令：

```
C:\Users\yy197\Documents\GitHub\nsoc\dist\authority-bundle\nsoc-authority-src.zip
```

它包含**当前全部代码**：`state_hash` 日志、判据 4 相关修复、B1 首切片（反射收敛 87→75）。
上传前可在本机核对（`Get-FileHash ... -Algorithm SHA256` 应得到）：

```
891E088C205ACA6F040A76E24ED92094B6B8A6B23189026AEC338B10D26B1655  nsoc-authority-src.zip
```

> 想自己重打（改了代码/数据之后）：
> ```powershell
> cd C:\Users\yy197\Documents\GitHub\nsoc
> powershell -NoProfile -ExecutionPolicy Bypass -File tools\ci\build_authority_bundle.ps1
> ```
> 脚本会先跑一次 `--import` 刷新类名缓存并自检条数（应为 95），**这一步不能省** ——
> 带了过期缓存上服务器会让所有 `class_name` 解析失败。

**只需要传这一个 zip**（Godot 运行时服务器上已经有了，不必重传 82 MB 那个）。

顺带把采集脚本也带上去（第 4 步用，只有几 KB）：

```powershell
# 传到服务器 C:\nsoc\ （RDP 拖拽即可）
server\deploy\collect-acceptance.ps1
```

## 第 1 步【服务器】替换快照并重启权威

把上面的 `nsoc-authority-src.zip` 传到服务器 `C:\nsoc\`，然后管理员 PowerShell：

```powershell
tar -xf C:\nsoc\nsoc-authority-src.zip -C C:\nsoc\authority
"unzip exit = $LASTEXITCODE"

Restart-Service nsoc-authority
Start-Sleep -Seconds 12

Get-Service nsoc-authority | Select-Object Name, Status
Select-String -Path C:\nsoc\authority\authority*.log -Pattern 'ready, waiting' | Select-Object -Last 2
```

期望：`Running`，且日志最后一行是 `[authority] ready, waiting for room assignment`。

> 快速自检新代码有没有生效：对局开始后日志里应出现 `[authority] state_hash ...`。

---

## 第 2 步【电脑 A + 电脑 B】各自启动客户端

### 方式一（推荐）：成品客户端，双击即开

**不用装 Godot、不用拉仓库**。成品在：

```
dist\NSOC-client-win64-single.zip      （59 MB）
```

拷到两台电脑 → 解压 → **双击 `NSOC.exe`**（127 MB 单文件，资源已内嵌，**不需要**旁边的 `.pck`）。
想让日志可见就双击 `NSOC.console.exe`（0.1 MB 的可选包装器，不拷也行）。

服务器地址默认就是云上 `159.75.154.122:8080`，权威模式**默认开启** —— **两台都不用改任何设置**。

### 方式二（开发仓库，调试用）

**电脑 B 的前置**：仓库是**当前代码**（`git pull` 到最新），Godot 4.7.x 就位。
旧导出的 exe / apk **不行**（里面没有 v2 代码）——用方式一就没有这个问题。

```powershell
# 电脑 A（房主）
cd C:\Users\yy197\Documents\GitHub\nsoc
& "C:\D\GodotEngine\Godot_v4.7.2-stable_win64_console.exe" --path dev_gd\nsoc

# 电脑 B（加入方）
cd <电脑 B 上的仓库路径>
& "<Godot 4.7.x 控制台可执行文件>" --path dev_gd\nsoc
```

> 权威模式现已**默认开启**，不再需要 `$env:NSOC_AUTHORITATIVE = "1"`。
> 想强制走 v1 才需要：环境变量 `NSOC_AUTHORITATIVE=0`，或在 `user://server.json` 里写
> `"authoritative": false`（该文件位置：`%APPDATA%\Godot\app_userdata\NSOC\server.json`）。

> **一个坑**：客户端身份是 `%APPDATA%\Godot\app_userdata\NSOC\profile.json` 里的 UUID。
> 若某台电脑**以前跑过** NSOC，两台可能带同一 UUID 而被服务器视为同一玩家 —— 删掉那台的
> `profile.json` 再启动即可（全新机器不会发生）。

## 第 3 步 跑一局（最小路径）

1. 两边主菜单 → 对战（联机）→「演武切磋」；
2. **A 进「我的房间」建房**，把房号念给 B；
3. **B 进「加入房间」**输入房号加入，双方准备；
4. **房主 A 点开始**；
5. 第一局只做最小动作：**各出一张单位卡 → 结束回合**，确认两端盘面/手牌/费用/回合按钮一致；
6. 确认无误后再试法术 / 装备 / 英雄技能。

## 第 4 步【服务器】一条命令采集证据

仓库里带了采集脚本 `server\deploy\collect-acceptance.ps1`；把它和快照一起传到服务器
（例如 `C:\nsoc\`），然后**一条命令**拿到全部证据：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File C:\nsoc\collect-acceptance.ps1
```

它会打印：两个服务的状态、中继 `/health`、四个日志的新鲜度，然后逐条列出
派单/开局/裁决/状态哈希/交还/`SECURITY`/v1 兜底等关键行，并对判据 1 给出 PASS/WARN 结论。
**把整段输出贴回来即可**，不用手工 grep。

<details>
<summary>如果你想手工核对（可选）</summary>

```powershell
# 权威侧：派单 / 开局 / 裁决 / 状态哈希 / 交还
Select-String -Path C:\nsoc\authority\authority*.log -Pattern 'assigned|start_match|accepted|state_hash|released' |
    ForEach-Object { $_.Line.Trim() }

# 中继侧：派单与释放
Select-String -Path C:\nsoc\relay.out.log, C:\nsoc\relay.log -Pattern 'authority' |
    ForEach-Object { $_.Line.Trim() } | Select-Object -Last 20
```
</details>

**期望看到的行（对照 `docs/OPERATOR-TODO.md` 附录的表）**：

| 行 | 含义 |
|---|---|
| `authority assigned room=xxxxx uuid=...` | 中继把这一局派给了权威 → **这一局在走 v2** |
| `[authority] start_match players=[...]` | 大厅开局配置到达权威 |
| `[authority] intent/... from=<pid> accepted=true` | 每次出牌/结束回合都由权威裁决（`false` 会带 `reason=`） |
| `[authority] state_hash <sha256> turn=N active=<pid>` | **判据 1 的证据**：权威是唯一真相，逐回合推进 |
| `[authority] released room=xxxxx reason=... -> standby` | 一局结束、权威回待命 |
| `authority released room=xxxxx uuid=... reason=...` | 中继侧确认释放 |

**判读**：

- 没有 `assigned room` ⇒ 这一局走的是 v1（房主 `NSOC_AUTHORITATIVE=1` 没生效），本次验收不成立，重来；
- 出现 `accepted=false` ⇒ 把那行原文贴出来，按 `reason=` 定位（`not_your_turn` / `stale_seq` / `not_handshaken` …）；
- `state_hash` 只出现一行且 `turn=` 不再增长 ⇒ 权威没有继续结算，把权威日志整段贴出来。

## 第 5 步【服务器 + 电脑 A】第二局（证明权威不重启也能连着服务）

**不要重启任何服务**，直接再来一局：A 退出房间重新建房 → B 重新加入 → 开始。

期望权威日志**再次**出现 `authority assigned room=<新房号>` 与新的 `state_hash ... turn=1`，
且中间有一行 `released ... -> standby`。这一步证明"一个权威进程可以连续服务多局"。

---

## 判据 4：权威崩溃重启后，下一局还能走 v2

这是**唯一必须真机做**的一条（本地没有真中继）。语义先说清楚，避免误判：

> 权威崩溃时**旧房间不会消失** —— 那是玩家的房间，玩家还在，房间就该在（他们可以按 v1
> 打完或自行退房，闲置 60 分钟才过期）。要证明的是**没有残留状态挡住下一局**：
> 崩溃后房间不再挂权威；重启后新权威回到待命池；**再建房仍能派单成功**。

操作：

```powershell
# 【服务器】打一局的过程中，把权威停掉（模拟崩溃）
Stop-Service nsoc-authority

# 【服务器】确认中继已把权威从房间里摘掉
Select-String -Path C:\nsoc\relay.out.log, C:\nsoc\relay.log -Pattern 'authority left room' |
    ForEach-Object { $_.Line.Trim() } | Select-Object -Last 3
# 期望: authority left room=<房号> uuid=<权威 uuid>

# 【服务器】把权威拉回来（服务配了自动重启，这一步等价于崩溃后自愈）
Start-Service nsoc-authority
Start-Sleep -Seconds 12
Select-String -Path C:\nsoc\authority\authority*.log -Pattern 'ready, waiting' |
    ForEach-Object { $_.Line.Trim() } | Select-Object -Last 1
# 期望: [authority] ready, waiting for room assignment   （重新进待命池）

# 【电脑 A】重新建房
# 期望顺序：中继 authority assigned room=<新房号> → 客户端拿到 authoritative=true
Select-String -Path C:\nsoc\relay.out.log, C:\nsoc\relay.log -Pattern 'authority assigned room' |
    ForEach-Object { $_.Line.Trim() } | Select-Object -Last 2
```

**通过标准**：崩溃后能看到 `authority left room=...`；重启后有 `ready, waiting`；
重新建房时**又**出现 `authority assigned room=<新房号>`（而不是 `room <房号> requested authoritative but no idle authority`）。

> 中继侧的这条链路已有单测守着：`server/authority_relay_test.go` 的
> `TestAuthorityCrashDoesNotLeakIntoNextMatch`（崩溃 → 旧房间不再挂权威 → 重启注册 → 新局仍派单 → 旧房间不被新权威接管）。
> 真机这一步验的是"服务化部署 + 自动重启"这一层，不是规则层。

---

## 验收记录（把结果填在这里或贴回聊天）

| 判据 | 证据 | 通过？ |
|---|---|---|
| 1. 权威唯一真相（`state_hash` 逐回合推进） | | |
| 2. 篡改消息无效（复看中继日志：`SECURITY` 行 / 玩家间无 `intent/*` 互转） | | |
| 3. 关掉权威建房 → `authoritative=false`（静默退回 v1） | | |
| 4. 权威崩溃重启 → 新局仍 `assigned room`（见上） | | |
| 第二局不重启权威仍走 v2 | | |

## 出问题时给我这三样

1. 【服务器】`C:\nsoc\authority\authority.log` 与 `authority.out.log` 的尾部；
2. 【服务器】`C:\nsoc\relay.out.log` 尾部；
3. 客户端控制台里 `[SparringPanel]` / `Net` 相关的报错行。

> Godot 的 `print` 实测走 **stderr**，而装服务脚本把 stdout 写进 `authority.out.log`、stderr 写进
> `authority.log` —— 所以**两个日志都要看**。
