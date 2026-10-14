# 随机移动（到处跑）自测：只测纯函数（选点 / 步进 / 夹取）。
# 不需要起桌宠、不需要 WPF —— 那部分（Update-Wander）在桌宠里，靠运行时验证。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\desktop\tests\test-wander.ps1
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
$modulePath = Join-Path (Split-Path -Parent $here) 'kun-pet-wander.ps1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    Write-Host ("找不到模块: " + $modulePath) -ForegroundColor Red
    exit 1
}
. $modulePath

# 一块标准工作区（1920x1080，任务栏在下方 → 工作区高 1040）
$wa = @{ Left = 0.0; Top = 0.0; Right = 1858.0; Bottom = 1040.0 }
$winW = 272.0
$winH = 145.0

Write-Host ""
Write-Host "=== 1. 目标点必须落在工作区内 ===" -ForegroundColor Cyan
$outCount = 0
for ($i = 0; $i -lt 300; $i++) {
    $t = Get-WanderTarget $wa $winW $winH 100.0 100.0 140
    $inX = ($t.x -ge $wa.Left) -and (($t.x + $winW) -le $wa.Right)
    $inY = ($t.y -ge $wa.Top) -and (($t.y + $winH) -le $wa.Bottom)
    if (-not ($inX -and $inY)) { $outCount++ }
}
Check '300 次随机选点全部落在工作区内（越界次数）' $outCount 0

Write-Host ""
Write-Host "=== 2. 会挑到「离当前位置够远」的点（真的会走动）===" -ForegroundColor Cyan
$farCount = 0
for ($i = 0; $i -lt 200; $i++) {
    $t = Get-WanderTarget $wa $winW $winH 900.0 500.0 140
    $dx = $t.x - 900.0; $dy = $t.y - 500.0
    if ([math]::Sqrt($dx * $dx + $dy * $dy) -ge 140) { $farCount++ }
}
Check '200 次都满足最小位移 140px' $farCount 200

Write-Host ""
Write-Host "=== 3. 极端情况：窗口比工作区还大 → 不能算出负数/越界 ===" -ForegroundColor Cyan
$tiny = @{ Left = 0.0; Top = 0.0; Right = 100.0; Bottom = 80.0 }
$t = Get-WanderTarget $tiny 400.0 300.0 0.0 0.0 140
Check '  x 夹到左边界 0' $t.x 0
Check '  y 夹到上边界 0' $t.y 0

Write-Host ""
Write-Host "=== 4. 步进：朝目标走且不会冲过头 ===" -ForegroundColor Cyan
$s = Get-WanderStep 0.0 0.0 100.0 0.0 3.0
Check '  一步走 3px' ([math]::Round($s.x, 4)) 3
Check '  还没到' $s.arrived $false
Check '  朝右 → running-right' $s.dir 'running-right'

$s = Get-WanderStep 0.0 0.0 1.0 0.0 3.0
Check '  剩余距离小于步长 → 直接落在目标上（不冲过头）' $s.x 1
Check '  标记到达' $s.arrived $true

$s = Get-WanderStep 10.0 10.0 0.0 10.0 3.0
Check '  朝左 → running-left' $s.dir 'running-left'

# 斜向速度一致性：走 (3,4) 归一化后距离仍是 3（否则对角线会快）
$s = Get-WanderStep 0.0 0.0 300.0 400.0 5.0
$moved = [math]::Sqrt($s.x * $s.x + $s.y * $s.y)
CheckTrue '  斜向每步位移也正好是步长（速度一致，不会斜着更快）' ([math]::Abs($moved - 5.0) -lt 0.0001)

$s = Get-WanderStep 5.0 5.0 5.0 5.0 3.0
Check '  已在目标上 → 视为到达' $s.arrived $true

Write-Host ""
Write-Host "=== 5. 夹取：把点拉回「窗口能完整放下」的范围 ===" -ForegroundColor Cyan
$c = Get-WanderClamped $wa $winW $winH -500.0 -500.0
CheckTrue '  左上越界 → 拉回 (0,0)' ($c.x -eq 0 -and $c.y -eq 0)
$c = Get-WanderClamped $wa $winW $winH 99999.0 99999.0
Check '  右下越界 → 右边界 = Right - winW' $c.x (1858 - 272)
Check '  下边界 = Bottom - winH' $c.y (1040 - 145)
$c = Get-WanderClamped $wa $winW $winH 500.0 400.0
Check '  界内点保持不变 x' $c.x 500
Check '  界内点保持不变 y' $c.y 400

Write-Host ""
Write-Host "=== 6. Get-RandDouble 的区间与类型 ===" -ForegroundColor Cyan
$minSeen = [double]::MaxValue
$maxSeen = [double]::MinValue
for ($i = 0; $i -lt 500; $i++) {
    $v = Get-RandDouble 10.0 20.0
    if ($v -lt $minSeen) { $minSeen = $v }
    if ($v -gt $maxSeen) { $maxSeen = $v }
}
CheckTrue '  500 次抽样都 >= 10' ($minSeen -ge 10.0)
CheckTrue '  500 次抽样都 <= 20' ($maxSeen -le 20.0)
CheckTrue '  确实有随机性（抽样不全相等）' (($maxSeen - $minSeen) -gt 1.0)
Check '  非法区间（min==max）返回 min' (Get-RandDouble 5.0 5.0) 5
Check '  非法区间（min>max）返回 min' (Get-RandDouble 7.0 3.0) 7

Write-Host ""
Write-Host "=== 7. 走完全程模拟：从起点走到目标后必须正好停在目标 ===" -ForegroundColor Cyan
$curX = 100.0; $curY = 100.0
$t = @{ x = 800.0; y = 600.0 }
$steps = 0
$arrived = $false
while (-not $arrived -and $steps -lt 5000) {
    $s = Get-WanderStep $curX $curY $t.x $t.y 3.0
    $curX = $s.x; $curY = $s.y
    $arrived = $s.arrived
    $steps++
}
CheckTrue '  在有限步内到达' ($steps -lt 5000)
Check '  最终 x 正好等于目标' $curX 800
Check '  最终 y 正好等于目标' $curY 600
# 全程不许越界（用夹取模拟真实流程）
CheckTrue '  步数合理（约 距离/步长）' ($steps -gt 200 -and $steps -lt 400)

Write-Host ""
if ($script:fail -eq 0) { Write-Host ("全部通过：{0} 项" -f $script:pass) -ForegroundColor Green; exit 0 }
else { Write-Host ("失败 {0} 项 / 通过 {1} 项" -f $script:fail, $script:pass) -ForegroundColor Red; exit 1 }
