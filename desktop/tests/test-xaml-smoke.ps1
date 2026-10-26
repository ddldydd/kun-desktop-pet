# XAML 冒烟检查：确认主脚本内嵌的 XAML 能被 XamlReader 解析，
# 且动画帧要用到的元素名都能 FindName 到（改 XAML 忘记配套主脚本时这里先红）。
# 只解析窗口、不 Show，不进消息循环，不会在桌面弹出任何东西。
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
$root = Split-Path -Parent $here

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase | Out-Null

$src = Get-Content -Raw -LiteralPath (Join-Path $root 'kun-pet-desktop.ps1') -Encoding UTF8
$start = $src.IndexOf("$xaml = @'")
if ($start -lt 0) { Write-Host '找不到 XAML here-string 起始标记' -ForegroundColor Red; exit 1 }
$start = $src.IndexOf("`n", $start) + 1
$end = $src.IndexOf("'@`n", $start)
if ($end -lt 0) { Write-Host '找不到 XAML here-string 结束标记' -ForegroundColor Red; exit 1 }
$xamlText = $src.Substring($start, $end - $start)

$fail = 0; $pass = 0
$window = $null
try {
    $window = [Windows.Markup.XamlReader]::Parse($xamlText)
    $pass++; Write-Host '  [ok]   XAML 解析成功' -ForegroundColor Green
} catch {
    $fail++; Write-Host ('  [FAIL] XAML 解析失败: ' + $_.Exception.Message) -ForegroundColor Red
    exit 1
}

# 动画帧/主脚本运行时 FindName 的全部元素（缺一个就会在运行时炸）
foreach ($name in @(
    'floatTransform', 'petScale', 'userScale', 'petShell', 'vectorPet', 'sheetPet',
    'badgeText', 'bubbleText', 'bubble', 'bubbleWrap', 'alertBorder', 'alertText',
    'progressText', 'bubbleTail', 'hintText', 'approvalBorder', 'approvalText',
    'btnApprove', 'btnReject'
)) {
    $el = $window.FindName($name)
    if ($null -ne $el) { $pass++; Write-Host ('  [ok]   FindName ' + $name) -ForegroundColor Green }
    else { $fail++; Write-Host ('  [FAIL] FindName ' + $name + ' → $null') -ForegroundColor Red }
}

if ($fail -eq 0) { Write-Host ('全部通过：{0} 项' -f $pass) -ForegroundColor Green; exit 0 }
else { Write-Host ('失败 {0} 项 / 通过 {1} 项' -f $fail, $pass) -ForegroundColor Red; exit 1 }
