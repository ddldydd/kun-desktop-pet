# 排错手册

按「现象 → 原因 → 处理」组织。桌宠日志在**脚本所在目录**，插件日志在 `~/.dsh/kun-pet-host.log`。

---

## 一、桌宠起不来 / 看不到

### ⚠️ 先看这条：`.ps1` 必须带 UTF-8 BOM（实测踩过）

**现象**：用 `powershell -NoProfile -ExecutionPolicy Bypass -File .\kun-pet-desktop.ps1`
跑脚本时报**语法错误**，报错行里是乱码（如 `Unexpected token '浼氳瘽...'`），
但双击 `启动桌宠.vbs` 却一切正常。

**原因**：Windows PowerShell 5.1 在**没有 BOM** 时按系统 ANSI 代码页（中文机器上是 GBK）
读取 `.ps1`。仓库里的脚本含中文，于是：

1. 中文字符串/注释全部变乱码（气泡里的中文会花掉）；
2. 更糟的是某些 GBK 双字节序列会把紧随其后的**引号吞掉**，直接变成语法错误。

`启动桌宠.vbs` 之所以没事，是因为它显式按 UTF-8 读脚本再交给 ScriptBlock 执行：

```vbs
$c=[IO.File]::ReadAllText('...kun-pet-desktop.ps1',[Text.Encoding]::UTF8)
```

**处理**：给含非 ASCII 的脚本补 BOM（本仓库已提供工具）：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\add-bom.ps1 -Path .\desktop
powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\add-bom.ps1 -Path . -WhatIfOnly   # 只报告
```

> **改脚本的人注意**：有些编辑器/写入工具保存时会**去掉 BOM**。改完含中文的 `.ps1`
> 后，用上面的 `add-bom.ps1` 补一次，否则 5.1 下又会解析失败。
> 纯 ASCII 脚本（`KunPet-pet-running.ps1`、`add-bom.ps1` 自己）不受影响。

### 桌面「启动桌宠」快捷方式不见了 / 双击报错

安装完成后桌面会有一个「启动桌宠」快捷方式，指向 `%USERPROFILE%\kun-desktop-pet\启动桌宠.vbs`。

- 找不到了：直接双击 `%USERPROFILE%\kun-desktop-pet\启动桌宠.vbs` 一样能启动，不用翻安装目录；
- 想重建快捷方式：重跑一次根目录的 `安装.cmd`（或 `install.ps1`）。没有快捷方式会补上；还是空白图标会换成宠物图标；已经是宠物图标的不会被换掉；
- 不想要快捷方式：安装时加 `-NoShortcut`（`install.ps1 -NoShortcut`）；卸载时脚本会自动把它删掉。

### 双击没反应，或黑框一闪而过

1. 用 PowerShell 直接跑脚本看完整报错：

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\kun-pet-desktop.ps1
   ```

2. 看日志：同目录 `kun-pet-desktop.log`。
3. 常见原因：
   - 执行策略拦截 → 用上面的 `-ExecutionPolicy Bypass`；
   - 被杀软 / 安全软件拦下 WPF 窗口创建 → 加白名单；
   - 脚本被存成了非 UTF-8，或因编辑丢了 UTF-8 BOM → 见本页最上面那条，
     用 `tools\add-bom.ps1` 补回 BOM。

### 桌宠「不见了」，但进程还在

这是**设计使然**：桌宠是「置顶 + 分层 + 工具窗口」，Windows 里 `MainWindowHandle` **恒为 0**，
所以常规「找窗口」的方法（Alt+Tab、任务栏、`MainWindowTitle`）都看不到它。它可能只是被别的全屏 / 置顶窗口压在下面。

处理：

- 按 **`Win + D`** 显示桌面；
- 或右键托盘图标 → **重置位置**（把跑到屏幕外的小宠拉回工作区内）。

排查先确认进程：

```powershell
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -match 'kun-pet-desktop' } |
  Select-Object ProcessId, CreationDate
```

### 开了两只

桌宠有一个单实例互斥体（`Local\KunPetDesktopPet`）。若真出现两只，多半是其中一只由**不同的脚本副本**启动
（不同目录 = 不同配置 = 不同形象/位置）。统一用同一个安装目录启动即可。

### 每次开机都变回默认形象

