<#
  pi 源适配器自测（不需要真的起一只桌宠，也不需要装 pi）

  用法：
    powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\test-pi-source.ps1

  它做三件事：
    1. 纯函数回归：Get-PiStateFromRecords / Get-PiSessionVerdict 直接吃夹具记录，
       验证「toolCall/toolResult 配平」「尾部 stopReason」「错误尾部」的判定。
    2. 端到端：把夹具拷进一个临时 sessions 目录（并伪造 mtime），
       走完整的 Get-StateFromPiSessions，验证「在跑 / 收尾 / 出错 / 待机」四种结论。
    3. 边界：空文件、半行 JSON、坏 JSON、空目录都要静默降级，不抛异常。

  全程只读夹具、只写系统临时目录，不碰 ~/.pi 与 ~/.dsh 的任何真实文件。
#>
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'

$script:fail = 0
$script:pass = 0

function Check([string]$name, $actual, $expected) {
    $a = if ($null -eq $actual) { '<null>' } else { [string]$actual }
    $e = if ($null -eq $expected) { '<null>' } else { [string]$expected }
    if ($a -eq $e) {
        $script:pass++
        Write-Host ("  [ok]   {0}" -f $name) -ForegroundColor Green
    } else {
        $script:fail++
        Write-Host ("  [FAIL] {0}  期望={1} 实际={2}" -f $name, $e, $a) -ForegroundColor Red
    }
}

function CheckTrue([string]$name, $cond) {
    Check $name $(if ($cond) { 'True' } else { 'False' }) 'True'
}

# ---------------- 加载被测模块 ----------------
$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
$desktop = Split-Path -Parent $here
$modulePath = Join-Path $desktop 'kun-pet-pi-source.ps1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    Write-Host ("找不到模块: " + $modulePath) -ForegroundColor Red
    exit 1
}
. $modulePath

# 关掉日志噪音（模块里的兜底 Write-Log 是空实现，但显式再盖一层更保险）
function Write-Log([string]$msg) { }
function Note-TickError([string]$where, $err) { }

$fixtures = Join-Path $here 'fixtures'

# jsonl -> 记录数组（与模块内部同一套解析路径）
function Read-FixtureRecords([string]$path) {
    $out = New-Object System.Collections.ArrayList
    foreach ($line in (Get-Content -LiteralPath $path -Encoding UTF8)) {
        if (-not $line) { continue }
        $t = $line.Trim()
        if ($t.Length -lt 3) { continue }
        try { [void]$out.Add(($t | ConvertFrom-Json)) } catch { }
    }
    return $out
}

Write-Host ""
Write-Host "=== 1. 记录解析（纯函数） ===" -ForegroundColor Cyan

# --- running：最后一个 toolCall 还没有 toolResult ---
$recs = Read-FixtureRecords (Join-Path $fixtures 'pi-running.jsonl')
$st = Get-PiStateFromRecords $recs
Check 'running: 悬空工具调用数 = 1' $st.pendingCount 1
Check 'running: 用户轮次 = 1' $st.userTurns 1
Check 'running: 工具调用总数 = 3' $st.toolCalls 3
Check 'running: 工具结果总数 = 2' $st.toolResults 2
Check 'running: 尾部 stopReason = toolUse' $st.tailStop 'toolUse'
Check 'running: 最近工具 = bash' $st.lastTool 'bash'
Check 'running: 模型' $st.model 'cline-pass/deepseek-v4.1-flash'
CheckTrue 'running: 任务文本非空' ($st.lastPrompt.Length -gt 0)
Check 'running: 累计失败 = 0' $st.failed 0
CheckTrue 'running: 有意义的任务文本就是那句修登录页' ($st.lastPromptMeaningful -match '登录')

# --- finished：全部配平，尾部是普通 stop ---
$recs = Read-FixtureRecords (Join-Path $fixtures 'pi-finished.jsonl')
$st = Get-PiStateFromRecords $recs
Check 'finished: 无悬空工具调用' $st.pendingCount 0
Check 'finished: 尾部 stopReason = stop' $st.tailStop 'stop'
Check 'finished: 尾部角色 = assistant' $st.tailRole 'assistant'
Check 'finished: 工具调用 = 2' $st.toolCalls 2
Check 'finished: 工具结果 = 2' $st.toolResults 2
Check 'finished: 模型 = mimo-v2.6-pro' $st.model 'mimo-v2.6-pro'
CheckTrue 'finished: 读到 agent-summary 摘要（加分项）' ($null -ne $st.lastSummary -and $st.lastSummary.Length -gt 0)

