# 用**真实**的 pi 会话数据验证适配器（只读，不写任何 pi 目录）。
# 目的：夹具是自己造的，只有真数据才能证明「配平判定」「模型/轮次提取」在
# 真实的 ~/.pi/agent/sessions 上成立。
$modulePath = Join-Path (Split-Path -Parent $PSScriptRoot) 'kun-pet-pi-source.ps1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    Write-Host ("找不到模块: " + $modulePath) -ForegroundColor Red
    exit 1
}
. $modulePath

$root = Join-Path $env:USERPROFILE '.pi\agent\sessions'
Write-Output ("pi sessions root : " + $root)
Write-Output ("exists           : " + (Test-Path -LiteralPath $root))

Set-PiSourcePaths $root (Join-Path $env:USERPROFILE '.pi\agent\kun-pet-state.json')
Reset-PiCompletionState

$all = @(Get-ChildItem -LiteralPath $root -Recurse -Filter *.jsonl -File -ErrorAction SilentlyContinue |
         Sort-Object LastWriteTime -Descending)
Write-Output ("session files    : " + $all.Count)

Write-Output ""
Write-Output "--- 逐会话解析结果（最近 12 个）---"
$fmt = "{0,-7} {1,-9} {2,-6} {3,-28} {4}"
Write-Output ($fmt -f 'ageSec', 'pending', 'turns', 'model', 'verdict')
$i = 0
foreach ($f in $all) {
    if ($i -ge 12) { break }
    $i++
    $st = Get-PiFileState $f
    if ($null -eq $st) {
        Write-Output ($fmt -f [int]((Get-Date) - $f.LastWriteTime).TotalSeconds, '-', '-', '(未解析: 非 pi 会话/首行缺失)', '-')
        continue
    }
    $v = Get-PiSessionVerdict $st
    Write-Output ($fmt -f `
        ([int]$st.ageSec), `
        ([int]$st.parsed.pendingCount), `
        ([int]$st.parsed.userTurns), `
        ([string]$st.parsed.model), `
        ("{0} ({1})" -f $v.mode, $v.reason))
}

Write-Output ""
Write-Output "--- 聚合快照（真实数据）---"
$snap = Get-StateFromPiSessions
if ($null -eq $snap) {
    Write-Output "返回 `$null（当前没有 15 分钟内活跃的 pi 会话 —— 这是正常且安全的降级）"
} else {
    foreach ($k in @('mode','source','message','runningAgents','toolCount','lastTool','piModel','piProvider','piTurns','piSteps','completedAt')) {
        Write-Output ("  {0,-15} = {1}" -f $k, $snap[$k])
    }
    Write-Output ("  progressLines   = " + (@($snap.progressLines) -join ' | '))
}

Write-Output ""
Write-Output "--- 头部读取（真实文件，验证「读头≠读尾」）---"
foreach ($f in ($all | Select-Object -First 3)) {
    $hdr = Get-PiHeader $f.FullName
    $len = (Get-Item -LiteralPath $f.FullName).Length
    Write-Output ("  [{0,10} B] cwd={1}" -f $len, $hdr.cwd)
}
