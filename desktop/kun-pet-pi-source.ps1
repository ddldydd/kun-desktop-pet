# =====================================================================
#  Kun Like 桌宠 · pi coding agent 源适配器
# =====================================================================
#  目的：让桌宠把 pi（@earendil-works/pi-coding-agent）的任务进展当作一等数据源，
#        产出与 DSH 路径**完全相同形状**的归一化快照，从而复用现有的动画/气泡/
#        提醒/多任务展示逻辑，一行渲染代码都不用改。
#
#  两条通道（自动降级，与 DSH 侧的「插件 HTTP → 插件文件 → 投影缓存」同构）：
#    1) 扩展状态文件  ~/.pi/agent/kun-pet-state.json          【精确，需装 pi 扩展】
#       —— 唯一能可靠表达「pi 正在等你确认」的来源（ui_prompt_start 事件）。
#    2) 会话 JSONL    ~/.pi/agent/sessions/<转义cwd>/*.jsonl   【零安装，只读尾随】
#       —— 覆盖「在干活 / 收尾 / 出错 / 模型 / 轮次步骤」。
#
#  设计约束：
#    - fail-soft：pi 没装、目录不存在、JSON 坏行、schema 升版，一律静默降级，
#      绝不影响 DSH 侧表现，也绝不抛异常打断 500ms 轮询。
#    - 只读：**永不写** pi 目录。特别注意绝不打开 models.json / auth.json /
#      secrets.dpapi.json —— 那里是明文 API Key，日志里也只允许出现 provider 名与 modelId。
#    - 零依赖：纯 PowerShell 5.1 + .NET Framework。
#    - 性能：会话文件可能很大（单行含大段工具输出）。因此
#      ① 只回读文件尾部窗口；② 按 (mtime, length) 缓存解析结果，
#      文件没变就完全不重新解析（正常轮询每轮只解析 0~1 个文件）。
#
#  被 kun-pet-desktop.ps1 以 dot-source 方式加载；也可被自测脚本单独加载。
# =====================================================================