# --- error：尾部是 error，且带 errorMessage ---
$recs = Read-FixtureRecords (Join-Path $fixtures 'pi-error.jsonl')
$st = Get-PiStateFromRecords $recs
Check 'error: 尾部 stopReason = error' $st.tailStop 'error'
Check 'error: 累计失败 = 2' $st.failed 2
CheckTrue 'error: 记录了 errorMessage' ($st.lastError.Length -gt 0)
CheckTrue 'error: lastErrorAt > 0' ($st.lastErrorAt -gt 0)

Write-Host ""
Write-Host "=== 2. 单会话判定 ===" -ForegroundColor Cyan

# 「用户只回一个字」的真实情况（本机实测有 "可以" / "+" 这类输入）：
# 气泡不该显示 "进行中：+"，应保留最近一条有信息量的任务描述。
$trivial = @(
    '{"type":"session","version":3,"id":"t1","timestamp":"2026-10-13T10:00:00.000Z","cwd":"E:\\demo\\trivial"}',
    '{"type":"message","id":"u1","parentId":null,"timestamp":"2026-10-13T10:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"把登录页的空指针修掉"}],"timestamp":1}}',
    '{"type":"message","id":"a1","parentId":"u1","timestamp":"2026-10-13T10:00:02.000Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"c1","name":"bash","arguments":{}}],"api":"x","provider":"p","model":"m","stopReason":"toolUse","timestamp":2}}',
    '{"type":"message","id":"t1r","parentId":"a1","timestamp":"2026-10-13T10:00:03.000Z","message":{"role":"toolResult","toolCallId":"c1","toolName":"bash","content":[{"type":"text","text":"ok"}],"isError":false,"timestamp":3}}',
    '{"type":"message","id":"u2","parentId":"t1r","timestamp":"2026-10-13T10:00:04.000Z","message":{"role":"user","content":[{"type":"text","text":"+"}],"timestamp":4}}',
    '{"type":"message","id":"a2","parentId":"u2","timestamp":"2026-10-13T10:00:05.000Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"c2","name":"read","arguments":{}}],"api":"x","provider":"p","model":"m","stopReason":"toolUse","timestamp":5}}'
) | ForEach-Object { $_ | ConvertFrom-Json }
$stT = Get-PiStateFromRecords $trivial
Check 'trivial: lastPrompt 是那个 "+"' $stT.lastPrompt '+'
Check 'trivial: 有意义的文本仍是修登录页' $stT.lastPromptMeaningful '把登录页的空指针修掉'

function New-VerdictState($parsed, [double]$ageSec, [string]$cwd = 'X:\demo') {
    return @{ id = 'x'; cwd = $cwd; version = 3; ageSec = $ageSec; parsed = $parsed }
}

# 悬空工具 + 很老的文件：仍然必须判「在跑」（这是配平信号的价值：不看 mtime）
$st = Get-PiStateFromRecords (Read-FixtureRecords (Join-Path $fixtures 'pi-running.jsonl'))
$v = Get-PiSessionVerdict (New-VerdictState $st 9999)
Check 'running(老文件但工具悬空): 仍在跑' $v.running $true
Check 'running(老文件但工具悬空): mode=working' $v.mode 'working'

# 刚结束的一轮
$st = Get-PiStateFromRecords (Read-FixtureRecords (Join-Path $fixtures 'pi-finished.jsonl'))
$v = Get-PiSessionVerdict (New-VerdictState $st 3)
Check 'finished(3s): 不在跑' $v.running $false
Check 'finished(3s): mode=celebrating' $v.mode 'celebrating'

# 已结束很久 → 待机
$v = Get-PiSessionVerdict (New-VerdictState $st 600)
Check 'finished(600s): mode=idle' $v.mode 'idle'
Check 'finished(600s): 不在跑' $v.running $false

