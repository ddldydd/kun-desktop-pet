# DPI 换算 + 拖拽落点 + 位置夹紧 自测（纯逻辑，不启动桌宠）。
# 测 kun-pet-wander.ps1 里的 Convert-PxToDip / Get-ClampedPos / Get-DragWindowPos。
#
# 旧拖拽把 PointToScreen 的物理像素直接加到 $window.Left（DIP）上：
#   125% 缩放下鼠标走 150px，窗口会走 150 DIP = 187.5px，比值 1.25，
#   桌宠比鼠标快一截，再叠上 SizeChanged 回拉，观感就是「卡、跟不住」。
# 新公式必须先除以 DPI 再累加，并允许在拖拽时夹紧到虚拟屏内。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\test-position.ps1
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
function CheckNear([string]$name, [double]$actual, [double]$expected) {
    $d = [math]::Abs($actual - $expected)
    if ($d -lt 0.0001) { $script:pass++; Write-Host ("  [ok]   " + $name + " = " + $actual) -ForegroundColor Green }
    else { $script:fail++; Write-Host ("  [FAIL] {0}  期望≈{1} 实际={2}" -f $name, $expected, $actual) -ForegroundColor Red }
}

$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
. (Join-Path (Split-Path -Parent $here) 'kun-pet-wander.ps1')

Write-Host ""
Write-Host "=== 1. 物理像素位移 → DIP 位移（Convert-PxToDip）===" -ForegroundColor Cyan
CheckNear '100% 缩放：120px → 120 DIP' (Convert-PxToDip 120.0 1.0) 120.0
CheckNear '125% 缩放：150px → 120 DIP' (Convert-PxToDip 150.0 1.25) 120.0
CheckNear '150% 缩放：180px → 120 DIP' (Convert-PxToDip 180.0 1.5) 120.0
CheckNear '200% 缩放：240px → 120 DIP' (Convert-PxToDip 240.0 2.0) 120.0
CheckNear '负方向同样换算：-150px@1.25 → -120 DIP' (Convert-PxToDip -150.0 1.25) -120.0
CheckNear 'scale<=0 异常输入 → 按 1:1 原样返回（不除零）' (Convert-PxToDip 50.0 0.0) 50.0
CheckNear 'scale<0 同样退回 1:1' (Convert-PxToDip 50.0 -1.0) 50.0

Write-Host ""
Write-Host "=== 2. 完整夹紧（keepPx<=0）：窗口整个落在虚拟屏内 ===" -ForegroundColor Cyan
$vs = @{ Left = -1920.0; Top = 0.0; Right = 1920.0; Bottom = 1080.0 }
$winW = 272.0; $winH = 145.0

$c = Get-ClampedPos $vs $winW $winH -1500.0 400.0 0.0
CheckTrue '副屏（负坐标）位置不被误判非法 → 保持不变 x' ($c.x -eq -1500.0)
CheckTrue '副屏 y 保持不变' ($c.y -eq 400.0)

$c = Get-ClampedPos $vs $winW $winH 500.0 300.0 0.0
CheckTrue '主屏位置保持不变 x' ($c.x -eq 500.0)
CheckTrue '主屏位置保持不变 y' ($c.y -eq 300.0)

$c = Get-ClampedPos $vs $winW $winH 99999.0 99999.0 0.0
CheckNear '右下越界 → 夹到 Right - winW' $c.x (1920.0 - 272.0)
CheckNear '下越界 → 夹到 Bottom - winH' $c.y (1080.0 - 145.0)

$c = Get-ClampedPos $vs $winW $winH -99999.0 -99999.0 0.0
CheckNear '左上越界 → 夹到 Left=-1920' $c.x -1920.0
CheckNear '上越界 → 夹到 Top=0' $c.y 0.0

Write-Host ""
Write-Host "=== 3. 换分辨率：屏幕变小后旧位置被夹回 ===" -ForegroundColor Cyan
$vsSmall = @{ Left = 0.0; Top = 0.0; Right = 1280.0; Bottom = 800.0 }
$c = Get-ClampedPos $vsSmall $winW $winH 1500.0 900.0 0.0
CheckNear 'x=1500 超出新屏 → 夹到 1280-272' $c.x (1280.0 - 272.0)
CheckNear 'y=900 超出新屏 → 夹到 800-145' $c.y (800.0 - 145.0)

Write-Host ""
Write-Host "=== 4. 窗口比屏还大 → 退化为贴左上角（不产生 NaN/越界）===" -ForegroundColor Cyan
$tiny = @{ Left = 0.0; Top = 0.0; Right = 100.0; Bottom = 80.0 }
$c = Get-ClampedPos $tiny 400.0 300.0 50.0 50.0 0.0
CheckNear '窗口过大 → x 贴 Left' $c.x 0.0
CheckNear '窗口过大 → y 贴 Top' $c.y 0.0

Write-Host ""
Write-Host "=== 5. 部分可见夹紧（keepPx>0，拖拽实时夹紧用）===" -ForegroundColor Cyan
$vs2 = @{ Left = 0.0; Top = 0.0; Right = 1920.0; Bottom = 1080.0 }
$c = Get-ClampedPos $vs2 $winW $winH 500.0 400.0 40.0
CheckTrue '界内点不受影响 x' ($c.x -eq 500.0)
CheckTrue '界内点不受影响 y' ($c.y -eq 400.0)

$c = Get-ClampedPos $vs2 $winW $winH 99999.0 400.0 40.0
CheckNear '右缘外甩飞 → 夹到 Right-40（保留贴边手感 + 40px 可见）' $c.x (1920.0 - 40.0)

$c = Get-ClampedPos $vs2 $winW $winH -99999.0 400.0 40.0
CheckNear '左缘外甩飞 → 夹到 Left-winW+40' $c.x (0.0 - 272.0 + 40.0)

