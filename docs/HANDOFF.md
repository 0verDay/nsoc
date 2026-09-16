# 交接：转为纯本地之后还剩什么（2026-09-16）

> 一页说明**现在的状态**、**你要做的事**、以及**不需要你做的事**。
> 联机功能的删除清单与恢复方法：**唯一必读**是
> [`docs/archive/multiplayer-removal.md`](archive/multiplayer-removal.md)。

## 1. 现在的状态

| 项 | 状态 |
|---|---|
| 项目方向 | ✅ **纯本地**：战役章节 + 自由对战 + 演义（帝国）模式 |
| 联机 | ❌ **已删除**。主菜单「演武切磋」可进入，四个模式页可切换，但「我的房间」「加入房间」只显示**「联机功能暂未开放」** —— 无法创建房间、无法加入房间、无法开局 |
| 客户端网络层 | ✅ autoload `Net` 降级为**空壳**（无 socket、`is_connected_to_server()` 恒 false）；`NetProtocol` 降级为常量表 |
| 服务端 | ❌ Go 中继（`server/`）、Godot 权威裁判（`scripts/server/` + `nsoc/server/`）、云部署与 e2e 脚本**全部删除** |
| PVP 回合 / 队伍内核 | 🟡 **保留为死代码**（无入口）：`Game.bootstrap_pvp` / `pvp_*` / `run_pvp_phase*` / 队伍工具 |
| 代码侧回归 | ✅ Godot `--import` 无解析错误；`check_layers.py` 通过（棘轮 75）；`check_content.py` 通过；**本地 headless 矩阵 11/11 全绿，两条黄金路径哈希逐位不变** |
| 云上服务 | ⚠️ **`nsoc-server` / `nsoc-authority` 两个 NSSM 服务不会自己停** —— 需要你手动停用/卸载，命令见 `docs/archive/multiplayer-removal.md` §6 |

## 2. 你要做的事

### ① 停掉云上的两个服务（唯一必须动手的事，约 2 分钟）

代码删干净了，但腾讯云那台机器上的两个 NSSM 服务还在跑。虽然客户端已经**不可能**再连上任何
服务器（`Net` 是空壳、大厅无入口），但为了省资源和避免误判，建议停掉：

【服务器】管理员 PowerShell：

```powershell
Stop-Service nsoc-server, nsoc-authority
Set-Service nsoc-server, nsoc-authority -StartupType Manual
```

确认已停：

```powershell
Get-Service nsoc-server, nsoc-authority | Select-Object Name, Status, StartType
```

彻底卸载（不再需要的话）：

```powershell
Stop-Service nsoc-server, nsoc-authority
sc.exe delete nsoc-server
sc.exe delete nsoc-authority
Remove-Item -Recurse -Force C:\nsoc
```

