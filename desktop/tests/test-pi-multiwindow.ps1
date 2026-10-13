# 复现用户的真实场景：在**同一个目录**开多个 pi 窗口。
# 做法：往一个临时 sessions 根写多个会话文件（不同 id、同一 cwd），
# 看适配器识别出几个任务。完全只读，不碰真实 pi 数据。
[CmdletBinding()]
param([int]$Windows = 3)

$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
$desktop = Split-Path -Parent $here
. (Join-Path $desktop 'kun-pet-pi-source.ps1')

$tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ('kun-pet-multiwin-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$projDir = Join-Path $tmpRoot '--E--demo--'
New-Item -ItemType Directory -Force -Path $projDir | Out-Null

function New-FakeSession([string]$id, [string]$cwd, [string]$prompt, [double]$ageSec) {
    $lines = @(
        ('{"type":"session","version":3,"id":"' + $id + '","timestamp":"2026-10-13T10:00:00.000Z","cwd":"' + ($cwd -replace '\\','\\') + '"}'),
        ('{"type":"message","id":"u1","parentId":null,"timestamp":"2026-10-13T10:00:01.000Z","message":{"role":"user","content":[{"type":"text","text":"' + $prompt + '"}],"timestamp":1}}'),
        ('{"type":"message","id":"a1","parentId":"u1","timestamp":"2026-10-13T10:00:02.000Z","message":{"role":"assistant","content":[{"type":"toolCall","id":"c1","name":"bash","arguments":{}}],"api":"x","provider":"p","model":"m","stopReason":"toolUse","timestamp":2}}')
    )
    # 文件名必须**互相不同**：早先这里用 id 的前 8 位当文件名，而几个夹具 id 前缀
    # 相同（都是 01a1aaaa），于是后写的覆盖先写的 → 目录里只剩 1 个会话，
    # 测试却报「只识别到 1 个任务」，看起来像模块的去重 bug（排查时误导过我一次）。
    # 真实 pi 的文件名是「ISO 时间戳_UUID」，天然唯一，这里照同样的形状生成。
    $p = Join-Path $projDir ('2026-10-13T10-00-0' + $i + '-000Z_' + $id + '.jsonl')
    Set-Content -LiteralPath $p -Value $lines -Encoding UTF8
    (Get-Item -LiteralPath $p).LastWriteTime = (Get-Date).AddSeconds(-$ageSec)
    return $p
}

Write-Output ("临时 sessions 根: " + $tmpRoot)
Set-PiSourcePaths $tmpRoot (Join-Path $tmpRoot 'none.json')
Reset-PiCompletionState
$script:logLines = New-Object System.Collections.ArrayList

# 同一 cwd，多个窗口，各自不同的任务
for ($i = 1; $i -le $Windows; $i++) {
    $suffix = $i.ToString('x2').PadLeft(8, '0')
    [void](New-FakeSession "01a1aaaa-0000-7000-8000-$suffix" 'E:\demo' ("窗口 $i 的任务") 5)
}

$snap = Get-StateFromPiSessions
Write-Output ""
Write-Output ("识别到的任务数 : " + $snap.runningAgents)
Write-Output ("气泡主行       : " + $snap.message)
Write-Output ("逐条进展       :")
foreach ($l in @($snap.progressLines)) { Write-Output ("   " + $l) }
Write-Output ""
Write-Output ("期望任务数     : " + $Windows)

# 明确给出退出码，供 CI 判定（不能只打印结果，否则 CI 会「静默通过」）
$ok = ($null -ne $snap -and [int]$snap.runningAgents -eq $Windows)
if ($ok) {
    Write-Output '结果           : 通过 —— 每个窗口都是独立任务'
} else {
    Write-Output ('结果           : 不符 —— 识别到 {0} 个，期望 {1} 个（检查是否又按 cwd 合并了）' -f
                  $(if ($null -ne $snap) { [int]$snap.runningAgents } else { 'null' }), $Windows)
}

Remove-Item -LiteralPath $tmpRoot -Recurse -Force -ErrorAction SilentlyContinue
if ($ok) { exit 0 } else { exit 1 }
