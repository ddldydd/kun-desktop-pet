# Kun Like 桌宠 · 桌面版

一只**真正悬浮在 Windows 桌面上**的像素桌宠：始终置顶、可拖动、能换形象，实时播报 **DSH（DeepSeek Harness）** 的任务进展；遇到需要你确认的权限审批时，**直接在桌宠上点「✓ 同意 / ✗ 拒绝」**，不用切回 Harness 窗口。

| 等你审批（桌宠上直接放行） | Agent 向你提问 | 任务进行中 |
|---|---|---|
| ![审批面板](screenshots/approval-panel.png) | ![提问气泡](screenshots/question-bubble.png) | ![任务进行中](screenshots/running-bubble.png) |

> 纯 **PowerShell + WPF**，Windows 自带组件，**零依赖、零安装**（不需要 Node / Python / .NET 额外运行库）。

---

## 目录

- [这是什么](#这是什么)
- [环境要求](#环境要求)
- [快速开始](#快速开始)
- [一键安装 / 卸载](#一键安装--卸载)
- [功能一览](#功能一览)
- [右键菜单](#右键菜单)
- [装形象素材（换皮肤）](#装形象素材换皮肤)
- [可选：装 DSH 插件（任务进展 + 审批按钮）](#可选装-dsh-插件任务进展--审批按钮)
- [可选：开机自启](#可选开机自启)
- [配置文件](#配置文件)
- [排错](#排错)
- [素材来源与版权](#素材来源与版权)
- [许可](#许可)

---

## 这是什么

仓库里一共三部分，**可以只用第一部分**：

| 目录 | 内容 | 需要 DSH 吗 |
|---|---|---|
| `desktop/` | **桌面桌宠本体**：悬浮在 Windows 桌面上的那只宠物 | 不需要 |
| `plugin/` | **DSH 插件 `@local/kun-pet`**：给桌面桌宠提供「审批 / 提问」数据通道，并能在 Harness 网页里再显示一只小宠 | 需要 |
| `assets/pets/` | 两只随仓库附带的桌宠形象（`ikkun`、`haiyue-classic`），可直接用 | 不需要 |

**不装 DSH 也能正常用**：桌宠会以待机动画待在桌面上，单击挥手、双击跳一下、拖动移动，只是不会有任务进展气泡。装上 `plugin/` 后它才会跟着任务状态变化。

---

## 环境要求

- **Windows 10 / 11**（依赖系统自带的 PowerShell 5.1 + WPF，无需额外安装）
- 可选：**DeepSeek Harness**（要用「任务进展提示」和「桌宠上审批」才需要）

> `desktop/kun-pet-desktop.ps1` 是 PowerShell 5.1 脚本，**Windows PowerShell** 可直接运行，
> 不需要 PowerShell 7。若你机器上 `powershell.exe` 被安全策略限制，用
> `powershell -NoProfile -ExecutionPolicy Bypass -File .\desktop\kun-pet-desktop.ps1` 手动跑一次即可看到完整报错。

---

## 快速开始

### 方式 A：直接下载 ZIP（最简单）

1. 本页右上角 **Code → Download ZIP**，解压到任意目录（例如 `D:\kun-desktop-pet`）。
2. （推荐）把形象素材装进 petdex 目录，见 [装形象素材](#装形象素材换皮肤)。
3. 双击 **`desktop\启动桌宠.vbs`**。

完成。桌宠会出现在桌面右下角附近。

### 方式 B：git clone

```powershell
git clone https://github.com/ddldydd/kun-desktop-pet.git
cd kun-desktop-pet
.\desktop\启动桌宠.vbs     # 直接启动
```

### 方式 C：一键安装（推荐给想「装到固定目录 + 素材 + 自启」的人）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
```

它会：

1. 把桌宠复制到 `%USERPROFILE%\kun-desktop-pet`（固定目录，与自启脚本一致，配置文件不会被拆成两份）；
2. 把 `assets/pets/*` 安装到 `%USERPROFILE%\.petdex\pets\`（已存在的同名素材**不会**被覆盖）；
3. 可选装 DSH 插件、可选注册开机自启（用开关控制，见下）。

常用参数：

```powershell
.\install.ps1 -Autostart                 # 顺带注册开机自启
.\install.ps1 -InstallPlugin             # 顺带装 DSH 插件（默认 profile: desktop）
.\install.ps1 -InstallPlugin -Profile web
.\install.ps1 -SkipAssets                # 不装素材（用内置矢量形象）
.\install.ps1 -Target D:\pets\kun        # 装到别处
```

卸载：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
# 连素材 / 插件 / 自启一起清掉：
powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1 -RemoveAssets -RemovePlugin -RemoveAutostart
```

---

## 功能一览

对齐 **Codex / petdex 桌宠**规格：

| 功能 | 说明 |
|---|---|
| **9 个标准动作** | `idle` / `running-right` / `running-left` / `waving` / `jumping` / `failed` / `waiting` / `running` / `review`（与 Codex 桌宠九行状态一一对应） |
| **单击 = 挥手** | 与 Codex 桌宠一致 |
| **双击 = 跳一下** | 与 Codex 桌宠一致 |
| **拖动移动** | 拖动时按方向切换 `running-right` / `running-left` |
| **16 向待机视线** | 从正上方开始顺时针轮转，眼睛会跟着「看」 |
| **右键 / 托盘菜单** | 宠物、动作、大小、间距、多任务展示、暂停、鼠标穿透、重置位置、退出 |
| **自定义大小（4 种方式）** | ① 在宠物上**滚轮**直接缩放 ② 菜单「大小」8 档预设（25%–300%，带勾选） ③ 菜单「放大 / 缩小」每次 ±10% ④ 菜单「自定义…」输入任意百分比（25–300） |
| **状态持久化（含形象）** | 尺寸、位置、**上次选的宠物形象**、暂停状态、多任务展示方式都写进 `kun-pet-settings.json`，下次启动原样恢复 |
| **鼠标穿透** | 开启后点击穿透小宠，不影响底下的窗口（可再关掉） |
| **petdex 素材兼容** | 自动发现 `~/.petdex/pets/<slug>/` 与 `~/.codex/pets/<id>/` 下的 `pet.json` + `spritesheet.png\|webp`，按 8×9（或 8×11）、每格 192×208 渲染；没素材就用内置形象 |
| **空帧自动跳过** | 启动时逐行扫描精灵图，只在真正有内容的列之间循环，**不会出现「一闪一闪」**（见 [docs/internals.md](docs/internals.md)） |

### 主动提醒：需要你介入时不用盯着屏幕

| 时机 | 桌宠的反应 |
|---|---|
| **Harness 等待审批** | 绿色操作面板「需要你确认：<工具名>」+ **✓ 同意 / ✗ 拒绝 按钮（桌宠上直接操作）** + 三声提示铃 + 托盘通知 + 小宠脉冲放大 + 抢一次置顶 |
| **Agent 向你提问** | 同上，横幅写「需要你回答：Agent 正在向你提问」，气泡里列出问题、说明与选项 |
| **Agent 提交方案待批准** | 琥珀色气泡「📋 需要你确认方案」+ 计划摘要 |
| **任务结束** | 绿色横幅「**任务结束 ✓** · N 次工具调用 · 用时 X」+ 上行琶音 + 托盘通知 + 跳跃庆祝 |
| **出错** | 红色摇晃（`failed`）+ 系统提示音 |

设计要点：**同一件事只提醒一次**（按事件去重），不会每 500 ms 轮询就重复弹窗刷屏；你处理完后自动复位。「任务结束」只在**刚刚发生的 20 秒内**提醒，避免重启桌宠后翻出旧任务反复报。

### 任务进展提示

| DSH 状态 | 桌宠表现 | 含义 |
|---|---|---|
| 待机 | 🐳 轻浮动 + 视线游移 | 无任务 |
| 干活中 | 💧 快速蹦跳（`running`） | Agent 正在执行工具，底部显示「正在执行 xxx（第 N 次）」 |
| 复核中 | 🔍 探头（`review`） | 运行中但暂未调工具 |
| **等你审批** | ⏳ 抖动催促 + 红色横幅 + 绿色面板 | 需要你确认 |
| **出错** | ❗ 变红摇晃（`failed`）+ 提示音 | 请求出错 |
| **任务完成** | 🎉 跳跃 + 琶音 + 「任务结束」横幅与通知 | 任务全部完成 |

桌宠是**全局**的，会**同时跟踪所有活跃任务会话**（自动排除子代理会话）：

- 只要还有任何一个任务在跑，气泡就持续显示「正在处理：…」并逐任务列出进展；
- 多个任务并行时显示「N 个任务进行中」+ 逐行列表（超过 3 条折叠为「… 共 N 个任务进行中」）；
- 每个任务收尾都**单独**提示「任务结束 ✓」，一个任务完成不影响其余任务的进展显示；
- 任一会话向你提问 / 等审批，立即切换为等待提醒。

多任务展示方式可配置（右键菜单「多任务展示」，持久化）：

| 模式 | 气泡表现 |
|---|---|
| **全部展示**（默认） | 逐条列出所有任务，如「· 修登录 bug（2 轮 / 5 步）」，超过 3 条折叠 |
| **轮换展示** | 每隔 N 秒切换一条（带「(1/3)」序号），间隔 2 / 4 / 8 秒可配 |
| **仅展示最活跃任务** | 只显示最新活跃的一条，并标注「（共 N 个任务）」 |

### 暂停 = 只暂停动画，提示照常

菜单里的「暂停」只冻结**小宠本身**（不推进动画帧、不浮动缩放、点击不再挥手出声）；
**任务气泡、进度、底部提示、提醒全部照常更新**——暂停动画也不会漏掉任务进展。

---

## 右键菜单

在桌宠上**右键**（或按 `Ctrl+,`）打开：

| 菜单 | 可选项 |
|---|---|
| **宠物** | 自动发现的所有 petdex 素材 + 「内置形象」，当前显示的那项带勾选 |
| **动作** | 手动切到 9 个标准动作中的任意一个（用于预览素材） |
| **大小** | 8 档预设（25%–300%）、放大 / 缩小（±10%）、自定义…（25–300） |
| **间距** | 气泡与宠物之间的距离（`gapPx`） |
| **多任务展示** | 全部展示 / 轮换展示（2s / 4s / 8s）/ 仅展示最活跃任务 |
| **暂停** | 冻结/恢复小宠动画（提示照常） |
| **鼠标穿透** | 点击穿透小宠 |
| **重置位置** | 把跑到屏幕外的小宠拉回工作区内 |
| **退出** | 关闭桌宠 |

---

## 装形象素材（换皮肤）

桌宠按 **petdex / Codex 桌宠**的素材规格加载。把素材目录放到：

```
%USERPROFILE%\.petdex\pets\<slug>\
    pet.json
    spritesheet.png        # 或 spritesheet.webp
```

也支持 `%USERPROFILE%\.codex\pets\<id>\`（或 `%CODEX_HOME%\pets`）。

**本仓库自带两只**（`assets/pets/`），复制过去即可：

```powershell
# 在仓库根目录执行
New-Item -ItemType Directory -Force "$env:USERPROFILE\.petdex\pets" | Out-Null
Copy-Item .\assets\pets\* "$env:USERPROFILE\.petdex\pets\" -Recurse -Force
```

| 形象 | 预览 |
|---|---|
| `ikkun`（灰发圆眼、黑色背带裤的团雀风小宠） | ![ikkun](screenshots/sheet-ikkun.png) |
| `haiyue-classic`（海月·幻海映月，蓝紫长发银白衣装） | ![haiyue](screenshots/sheet-haiyue.png) |

素材格式要求：

- 精灵图 **8 列 × 9 行**（也兼容 8×11），**每格 192×208**，行顺序即上表 9 个动作的顺序；
- `pet.json` 里的 `id` / `displayName` / `spritesheetPath` 会被读取；也可以在 `pet.json` 里显式写
  `columns` / `rows` / `frameWidth` / `frameHeight` 覆盖默认值；
- ⚠️ **WPF 原生不支持 WebP**。若素材只有 `.webp`，请自行转成 `.png`，或安装 Windows 的
  「Webp 图像扩展」。菜单里会标注「需 WebP 扩展」表示当前无法解码。
  （本仓库自带的素材**同时提供 .png 与 .webp**，直接可用。）

---

## 可选：装 DSH 插件（任务进展 + 审批按钮）

`plugin/` 是 DSH 插件 `@local/kun-pet`，它提供两条通道：

| 通道 | 位置 | 能力 |
|---|---|---|
| HTTP | `/kun-pet/state`、`/kun-pet/approval` | 读状态 + **在桌宠上直接 ✓同意 / ✗拒绝** |
| 文件 | `~/.dsh/kun-pet-state.json` | 读状态（气泡照常提示，决策要回 Harness 窗口点） |

桌宠优先走 HTTP，失败自动退回文件通道。只有文件通道时，气泡会提示「切回 Harness 窗口点同意 / 拒绝」，并且**不显示** ✓/✗ 按钮（那种情况按钮送不出去，显示出来只会误导）。

安装（也可以让 `install.ps1 -InstallPlugin` 代劳）：

```powershell
$profile = "$env:USERPROFILE\.dsh\profiles\desktop"        # 你的 profile 目录
$dest    = Join-Path $profile "node_modules\@local\kun-pet"
New-Item -ItemType Directory -Force $dest | Out-Null
Copy-Item .\plugin\* $dest -Recurse -Force
```

然后在该 profile 的 `cordis.patch.yml` 末尾追加：

```yaml
- insert:
    - id: kun-pet
      name: '@local/kun-pet'
      config: {}
```

> **profile 只在 DSH 启动时读一次**，`cordis.patch.yml` 没有热加载，所以**必须重启一次 DSH** 插件才会挂上。

重启后自查：

```powershell
Invoke-RestMethod http://127.0.0.1:19387/kun-pet/state | Select-Object mode, updatedAt
```

看到 JSON（而不是 404）就对了。插件自己的日志在 `~/.dsh/kun-pet-host.log`。

**网页里的那只小宠**：`plugin/client.js` 里带了「Harness 网页右下角小宠」的实现，本仓库默认**开启**（这样你可以在网页里也养一只）。不想要就用：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\plugin\toggle-gui-pet.ps1 status
powershell -NoProfile -ExecutionPolicy Bypass -File .\plugin\toggle-gui-pet.ps1 disable   # 关掉网页那只（host 半区不受影响）
powershell -NoProfile -ExecutionPolicy Bypass -File .\plugin\toggle-gui-pet.ps1 restore   # 恢复
```

改完刷新 Harness 页面（F5）生效。

---

## 可选：开机自启

把这两个文件放进「启动」文件夹（`Win+R` 输入 `shell:startup`）：

| 文件 | 作用 |
|---|---|
| `KunPet-autostart.cmd` | 自启入口，**删掉它即可关闭自启**（不影响桌宠本身） |
| `KunPet-pet-running.ps1` | 探测桌宠是否已在运行，避免开出第二只 |

`install.ps1 -Autostart` 会自动生成并放好这两个文件（路径按你的 `-Target` 目录写好）。
注意 `KunPet-autostart.cmd` 里写的是**你安装时的绝对路径**，换目录后要重新生成。

> 这两个文件刻意保持**纯 ASCII**：`cmd.exe` 在部分代码页下会把非 ASCII 字节解析错，
> 之前用中文文件名 / 中文注释的版本会报「不是内部或外部命令」。

---

## 配置文件

桌宠把自己的状态写在**脚本同目录**的 `kun-pet-settings.json`（首次运行自动生成）：

| 字段 | 含义 |
|---|---|
| `petId` | 上次选的形象：素材目录名 / `builtin`（主动选了内置形象）/ 不存在或 `none`（从没选过，自动挑第一个可用素材） |
| `petMode` | `sprite`（素材贴图）或矢量内置形象 |
| `scale` | 缩放比例（0.25–3.0） |
| `posLeft` / `posTop` / `posW` / `posH` | 窗口位置与尺寸（按「底边 + 水平中心」还原，夹在工作区内） |
| `gapPx` | 气泡与宠物的间距 |
| `multiMode` / `rotateSec` | 多任务展示方式 / 轮换间隔秒数 |
| `paused` | 是否暂停动画 |
| `floating` | 是否开启鼠标穿透 |

日志写在同目录的 `kun-pet-desktop.log`。

> 三个启动器（`启动桌宠.vbs` / `start-pet.vbs` / `启动桌宠.bat`）都会显式把**脚本所在目录**设为工作目录并传给脚本，
> 所以手动双击与开机自启读写的是**同一份配置**（否则自启会另起一份默认配置，表现就是「每次开机都变回默认形象」）。

---

## 排错

| 现象 | 处理 |
|---|---|
| 双击没反应 / 黑框一闪而过 | 右键用 PowerShell 运行 `kun-pet-desktop.ps1` 看完整报错；日志在同目录 `kun-pet-desktop.log` |
| 一直显示「DSH 没连上」 | 重启一次 DSH 桌面端，让插件接口生效；或忽略（不影响桌宠本身） |
| **桌宠「不见了」** | 先看任务管理器里有没有 `kun-pet-desktop.ps1` 的 powershell 进程。桌宠是「置顶 + 分层 + 工具窗口」，Windows 里 `MainWindowHandle` 恒为 0，常规「找窗口」方法看不到它；它可能只是被别的全屏 / 置顶窗口压在下面。按 `Win+D` 显示桌面，或右键菜单「重置位置」把它拉回屏幕内 |
| 小宠一闪一闪 | 已在 v2 修复（空帧跳过 + 固定缩放取整位移）。若你自己换的素材仍有此问题，用 `docs/` 里的方法检查每行有效帧数 |
| 素材在菜单里显示「需 WebP 扩展」 | 该素材只有 `.webp`，转成 `.png` 或装 Windows「Webp 图像扩展」 |
| 审批气泡不弹 | 插件没加载：`http://127.0.0.1:19387/kun-pet/state` 返回 404 ⇒ 重启 DSH；再看 `~/.dsh/kun-pet-host.log` |
| 在桌宠上点了同意，Harness 卡片还挂着 | 旧版问题，已修（桌宠应答时会顺手 cancel 网页端那张远程卡片）；DSH 版本差异导致取不到内部结构时，会自动退回「先给桌宠 6 秒独占窗口」的兜底策略 |

更细的原理与自查脚本见 [docs/internals.md](docs/internals.md) 与 [docs/troubleshooting.md](docs/troubleshooting.md)。

---

## 卸载

1. 右键托盘图标 → **退出**（结束桌宠）；
2. 删掉桌宠所在目录；
3. 若装了自启，删掉「启动」文件夹里的 `KunPet-autostart.cmd` 与 `KunPet-pet-running.ps1`；
4. 若装了插件，删掉 `<profile>\node_modules\@local\kun-pet` 并移除 `cordis.patch.yml` 里的 `kun-pet` insert 项；
5. 素材在 `%USERPROFILE%\.petdex\pets\`，不需要就一并删除。

或者直接：

```powershell
.\uninstall.ps1 -RemoveAssets -RemovePlugin -RemoveAutostart
```

---

## 素材来源与版权

- **代码**（`desktop/`、`plugin/`、`install.ps1` 等）采用 **MIT**，见 [LICENSE](LICENSE)。
- **桌宠形象素材**（`assets/pets/ikkun`、`assets/pets/haiyue-classic`）来自 **petdex / codex-pet.org** 生态，
  **版权归原作者所有，不适用本仓库的 MIT 许可**。本仓库附带它们只是为了方便玩家开箱即用；
  若原作者有异议，会立即移除。详见 [NOTICE.md](NOTICE.md)。
- 想用别的形象：把自己的 petdex 素材丢进 `~/.petdex/pets/` 即可，无需改代码。

---

## 许可

[MIT](LICENSE) © 2026 ddldydd —— 代码部分。
第三方桌宠素材见 [NOTICE.md](NOTICE.md)。