### ② （可选）确认本地内容没有退化

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tools\ci\run_headless_matrix.ps1
```

应输出 `MATRIX_RESULT PASS`（11 个本地 PVE 场景）。两条黄金路径哈希应逐位不变：

- 战役单盘 `652a3ef286eca42605d10065f817b3cf955ffcfab238417348729a3398331df8`
- 多棋盘 PVE `0576fcc90d28747719b68bcb9cb40d79fbc25d08f780a7dda19fb1828995e0ce`

> 上面这两个命令都已跑过：11/11 全绿、两条哈希逐位一致。其中 `SparringPanelTest`（16 条断言）
> 专门守着"入口能进、但创建与加入都不可用"这条契约。

### ③ （可选）进游戏点一遍

启动游戏 → 主菜单 →「演武切磋」→ 四个模式按钮都能切，前两个只显示「联机功能暂未开放」，
**没有**任何创建/加入房间的入口 → 「返回」能正常回到主菜单。
再确认本地三条路径照旧能玩：战役 → 长坂坡；「战役 → 街亭遗恨 / 威震华夏」；
以及演义模式的出征战斗。

## 3. 验证结果（已跑完）

| 项 | 状态 |
|---|---|
| Godot `--import` 脚本解析 | ✅ 已跑，0 条 Parse Error |
| `tools/ci/check_layers.py` | ✅ 通过（当前违规 75，棘轮未涨） |
| `tools/ci/check_content.py` | ✅ 通过（17 条既有警告：`ceshi_map.json` 关卡名为空） |
| `tools/ci/run_headless_matrix.ps1` | ✅ **11/11 全绿**（含新增的演武切磋入口契约测试） |
| 两条黄金路径哈希 | ✅ 逐位不变（`652a3ef2…` / `0576fcc9…`） |
| `tests/ContentHashTest`（构建侧 vs 引擎内容哈希） | ✅ PASS（5 条），说明 `NetProtocol.VERSION` / `content_hash()` 保留得当 |

## 4. 手动导出（引擎里出桌面端 + 安卓端）

产物目录已清空，`dev_gd/nsoc/exports/` 等你手动导出。两个预设都已配好：

| 预设 | `export_path` | 验证结果 |
|---|---|---|
| `Windows Desktop` | `exports/NSOC.exe` | ✅ **release 导出通过**（126.8 MB，单文件内嵌 pck，拷走即玩） |
| `Android` | `exports/NSOC.apk` | ⚠️ **debug 导出通过**（49.7 MB）；**release 需要你先配发布密钥库**（见下） |

操作：引擎打开 `dev_gd/nsoc` → `项目 → 导出` → 选预设 → 勾「导出项目」→ 输出路径保持默认 `exports/...`。

### Android release 必须先配密钥库

预设里 `package/signed=true`，但 `keystore/release` 为空，命令行导出会走到最后一步才失败：

```
[98%] 正在签名发布 APK……
WARNING: 代码签名: 找不到发布密钥库，无法导出。
ERROR: Project export for preset "Android" failed.
```

> 注意：这时 `exports/NSOC.apk` **可能已经写出一个未签名的 48 MB 文件**，别当成成品拿去装。

三种处理方式，任选：

1. **先要能装能玩** → 导出时选 **`导出调试`（debug）** 而不是 release。debug 用 Godot 自带调试签名，实测通过（49.7 MB）。缺点：包体大、有调试输出、不能上架。
2. **要正式 release 包** → 自己生成一个 keystore，然后在 `项目 → 导出 → Android → 密钥库` 里填：
   ```powershell
   & "C:\Program Files\Android\Android Studio\jbr\bin\keytool.exe" -keygen -v `
       -keystore C:\Users\yy197\nsoc-release.keystore `
       -alias nsoc -keyalg RSA -keysize 2048 -validity 10000
   ```
   （任何 JDK 的 `keytool` 都行；路径按你机器上的实际情况改。**这个文件和密码要自己留好** —— 丢了就无法给已上架的应用发更新。）
3. **用 gradle 构建** → 预设里 `use_gradle_build=false`（用预编译模板，开箱可用）。要走 gradle 的话需要额外装 Android SDK + 构建模板，然后改这个开关。

顺带一个已修好的坑：`package/unique_name="com.example.$genname"`，正式发版前建议改成你自己的包名（如 `com.yuyi.nsoc`），改完记得重新导所有包。

## 5. 不需要你做的事

- 不用重传任何东西上服务器（权威进程已不在项目内）；
- 不用改客户端配置（服务器地址对话框已随大厅一起删掉，`user://server.json` 不再被读取）；
- 不用为了验证去装 Godot —— 上面 §2 的命令我会跑；只有 §2① 必须你在服务器上操作。

## 6. 想继续推进代码侧（可选，不需要你的机器）

`docs/NEXT.md` B 组剩下的项（**全部是本地重构**，与联机无关）：

1. **B1 反射收敛余下 35 处**（8 处 effects 的 `cell.has_method` 守卫可直接删；6 处 `turn_system`
   的 `.call` 需显式化；`action_registry` 2 处需先引入 `Action` 基类）；
2. **B2 表现宿主**（`Control`/`Tween`/`get_tree` 约 12 处下沉）；
3. **B3** `turn_system` 拉直 `await`；**B4** `board_slot_factory` 的 `grid_cells` 类型收敛；
4. **B5 尾巴**：导出已在 B5 的 `build_release.ps1` 里留了位置（缺预设/模板时优雅跳过）；
   现在预设与模板都齐了，可选把 `-SkipExport` 去掉、让它一并产出成品。

每一步的验收门槛见 `docs/NEXT.md` C 组，一条命令自查：
`powershell -File tools\ci\run_headless_matrix.ps1`（应输出 `MATRIX_RESULT PASS`）。
