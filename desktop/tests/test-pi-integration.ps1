# 端到端集成测试：验证「主脚本 dot-source 模块 + 多源仲裁」这条真实路径。
#
# 为什么需要它：单元测试只验模块自己；而真正容易出错的是**接入**部分 ——
#   ① 主脚本用 . 加载模块后，函数与 $script: 变量是否真的可见/可用；
#   ② DSH 闲着而 pi 在跑时，仲裁是否真的把 pi 的状态采纳（而不是被 DSH 顶掉）；
#   ③ pi 与 DSH 同时在跑时，是否真的并列显示。
#
# 做法：不启动 WPF 窗口，而是把主脚本里**那段仲裁逻辑**用真实函数重放一遍。
# 数据用临时目录里的夹具会话，绝不碰 ~/.pi 与 ~/.dsh 的真实数据。
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:fail = 0
$script:pass = 0

function Check([string]$name, $actual, $expected) {
    $a = if ($null -eq $actual) { '<null>' } else { [string]$actual }
    $e = if ($null -eq $expected) { '<null>' } else { [string]$expected }
    if ($a -eq $e) { $script:pass++; Write-Host ("  [ok]   " + $name) -ForegroundColor Green }
    else { $script:fail++; Write-Host ("  [FAIL] {0}  期望={1} 实际={2}" -f $name, $e, $a) -ForegroundColor Red }
}
function CheckTrue([string]$name, $cond) { Check $name $(if ($cond) { 'True' } else { 'False' }) 'True' }

$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
$desktop = Split-Path -Parent $here
$modulePath = Join-Path $desktop 'kun-pet-pi-source.ps1'
$fixtures = Join-Path $here 'fixtures'

# 模拟主脚本提供的依赖（真实运行时由 kun-pet-desktop.ps1 定义）
$script:epochRef = [System.DateTime]::new(1970, 1, 1, 0, 0, 0, [System.DateTimeKind]::Utc)
$script:logLines = New-Object System.Collections.ArrayList
function Write-Log([string]$msg) { [void]$script:logLines.Add($msg) }
function Limit-Text([string]$text, [int]$max) {
    if (-not $text) { return '' }
    $t = ($text -replace '\s+', ' ').Trim()
    if ($t.Length -le $max) { return $t }
    return $t.Substring(0, $max) + '…'
}
function Note-TickError([string]$where, $err) { [void]$script:logLines.Add("ERR $where") }
function Get-EpochMs { return [int64]((Get-Date).ToUniversalTime() - $script:epochRef).TotalMilliseconds }

Write-Host ""
Write-Host "=== 1. dot-source 加载（模拟主脚本的接入方式）===" -ForegroundColor Cyan

# 关键：用 . 加载（和主脚本完全一样），验证函数在**调用方作用域**可见
. $modulePath
CheckTrue 'dot-source 后 Set-PiSourcePaths 可见' ([bool](Get-Command -Name 'Set-PiSourcePaths' -CommandType Function -ErrorAction SilentlyContinue))
CheckTrue 'dot-source 后 Get-StateFromPi 可见'   ([bool](Get-Command -Name 'Get-StateFromPi'   -CommandType Function -ErrorAction SilentlyContinue))
CheckTrue 'dot-source 后 Get-StateFromPiSessions 可见' ([bool](Get-Command -Name 'Get-StateFromPiSessions' -CommandType Function -ErrorAction SilentlyContinue))