# ---------------- 依赖兜底：单独加载（自测）时不至于报错 ----------------
# 主脚本已定义同名函数时不会被覆盖（dot-source 到主脚本作用域，Get-Command 能找到）。
if (-not (Get-Command -Name 'Write-Log' -CommandType Function -ErrorAction SilentlyContinue)) {
    function Write-Log([string]$msg) { }
}
if (-not (Get-Command -Name 'Limit-Text' -CommandType Function -ErrorAction SilentlyContinue)) {
    function Limit-Text([string]$text, [int]$max) {
        if (-not $text) { return '' }
        $t = ($text -replace '\s+', ' ').Trim()
        if ($t.Length -le $max) { return $t }
        return $t.Substring(0, $max) + '…'
    }
}
if (-not (Get-Command -Name 'Note-TickError' -CommandType Function -ErrorAction SilentlyContinue)) {
    function Note-TickError([string]$where, $err) { }
}
if (-not (Get-Command -Name 'Get-EpochMs' -CommandType Function -ErrorAction SilentlyContinue)) {
    function Get-EpochMs { return [int64]((Get-Date).ToUniversalTime() - $script:epochRef).TotalMilliseconds }
}
if (-not $script:epochRef) {
    $script:epochRef = [System.DateTime]::new(1970, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
}

# ---------------- 配置（主脚本的 Load-Settings 可覆盖） ----------------
# 家目录解析必须跨平台且容错：
#   - Windows PowerShell 5.1 / 7 有 $env:USERPROFILE
#   - Linux/macOS（CI 就跑在 ubuntu-latest 上）只有 $env:HOME
# 早先这里直接 `Join-Path $env:USERPROFILE ...`，在 Linux 上 USERPROFILE 为空串，
# Join-Path 会抛 ParameterBindingValidationException —— 而且是**在 dot-source 阶段**
# 抛，导致本文件后面所有函数都没被定义（CI 上表现为「测试全挂」）。
# 所以这里先稳妥地求出家目录，求不到就退回当前目录，绝不抛。
function Get-PiHomeDir {
    foreach ($v in @($env:USERPROFILE, $env:HOME, $env:HOMEDRIVE)) {
        if ($v -and ([string]$v).Trim()) {
            $s = ([string]$v).Trim()
            # HOMEDRIVE 单独用没有意义（如 'C:'），跳过
            if ($s.Length -le 2 -and $s -match '^[A-Za-z]:$') { continue }
            return $s
        }
    }
    try {
        $h = [Environment]::GetFolderPath('UserProfile')
        if ($h -and $h.Trim()) { return $h }
    } catch { }
    return (Get-Location).Path
}

$script:piHomeDir = Get-PiHomeDir
if (-not $script:piSessionsRoot) {
    $script:piSessionsRoot = Join-Path $script:piHomeDir '.pi/agent/sessions'
}
if (-not $script:piStateFile) {
    $script:piStateFile = Join-Path $script:piHomeDir '.pi/agent/kun-pet-state.json'
}
# 扩展状态文件的新鲜度窗口（扩展每 5s 心跳重写一次）
if (-not $script:piStateFileFreshSec) { $script:piStateFileFreshSec = 30 }
# 每个会话只回读尾部这么多字节：足够判定「在跑 / 刚收尾」
if (-not $script:piTailBytes) { $script:piTailBytes = 262144 }
# 会话年龄超过这个值就不再当「在跑」（容忍长时间思考时不写盘的情况）
if (-not $script:piFreshSec) { $script:piFreshSec = 180 }
# 候选会话的年龄上限（与 DSH 侧一致：15 分钟内写过）
if (-not $script:piCandidateSec) { $script:piCandidateSec = 900 }
# 「刚出错」「刚收尾」的提醒窗口（与主脚本 Update-Alerts 的 20s 窗口对齐）
if (-not $script:piRecentErrorSec) { $script:piRecentErrorSec = 15 }
if (-not $script:piRecentDoneSec) { $script:piRecentDoneSec = 20 }
if ($null -eq $script:piEnabled) { $script:piEnabled = $true }

$script:piDocCache = @{}      # path -> @{ stamp; header; state }
$script:piRunPrev = @{}       # sessionId -> 上一帧是否在跑（逐会话下降沿）
# 上一帧「在跑」的会话**文件路径**集合。候选筛选阶段的「跟踪中的保留」查它：
# 那时还没解析文件拿不到会话 id，只能按路径跟踪（旧代码查 piRunPrev 的文件名键，
# 但那张表实际按会话 id 存键，永远查不到 → 跟踪保留从未生效）。
$script:piPrevPaths = @{}     # fileFullName -> $true
# 嵌套会话文件（子代理产物）的「已记过日志」集合：否则每 500ms 轮询都会为
# 同一批文件各写一行 skip 日志，日志文件每秒膨胀数行。
$script:piSkippedLogged = @{}
$script:piCompletionAt = 0    # 最近一次「某会话刚收尾」的时间（epoch ms）
$script:piCompletionSummary = $null
$script:piMissingLogged = $false
$script:piSchemaWarned = @{}
# 上一帧「识别到的任务集合」签名，用于只在变化时打一行日志（排查多窗口问题）
$script:piRunningSig = $null

# ---------------- 配置入口（由主脚本调用） ----------------
# 为什么用函数而不是让主脚本直接 `$script:piSessionsRoot = ...`：
# 本文件是被 dot-source 进来的，跨文件写 `$script:` 变量的作用域解析规则很微妙
# （`$script:` 到底落在谁的脚本作用域，取决于 dot-source 语义与函数定义位置）。
# 由**本文件内**定义的函数来写、本文件内的函数来读，读写落在同一个作用域里，
# 不依赖那条规则，行为是确定的。主脚本只需要调用这两个 setter。
function Set-PiSourcePaths([string]$sessionsRoot, [string]$stateFile) {
    if ($sessionsRoot) { $script:piSessionsRoot = $sessionsRoot }
    if ($stateFile) { $script:piStateFile = $stateFile }
    # 路径变了就把解析缓存清掉，避免拿着旧路径的结果继续用
    $script:piDocCache = @{}
    $script:piRunPrev = @{}
    $script:piPrevPaths = @{}
    $script:piSkippedLogged = @{}
}

function Set-PiEnabled([bool]$enabled) {
    $script:piEnabled = [bool]$enabled
    if (-not $script:piEnabled) {
        $script:piDocCache = @{}
        $script:piRunPrev = @{}
        $script:piPrevPaths = @{}
    }
}

function Get-PiSourceInfo {
    return @{
        enabled      = [bool]$script:piEnabled
        sessionsRoot = [string]$script:piSessionsRoot
        stateFile    = [string]$script:piStateFile
    }
}

# 自测脚本用它观察/复位「刚收尾」缓冲（跨文件读 $script: 变量的作用域同样微妙，
# 统一走函数出入口，行为确定）
function Get-PiCompletionState {
    return @{ at = [int64]$script:piCompletionAt; summary = $script:piCompletionSummary }
}

function Reset-PiCompletionState {
    $script:piCompletionAt = 0
    $script:piCompletionSummary = $null
    $script:piRunPrev = @{}
    $script:piPrevPaths = @{}
}

function Restore-PiCompletionState([int64]$at, $summary) {
    $script:piCompletionAt = [int64]$at
    $script:piCompletionSummary = $summary
}

# ---------------- 小工具 ----------------
# pi 的记录级 timestamp 是 ISO8601（UTC，带 Z）。转 epoch ms。
function Convert-PiTimestamp([string]$ts) {
    try {
        if (-not $ts) { return [int64]0 }
        $dt = [datetime]::Parse($ts, [System.Globalization.CultureInfo]::InvariantCulture,
                                ([System.Globalization.DateTimeStyles]::AdjustToUniversal -bor
                                 [System.Globalization.DateTimeStyles]::AssumeUniversal))
        return [int64](($dt - $script:epochRef).TotalMilliseconds)
    } catch { return [int64]0 }
}

# 从 message.content 里取第一段文本：content 既可能是数组（正常消息），
# 也可能是字符串（system 段）。
function Get-PiFirstText($content, [int]$max = 200) {
    try {
        if ($null -eq $content) { return '' }
        if ($content -is [string]) { return (Limit-Text ([string]$content) $max) }
        foreach ($b in @($content)) {
            if ($null -eq $b) { continue }
            try {
                if ($b.type -eq 'text' -and $b.text) { return (Limit-Text ([string]$b.text) $max) }
            } catch { }
        }
    } catch { }
    return ''
}

# 私有：从**显式偏移**读一段字节。
# **必须 FileShare.ReadWrite**：pi 正在追加写这个文件，用默认共享模式会偶发
# IOException，表现为轮询日志被刷屏。
# 返回 @{ text; start; length }；start 是实际起点（便于调用方判断有没有截断）。
function Read-PiSlice([string]$path, [int64]$start, [int]$maxBytes) {
    $res = @{ text = ''; start = [int64]0; length = [int64]0 }
    $fs = $null
    try {
        $fs = [System.IO.File]::Open($path, [System.IO.FileMode]::Open,
                                     [System.IO.FileAccess]::Read, [System.IO.FileShare]::ReadWrite)
        $len = $fs.Length
        $res.length = $len
        if ($len -le 0) { return $res }
        if ($start -lt 0) { $start = [int64]0 }
        if ($start -gt $len) { $start = $len }
        $res.start = $start
        $count = [int]($len - $start)
        if ($count -le 0) { return $res }
        # maxBytes <= 0 = 只要元数据（长度），**不读内容**。
        # 这条很关键：Read-PiTailText 先用它取长度，若这里照读，
        # 每次轮询都会把整个会话文件读进内存 —— 恰好废掉了「只读尾部窗口」的意义。
        if ($maxBytes -le 0) { return $res }
        if ($count -gt $maxBytes) { $count = $maxBytes }
        [void]$fs.Seek($start, [System.IO.SeekOrigin]::Begin)
        $buf = New-Object byte[] $count
        $read = $fs.Read($buf, 0, $count)
        if ($read -le 0) { return $res }
        # 显式 UTF8 解码：pi 写的是不带 BOM 的 UTF-8，中文任务描述必须走这条路，
        # 否则在某些代码页下会变成乱码。
        $text = [System.Text.Encoding]::UTF8.GetString($buf, 0, $read)
        # 剥掉可能存在的 BOM。注意 .NET Framework 的 Trim() **不**把 U+FEFF 当空白，
        # 不显式剥掉的话首行会以 U+FEFF 开头，导致
        # ① `$t[0] -ne '{'` 把 session 头整行丢掉 ② ConvertFrom-Json 解析失败。
        # 我们自己的测试夹具（PS 5.1 的 Set-Content -Encoding UTF8）就是带 BOM 的。
        if ($text.Length -gt 0 -and $text[0] -eq [char]0xFEFF) {
            $text = $text.Substring(1)
        }
        $res.text = $text
    } catch {
        # 读不到（被独占/删除/权限）就当这次没有这个会话，不改任何状态
    } finally {
        if ($fs) { try { $fs.Dispose() } catch { } }
    }
    return $res
}

# 读文件**开头**（取会话头那一行：cwd / id / version）。
function Read-PiHeadText([string]$path, [int]$maxBytes) {
    return (Read-PiSlice $path ([int64]0) $maxBytes)
}

# 读文件**结尾**窗口。
# 返回 @{ text; truncated }：truncated = 窗口没覆盖到文件开头（首行可能是半行）。
function Read-PiTailText([string]$path, [int]$maxBytes) {
    $probe = Read-PiSlice $path ([int64]0) 0     # 只取长度，不读内容
    $len = [int64]$probe.length
    if ($len -le 0) { return @{ text = ''; truncated = $false } }
    $start = $len - $maxBytes
    if ($start -lt 0) { $start = [int64]0 }
    $slice = Read-PiSlice $path $start $maxBytes
    return @{ text = [string]$slice.text; truncated = ($start -gt 0) }
}

# 从尾部窗口切出「完整的 JSON 行」。
# 两个必须处理的截断坑：
#   ① 窗口首行可能是半行（截断点落在行中间）→ 丢弃；
#   ② 末行可能正被写入（没有结尾换行）→ 丢弃，否则会解析到半条 JSON。
function Read-PiTailLines([string]$path) {
    $win = Read-PiTailText $path $script:piTailBytes
    if (-not $win.text) { return @() }
    $lines = @($win.text -split "`n")
    if ($win.truncated -and $lines.Count -gt 1) {
        $lines = @($lines[1..($lines.Count - 1)])
    }
    if (-not $win.text.EndsWith("`n")) {
        if ($lines.Count -le 1) { return @() }
        $lines = @($lines[0..($lines.Count - 2)])
    }
    return $lines
}

# 会话头（第一行）：只有 cwd / id / version。
# 注意：pi 会话文件可能很大，所以这里**只读文件开头 4KB**（不是尾部窗口）——
# 这是 Read-PiHeadText 与 Read-PiTailText 分开的原因。
function Get-PiHeader([string]$path) {
    try {
        $win = Read-PiHeadText $path 4096
        if (-not $win.text) { return $null }
        $first = ($win.text -split "`n")[0]
        if (-not $first) { return $null }
        $rec = $first.Trim() | ConvertFrom-Json
        if ($null -eq $rec -or [string]$rec.type -ne 'session') { return $null }
        return $rec
    } catch { return $null }
}

# ---------------- 核心：把「一批会话记录」解析成中间状态 ----------------
# 抽成纯函数（不碰文件系统）是为了能用夹具直接自测 —— 见 tests/test-pi-source.ps1。
# 只依赖 pi 的**核心**记录类型：session / model_change / message / compaction。
# 刻意**不**依赖 custom(agent-summary)：那是扩展写的，纯净安装下不存在。
function Get-PiStateFromRecords($records) {
    $st = @{
        provider = $null; model = $null
        userTurns = 0; toolCalls = 0; toolResults = 0; failed = 0
        lastTool = $null; lastPrompt = ''; lastPromptMeaningful = ''; lastSummary = $null
        tailRole = $null; tailStop = $null
        lastError = ''; lastErrorAt = 0; lastRecordAt = 0
        compactionAt = 0
        tokens = 0; cost = 0.0
        pendingCount = 0
    }
    # toolCallId -> toolName（出现 toolCall 进，出现 toolResult 出）。
    # 注意：解析窗口是文件尾部，窗口首行可能落在某个 toolResult 上（其 toolCall
    # 在窗口之外）。Remove 不存在的 key 是 no-op，因此只会「少算」pending，
    # 绝不会算出负数 —— 这个方向是安全的（少算只会退化成按 mtime 判断）。
    $pending = @{}

    foreach ($rec in $records) {
        if ($null -eq $rec) { continue }
        $type = ''
        try { $type = [string]$rec.type } catch { continue }
        $at = 0
        try { $at = Convert-PiTimestamp ([string]$rec.timestamp) } catch { }
        if ($at -gt $st.lastRecordAt) { $st.lastRecordAt = $at }

        if ($type -eq 'model_change') {
            try {
                if ($rec.provider) { $st.provider = [string]$rec.provider }
                if ($rec.modelId) { $st.model = [string]$rec.modelId }
            } catch { }
            continue
        }
        if ($type -eq 'compaction') {
            $st.compactionAt = $at
            continue
        }
        if ($type -eq 'custom') {
            # agent-summary 只作为「加分项」填摘要，绝不作为收尾主信号
            try {
                if ([string]$rec.customType -eq 'agent-summary' -and $rec.data) {
                    $bits = @()
                    if ($null -ne $rec.data.commands) { $bits += ('{0} 次命令' -f [int]$rec.data.commands) }
                    if ($null -ne $rec.data.edits) { $bits += ('{0} 次编辑' -f [int]$rec.data.edits) }
                    if ($null -ne $rec.data.writes) { $bits += ('{0} 次写文件' -f [int]$rec.data.writes) }
                    if ($bits.Count -gt 0) { $st.lastSummary = '· ' + ($bits -join ' · ') }
                }
            } catch { }
            continue
        }
        if ($type -ne 'message') { continue }

        $m = $null
        try { $m = $rec.message } catch { }
        if ($null -eq $m) { continue }
        $role = ''
        try { $role = [string]$m.role } catch { continue }

        if ($role -eq 'system') { continue }

        if ($role -eq 'user') {
            $st.userTurns++
            $t = Get-PiFirstText $m.content 200
            if ($t) {
                # 记「最近一条」（保底）
                $st.lastPrompt = $t
                # 再记「最近一条**有意义**的」：pi 用户经常只回一个字（"可以" / "+" / "继续"），
                # 拿它当气泡里的任务描述毫无信息量。
                # 判据：去掉标点/空白后长度 >= 4 才算有意义（"可以"=2 不算，"继续跑测试"算）。
                $core = ($t -replace '[\s\p{P}\p{S}]', '')
                if ($core.Length -ge 4) { $st.lastPromptMeaningful = $t }
            }
            $st.tailRole = 'user'
            $st.tailStop = $null
            continue
        }

        if ($role -eq 'assistant') {
            try {
                if ($m.provider) { $st.provider = [string]$m.provider }
                if ($m.model) { $st.model = [string]$m.model }
                if ($m.usage) {
                    if ($m.usage.totalTokens) { $st.tokens += [int]$m.usage.totalTokens }
                    if ($m.usage.cost) {
                        try { if ($m.usage.cost.total) { $st.cost += [double]$m.usage.cost.total } } catch { }
                    }
                }
            } catch { }

            $stop = ''
            try { $stop = [string]$m.stopReason } catch { }
            $st.tailRole = 'assistant'
            $st.tailStop = $stop
            if ($stop -eq 'error') {
                $st.failed++
                $st.lastErrorAt = $at
                try { $st.lastError = [string]$m.errorMessage } catch { }
            }
            try {
                foreach ($b in @($m.content)) {
                    if ($null -eq $b) { continue }
                    if ($b.type -eq 'toolCall') {
                        $id = [string]$b.id
                        $name = [string]$b.name
                        if ($id) { $pending[$id] = $name }
                        $st.toolCalls++
                        if ($name) { $st.lastTool = $name }
                    }
                }
            } catch { }
            continue
        }

        if ($role -eq 'toolResult') {
            $st.toolResults++
            try {
                $id = [string]$m.toolCallId
                if ($id) { [void]$pending.Remove($id) }
                if ($m.isError) {
                    $st.failed++
                    $st.lastErrorAt = $at
                }
                $name = ''
                try { $name = [string]$m.toolName } catch { }
                if ($name) { $st.lastTool = $name }
            } catch { }
            $st.tailRole = 'toolResult'
            $st.tailStop = $null
            continue
        }
    }

    $st.pendingCount = $pending.Count
    return $st
}

# ---------------- 单个会话文件 → 状态（带缓存） ----------------
function Get-PiFileState($file) {
    try {
        $path = [string]$file.FullName
        $stamp = '{0}:{1}' -f $file.LastWriteTimeUtc.Ticks, $file.Length
        $hit = $script:piDocCache[$path]
        if ($null -ne $hit -and [string]$hit.stamp -eq $stamp) {
            return $hit.state
        }

        $header = Get-PiHeader $path
        if ($null -eq $header) {
            # 首行还没写完（文件刚建）或不是 pi 会话 → 本轮跳过
            $script:piDocCache[$path] = @{ stamp = $stamp; header = $null; state = $null }
            return $null
        }

        $ver = 0
        try { $ver = [int]$header.version } catch { $ver = 0 }
        if ($ver -gt 3) {
            # schema 升版：字段可能变了。不猜字段，但**仍然按已知字段尽力解析**
            # （坏行/缺字段都会被下面逐行 try 吞掉），只是记一行日志便于排查。
            $sid0 = [string]$header.id
            if (-not $script:piSchemaWarned.ContainsKey($sid0)) {
                $script:piSchemaWarned[$sid0] = $true
                Write-Log ('pi source: session schema v{0} is newer than adapted v3 ({1}); parsing best-effort' -f $ver, $sid0)
            }
        }

        $raw = Read-PiTailLines $path
        $records = New-Object System.Collections.ArrayList
        foreach ($line in $raw) {
            if (-not $line) { continue }
            $t = $line.Trim()
            if ($t.Length -lt 3 -or $t[0] -ne '{') { continue }
            try {
                [void]$records.Add(($t | ConvertFrom-Json))
            } catch {
                # 坏行（写一半/编码问题）跳过，不中断整个文件
            }
        }

        $st = Get-PiStateFromRecords $records
        $state = @{
            id = [string]$header.id
            cwd = [string]$header.cwd
            version = $ver
            ageSec = ((Get-Date) - $file.LastWriteTime).TotalSeconds
            parsed = $st
        }
        $script:piDocCache[$path] = @{ stamp = $stamp; header = $header; state = $state }
        return $state
    } catch {
        return $null
    }
}

# 数一个目录在 root 之下有几层（root 自己 = 0，直接子目录 = 1，以此类推）。
# 不在 root 之下时返回 -1。
#
# 为什么不用 Substring：那要求两个字符串长度严格对齐。真实踩过的坑——
# 路径里出现 8.3 短名（同一目录的长名与 ~1 短名混用）时，Substring 会切错位置，
# 相对路径变成 'sions\proj\a.jsonl'，层级算错 → 会话被静默跳过（整体失效）。
# 这里改成从目录**向上逐级比对**父目录，用 .NET 规范化后的 FullName 比较，与长度无关。
function Get-PiLevelsBelowRoot($dir, [string]$rootFull) {
    try {
        if ($null -eq $dir) { return -1 }
        $cur = [System.IO.DirectoryInfo]$dir
        $levels = 0
        while ($null -ne $cur) {
            $curFull = $cur.FullName.TrimEnd('\', '/')
            if ([string]::Equals($curFull, $rootFull, [System.StringComparison]::OrdinalIgnoreCase)) {
                return $levels
            }
            $levels++
            $cur = $cur.Parent
            if ($levels -gt 64) { break }   # 防御：异常深的路径直接放弃
        }
        return -1
    } catch { return -1 }
}

# ---------------- 判定：单个会话是「在跑」还是「已收尾」 ----------------
# 返回 @{ running; mode; reason }。mode 只用桌宠已有的词汇。
function Get-PiSessionVerdict($state) {
    $st = $state.parsed
    $age = [double]$state.ageSec
    $fresh = ($age -lt $script:piFreshSec)

    $hasPending = ([int]$st.pendingCount -gt 0)
    $toolUseTail = ($st.tailRole -eq 'assistant' -and $st.tailStop -eq 'toolUse')
    $errTail = ($st.tailStop -eq 'error')
    $doneTail = ($st.tailRole -eq 'assistant' -and $st.tailStop -eq 'stop')

    # 「在跑」= 有悬空工具调用（最强信号，完全不看 mtime）
    #        或 尾部明确还要调工具
    #        或 尾部是 user/toolResult 且会话仍新鲜（agent 正在处理/思考）
    # 注意：**错误尾部不算在跑** —— 否则会把「已失败」显示成「干活中」，
    # 与你想要的「出错变红摇晃」正好相反。
    $running = $false
    if ($hasPending) { $running = $true }
    elseif ($toolUseTail) { $running = $true }
    elseif (($st.tailRole -eq 'user' -or $st.tailRole -eq 'toolResult') -and $fresh) { $running = $true }

    $mode = 'idle'
    $reason = 'idle'
    if ($running) {
        if ($hasPending) { $mode = 'working'; $reason = 'tool-pending' }
        elseif ($toolUseTail) { $mode = 'working'; $reason = 'tooluse-tail' }
        elseif ($age -lt 15) { $mode = 'working'; $reason = 'fresh-activity' }
        else { $mode = 'review'; $reason = 'thinking' }
    } elseif ($errTail -and $age -lt $script:piRecentErrorSec) {
        $mode = 'failed'; $reason = 'error'
    } elseif ($doneTail -and $age -lt $script:piRecentDoneSec) {
        # 刚结束一轮（只在「刚刚」的窗口内才算 celebrating）。
        # 必须带 $age 判断：否则几天前就跑完的会话会永远报 celebrating，
        # 桌宠重启后会把它当成刚结束的任务反复庆祝。
        # 真正的「收尾提醒」由聚合层的「逐会话下降沿」触发，这里只是让判定自洽。
        $mode = 'celebrating'; $reason = 'turn-done'
    }

    return @{ running = $running; mode = $mode; reason = $reason }
}

# ---------------- 通道 2：会话 JSONL 聚合（零安装） ----------------
function Get-StateFromPiSessions {
    try {
        if (-not (Test-Path -LiteralPath $script:piSessionsRoot)) {
            if (-not $script:piMissingLogged) {
                $script:piMissingLogged = $true
                Write-Log ('pi source: sessions dir not found ({0}); pi compatibility idle' -f $script:piSessionsRoot)
            }
            return $null
        }

        $root = New-Object System.IO.DirectoryInfo $script:piSessionsRoot
        $all = $root.GetFiles('*.jsonl', [System.IO.SearchOption]::AllDirectories)
        if ($null -eq $all -or $all.Length -eq 0) { return $null }

        # ---- 精确排除子代理会话：**按目录层级**，而不是按 cwd 去重 ----
        #
        # pi-subagents 的子女会话**从不**直接写在 <sessions 根>/<转义cwd>/*.jsonl，
        # 而是落在 artifacts 目录里（读过 pi-subagents 源码 + 本机实测确认）：
        #   - artifactDir='session'（**默认**）→ <sessions根>/<转义cwd>/subagent-artifacts/…
        #   - artifactDir='project'           → <项目>/.pi/subagents/artifacts/…（根本不在 sessions 下）
        #   - artifactDir='temp'              → 系统临时目录
        # 也就是说：**主会话的会话文件深度恒为 2**（根/项目目录/文件），
        # 任何更深层的 .jsonl 都是子代理产物。按深度过滤既精确、又零代价。
        #
        # 这里刻意**不再**按 cwd 去重 —— 那是我最初的错误做法：它会把「同一项目目录下
        # 开了多个 pi 窗口」误判成子代理，只显示一个任务。多窗口恰恰是常见用法。
        $sessionFiles = New-Object System.Collections.ArrayList
        $rootFull = ([System.IO.DirectoryInfo]$script:piSessionsRoot).FullName.TrimEnd('\', '/')
        foreach ($f in $all) {
            # 用「向上走父目录」算层级，**不要**用 Substring($root.Length)：
            # 后者假设两边字符串长度完全一致，一旦路径被规范化过就会错位 ——
            # 例如 8.3 短名（ADMINI~1 vs Administrator）、尾斜杠、符号链接。
            # 实测踩过：Substring 多切了 6 个字符，相对路径成了 'sions\proj\a.jsonl'，
            # 段数算成 3 → 该文件被当成子代理产物**静默跳过**（功能整体失效）。
            # 让 .NET 自己规范化两边再比，就不会有这个问题。
            $levels = Get-PiLevelsBelowRoot $f.Directory $rootFull
            if ($levels -lt 0 -or $levels -gt 1) {
                # levels<0：不在 root 下（异常情况）；levels>1：在子目录里 → 子代理产物
                # 日志每个文件只记一次（表太大了就整表重置，宁可重记也不无限增长）
                if (-not $script:piSkippedLogged.ContainsKey($f.FullName)) {
                    if ($script:piSkippedLogged.Count -gt 200) { $script:piSkippedLogged = @{} }
                    $script:piSkippedLogged[$f.FullName] = $true
                    Write-Log ('pi source: skipped nested session file (likely subagent artifact): {0}' -f $f.FullName)
                }
                continue
            }
            [void]$sessionFiles.Add($f)
        }
        if ($sessionFiles.Count -eq 0) { return $null }

        # 候选：最近 piCandidateSec 内写过的 + 之前跟踪中的（保证收尾下降沿能被观测到）
        # 「跟踪中」查的是按**文件路径**记的 piPrevPaths——旧代码查 piRunPrev 的
        # 文件名键，而那张表实际按会话 id 存键，永远查不到（等于没有跟踪保留）。
        $now = Get-Date
        $candidates = New-Object System.Collections.ArrayList
        foreach ($f in $sessionFiles) {
            $ageSec = ($now - $f.LastWriteTime).TotalSeconds
            $tracked = $false
            try { $tracked = $script:piPrevPaths.ContainsKey([string]$f.FullName) } catch { }
            if ($ageSec -le $script:piCandidateSec -or $tracked) {
                [void]$candidates.Add($f)
            }
        }
        if ($candidates.Count -eq 0) { return $null }

        # 只处理最新的若干会话，避免历史会话拖慢轮询。
        # 上限从 12 提到 24：多窗口场景下「同时在跑的 pi」很容易超过 12 个，
        # 截断会让最新的窗口挤掉别的活跃窗口（表现为「有的窗口不显示」）。
        $ordered = @($candidates | Sort-Object LastWriteTime -Descending | Select-Object -First 24)

        # (a) 先把候选会话全部求值（含逐会话下降沿），(b) 再聚合。
        $seen = New-Object System.Collections.ArrayList
        $seenIds = @{}
        $seenPaths = @{}
        $anyFresh = $false
        $nowMs0 = [int64]((Get-Date).ToUniversalTime() - $script:epochRef).TotalMilliseconds

        foreach ($f in $ordered) {
            $state = Get-PiFileState $f
            if ($null -eq $state) { continue }

            $fPath = [string]$f.FullName
            $seenPaths[$fPath] = $true
            $sid = [string]$state.id
            if ($sid) { $seenIds[$sid] = $true }

            $verdict = Get-PiSessionVerdict $state
            $wasRunning = $false
            if ($sid -and $script:piRunPrev.ContainsKey($sid)) { $wasRunning = [bool]$script:piRunPrev[$sid] }
            if ($sid) { $script:piRunPrev[$sid] = [bool]$verdict.running }
            # 路径跟踪表与 id 表同步维护：候选筛选阶段靠它保留「之前在跑」的会话
            if ($verdict.running) { $script:piPrevPaths[$fPath] = $true }
            else { try { [void]$script:piPrevPaths.Remove($fPath) } catch { } }

            # ---- 逐会话下降沿 = 「这一轮结束了」----
            # 必须逐会话记「上一帧是否在跑」。共用一个全局标记时，B 会话的静止会被
            # 误当成 A 会话的收尾（DSH 侧踩过，会误报/漏报完成）。
            if ($wasRunning -and -not $verdict.running) {
                # 完成时刻取「**现在**」（我们观察到下降沿的这一刻），而不是文件里
                # 最后一条记录的时间戳。原因：
                #  ① 语义上我们要表达的是「刚刚发现它收尾了」，提醒窗口（20s）就是以
                #     这个时刻为基准的；
                #  ② 用记录时间戳会依赖会话文件里的时钟，遇到 pi 写入时间与本地时钟
                #     有偏差（或会话被挂起后恢复）就会算出「很久以前完成」，提醒直接丢失。
                $script:piCompletionAt = $nowMs0
                $bits = @()
                if ($state.parsed.toolCalls -gt 0) { $bits += ('{0} 次工具调用' -f [int]$state.parsed.toolCalls) }
                if ($state.parsed.failed -gt 0) { $bits += ('{0} 次失败' -f [int]$state.parsed.failed) }
                if ($bits.Count -eq 0 -and $state.parsed.lastSummary) { $bits += [string]$state.parsed.lastSummary }
                if ($bits.Count -gt 0) {
                    $script:piCompletionSummary = '· ' + ($bits -join ' · ')
                } else {
                    $script:piCompletionSummary = $null
                }
            }

            if ([double]$state.ageSec -lt 20) { $anyFresh = $true }

            [void]$seen.Add(@{
                id       = $sid
                cwd      = [string]$state.cwd
                ageSec   = [double]$state.ageSec
                running  = [bool]$verdict.running
                mode     = [string]$verdict.mode
                reason   = [string]$verdict.reason
                parsed   = $state.parsed
            })
        }

        # (b) 每个正在跑的会话都算一个任务 —— **不做** cwd 合并。
        #
        # 子代理已经在上面按「目录层级」精确排除了，所以这里不需要（也不应该）
        # 再按 cwd 去重：同一项目目录下开多个 pi 窗口是完全正常的用法，
        # 每个窗口都是一个独立任务，必须都显示出来。
        # （早先版本按 cwd 只保留一个，导致「多开 pi 只认得到一个任务」，已修。）
        $runningAll = @($seen | Where-Object { $_.running })
        $runningSessions = New-Object System.Collections.ArrayList
        foreach ($chosen in $runningAll) {
            # 气泡优先用「有意义的最近一条」：pi 里用户常只回 "可以" / "+" / "继续"，
            # 直接显示那条对用户毫无信息量。只有在没有更有意义的输入时才退回它。
            $shownPrompt = [string]$chosen.parsed.lastPromptMeaningful
            if (-not $shownPrompt) { $shownPrompt = [string]$chosen.parsed.lastPrompt }
            [void]$runningSessions.Add(@{
                id     = $chosen.id
                cwd    = $chosen.cwd
                prompt = $shownPrompt
                turns  = [int]$chosen.parsed.userTurns
                steps  = [int]$chosen.parsed.toolCalls
                tool   = $chosen.parsed.lastTool
                mode   = $chosen.mode
                reason = $chosen.reason
                ageSec = $chosen.ageSec
            })
        }
        # 同一目录多窗口时，气泡里加项目名区分（否则几行看起来一模一样，分不清哪个是哪个）
        $cwdCount = @{}
        foreach ($r in $runningSessions) {
            $k = [string]$r.cwd
            if (-not $k) { $k = '?' }
            if (-not $cwdCount.ContainsKey($k)) { $cwdCount[$k] = 0 }
            $cwdCount[$k]++
        }

        # ---- 汇总（只在被选中的会话上统计，避免把子代理的数字算进主任务）----
        $totalTurns = 0; $totalSteps = 0
        $failureCount = 0
        $lastErrorText = ''
        $recentErrorAt = [int64]0
        $provider = $null; $model = $null
        $tokens = 0; $cost = 0.0
        $compacting = $false
        foreach ($s in $seen) {
            $p = $s.parsed
            $totalTurns += [int]$p.userTurns
            $totalSteps += [int]$p.toolCalls
            $failureCount += [int]$p.failed
            $tokens += [int]$p.tokens
            $cost += [double]$p.cost
            if ($p.provider) { $provider = [string]$p.provider }
            if ($p.model) { $model = [string]$p.model }
            if ($p.compactionAt -gt 0 -and ($nowMs0 - $p.compactionAt) -lt 10000) { $compacting = $true }
            # 「最近出错」用时间窗，而不是累计失败数：
            # failureCount 覆盖整个 256KB 尾部窗口，长会话里几乎必然 >0，
            # 拿它判 failed 会让桌宠永远显示红色。
            if ([int64]$p.lastErrorAt -gt $recentErrorAt) {
                $recentErrorAt = [int64]$p.lastErrorAt
                $lastErrorText = [string]$p.lastError
            }
        }
        $recentError = ($recentErrorAt -gt 0 -and
                        ($nowMs0 - $recentErrorAt) -lt ($script:piRecentErrorSec * 1000))

        # 跟踪表裁剪：会话文件被删/改名后不要无限增长（id 表与路径表都要裁）
        if ($script:piRunPrev.Count -gt 64) {
            foreach ($k in @($script:piRunPrev.Keys)) {
                if (-not $seenIds.ContainsKey($k)) { [void]$script:piRunPrev.Remove($k) }
            }
        }
        if ($script:piPrevPaths.Count -gt 64) {
            foreach ($k in @($script:piPrevPaths.Keys)) {
                if (-not $seenPaths.ContainsKey($k)) { [void]$script:piPrevPaths.Remove($k) }
            }
        }

        # 全部会话都已收尾，且缓冲里有「刚刚」发生的一次完成
        $nowMs = [int64]((Get-Date).ToUniversalTime() - $script:epochRef).TotalMilliseconds
        $doneRecent = ($script:piCompletionAt -gt 0 -and ($nowMs - $script:piCompletionAt) -lt ($script:piRecentDoneSec * 1000))

        # 只在「识别到的任务集合」变化时打一行日志。
        # 必须放在下面那个 idle 提前 return **之前**，否则「任务数变成 0」这条最关键
        # 的转变不会被记录（排查「多开 pi 只显示一个」时正需要看每次集合变化）。
        try {
            $sig = (@($runningSessions | ForEach-Object { ([string]$_.id) + '@' + ([string]$_.cwd) }) -join '|')
            if ($sig -ne $script:piRunningSig) {
                $script:piRunningSig = $sig
                if ($runningSessions.Count -gt 0) {
                    $ids = @($runningSessions | ForEach-Object {
                        $s = [string]$_.id
                        $s.Substring(0, [Math]::Min(8, $s.Length))
                    })
                    Write-Log ('pi source: {0} running task(s) [{1}]' -f $runningSessions.Count, ($ids -join ', '))
                } else {
                    Write-Log 'pi source: no running tasks'
                }
            }
        } catch { }

        if ($runningSessions.Count -eq 0 -and -not $doneRecent -and -not $anyFresh) {
            # 没有在跑、也没有刚收尾 → 这个源此刻没有可报告的东西。
            # 返回 idle 快照让上层知道「pi 装了但闲着」，便于显示来源标签。
            return @{
                mode           = 'idle'
                seq            = 5
                source         = 'pi'
                agentSource    = 'pi'
                message        = 'pi 待机中'
                progressLines  = @()
                waiting        = $false
                waitingKind    = $null
                waitingCount   = 0
                waitingSeconds = 0
                runningAgents  = 0
                toolCount      = $totalSteps
                lastTool       = $null
                lastSummary    = $null
                completedAt    = 0
                failureCount   = $failureCount
                taskText       = ''
                piModel        = $model
                piProvider     = $provider
                piTurns        = $totalTurns
                piSteps        = $totalSteps
                piTokens       = $tokens
                piCostTotal    = $cost
                piCompacting   = $compacting
            }
        }

        # ---- 聚合模式 ----
        $mode = 'idle'
        $message = ''
        $progressLines = @()
        $taskText = ''
        $lastTool = $null
        $runningCount = $runningSessions.Count

        # 判 failed 用「最近 piRecentErrorSec 内出错」，**不用** failureCount：
        # 后者统计的是整个 256KB 尾部窗口，长会话里几乎必然 >0，
        # 一旦拿它判 failed，桌宠会在任务正常跑着的时候一直红色告警。
        if ($recentError -and $runningCount -eq 0) {
            $mode = 'failed'
            if ($lastErrorText) { $message = '出错了：' + (Limit-Text $lastErrorText 40) }
            else { $message = 'pi 出错了' }
            $progressLines = @($message)
        } elseif ($doneRecent -and $runningCount -eq 0) {
            $mode = 'celebrating'
        } elseif ($runningCount -gt 0) {
            # 逐会话取最「实」的模式：有工具在跑优先于思考中
            $mode = 'review'
            foreach ($r in $runningSessions) {
                if ($r.mode -eq 'working') { $mode = 'working'; break }
            }
            $lastTool = $null
            foreach ($r in $runningSessions) { if ($r.tool) { $lastTool = [string]$r.tool } }

            if ($runningCount -eq 1) {
                $one = $runningSessions[0]
                $taskText = [string]$one.prompt
                $message = '进行中：' + (Limit-Text $taskText 46)
                $progressLines += ('正在处理：' + (Limit-Text $taskText 40) +
                                   (' · {0} 轮 / {1} 步' -f [int]$one.turns, [int]$one.steps))
            } else {
                $message = '{0} 个 pi 任务进行中' -f $runningCount
                foreach ($r in $runningSessions) {
                    $line = '· [pi] ' + (Limit-Text ([string]$r.prompt) 34)
                    # 同一目录开了多个窗口时，几行会长得一模一样，分不清哪个是哪个。
                    # 这种情况给每行补一个项目名（取路径最后一段）作区分。
                    $cwdKey = [string]$r.cwd
                    if (-not $cwdKey) { $cwdKey = '?' }
                    if ($cwdCount[$cwdKey] -gt 1 -and $r.cwd) {
                        $proj = Split-Path -Leaf ([string]$r.cwd)
                        if ($proj) { $line += ('〔' + (Limit-Text $proj 16) + '〕') }
                    }
                    $line += ('（{0} 轮 / {1} 步）' -f [int]$r.turns, [int]$r.steps)
                    $progressLines += $line
                }
                # 上限从 3 提到 5：多开 pi 时前 3 条会把后面的窗口全遮掉。
                # 折叠行里保留总数，保证「有几个任务」永远看得见。
                if ($progressLines.Count -gt 5) {
                    $progressLines = @($progressLines[0..4])
                    $progressLines += ('… 共 {0} 个 pi 任务进行中' -f $runningCount)
                }
            }
        } else {
            $mode = 'idle'
            $message = 'pi 待机中'
        }

        if ($compacting) { $progressLines = @($progressLines) + @('（pi 正在压缩上下文）') }

        # （任务集合变化日志已在上面的 idle 提前 return 之前统一输出，这里不再重复）

        $modeWeight = 5
        if ($mode -eq 'waiting') { $modeWeight = 1 }
        elseif ($mode -eq 'working') { $modeWeight = 2 }
        elseif ($mode -eq 'celebrating') { $modeWeight = 3 }
        elseif ($mode -eq 'review') { $modeWeight = 4 }
        elseif ($mode -eq 'failed') { $modeWeight = 6 }
        $seqFp = [int](((($totalTurns * 100000L) + ($totalSteps * 10L) +
                        ($runningCount * 6L) + $modeWeight) % 2000000000L))

        # 注意：`if` 不能作为表达式出现在哈希字面量里（PS 5.1 会报「if 不是有效表达式」，
        # 这个坑 README 里针对启动器已记录过一次）。先算好变量再放进 @{}。
        $completedValue = [double]0
        if ($doneRecent) { $completedValue = [double]$script:piCompletionAt }

        return @{
            mode           = $mode
            seq            = $seqFp
            source         = 'pi'
            agentSource    = 'pi'
            message        = $message
            progressLines  = @($progressLines)
            waiting        = $false
            waitingKind    = $null
            waitingCount   = 0
            waitingSeconds = 0
            runningAgents  = $runningCount
            toolCount      = $totalSteps
            lastTool       = $lastTool
            lastSummary    = $script:piCompletionSummary
            completedAt    = $completedValue
            failureCount   = $failureCount
            taskText       = (Limit-Text $taskText 60)
            piModel        = $model
            piProvider     = $provider
            piTurns        = $totalTurns
            piSteps        = $totalSteps
            piTokens       = $tokens
            piCostTotal    = $cost
            piCompacting   = $compacting
        }
    } catch {
        Note-TickError 'pi-state-sessions' $_
        return $null
    }
}

# ---------------- 通道 1：扩展状态文件（精确，需装 pi 扩展） ----------------
# 扩展用 pi 的 ui_prompt_start / ui_prompt_end 事件，这是**唯一**能可靠表达
# 「pi 正在等你确认」的官方信号；纯文件尾随拿不到这一项。
function Get-StateFromPiExtension {
    try {
        if (-not $script:piStateFile) { return $null }
        if (-not (Test-Path -LiteralPath $script:piStateFile)) { return $null }

        $resp = $null
        try {
            # 与 DSH 侧同样的写法：显式 UTF8 读整份快照（体积很小）
            $resp = Get-Content -LiteralPath $script:piStateFile -Raw -Encoding UTF8 | ConvertFrom-Json
        } catch { return $null }
        if ($null -eq $resp) { return $null }

        # 新鲜度：扩展每 5s 心跳重写；过期说明 pi 已退出，不能采信陈旧状态
        $updatedAt = 0
        try { if ($resp.updatedAt) { $updatedAt = [int64]$resp.updatedAt } } catch { $updatedAt = 0 }
        $fresh = $false
        if ($updatedAt -gt 0) {
            $nowMs = [int64]((Get-Date).ToUniversalTime() - $script:epochRef).TotalMilliseconds
            $ageMs = $nowMs - $updatedAt
            $fresh = ($ageMs -ge -5000 -and $ageMs -lt ($script:piStateFileFreshSec * 1000))
        } else {
            $ageSec = ((Get-Date) - (Get-Item -LiteralPath $script:piStateFile).LastWriteTime).TotalSeconds
            $fresh = ($ageSec -lt $script:piStateFileFreshSec)
        }
        if (-not $fresh) { return $null }

        $waitingKind = $null
        try { if ($resp.waitingKind) { $waitingKind = [string]$resp.waitingKind } } catch { }
        $msg = ''
        try { $msg = [string]$resp.message } catch { }
        if (-not $msg) {
            if ($resp.waiting) { $msg = 'pi 正在等你确认' } else { $msg = 'pi 待机中' }
        }
        $approvals = @()
        try { if ($resp.pendingApprovals) { $approvals = @($resp.pendingApprovals) } } catch { }

        $lastToolExt = $null
        if ($resp.lastTool) { $lastToolExt = [string]$resp.lastTool }
        $modelExt = $null
        if ($resp.model) { $modelExt = [string]$resp.model }
        $providerExt = $null
        if ($resp.provider) { $providerExt = [string]$resp.provider }

        return @{
            mode           = [string]$resp.mode
            seq            = [int]$resp.seq
            source         = 'pi'
            agentSource    = 'pi'
            message        = $msg
            progressLines  = @($msg)
            waiting        = [bool]$resp.waiting
            waitingKind    = $waitingKind
            waitingCount   = [int]$resp.waitingCount
            waitingSeconds = [int]$resp.waitingSeconds
            runningAgents  = [int]$resp.runningAgents
            toolCount      = [int]$resp.toolCount
            lastTool       = $lastToolExt
            lastSummary    = [string]$resp.lastSummary
            completedAt    = [double]$resp.completedAt
            failureCount   = [int]$resp.failureCount
            taskText       = ''
            questionText   = [string]$resp.waitingTitle
            piModel        = $modelExt
            piProvider     = $providerExt
            piTurns        = [int]$resp.turns
            piSteps        = [int]$resp.steps
            piCompacting   = [bool]$resp.compacting
            pendingApprovals = $approvals
            # pi 侧目前没有「在桌宠上直接批准」的通道（P3 未启用），
            # 显式标成非 http，避免主脚本误显示 ✓/✗ 面板
            approvalChannel = 'pi'
        }
    } catch {
        return $null
    }
}

# ---------------- 入口：两通道合并 ----------------
# 优先级：扩展（精确，能表达「等你确认」）> 会话尾随（零安装，覆盖进展/收尾/出错）。
# 两者都新鲜时，用扩展决定 mode/waiting，用会话补齐 model/turns/steps
# （扩展不一定知道这些，会话文件里一定有）。
# 【v2.4.4 性能】会话尾随通道节流：GetFiles(AllDirectories) 递归扫描 + 候选文件 tail
# 256KB 读 + 逐行 ConvertFrom-Json，全部跑在 UI 线程（DispatcherTimer 回调）。
# 实测：24 个候选的最坏情况要几百毫秒 —— 这就是「宠物动着动着停一下」的另一半来源。
# 会话状态本身是秒级变化的，2 秒节流对气泡没有任何可感知影响；扩展状态文件通道很便宜，
# 保持每轮（它才是「等你确认」的权威信号）。
$script:piSesCache = $null
$script:piSesCacheAt = [datetime]::MinValue
$script:piSesCacheEmpty = $false
$script:piSesIntervalMs = 2000

# 测试钩子：夹具文件被改写后清掉节流缓存，让下一次调用立即重扫。
# 真实运行不需要它（真实会话文件由 pi 追加写，mtime 变化本来就落在下个节流窗口里）。
function Set-PiSessionCacheStale {
    $script:piSesCache = $null
    $script:piSesCacheAt = [datetime]::MinValue
}

function Get-StateFromPiSessionsThrottled {
    $now = Get-Date
    if (($now - $script:piSesCacheAt).TotalMilliseconds -lt $script:piSesIntervalMs) {
        # 窗口内：直接用上一次结果（空/非空都缓存，避免每 500ms 白扫目录）
        return $script:piSesCache
    }
    $script:piSesCacheAt = $now
    $ses = Get-StateFromPiSessions
    $script:piSesCache = $ses
    return $ses
}

function Get-StateFromPi {
    if (-not $script:piEnabled) { return $null }
    try {
        $ext = Get-StateFromPiExtension
        $ses = Get-StateFromPiSessionsThrottled

        if ($null -eq $ext -and $null -eq $ses) { return $null }
        if ($null -eq $ext) { return $ses }
        if ($null -eq $ses) { return $ext }

        # 扩展权威地决定「等你确认」与模式；等待优先于一切
        if ($ext.waiting) {
            if (-not $ext.piModel -and $ses.piModel) { $ext.piModel = $ses.piModel }
            if (-not $ext.piProvider -and $ses.piProvider) { $ext.piProvider = $ses.piProvider }
            return $ext
        }
        # 扩展说闲着但会话正在跑 → 以会话为准（扩展可能还没收到事件）
        if ($ses.runningAgents -gt 0) {
            foreach ($k in @('piModel', 'piProvider', 'piTurns', 'piSteps', 'piTokens', 'piCostTotal')) {
                if ($ses.ContainsKey($k) -and ($null -eq $ext[$k] -or $ext[$k] -eq 0)) { $ext[$k] = $ses[$k] }
            }
            return $ses
        }
        # 会话刚有完成事件而扩展还没标记 → 用会话的完成信息
        if ($ses.completedAt -gt 0 -and $ext.completedAt -le 0) {
            $ext.completedAt = $ses.completedAt
            if ($ses.lastSummary) { $ext.lastSummary = $ses.lastSummary }
        }
        foreach ($k in @('piModel', 'piProvider', 'piTurns', 'piSteps', 'piTokens', 'piCostTotal')) {
            if (-not $ext[$k] -and $ses[$k]) { $ext[$k] = $ses[$k] }
        }
        return $ext
    } catch {
        Note-TickError 'pi-state' $_
        return $null
    }
}

# ---------------- 初始化日志 ----------------
# 注意：这里**不**打印就绪日志。模块被 dot-source 时，主脚本紧接着还会用
# Config 覆盖 piSessionsRoot / piStateFile，此时打印会写出一个即将被改掉的路径，
# 排查时反而误导。就绪日志由主脚本在覆盖之后统一打（见 kun-pet-desktop.ps1）。