# 错误尾部 + 新鲜：必须是 failed，**不能**是 working
$st = Get-PiStateFromRecords (Read-FixtureRecords (Join-Path $fixtures 'pi-error.jsonl'))
$v = Get-PiSessionVerdict (New-VerdictState $st 3)
Check 'error(3s): 不在跑' $v.running $false
Check 'error(3s): mode=failed' $v.mode 'failed'

# 错误尾部但已很久：不再报 failed（避免重启后翻旧账）
$v = Get-PiSessionVerdict (New-VerdictState $st 600)
Check 'error(600s): 不再 failed' ($v.mode -ne 'failed') $true

Write-Host ""
Write-Host "=== 3. 端到端（临时 sessions 目录） ===" -ForegroundColor Cyan

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('kun-pet-pi-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
# 通过模块自己的 setter 切换路径（与主脚本走同一条入口），
# 这样自测验证的就是真实运行时的那套作用域行为。
$oldInfo = Get-PiSourceInfo
$oldDone = Get-PiCompletionState

try {
    Set-PiSourcePaths $tmp ([string]$oldInfo.stateFile)
    Reset-PiCompletionState

    # 空目录：必须返回 $null，不抛异常
    $snap = Get-StateFromPiSessions
    Check '空目录 → 返回 $null' $(if ($null -eq $snap) { 'null' } else { 'snap' }) 'null'

    # --- 场景 A：一个「正在跑」的会话（悬空工具） ---
    $f = Join-Path $tmp 'a.jsonl'
    Copy-Item -LiteralPath (Join-Path $fixtures 'pi-running.jsonl') -Destination $f -Force
    # mtime 设成 5 秒前
    (Get-Item -LiteralPath $f).LastWriteTime = (Get-Date).AddSeconds(-5)
    $snap = Get-StateFromPiSessions
    CheckTrue 'A: 拿到快照' ($null -ne $snap)
    Check 'A: source=pi' $snap.source 'pi'
    Check 'A: mode=working' $snap.mode 'working'
    Check 'A: runningAgents=1' $snap.runningAgents 1
    Check 'A: 最近工具=bash' $snap.lastTool 'bash'
    Check 'A: 模型透出' $snap.piModel 'cline-pass/deepseek-v4.1-flash'
    CheckTrue 'A: waiting=false（纯文件尾随拿不到等待态）' ($snap.waiting -eq $false)

    # --- 场景 B：同一会话转为「已收尾」→ 应触发一次「刚结束」---
    Remove-Item -LiteralPath $f -Force
    $f = Join-Path $tmp 'a.jsonl'
    Copy-Item -LiteralPath (Join-Path $fixtures 'pi-finished.jsonl') -Destination $f -Force
    (Get-Item -LiteralPath $f).LastWriteTime = (Get-Date).AddSeconds(-4)
    $snap = Get-StateFromPiSessions
    # id 变了（夹具不同会话）→ 上一帧的 running 记录不会落到新 id 上，
    # 所以这里主要验证「新会话已收尾」被正确识别为完成/空闲，而不是卡在 working
    CheckTrue 'B: 不再显示在跑' ($snap.mode -ne 'working')
    Check 'B: runningAgents=0' $snap.runningAgents 0

    # --- 场景 C：让同一个会话 id 先跑后停，验证逐会话下降沿 ---
    Reset-PiCompletionState
    $f2 = Join-Path $tmp 'b.jsonl'
    Copy-Item -LiteralPath (Join-Path $fixtures 'pi-running.jsonl') -Destination $f2 -Force
    (Get-Item -LiteralPath $f2).LastWriteTime = (Get-Date).AddSeconds(-5)
    $snap1 = Get-StateFromPiSessions
    Check 'C1: 首帧在跑' $snap1.mode 'working'

    # 同一个会话（running 夹具里的 id）换成 finished 夹具内容会换 id；
    # 这里改成「把 running 夹具补上一个 toolResult」来模拟同一会话收尾。
    $lines = @(Get-Content -LiteralPath (Join-Path $fixtures 'pi-running.jsonl') -Encoding UTF8)
    $lines += '{"type":"message","id":"z1","parentId":"c908a211","timestamp":"2026-10-13T05:41:20.000Z","message":{"role":"toolResult","toolCallId":"call_00_ccc","toolName":"bash","content":[{"type":"text","text":"All tests passed"}],"isError":false,"durationMs":300,"timestamp":1791870080000}}'
    $lines += '{"type":"message","id":"z2","parentId":"z1","timestamp":"2026-10-13T05:41:22.000Z","message":{"role":"assistant","content":[{"type":"text","text":"修好了，测试全绿。"}],"api":"openai-completions","provider":"newapixiacan","model":"cline-pass/deepseek-v4.1-flash","usage":{"input":400,"output":30,"cacheRead":0,"cacheWrite":0,"reasoning":0,"totalTokens":430,"cost":{"input":0,"output":0,"cost":0}},"stopReason":"stop","timestamp":1791870082000,"rawStopReason":"stop"}}'
    Set-Content -LiteralPath $f2 -Value $lines -Encoding UTF8
    (Get-Item -LiteralPath $f2).LastWriteTime = (Get-Date).AddSeconds(-3)

    $snap2 = Get-StateFromPiSessions
    $doneState = Get-PiCompletionState
    CheckTrue 'C2: 收尾触发完成时间' ($doneState.at -gt 0)
    CheckTrue 'C2: 完成摘要非空' ($null -ne $doneState.summary)
    CheckTrue 'C2: completedAt 反映到快照' ($snap2.completedAt -gt 0)
    CheckTrue 'C2: 不再在跑' ($snap2.runningAgents -eq 0)
    CheckTrue 'C2: 摘要含工具调用次数' ([string]$snap2.lastSummary -match '工具调用')

    # --- 场景 D：坏数据必须静默降级 ---
    Reset-PiCompletionState
    Remove-Item -LiteralPath $f2 -Force -ErrorAction SilentlyContinue
    $bad = Join-Path $tmp 'bad.jsonl'
    $good = '{"type":"session","version":3,"id":"01a10000-0000-7000-8000-0000000000ff","timestamp":"2026-10-13T08:00:00.000Z","cwd":"E:\\demo\\bad"}'
    Set-Content -LiteralPath $bad -Value @(
        $good,
        '{"type":"message","id":"half","parentId":null,"timestamp":"2026-10-13T08:00:01.000Z","message":{"role":"assistant","content":[{"type":"te',  # 半行：
        'this is not json at all',
        '{"broken": '
    ) -Encoding UTF8
    (Get-Item -LiteralPath $bad).LastWriteTime = (Get-Date).AddSeconds(-2)

    $threw = $false
    $snapBad = $null
    try { $snapBad = Get-StateFromPiSessions } catch { $threw = $true }
    CheckTrue 'D: 坏数据不抛异常' (-not $threw)
    CheckTrue 'D: 仍能返回一个快照' ($null -ne $snapBad)

    # 只有空文件
    Remove-Item -LiteralPath $bad -Force
    $empty = Join-Path $tmp 'empty.jsonl'
    New-Item -ItemType File -Path $empty -Force | Out-Null
    $threw = $false
    try { $null = Get-StateFromPiSessions } catch { $threw = $true }
    CheckTrue 'D: 空文件不抛异常' (-not $threw)

    # --- 场景 E：文件比尾部窗口还大，确认「读头取会话头 + 读尾判状态」两条路都对 ---
    # 刻意让文件超过 piTailBytes（256KB）：这样尾部窗口一定会截掉文件开头，
    # ① 首行（session 头）落在窗口之外 —— 只有 Read-PiHeadText 仍能拿到 cwd/id；
    # ② 窗口首行是半行 —— 必须被丢弃，否则首条 JSON 解析失败。
    # 只要 mode 能判成 working，就说明这两件事都做对了。
    Reset-PiCompletionState
    Remove-Item -LiteralPath $empty -Force -ErrorAction SilentlyContinue
    $big = Join-Path $tmp 'big.jsonl'
    $blob = ('x' * 400000)   # 单行 400KB > 256KB 窗口
    $bigLines = @(
        '{"type":"session","version":3,"id":"01a10000-0000-7000-8000-0000000000ee","timestamp":"2026-10-13T09:00:00.000Z","cwd":"E:\\demo\\big"}',
        '{"type":"message","id":"bu","parentId":null,"timestamp":"2026-10-13T09:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"读一个大文件"}],"timestamp":1}}',
        ('{"type":"message","id":"ba","parentId":"bu","timestamp":"2026-10-13T09:00:02.000Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_big","name":"read","arguments":{"path":"huge.log"}}],"api":"openai-completions","provider":"p","model":"m","stopReason":"toolUse","timestamp":2}}'),
        ('{"type":"message","id":"bt","parentId":"ba","timestamp":"2026-10-13T09:00:03.000Z","message":{"role":"toolResult","toolCallId":"call_big","toolName":"read","content":[{"type":"text","text":"' + $blob + '"}],"isError":false,"timestamp":3}}'),
        ('{"type":"message","id":"ba2","parentId":"bt","timestamp":"2026-10-13T09:00:04.000Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"call_big2","name":"bash","arguments":{"command":"wc -l huge.log"}}],"api":"openai-completions","provider":"p","model":"m","stopReason":"toolUse","timestamp":4}}')
    )
    Set-Content -LiteralPath $big -Value $bigLines -Encoding UTF8
    (Get-Item -LiteralPath $big).LastWriteTime = (Get-Date).AddSeconds(-2)
    $snapBig = Get-StateFromPiSessions
    CheckTrue 'E: 大文件仍能判定在跑' ($null -ne $snapBig -and $snapBig.mode -eq 'working')
    Check 'E: 最近工具=bash' $snapBig.lastTool 'bash'

    # 关键回归：会话头在尾部窗口之外（文件 400KB > 256KB 窗口），
    # 只有「单独读文件开头」才拿得到 cwd / id。这里读成 <null> 就说明
    # 读头又退回成读尾了（曾经就是这个 bug：所有 >4KB 的会话都被当成
    # 「不是 pi 会话」而跳过，pi 支持静默失效）。
    $hdr = Get-PiHeader $big
    CheckTrue 'E: Get-PiHeader 能拿到记录' ($null -ne $hdr)
    Check 'E: Get-PiHeader 读到 cwd' $hdr.cwd 'E:\demo\big'
    Check 'E: Get-PiHeader 读到 id' $hdr.id '01a10000-0000-7000-8000-0000000000ee'

    # --- 场景 F：同一目录开多个 pi 窗口 → **每个都要算一个任务** ---
    #
    # 这是回归测试：早先实现按 cwd 去重（为防子代理），结果同一项目目录下
    # 多开 pi 只显示一个任务。正确做法是按「目录层级」排除子代理，而不是按 cwd 合并。
    # 注意：这里必须换到**干净的独立目录**。前面场景在 $tmp 根下还留着 a.jsonl
    # （场景 A 建的，一直在跑），直接复用 $tmp 会把它一起数进去 → 断言 3 却得到 4。
    Reset-PiCompletionState
    $multiRoot = Join-Path $tmp 'multiroot'
    $multi = Join-Path $multiRoot 'proj'
    New-Item -ItemType Directory -Force -Path $multi | Out-Null
    Set-PiSourcePaths $multiRoot ([string]$oldInfo.stateFile)
    # 三个会话，**同一个 cwd**，都在跑
    for ($i = 1; $i -le 3; $i++) {
        $src = Get-Content -LiteralPath (Join-Path $fixtures 'pi-running.jsonl') -Encoding UTF8
        $src[0] = '{"type":"session","version":3,"id":"01a10000-0000-7000-8000-00000000000' + $i + '","timestamp":"2026-10-13T05:41:09.439Z","cwd":"E:\\demo\\same-project"}'
        $p = Join-Path $multi ("w$i.jsonl")
        Set-Content -LiteralPath $p -Value $src -Encoding UTF8
        (Get-Item -LiteralPath $p).LastWriteTime = (Get-Date).AddSeconds(-5)
    }
    $snapMulti = Get-StateFromPiSessions
    CheckTrue 'F: 同 cwd 三个窗口 → 拿到快照' ($null -ne $snapMulti)
    Check 'F: 三个窗口都被算作任务' $snapMulti.runningAgents 3
    Check 'F: 气泡说明有 3 个任务' $snapMulti.message '3 个 pi 任务进行中'
    Check 'F: 逐条列出 3 行' @($snapMulti.progressLines).Count 3
    # 同目录多窗口时每行要带项目名，否则三行看起来一模一样
    CheckTrue 'F: 三行都带项目名以便区分' (@($snapMulti.progressLines | Where-Object { $_ -match 'same-project' }).Count -eq 3)

    # --- 场景 G：子代理产物（更深层级）必须被排除 ---
    #
    # pi-subagents 的子会话写在 <会话目录>/subagent-artifacts/…（深一层），
    # 或 <项目>/.pi/subagents/artifacts/（不在 sessions 根下）。
    # 主会话段数恒为 2，所以按段数过滤能精确排除，且不影响多窗口。
    Reset-PiCompletionState
    # 本脚本里 Write-Log 是空实现（不收集日志），所以这里只断言「结果正确」；
    # 「日志里记录了跳过」的断言放在 test-pi-integration.ps1（那边收集日志）。
    $artDir = Join-Path $multi 'subagent-artifacts'
    New-Item -ItemType Directory -Force -Path $artDir | Out-Null
    Copy-Item -LiteralPath (Join-Path $fixtures 'pi-running.jsonl') -Destination (Join-Path $artDir 'run_worker.jsonl') -Force
    (Get-Item -LiteralPath (Join-Path $artDir 'run_worker.jsonl')).LastWriteTime = (Get-Date).AddSeconds(-3)

    $snapArt = Get-StateFromPiSessions
    # 仍是 3 个（那 3 个主会话），子代理产物没被算进来
    Check 'G: 子代理产物不计入任务数' $snapArt.runningAgents 3
    # 恢复到 F 之前的路径，后面的清理与断言不受影响
    Set-PiSourcePaths $tmp ([string]$oldInfo.stateFile)
}
finally {
    Set-PiSourcePaths ([string]$oldInfo.sessionsRoot) ([string]$oldInfo.stateFile)
    Reset-PiCompletionState
    Restore-PiCompletionState ([int64]$oldDone.at) $oldDone.summary
    try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

Write-Host ""
Write-Host "=== 4. 多窗口 / 子代理排除（纯函数级）===" -ForegroundColor Cyan
# 直接验证「段数」判据本身（与模块内 $depth 的算法逐字一致）：
#   主会话 = 根/转义cwd/文件                  → 2 段 → 不跳过
#   子代理 = 根/转义cwd/subagent-artifacts/…  → ≥3 段 → 跳过
#
# 用 [IO.Path]::DirectorySeparatorChar 拼路径，保证 Windows(\) 与 Linux(/) 都能跑
# —— CI 就在 ubuntu-latest 上（pwsh 7 / Linux）。早先这里硬编码 'E:\...'，
# 在 Linux 上会把整条路径当成一个段，断言全错。
$sep = [IO.Path]::DirectorySeparatorChar
$rootPrefix = 'PIROOT' + $sep + 'agent' + $sep + 'sessions' + $sep
$sessionsRootLen = $rootPrefix.Length
foreach ($case in @(
    @{ rel = 'proj' + $sep + 'a.jsonl';                                   want = 2 },
    @{ rel = 'proj' + $sep + 'subagent-artifacts' + $sep + 'run-0' + $sep + 'session.jsonl'; want = 4 }
)) {
    $full = $rootPrefix + $case.rel
    $rel = $full.Substring($sessionsRootLen).TrimStart('\', '/')
    $depth = @($rel -split '[\\/]').Count
    Check ("段数判据: " + $rel) $depth $case.want
    CheckTrue ("  该文件应" + $(if ($case.want -gt 2) { '被跳过' } else { '被保留' })) (($depth -gt 2) -eq ($case.want -gt 2))
}

Write-Host ""
if ($script:fail -eq 0) {
    Write-Host ("全部通过：{0} 项" -f $script:pass) -ForegroundColor Green
    exit 0
} else {
    Write-Host ("失败 {0} 项 / 通过 {1} 项" -f $script:fail, $script:pass) -ForegroundColor Red
    exit 1
}