$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('kun-pet-pi-e2e-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$oldInfo = Get-PiSourceInfo
$oldDone = Get-PiCompletionState

try {
    Set-PiSourcePaths $tmp (Join-Path $tmp 'no-such-state.json')
    Reset-PiCompletionState
    Set-PiEnabled $true

    # ---- 2. DSH 缺席、pi 在跑 → 必须采纳 pi ----
    Write-Host ""
    Write-Host "=== 2. 只有 pi 在跑（DSH 无数据）===" -ForegroundColor Cyan
    $f = Join-Path $tmp 'a.jsonl'
    Copy-Item -LiteralPath (Join-Path $fixtures 'pi-running.jsonl') -Destination $f -Force
    (Get-Item -LiteralPath $f).LastWriteTime = (Get-Date).AddSeconds(-4)

    $piSnap = Get-StateFromPi
    CheckTrue 'pi 源给出快照' ($null -ne $piSnap)
    Check 'mode=working' $piSnap.mode 'working'

    # 重放主脚本的仲裁：$snap(DSH)=$null，$piSnap 有值
    $snap = $null
    $agentSource = 'dsh'
    if ($null -eq $snap -and $null -ne $piSnap) { $snap = $piSnap; $agentSource = 'pi' }
    CheckTrue '仲裁后采纳了 pi' ($null -ne $snap)
    Check '仲裁后 agentSource=pi' $agentSource 'pi'
    Check '仲裁后 source=pi' $snap.source 'pi'
    CheckTrue '气泡显示 pi 的任务（含"登录"）' ([string]$snap.progressLines[0] -match '登录')

    # ---- 3. pi 与 DSH 同时「在跑」→ 必须并列显示 ----
    Write-Host ""
    Write-Host "=== 3. DSH 与 pi 同时在跑（并列显示）===" -ForegroundColor Cyan
    $dshSnap = @{
        mode = 'working'; source = 'harness'; message = '进行中：改支付模块'
        progressLines = @('正在处理：改支付模块 · 1 轮 / 2 步')
        waiting = $false; runningAgents = 1; toolCount = 2; lastTool = 'edit'
        completedAt = 0; lastSummary = $null
    }
    $snap = $dshSnap
    $agentSource = 'dsh'
    # —— 与 kun-pet-desktop.ps1 里的分支一一对应 ——
    if ($null -eq $snap -and $null -ne $piSnap) {
        $snap = $piSnap; $agentSource = 'pi'
    } elseif ($null -ne $snap -and $null -ne $piSnap) {
        $dshWaiting = [bool]$snap.waiting
        $piWaiting  = [bool]$piSnap.waiting
        $dshRunning = ($snap.mode -eq 'working' -or $snap.mode -eq 'review')
        $piRunning  = ($piSnap.mode -eq 'working' -or $piSnap.mode -eq 'review')
        if ($dshWaiting -or $piWaiting) {
            if ($piWaiting -and -not $dshWaiting) { $snap = $piSnap; $agentSource = 'pi' } else { $agentSource = 'dsh+pi' }
        } elseif ($piSnap.mode -eq 'failed' -and $snap.mode -ne 'failed') {
            $snap = $piSnap; $agentSource = 'pi'
        } elseif ($dshRunning -and $piRunning) {
            $agentSource = 'dsh+pi'
            $merged = @()
            foreach ($l in @($snap.progressLines)) { if ($l) { $merged += ('[DSH] ' + ([string]$l -replace '^·\s*', '')) } }
            foreach ($l in @($piSnap.progressLines)) { if ($l) { $merged += ('[pi] ' + ([string]$l -replace '^·\s*', '')) } }
            $snap.progressLines = @($merged)
            $dshAgents = [int]$snap.runningAgents
            if ($dshAgents -le 0) { $dshAgents = 1 }
            $snap.message = ('{0} 个任务进行中（DSH + pi）' -f ($dshAgents + [int]$piSnap.runningAgents))
        } elseif ($piRunning -and -not $dshRunning) {
            $snap = $piSnap; $agentSource = 'pi'
        } elseif ($dshRunning) { $agentSource = 'dsh' }
    }
    Check '并列时 agentSource=dsh+pi' $agentSource 'dsh+pi'
    Check '并列时有 2 行进展' @($snap.progressLines).Count 2
    CheckTrue '第 1 行带 [DSH] 前缀' ($snap.progressLines[0] -match '^\[DSH\]')
    CheckTrue '第 2 行带 [pi] 前缀'  ($snap.progressLines[1] -match '^\[pi\]')
    CheckTrue 'message 说明两边都在跑' ($snap.message -match 'DSH \+ pi')

    # ---- 4. pi 在等（扩展通道）优先于 DSH 在跑 ----
    Write-Host ""
    Write-Host "=== 4. pi 在等你确认（扩展通道）===" -ForegroundColor Cyan
    $stateFile = Join-Path $tmp 'kun-pet-state.json'
    $waitingJson = @{
        updatedAt = (Get-EpochMs); pid = 1234; mode = 'waiting'
        sessionId = 's1'; waiting = $true; waitingKind = 'plan-review'
        waitingTitle = '确认要删除这 3 个文件吗？'; waitingSince = (Get-EpochMs) - 12000
        waitingCount = 1; waitingSeconds = 12; runningAgents = 0
        toolCount = 5; lastTool = 'bash'; turns = 1; steps = 5
        completedAt = 0; failureCount = 0; provider = 'newapixiacan'
        model = 'cline-pass/deepseek-v4.1-flash'
    } | ConvertTo-Json -Depth 4
    [IO.File]::WriteAllText($stateFile, $waitingJson, (New-Object Text.UTF8Encoding($false)))
    Set-PiSourcePaths $tmp $stateFile

    $piWait = Get-StateFromPi
    CheckTrue '扩展通道给出快照' ($null -ne $piWait)
    Check '扩展通道 waiting=true' $piWait.waiting $true
    Check '扩展通道 waitingKind=plan-review' $piWait.waitingKind 'plan-review'
    Check '扩展通道问题标题透出' $piWait.questionText '确认要删除这 3 个文件吗？'
    Check '扩展通道 approvalChannel=pi（不显示 ✓/✗）' $piWait.approvalChannel 'pi'

    # DSH 在跑 + pi 在等 → 必须切成 pi 的等待态
    $snap = $dshSnap
    $agentSource = 'dsh'
    $dshWaiting = [bool]$snap.waiting
    $piWaiting  = [bool]$piWait.waiting
    if ($dshWaiting -or $piWaiting) {
        if ($piWaiting -and -not $dshWaiting) { $snap = $piWait; $agentSource = 'pi' } else { $agentSource = 'dsh+pi' }
    }
    Check 'pi 在等时采纳 pi' $agentSource 'pi'
    Check '切成 waiting' $snap.mode 'waiting'
    Check 'waitingKind 透传' $snap.waitingKind 'plan-review'

    # ---- 5. 过期快照必须被忽略（pi 退出后不能残留「正在等你」）----
    Write-Host ""
    Write-Host "=== 5. 过期扩展快照必须被忽略 ===" -ForegroundColor Cyan
    $stale = @{
        updatedAt = (Get-EpochMs) - 600000   # 10 分钟前
        mode = 'waiting'; waiting = $true; waitingKind = 'question'
        waitingTitle = '陈旧的问题'; waitingCount = 1; runningAgents = 0
    } | ConvertTo-Json -Depth 4
    [IO.File]::WriteAllText($stateFile, $stale, (New-Object Text.UTF8Encoding($false)))
    $piStale = Get-StateFromPiExtension
    Check '过期快照 → $null（不采信）' $(if ($null -eq $piStale) { 'null' } else { 'snap' }) 'null'

    # ---- 6. 多窗口：同一目录多个 pi 必须都是独立任务（回归）----
    Write-Host ""
    Write-Host "=== 6. 同一目录多开 pi（回归：曾经只认得到一个）===" -ForegroundColor Cyan
    $multiRoot = Join-Path $tmp 'multiroot'
    $multiDir = Join-Path $multiRoot 'proj'
    New-Item -ItemType Directory -Force -Path $multiDir | Out-Null
    Set-PiSourcePaths $multiRoot (Join-Path $tmp 'no-such-state.json')
    Reset-PiCompletionState
    for ($i = 1; $i -le 4; $i++) {
        $src = Get-Content -LiteralPath (Join-Path $fixtures 'pi-running.jsonl') -Encoding UTF8
        $src[0] = '{"type":"session","version":3,"id":"01a1e2e2-0000-7000-8000-00000000000' + $i + '","timestamp":"2026-10-13T05:41:09.439Z","cwd":"E:\\demo\\shared"}'
        $p = Join-Path $multiDir ("w$i.jsonl")
        Set-Content -LiteralPath $p -Value $src -Encoding UTF8
        (Get-Item -LiteralPath $p).LastWriteTime = (Get-Date).AddSeconds(-5)
    }
    $snapW = Get-StateFromPi
    CheckTrue '多窗口：拿到快照' ($null -ne $snapW)
    Check '多窗口：4 个窗口 = 4 个任务' $snapW.runningAgents 4
    Check '多窗口：气泡列出 4 行' @($snapW.progressLines).Count 4
    CheckTrue '多窗口：每行带项目名区分' (@($snapW.progressLines | Where-Object { $_ -match 'shared' }).Count -eq 4)

    # ---- 7. 子代理产物必须排除，且日志留痕 ----
    Write-Host ""
    Write-Host "=== 7. 子代理产物按目录层级排除 ===" -ForegroundColor Cyan
    Reset-PiCompletionState
    $script:logLines.Clear()
    $artDir = Join-Path $multiDir 'subagent-artifacts'
    New-Item -ItemType Directory -Force -Path $artDir | Out-Null
    Copy-Item -LiteralPath (Join-Path $fixtures 'pi-running.jsonl') -Destination (Join-Path $artDir 'run_worker.jsonl') -Force
    (Get-Item -LiteralPath (Join-Path $artDir 'run_worker.jsonl')).LastWriteTime = (Get-Date).AddSeconds(-3)
    $snapSub = Get-StateFromPi
    Check '子代理产物不计入任务数（仍为 4）' $snapSub.runningAgents 4
    CheckTrue '日志记录了跳过的嵌套会话' ((@($script:logLines) -join "`n") -match 'subagent artifact|skipped nested')
    Set-PiSourcePaths $tmp (Join-Path $tmp 'no-such-state.json')

    # ---- 8. 关掉开关后必须彻底不工作 ----
    Write-Host ""
    Write-Host "=== 8. 关掉 pi 开关 ===" -ForegroundColor Cyan
    Set-PiEnabled $false
    Check '关掉后 Get-StateFromPi = $null' $(if ($null -eq (Get-StateFromPi)) { 'null' } else { 'snap' }) 'null'
    Set-PiEnabled $true
    CheckTrue '重新打开后又能拿到' ($null -ne (Get-StateFromPi))
}
finally {
    Set-PiSourcePaths ([string]$oldInfo.sessionsRoot) ([string]$oldInfo.stateFile)
    Set-PiEnabled $true
    Reset-PiCompletionState
    Restore-PiCompletionState ([int64]$oldDone.at) $oldDone.summary
    try { Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue } catch { }
}

Write-Host ""
if ($script:fail -eq 0) { Write-Host ("全部通过：{0} 项" -f $script:pass) -ForegroundColor Green; exit 0 }
else { Write-Host ("失败 {0} 项 / 通过 {1} 项" -f $script:fail, $script:pass) -ForegroundColor Red; exit 1 }