$c = Get-ClampedPos $vs2 $winW $winH 500.0 -99999.0 40.0
CheckNear '上缘外甩飞 → 夹到 Top-winH+40' $c.y (0.0 - 145.0 + 40.0)

$c = Get-ClampedPos $vs2 $winW $winH 500.0 99999.0 40.0
CheckNear '下缘外甩飞 → 夹到 Bottom-40' $c.y (1080.0 - 40.0)

Write-Host ""
Write-Host "=== 6. keepPx 负数 → 视为完整夹紧（容错）===" -ForegroundColor Cyan
$c = Get-ClampedPos $vs2 $winW $winH 99999.0 99999.0 -1.0
CheckNear 'keepPx<0 → 完整夹紧 x' $c.x (1920.0 - 272.0)
CheckNear 'keepPx<0 → 完整夹紧 y' $c.y (1080.0 - 145.0)

Write-Host ""
Write-Host "=== 7. 拖拽落点：像素位移 + DPI → 窗口 DIP（Get-DragWindowPos）===" -ForegroundColor Cyan
$startL = 800.0; $startT = 400.0
$p = Get-DragWindowPos $startL $startT 160.0 0.0 1.0 $vs2 $winW $winH 40.0
CheckNear '100% DPI：鼠标向右 160px → 窗口 +160 DIP' $p.left ($startL + 160.0)
CheckNear '100% DPI：Y 不变' $p.top $startT
CheckTrue '超过 3px 算真正拖动' ([bool]$p.moved)
Check '朝右拖 → running-right' $p.dir 'running-right'

$p = Get-DragWindowPos $startL $startT 150.0 0.0 1.25 $vs2 $winW $winH 40.0
CheckNear '125% DPI：150px → +120 DIP（旧代码会 +150，窗口比鼠标快）' $p.left ($startL + 120.0)
Check '125% 仍朝右' $p.dir 'running-right'

$p = Get-DragWindowPos $startL $startT -180.0 40.0 1.5 $vs2 $winW $winH 40.0
CheckNear '150% DPI：-180px → -120 DIP' $p.left ($startL - 120.0)
CheckNear '150% DPI：40px → +26.666… DIP' $p.top ($startT + (40.0 / 1.5))
Check '朝左拖 → running-left' $p.dir 'running-left'

$p = Get-DragWindowPos $startL $startT 1.0 1.0 1.0 $vs2 $winW $winH 40.0
CheckTrue '小于抖动阈值不算 moved' (-not [bool]$p.moved)

$p = Get-DragWindowPos $startL $startT 99999.0 0.0 1.0 $vs2 $winW $winH 40.0
CheckNear '拖出右缘仍夹紧，避免甩飞' $p.left (1920.0 - 40.0)

$p = Get-DragWindowPos $startL $startT 80.0 0.0 1.0 $null $winW $winH 40.0
CheckNear 'bounds 为空时不夹紧，只换算' $p.left ($startL + 80.0)

Write-Host ""
Write-Host "=== 8. 拖拽期间冻结气泡/提示（避免 SizeToContent 跟鼠标抢位置）===" -ForegroundColor Cyan
$plan = Get-PetTickPlan @{ dragging = $true; paused = $false }
CheckTrue '拖拽中仍更新跑步帧' ([bool]$plan.updateSprite)
CheckTrue '拖拽中不改气泡/提示（防止窗口尺寸抖动）' (-not [bool]$plan.updateChrome)
CheckTrue '拖拽中不做随机走动' (-not [bool]$plan.wander)
CheckTrue '拖拽中跳过轮询 IO' (-not [bool]$plan.poll)

$plan = Get-PetTickPlan @{ dragging = $false; paused = $false }
CheckTrue '平时更新形象' ([bool]$plan.updateSprite)
CheckTrue '平时更新气泡' ([bool]$plan.updateChrome)
CheckTrue '平时允许 wander 判断' ([bool]$plan.wander)
CheckTrue '平时轮询' ([bool]$plan.poll)

$plan = Get-PetTickPlan @{ dragging = $false; paused = $true }
CheckTrue '暂停时不推进形象帧' (-not [bool]$plan.updateSprite)
CheckTrue '暂停时气泡仍更新' ([bool]$plan.updateChrome)
CheckTrue '暂停时不 wander' (-not [bool]$plan.wander)

$plan = Get-PetTickPlan @{ dragging = $false; paused = $false; menuOpen = $true }
CheckTrue '菜单打开时不推进形象（少抢 UI 线程，菜单才不卡）' (-not [bool]$plan.updateSprite)
CheckTrue '菜单打开时不改气泡' (-not [bool]$plan.updateChrome)
CheckTrue '菜单打开时不 wander' (-not [bool]$plan.wander)
CheckTrue '菜单打开时跳过轮询' (-not [bool]$plan.poll)

$plan = Get-PetTickPlan @{ dragging = $false; paused = $false; walking = $true }
CheckTrue '自己走路时仍更新跑步帧' ([bool]$plan.updateSprite)
CheckTrue '自己走路时仍允许 wander' ([bool]$plan.wander)
CheckTrue '自己走路时不改气泡/提示（避免 SizeToContent 每秒卡一下）' (-not [bool]$plan.updateChrome)
CheckTrue '自己走路时跳过轮询 IO（避免 500ms 顿一下）' (-not [bool]$plan.poll)

Write-Host ""
if ($script:fail -eq 0) { Write-Host ("全部通过：{0} 项" -f $script:pass) -ForegroundColor Green; exit 0 }
else { Write-Host ("失败 {0} 项 / 通过 {1} 项" -f $script:fail, $script:pass) -ForegroundColor Red; exit 1 }
