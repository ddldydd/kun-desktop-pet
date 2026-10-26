# 「临时提示走气泡」的验证。
#
# 背景：更新检查的结果提示原本用 MessageBox，但实测发现 WinForms 的 MessageBox
# **不是 Topmost**，而桌宠是 Topmost 窗口 —— 弹窗会落在桌宠**之下**、可能被挡住，
# 而且会抢焦点打断用户打字。改成走气泡（贴在置顶的小宠上，不打断操作）。
#
# 本测试**直接调用产品代码里的 Resolve-BubbleText**（kun-pet-ui.ps1），
# 而不是复制一份判断逻辑 —— 复制品会随产品代码失真而测试照样全绿。
$ErrorActionPreference = 'Stop'
$script:fail = 0; $script:pass = 0
function Check([string]$n, $a, $e) {
    $x = if ($null -eq $a) { '<null>' } else { [string]$a }
    $y = if ($null -eq $e) { '<null>' } else { [string]$e }
    if ($x -eq $y) { $script:pass++; Write-Host ("  [ok]   " + $n) -ForegroundColor Green }
    else { $script:fail++; Write-Host ("  [FAIL] {0} 期望={1} 实际={2}" -f $n, $y, $x) -ForegroundColor Red }
}
function CheckTrue([string]$n, $c) { Check $n $(if ($c) { 'True' } else { 'False' }) 'True' }

$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
$desktop = Split-Path -Parent $here
$mod = Join-Path $desktop 'kun-pet-ui.ps1'
if (-not (Test-Path -LiteralPath $mod)) { Write-Host ("找不到模块: " + $mod) -ForegroundColor Red; exit 1 }
. $mod
if (-not (Get-Command -Name 'Resolve-BubbleText' -CommandType Function -ErrorAction SilentlyContinue)) {
    Write-Host "Resolve-BubbleText 未定义" -ForegroundColor Red; exit 1
}

$now = Get-Date
$future = $now.AddSeconds(8)
$past = $now.AddSeconds(-1)

Write-Host ""
Write-Host "=== 1. 有提示时，提示盖过常态文案 ===" -ForegroundColor Cyan
$r = Resolve-BubbleText '我先去干活啦！' '✅ 已是最新版本 v2.1.0' $future $now
Check '气泡显示提示' $r.bubble '✅ 已是最新版本 v2.1.0'
Check '提示仍然保留（未过期）' $r.noticeText '✅ 已是最新版本 v2.1.0'

# 关键：提示必须盖过「等待介入」这种高优先级文案，
# 否则用户点了「检查更新」却看不到任何回应（气泡被等待提示占着）。
$r = Resolve-BubbleText '⏳ 需要你确认权限（已等 3 秒）' '✅ 已是最新版本 v2.1.0' $future $now
Check '提示盖过「需要你确认权限」' $r.bubble '✅ 已是最新版本 v2.1.0'
$r = Resolve-BubbleText '❓ 需要你选一下' '✅ 已是最新版本 v2.1.0' $future $now
Check '提示盖过「需要你选一下」' $r.bubble '✅ 已是最新版本 v2.1.0'
$r = Resolve-BubbleText '正在执行 bash…' '🔍 正在检查更新…' $future $now
Check '提示盖过「进行中」' $r.bubble '🔍 正在检查更新…'

Write-Host ""
Write-Host "=== 2. 过期后自动消失、回到常态 ===" -ForegroundColor Cyan
$r = Resolve-BubbleText '我先去干活啦！' '✅ 已是最新版本 v2.1.0' $past $now
Check '过期 → 回到常态文案' $r.bubble '我先去干活啦！'
Check '过期 → 提示状态被清空（调用方据此清 state）' $r.noticeText ''

Write-Host ""
Write-Host "=== 3. 没有提示时不干扰常态 ===" -ForegroundColor Cyan
$r = Resolve-BubbleText '怎么还不来找我~有事找我' '' $future $now
Check '空提示 → 常态文案' $r.bubble '怎么还不来找我~有事找我'
Check '空提示 → 状态仍为空' $r.noticeText ''
$r = Resolve-BubbleText 'idle 文案' '' ([datetime]::MinValue) $now
Check '提示为空且时间是 MinValue → 常态' $r.bubble 'idle 文案'

