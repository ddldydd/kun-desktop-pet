# 排错手册

按「现象 → 原因 → 处理」组织。所有日志都在**桌宠脚本所在目录**。

---

## 一、桌宠起不来 / 看不到

### 双击没反应，或黑框一闪而过

1. 用 PowerShell 直接跑脚本看完整报错：

   ```powershell
   powershell -NoProfile -ExecutionPolicy Bypass -File .\kun-pet-desktop.ps1
   ```

2. 看日志：同目录 `kun-pet-desktop.log`。
3. 常见原因：
   - 执行策略拦截 → 用上面的 `-ExecutionPolicy Bypass`；
   - 被杀软 / 安全软件拦下 WPF 窗口创建 → 加白名单；
   - 脚本被存成了非 UTF-8 → 重新从仓库下载（仓库文件带 UTF-8 BOM）。

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

1. 底部小字显示的数据来源是哪个？如果是「会话文件活跃度」，说明投影缓存没读到；
2. 是不是只有**子代理**在跑？桌宠会识别并跳过子代理会话（这是有意的，避免把子代理状态显示成你的主任务）；
3. 多任务模式下若选了「仅展示最活跃任务」，其余任务不会逐条列出——换「全部展示」看看。

### 任务结束了但没提示

「任务结束」**只在刚刚发生的 20 秒内**提醒。这是有意的：避免重启桌宠后翻出旧任务反复报。

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

### 在桌宠上点了同意，任务继续了，但 Harness 对话栏还挂着「等待审批」

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

## 六、收集信息（开 Issue 用）

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

# 系统
$PSVersionTable.PSVersion
[Environment]::OSVersion.VersionString
```

> 贴日志前请**先删掉里面可能出现的账号名、路径、任务内容**等隐私信息。
