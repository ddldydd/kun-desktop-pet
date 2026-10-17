# DPI 缩放换算 + 虚拟屏位置夹紧 自测（纯逻辑，跨平台，进 CI）。
# 只测 kun-pet-wander.ps1 里的 Convert-PxToDip / Get-ClampedPos 两个纯函数，
# 不碰 WPF、不启动桌宠。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\desktop\tests\test-position.ps1
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
# 主屏 1920x1080 在右侧，副屏 1920x1080 在左侧 → 虚拟屏 Left=-1920, Right=1920
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
# 之前双屏（Left=-1920,Right=1920）存的 posLeft=1500；现在只有单屏 1280x800
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

# 拖到屏幕右缘外：允许越界，但至少留 40px 宽可见 → x 最大 = Right - 40
$c = Get-ClampedPos $vs2 $winW $winH 99999.0 400.0 40.0
CheckNear '右缘外甩飞 → 夹到 Right-40（保留贴边手感 + 40px 可见）' $c.x (1920.0 - 40.0)

# 拖到屏幕左缘外：x 最小 = Left - winW + 40（窗口右缘留 40px 在屏内）
$c = Get-ClampedPos $vs2 $winW $winH -99999.0 400.0 40.0
CheckNear '左缘外甩飞 → 夹到 Left-winW+40' $c.x (0.0 - 272.0 + 40.0)

# 上缘外：y 最小 = Top - winH + 40
$c = Get-ClampedPos $vs2 $winW $winH 500.0 -99999.0 40.0
CheckNear '上缘外甩飞 → 夹到 Top-winH+40' $c.y (0.0 - 145.0 + 40.0)

# 下缘外：y 最大 = Bottom - 40
$c = Get-ClampedPos $vs2 $winW $winH 500.0 99999.0 40.0
CheckNear '下缘外甩飞 → 夹到 Bottom-40' $c.y (1080.0 - 40.0)

Write-Host ""
Write-Host "=== 6. keepPx 负数 → 视为完整夹紧（容错）===" -ForegroundColor Cyan
$c = Get-ClampedPos $vs2 $winW $winH 99999.0 99999.0 -1.0
CheckNear 'keepPx<0 → 完整夹紧 x' $c.x (1920.0 - 272.0)
CheckNear 'keepPx<0 → 完整夹紧 y' $c.y (1080.0 - 145.0)

Write-Host ""
if ($script:fail -eq 0) { Write-Host ("全部通过：{0} 项" -f $script:pass) -ForegroundColor Green; exit 0 }
else { Write-Host ("失败 {0} 项 / 通过 {1} 项" -f $script:fail, $script:pass) -ForegroundColor Red; exit 1 }
