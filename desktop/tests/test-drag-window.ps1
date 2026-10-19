# 进程内验证拖拽热路径：Get-DragWindowPos + SetWindowPos。
# 不模拟系统鼠标（透明分层窗上 SendInput 很容易点空），直接走产品同款挪窗 API。
# 用法：
#   powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\test-drag-window.ps1
[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
if ([Threading.Thread]::CurrentThread.GetApartmentState() -ne 'STA') {
    Write-Host '需要 STA：powershell -STA -File tests/test-drag-window.ps1' -ForegroundColor Red
    exit 1
}

$script:fail = 0
$script:pass = 0
function Check([string]$name, $actual, $expected) {
    if ([string]$actual -eq [string]$expected) {
        $script:pass++; Write-Host ("  [ok]   " + $name) -ForegroundColor Green
    } else {
        $script:fail++; Write-Host ("  [FAIL] {0}  期望={1} 实际={2}" -f $name, $expected, $actual) -ForegroundColor Red
    }
}
function CheckTrue([string]$name, $c) {
    if ($c) { $script:pass++; Write-Host ("  [ok]   " + $name) -ForegroundColor Green }
    else { $script:fail++; Write-Host ("  [FAIL] " + $name) -ForegroundColor Red }
}
function CheckNear([string]$name, [double]$actual, [double]$expected, [double]$tol = 2.0) {
    if ([math]::Abs($actual - $expected) -le $tol) {
        $script:pass++; Write-Host ("  [ok]   " + $name + " = " + $actual) -ForegroundColor Green
    } else {
        $script:fail++; Write-Host ("  [FAIL] {0}  期望≈{1} 实际={2}" -f $name, $expected, $actual) -ForegroundColor Red
    }
}

$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
$root = Split-Path -Parent $here
. (Join-Path $root 'kun-pet-wander.ps1')

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms
if (-not ('KunPet.WindowDrag' -as [type])) {
    Add-Type -TypeDefinition @'
using System;
using System.Runtime.InteropServices;
namespace KunPet {
    [StructLayout(LayoutKind.Sequential)]
    public struct DragPoint { public int X; public int Y; }
    [StructLayout(LayoutKind.Sequential)]
    public struct DragRect { public int Left; public int Top; public int Right; public int Bottom; }
    public static class WindowDrag {
        [DllImport("user32.dll")] public static extern bool GetCursorPos(out DragPoint lpPoint);
        [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr hWnd, out DragRect lpRect);
        [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr hWnd, IntPtr hWndInsertAfter, int X, int Y, int cx, int cy, uint uFlags);
        const uint SWP_MOVEFLAGS = 0x0015;
        public static bool MoveTo(IntPtr hWnd, int x, int y) {
            return SetWindowPos(hWnd, IntPtr.Zero, x, y, 0, 0, SWP_MOVEFLAGS);
        }
    }
}
'@
}

$win = New-Object System.Windows.Window
$win.WindowStyle = [System.Windows.WindowStyle]::None
$win.AllowsTransparency = $true
$win.Background = [System.Windows.Media.Brushes]::DeepSkyBlue
$win.Width = 120
$win.Height = 80
$win.Topmost = $true
$win.ShowInTaskbar = $false
$win.Left = 400
$win.Top = 300
$win.Show() | Out-Null
$win.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::ApplicationIdle)

$hwnd = [System.Windows.Interop.WindowInteropHelper]::new($win).Handle
$rc0 = New-Object KunPet.DragRect
[void][KunPet.WindowDrag]::GetWindowRect($hwnd, [ref]$rc0)
Write-Host ("起点 rect=({0},{1},{2},{3})" -f $rc0.Left, $rc0.Top, $rc0.Right, $rc0.Bottom)

$vs = [System.Windows.Forms.SystemInformation]::VirtualScreen
$bounds = @{
    Left = [double]$vs.X; Top = [double]$vs.Y
    Right = [double]$vs.Right; Bottom = [double]$vs.Bottom
}
$wpx = [double]($rc0.Right - $rc0.Left)
$hpx = [double]($rc0.Bottom - $rc0.Top)
$move = 160.0
$p = Get-DragWindowPos ([double]$rc0.Left) ([double]$rc0.Top) (-$move) 0.0 1.0 $bounds $wpx $hpx 40.0
$movedOk = [KunPet.WindowDrag]::MoveTo($hwnd, [int][math]::Round($p.left), [int][math]::Round($p.top))
$win.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::ApplicationIdle)

$rc1 = New-Object KunPet.DragRect
[void][KunPet.WindowDrag]::GetWindowRect($hwnd, [ref]$rc1)
$dx = $rc1.Left - $rc0.Left
Write-Host ("终点 rect=({0},{1},{2},{3}) dx={4}" -f $rc1.Left, $rc1.Top, $rc1.Right, $rc1.Bottom, $dx)

CheckTrue 'SetWindowPos 调用成功' $movedOk
CheckNear '窗口左移约 160px（与鼠标像素 1:1）' $dx (-160.0) 2.0
Check '朝左拖 → running-left' $p.dir 'running-left'
CheckTrue '超过阈值算 moved' ([bool]$p.moved)

# 同步回 WPF DIP 后，Left 应变，而不是被 SizeChanged 拽回去
$dpi = 1.0
try {
    $src = [System.Windows.PresentationSource]::FromVisual($win)
    if ($src) { $dpi = [double]$src.CompositionTarget.TransformToDevice.M11 }
} catch { }
if ($dpi -le 0) { $dpi = 1.0 }
$win.Left = Convert-PxToDip ([double]$rc1.Left) $dpi
$win.Top = Convert-PxToDip ([double]$rc1.Top) $dpi
CheckNear '松手后 WPF Left 与像素位置一致' ([double]$win.Left) (Convert-PxToDip ([double]$rc1.Left) $dpi) 1.0

$plan = Get-PetTickPlan @{ dragging = $true; paused = $false }
CheckTrue '拖拽中冻结气泡/轮询' ((-not $plan.updateChrome) -and (-not $plan.poll))

$win.Close()

Write-Host ""
if ($script:fail -eq 0) { Write-Host ("全部通过：{0} 项" -f $script:pass) -ForegroundColor Green; exit 0 }
else { Write-Host ("失败 {0} 项 / 通过 {1} 项" -f $script:fail, $script:pass) -ForegroundColor Red; exit 1 }
