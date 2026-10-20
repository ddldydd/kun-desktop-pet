# 运行时验证：随机移动的「护栏」是否真的生效。
# 做法：直接驱动 Update-Wander 所依赖的判断逻辑，在可控状态下检查是否移动。
# 不启动 WPF —— 用一个假的 $window/$state 复刻关键分支，验证守卫条件。
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
function CheckTrue([string]$name, $c) { Check $name $(if ($c) { 'True' } else { 'False' }) 'True' }

$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path (Split-Path -Parent $here) 'kun-pet-wander.ps1')

# 直接调用**产品代码**里的守卫函数（Test-WanderAllowed），不是复制一份判断逻辑。
# 复制品会随着产品代码改动而失真，测试却照样全绿 —— 那种测试没有价值。
function New-Ctx {
    return @{
        enabled = $true; paused = $false; dragging = $false; hover = $false
        waiting = $false; approvalCount = 0; winLeft = 100.0; winTop = 100.0
    }
}
function Test-Allowed($ctx) { return [bool](Test-WanderAllowed $ctx) }

Write-Host ""
Write-Host "=== 随机移动的护栏（哪些情况下必须不动）===" -ForegroundColor Cyan

CheckTrue '全部正常 → 允许移动' (Test-Allowed (New-Ctx))

$c = New-Ctx; $c.enabled = $false
CheckTrue '功能关闭 → 不动' (-not (Test-Allowed $c))

$c = New-Ctx; $c.paused = $true
CheckTrue '已暂停 → 不动（暂停的语义就是冻结小宠）' (-not (Test-Allowed $c))

$c = New-Ctx; $c.dragging = $true
CheckTrue '用户正在拖拽 → 不动（否则和鼠标抢窗口）' (-not (Test-Allowed $c))

# 悬停不再刹停：「鼠标停上去就冻住、得等它自己恢复」正是要消掉的割裂感。
# 遗留的 hover 字段必须被忽略，否则老调用点会重新引入冻结。
$c = New-Ctx; $c.hover = $true
CheckTrue '鼠标悬停在宠物上 → 照样允许走动（不再冻结）' (Test-Allowed $c)

$c = New-Ctx; $c.menuOpen = $true
CheckTrue '右键/托盘菜单正开着 → 不动（否则菜单还没点完它就跑走）' (-not (Test-Allowed $c))

$c = New-Ctx; $c.waiting = $true
CheckTrue '正在等你介入 → 不动（审批按钮不能被移走）' (-not (Test-Allowed $c))

$c = New-Ctx; $c.approvalCount = 1
CheckTrue '有审批面板显示 → 不动（同上）' (-not (Test-Allowed $c))

$c = New-Ctx; $c.winLeft = [double]::NaN
CheckTrue '窗口坐标还是 NaN（未布局）→ 不动（否则会抛异常）' (-not (Test-Allowed $c))

$c = New-Ctx; $c.winTop = [double]::NaN
CheckTrue 'winTop 是 NaN → 也不动' (-not (Test-Allowed $c))

CheckTrue '缺字段的 ctx（容错）→ 按「没开」处理，不动' (-not (Test-Allowed @{}))
CheckTrue 'ctx=$null → 不动（不抛异常）' (-not (Test-Allowed $null))

Write-Host ""
Write-Host "=== 夹取能修正「气泡把窗口顶到屏幕外」的情况 ===" -ForegroundColor Cyan
$wa = @{ Left = 0.0; Top = 0.0; Right = 1858.0; Bottom = 1080.0 }
# 实测出现过的场景：posTop = -7（气泡长高，窗口被顶出屏幕上沿）
$c2 = Get-WanderClamped $wa 218.0 171.0 806.0 -7.0
CheckTrue '  y=-7 → 被拉回工作区内（>= Top）' ($c2.y -ge 0)
Check '  修正后 y = 0' $c2.y 0
Check '  x 不受影响' $c2.x 806

Write-Host ""
if ($script:fail -eq 0) { Write-Host ("全部通过：{0} 项" -f $script:pass) -ForegroundColor Green; exit 0 }
else { Write-Host ("失败 {0} 项 / 通过 {1} 项" -f $script:fail, $script:pass) -ForegroundColor Red; exit 1 }