说明「双击启动」和「开机自启」读的不是同一份 `kun-pet-settings.json`。
本仓库的三个启动器都会显式把**脚本所在目录**设为工作目录并传入 `$cwd`，所以只要**安装目录没变**就不会出现。
如果你挪动过目录，重新跑一次 `install.ps1 -Autostart`（自启脚本里写的是安装时的绝对路径）。

---

## 二、形象 / 素材问题

### 菜单里显示「需 WebP 扩展」

该素材只有 `.webp`，而 **WPF 原生不支持 WebP**。二选一：

- 把 `spritesheet.webp` 转成 `spritesheet.png`（推荐，直接可用）；
- 或安装 Windows 的「Webp 图像扩展」商店组件。

仓库自带的两个素材同时提供 `.png` 与 `.webp`，不存在这个问题。

### 换了素材但菜单里没有

素材目录结构必须是：

```
%USERPROFILE%\.petdex\pets\<slug>\pet.json
%USERPROFILE%\.petdex\pets\<slug>\spritesheet.png     # 或 .webp
```

- `<slug>` 是**目录名**，会作为 `petId` 的取值；
- `pet.json` 必须存在且是合法 JSON（解析失败会被跳过）；
- 改完素材后**重启桌宠**（素材是启动时扫描的）；
- 也支持 `%USERPROFILE%\.codex\pets\<id>\`，或 `%CODEX_HOME%\pets\<id>\`。

### 小宠一闪一闪（周期性消失）

根因是**素材每行末尾有空帧**，而代码固定按 8 列循环——走到空格子就「不见了」。
v2 已改为启动时逐行扫描、只循环有内容的列。

若换了自己的素材仍有此问题，用仓库里的脚本看每行有效帧数：

```powershell
# 需要 Python + Pillow + numpy
python .\docs\tools\check-sheet-frames.py
```

输出里标 `EMPTY` 的格子就是空帧。正常情况下桌宠会自动跳过它们；
如果素材的行顺序和标准 9 行不一致，就会表现为「动作错位」而不是闪烁——那是素材本身的问题。

### 小宠被气泡裁掉 / 气泡换行时小宠上下跳

v2 已修：容器尺寸跟着素材格走（整张贴图计入布局），窗口尺寸变化时钉住「底边 + 水平中心」。
若你改了 XAML 布局，注意别破坏这两条。

---

## 三、任务进展 / 提醒问题

### 一直显示「DSH 没连上」

桌宠读不到 DSH 的会话状态。按顺序查：

1. **DSH 是否在跑**（桌面端 / 网页端任一）；
2. **会话投影缓存是否存在**：

   ```powershell
   Get-ChildItem "$env:USERPROFILE\.dsh\storages\session_projcache\sessions" | Select-Object Name, LastWriteTime
   ```

   这个目录是**明文 JSON**，是桌宠的默认数据源，不需要插件。
3. 如果目录存在但内容没更新 → DSH 侧的问题，重启一次 DSH。

> 「DSH 没连上」不影响桌宠本身：它照常待机、拖动、换形象。

### 任务在跑，但气泡不显示进展

按顺序查：

1. 底部小字显示的数据来源是哪个？如果是「会话活跃度(兜底)」，说明投影缓存没读到；
2. 是不是只有**子代理**在跑？桌宠会识别并跳过子代理会话（这是有意的，避免把子代理状态显示成你的主任务）；
3. 多任务模式下若选了「仅展示最活跃任务」，其余任务不会逐条列出——换「全部展示」看看。

### 任务结束了但没提示

「任务结束」**只在任务结束后 20 秒内**提醒。这是有意的：避免重启桌宠后翻出旧任务反复报。

### 气泡卡在「等你回答」不消失

两个已知坑（都已修，列出来便于你判断是不是新问题）：

1. 提问藏在 `userQuestions.val.questions.active[].questions[]` 的**嵌套**里，读错层级就永远只有一句泛泛的提示；
2. `active` 条目的 `state` 为 `continued` 表示**已经答过、Agent 正在继续**，只认 `state = open`。

如果升级后仍有此现象，检查会话投影里那条 `active` 条目的 `state` 实际值。

---

## 四、审批相关（最常出问题的一块）

### 卡在「等待审批」，桌宠毫无反应

**第一排查对象永远是「插件挂上了没有」**，因为权限审批的唯一来源是插件的 `/kun-pet/state`，
插件没加载时该端点直接 404，`pendingApprovals` 永远是空的。

```powershell
# 1) 端点通不通（404 = 插件没挂上）
try { Invoke-RestMethod http://127.0.0.1:19387/kun-pet/state | ConvertTo-Json -Depth 3 } catch { $_.Exception.Message }

# 2) 端点自描述文件（插件挂载时会写）
Test-Path "$env:USERPROFILE\.dsh\kun-pet-endpoint.json"

# 3) 插件自己的日志
Get-Content "$env:USERPROFILE\.dsh\kun-pet-host.log" -Tail 30
```

期望在 `kun-pet-host.log` 里看到：

```
host half mounting
HTTP channel ready
capability probe: GUI approval card cancel = available
```

如果端点 404 但文件都装好了 → **profile 只在 DSH 启动时读一次**，
`cordis.patch.yml` 没有热加载，**必须重启一次 DSH**。

还要确认 `cordis.patch.yml` 里确实有：

```yaml
- insert:
    - id: kun-pet
      name: '@local/kun-pet'
      config: {}
```

### 气泡提示了，但没有 ✓同意 / ✗拒绝 按钮

三种可能：

1. **只有文件通道**（HTTP 不通）→ 决策送不出去，所以不显示按钮，气泡会提示「切回 Harness 窗口点」。修好 HTTP 通道即可；
2. **`answerable = false`** → 插件已经把这个请求**委托给网页端**了（兜底策略：先给桌宠 6 秒独占窗口，
   窗口内没人答就交给网页端）。此时再点也只会收到 `409 + delegatedToHarness`；
3. 请求已经处理完了。

### 在桌宠上点了同意，任务继续了，但 DSH 对话栏还挂着「等待审批」

原因：审批有两个应答者，桌宠在**瀑布上游**先返回时，下游那条转发链只是被丢下，Gateway 不知道请求已结束，
网页端那张卡就不会撤。

- 正常路径：插件会顺手 `cancelRemoteEvent` 掉对应事件，网页端立刻撤卡；
- 取不到 Gateway 内部结构时（DSH 版本差异）会退回「先给桌宠 6 秒独占窗口」的兜底：这样即使撤不掉卡片，
  也不会出现「桌宠答完卡片还挂着」。

若两边的答案打架（都点了），**哪边先点听哪边**，另一边自动失效。

---

## 五、鼠标穿透 / 交互

### 开了「鼠标穿透」后点不到桌宠了

这是预期行为：点击会穿透小宠到下面的窗口。关掉的方式是**托盘图标右键菜单 → 鼠标穿透**（取消勾选）。

### 拖动后位置没保存

位置在**拖动结束时**写入 `kun-pet-settings.json`。若桌宠是被强制结束的（任务管理器结束进程），
最后一次移动可能没落盘。正常退出（菜单「退出」）会保存。

---

## 六、pi coding agent 兼容

### 桌宠完全不显示 pi 的状态

按顺序查：

1. **pi 目录在不在**。日志里应有 `pi source ready: sessions=… exists=True`。
   若 `exists=False`，说明 pi 没装或没运行过（`~/.pi/agent/sessions` 由 pi 首次运行时创建）。
2. **开关是否被关掉**。右键菜单 →「兼容 pi coding agent」要有勾选；
   配置文件 `kun-pet-settings.json` 里 `piEnabled` 应为 `true`。
3. **会话是否新鲜**。桌宠只看最近 15 分钟写过的会话；跑一次 pi 再观察。
4. **看通道日志**。日志里会出现 `pi channel: sessions`（只读会话文件）
   或 `pi channel: ext`（扩展状态文件）；两者都没有就是真的没读到数据。

### 有进展提示，但 pi 等我的时候桌宠不喊

**这是预期行为**，不是 bug：pi 的会话文件里**没有**「正在弹确认框」这类记录，
所以纯读文件的通道**永远**拿不到「等待确认」。要补上这一项**必须装扩展**：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -InstallPiExtension
```

装完在 **pi 里执行 `/reload`**（或重开 pi）。之后日志里应出现 `pi channel: ext`。

### 装了扩展，但日志里不是 `pi channel: ext`

- 确认文件在 `~/.pi/agent/extensions/kun-pet.ts`；
- **必须 `/reload`**（或重开 pi）才会加载新扩展；
- 看状态文件有没有在动：

  ```powershell
  Get-Content "$env:USERPROFILE\.pi\agent\kun-pet-state.json" -Raw
  ```

  里面 `updatedAt` 每 5 秒应变化一次（心跳）。若文件不存在或时间很旧，说明扩展没跑起来。

### pi 的状态卡在「进行中」不消失

正常情况下 pi 一轮结束会转成「任务结束」并复位。如果 pi 被**强制杀掉**：

- 扩展通道：快照不再更新，桌宠 **30 秒**后不再采信（新鲜度窗口）；
- 会话通道：文件不再写入，桌宠 **180 秒**后不再当成「在跑」。

若长期卡住，检查日志里 `pi channel:` 是否在反复跳通道。

### 同一目录开了多个 pi 窗口，桌宠只显示一个任务

**这是曾经的一个 bug，已修复。** 原因是早期实现为了排除子代理，按「同一 cwd 只保留一个
会话」，于是把同目录的多个 pi 窗口误当成子代理合并了。

现在的做法：子代理按**目录层级**精确排除（子会话产物在 `subagent-artifacts/` 等更深层，
主会话恒定在 `<转义cwd>/*.jsonl`），**不再**按 cwd 合并 —— 每个窗口都是一个独立任务。

若升级后仍只看到一个，检查：

1. 是否真的在跑的只有一个？看日志里这行（每次任务集合变化都会记录）：

   ```
   pi source: 3 running task(s) [01a1343b, 01a1343c, 01a1343d]
   ```

   只列出 1 个 id，就说明另一个窗口确实已经空闲（不是被合并）。
2. 超过 24 个会话时只跟踪最新的 24 个 —— 极端多开时较早的会被截掉。
3. 气泡一次最多逐条列 5 个，超出折叠成「… 共 N 个 pi 任务进行中」（总数仍在）。

### 同时装了 pi-subagents，桌宠把子代理显示成主任务

子代理产物写在更深的目录里（默认 `<转义cwd>/subagent-artifacts/…`，或
`<项目>/.pi/subagents/…`），桌宠按目录层级排除。日志里出现下面这行说明它在过滤：

```
pi source: skipped nested session file (likely subagent artifact): <相对路径>
```

如果子代理仍被当成主任务显示，请附上那行日志 —— 说明该版本的 `pi-subagents` 换了
存放位置，需要把新路径加进过滤规则。

### 担心 pi 的 API Key 被读走

不会。桌宠适配器只读两个路径：

- `~/.pi/agent/sessions/**/*.jsonl`（会话记录）
- `~/.pi/agent/kun-pet-state.json`（扩展自己写的快照）

**绝不**打开 `models.json` / `auth.json` / `secrets.dpapi.json`。日志里也只会出现
`provider` 名与模型 id，不写 key。

### 自测 pi 适配器（不需要真的开 pi）

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\desktop\tests\test-pi-source.ps1
```

用夹具覆盖「在跑 / 收尾 / 出错 / 坏数据 / 大文件截断」等场景，只写系统临时目录，
不碰真实的 pi 与 DSH 数据。

---

## 七、收集信息（开 Issue 用）

```powershell
# 桌宠进程
Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" |
  Where-Object { $_.CommandLine -match 'kun-pet-desktop' } |
  Select-Object ProcessId, CreationDate | Format-List

# 最近日志
Get-Content .\kun-pet-desktop.log -Tail 60

# 配置
Get-Content .\kun-pet-settings.json

# 素材扫描结果（日志里会写 frames/row）
Select-String -Path .\kun-pet-desktop.log -Pattern 'frames/row|sprite|pet scan' | Select-Object -Last 20

# 插件通道
try { Invoke-RestMethod http://127.0.0.1:19387/kun-pet/state | ConvertTo-Json -Depth 3 } catch { "HTTP 不可用: $_" }
Get-Content "$env:USERPROFILE\.dsh\kun-pet-host.log" -Tail 30 -ErrorAction SilentlyContinue

# pi 通道
Select-String -Path .\kun-pet-desktop.log -Pattern 'pi source|pi channel|running task|no running|skipped nested' | Select-Object -Last 20
Get-Content "$env:USERPROFILE\.pi\agent\kun-pet-state.json" -Raw -ErrorAction SilentlyContinue
(Get-ChildItem "$env:USERPROFILE\.pi\agent\sessions" -Recurse -Filter *.jsonl -ErrorAction SilentlyContinue |
  Sort-Object LastWriteTime -Descending | Select-Object -First 5 Name, LastWriteTime)

# 系统
$PSVersionTable.PSVersion
[Environment]::OSVersion.VersionString
```

> 贴日志前请**先删掉里面可能出现的账号名、路径、任务内容**等隐私信息。
