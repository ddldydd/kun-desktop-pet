# 运行时验证：桌面版「多桌面显示（跟随）」依赖的 Win32/COM 行为是否真的可用。
# 不需要开着桌宠：自己建一个 1×1 的透明窗口当替身，验证
#   1) IVirtualDesktopManager 能创建（IID/vtable 对得上）；
#   2) 能读出窗口所在虚拟桌面的 GUID；
#   3) 能把**本进程**的窗口搬到另一个虚拟桌面，并在搬回后重新「在当前桌面」。
# 需要 -STA（WPF 窗口）。直接跑：
#   powershell -NoProfile -STA -ExecutionPolicy Bypass -File tests\test-virtual-desktop.ps1
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$script:fail = 0
$script:pass = 0
$script:skip = 0
function Check([string]$name, $actual, $expected) {
    $a = if ($null -eq $actual) { '<null>' } else { [string]$actual }
    $e = if ($null -eq $expected) { '<null>' } else { [string]$expected }
    if ($a -eq $e) { $script:pass++; Write-Host ("  [ok]   " + $name) -ForegroundColor Green }
    else { $script:fail++; Write-Host ("  [FAIL] {0}  期望={1} 实际={2}" -f $name, $e, $a) -ForegroundColor Red }
}
function CheckTrue([string]$name, $c) { Check $name $(if ($c) { 'True' } else { 'False' }) 'True' }
function Skip([string]$name) { $script:skip++; Write-Host ("  [skip] " + $name) -ForegroundColor DarkYellow }

Write-Host ""
Write-Host "=== 多桌面（虚拟桌面）互操作 ===" -ForegroundColor Cyan

Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase

# 与 kun-pet-desktop.ps1 里的 KunPet.VDesk 保持同一套 IID 与 vtable 顺序。
# 这里单独定义一份：测试要能在产品脚本不加载的情况下跑（也顺便验证 IID 本身没写错）。
Add-Type -TypeDefinition @'
using System;
using System.Text;
using System.Runtime.InteropServices;

namespace VdTest {
  [ComImport, Guid("AA509086-5CA9-4C25-8F95-589D3C07B48A")]
  public class VirtualDesktopManagerClass { }

  [ComImport, Guid("A5CD92FF-29BE-454C-8D04-D82879FB3F1B"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
  public interface IVirtualDesktopManager {
    [PreserveSig] int IsWindowOnCurrentVirtualDesktop(IntPtr h, out bool onCurrent);
    [PreserveSig] int GetWindowDesktopId(IntPtr h, out Guid desktopId);
    [PreserveSig] int MoveWindowToDesktop(IntPtr h, ref Guid desktopId);
  }

  public static class Vd {
    static IVirtualDesktopManager _mgr;
    public static IVirtualDesktopManager Mgr {
      get { if (_mgr == null) _mgr = (IVirtualDesktopManager)new VirtualDesktopManagerClass(); return _mgr; }
    }
    public static bool IsOnCurrent(IntPtr h) {
      try { bool on; return Mgr.IsWindowOnCurrentVirtualDesktop(h, out on) == 0 && on; } catch { return false; }
    }
    public static string DesktopId(IntPtr h) {
      try {
        Guid g;
        if (Mgr.GetWindowDesktopId(h, out g) != 0 || g == Guid.Empty) return "";
        return g.ToString("D");
      } catch { return ""; }
    }
    public static bool MoveTo(IntPtr h, string guid) {
      try { Guid g = new Guid(guid); return Mgr.MoveWindowToDesktop(h, ref g) == 0; } catch { return false; }
    }
  }
}
'@

$mgr = $null
try { $mgr = [VdTest.Vd]::Mgr } catch { }
CheckTrue 'IVirtualDesktopManager 可创建（IID/vtable 对得上）' ($null -ne $mgr)
if ($null -eq $mgr) {
    Write-Host "`n  结果: $($script:pass) 通过 / $($script:fail) 失败 / $($script:skip) 跳过" -ForegroundColor Yellow
    exit 1
}

# 1×1 透明窗口：只为拿一个「属于本进程」的 HWND（MoveWindowToDesktop 只能移自己的窗口）
$w = New-Object System.Windows.Window
$w.Width = 1; $w.Height = 1
$w.WindowStyle = 'None'; $w.AllowsTransparency = $true; $w.Background = 'Transparent'
$w.Topmost = $true; $w.ShowInTaskbar = $false; $w.ShowActivated = $false
$w.Left = -3000; $w.Top = -3000
$w.Show()

function Pump([int]$ms) {
    $frame = New-Object System.Windows.Threading.DispatcherFrame
    $timer = New-Object System.Windows.Threading.DispatcherTimer
    $timer.Interval = [TimeSpan]::FromMilliseconds($ms)
    $timer.Add_Tick({ $this.Stop(); $frame.Continue = $false })
    $timer.Start()
    [System.Windows.Threading.Dispatcher]::PushFrame($frame)
}
Pump 300

$h = [System.Windows.Interop.WindowInteropHelper]::new($w).Handle
CheckTrue '拿到窗口句柄' ($h -ne [IntPtr]::Zero)
$id = [VdTest.Vd]::DesktopId($h)
CheckTrue '读到窗口所在虚拟桌面 GUID' ($id -match '^[0-9a-f\-]{36}$')
CheckTrue '该窗口被认为在当前桌面（未移动前）' ([VdTest.Vd]::IsOnCurrent($h))

# 注册表里列出所有桌面 GUID（顺序即桌面顺序），挑一个和当前不同的来搬
$guids = @()
try {
    $raw = (Get-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\VirtualDesktops' -ErrorAction Stop).VirtualDesktopIDs
    $i = 0
    while ($null -ne $raw -and ($i + 16) -le $raw.Count) {
        $guids += (New-Object guid (,[byte[]]($raw[$i..($i + 15)]))).ToString()
        $i += 16
    }
} catch { }
CheckTrue '注册表能列出虚拟桌面 GUID 列表' ($guids.Count -ge 1)

$other = @($guids | Where-Object { $_ -ne $id }) | Select-Object -First 1
if (-not $other) {
    Skip '只有一个虚拟桌面 → 跨桌面移动无法验证（多开一个桌面再跑）'
} else {
    CheckTrue ('把窗口搬到另一个桌面 ' + $other.Substring(0, 8) + '…') ([VdTest.Vd]::MoveTo($h, $other))
    Pump 200
    Check '搬过去后桌面 GUID 变成目标' ([VdTest.Vd]::DesktopId($h)) $other
    CheckTrue '搬过去后不再属于当前桌面（这正是跟随逻辑要修的形态）' (-not [VdTest.Vd]::IsOnCurrent($h))

    CheckTrue '搬回原桌面' ([VdTest.Vd]::MoveTo($h, $id))
    Pump 200
    Check '搬回后桌面 GUID 复原' ([VdTest.Vd]::DesktopId($h)) $id
    CheckTrue '搬回后重新属于当前桌面' ([VdTest.Vd]::IsOnCurrent($h))
}

try { $w.Close() } catch { }

Write-Host ""
if ($script:fail -eq 0) {
    Write-Host ("  结果: {0} 通过 / {1} 跳过" -f $script:pass, $script:skip) -ForegroundColor Green
} else {
    Write-Host ("  结果: {0} 通过 / {1} 失败 / {2} 跳过" -f $script:pass, $script:fail, $script:skip) -ForegroundColor Red
}
exit $(if ($script:fail -eq 0) { 0 } else { 1 })