Write-Host ""
Write-Host "=== 4. 边界：坏输入不能抛异常（否则动画定时器每帧报错）===" -ForegroundColor Cyan
$ok = $true
try { $r = Resolve-BubbleText $null $null $null $now } catch { $ok = $false }
CheckTrue '$null 全传不抛异常' $ok
Check '常态为 $null → 气泡是空串（不是 <null>）' $r.bubble ''
try { $r = Resolve-BubbleText 'x' '提示' 'not-a-date' $now } catch { $ok = $false }
CheckTrue '过期时间不是日期也不抛异常' $ok
Check '无法判断过期时按「已过期」处理（宁可显示常态也不卡住）' $r.bubble 'x'

Write-Host ""
Write-Host "=== 5. 即时反馈必须立刻成为气泡内容 ===" -ForegroundColor Cyan
# 守护一个真实 bug：检查更新最初是**同步**联网，而动画定时器跑在 UI 线程，
# 于是网络不可达时 UI 冻结 ~10 秒、气泡不重绘 ——
# 「🔍 正在检查更新…」一次都没显示出来（用户只看到小宠卡住然后报错）。
# 修法是把联网丢到后台 runspace。这里验证提示置位后立刻就是气泡内容；
# 真正的「UI 不阻塞」由运行时实测覆盖（见 docs/internals.md）。
$r = Resolve-BubbleText '我先去干活啦！' '🔍 正在检查更新…' (Get-Date).AddSeconds(30) (Get-Date)
Check '刚置位的提示立刻就是气泡内容' $r.bubble '🔍 正在检查更新…'

Write-Host ""
Write-Host "=== 6. 气泡可见性：有话可说才显示，没话说过完宽限期收起 ===" -ForegroundColor Cyan
# 守护一个真实反馈：没有任务时气泡永远挂着「怎么还不来找我~有事找我」，
# 不携带任何信息还占桌面。现在没话说时只保留一段宽限期，之后整体收起。
if (-not (Get-Command -Name 'Resolve-BubbleVisibility' -CommandType Function -ErrorAction SilentlyContinue)) {
    Write-Host "Resolve-BubbleVisibility 未定义" -ForegroundColor Red; exit 1
}
$t0 = Get-Date

# 有话说 → 立即显示，且清掉计时游标
$v = Resolve-BubbleVisibility $true $t0.AddSeconds(-60) $t0 6000
CheckTrue '有话说 → 显示' $v.visible
Check '有话说 → idleSince 清回 $null' $v.idleSince $null

# 刚进入没话说 → 宽限期内仍显示，并开始计时
$v = Resolve-BubbleVisibility $false $null $t0 6000
CheckTrue '刚没话说 → 宽限期内仍显示' $v.visible
Check '刚没话说 → idleSince 从现在开始计时' ($v.idleSince -eq $t0) 'True'

# 计时中（未到期）→ 仍显示，游标原样传回
$v = Resolve-BubbleVisibility $false $t0.AddSeconds(-3) $t0 6000
CheckTrue '计时 3s / 宽限 6s → 仍显示' $v.visible
Check '计时中 → 游标原样传回' ($v.idleSince -eq $t0.AddSeconds(-3)) 'True'

# 超过宽限期 → 收起
$v = Resolve-BubbleVisibility $false $t0.AddSeconds(-6.5) $t0 6000
Check '计时 6.5s / 宽限 6s → 收起' $v.visible 'False'
Check '收起后游标保留（继续持有起点，一旦有话说再清）' ($v.idleSince -eq $t0.AddSeconds(-6.5)) 'True'

# 收起后又有话说 → 立即恢复显示
$v = Resolve-BubbleVisibility $true $t0.AddSeconds(-99) $t0 6000
CheckTrue '收起后又有话说 → 立即恢复显示' $v.visible

# 边界：坏输入不抛异常（动画定时器每帧都调它）
$ok = $true
try { $v = Resolve-BubbleVisibility $false 'not-a-date' $t0 6000 } catch { $ok = $false }
CheckTrue '游标不是日期也不抛异常（按刚进入计）' $ok
$ok = $true
try { $v = Resolve-BubbleVisibility $false $null $null 6000 } catch { $ok = $false }
CheckTrue '$null 时间不抛异常' $ok

Write-Host ""
if ($script:fail -eq 0) { Write-Host ("全部通过：{0} 项" -f $script:pass) -ForegroundColor Green; exit 0 }
else { Write-Host ("失败 {0} 项 / 通过 {1} 项" -f $script:fail, $script:pass) -ForegroundColor Red; exit 1 }
