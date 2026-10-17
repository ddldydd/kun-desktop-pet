# 实机拖拽验证（Windows 实机，不接 CI）：
#   启动仓库副本桌宠（独立 cwd）→ 找窗口 → 模拟鼠标拖拽 → 测「窗口位移/鼠标位移」比值。
#   修复后应 ≈1.0（任意 DPI）；修复前在 125% 下 ≈1.25。
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\desktop\tests\test-drag-live.ps1 [移动像素] [备注DPI]
$ErrorActionPreference = 'Stop'
$movePx = 160
if ($args.Count -ge 1 -and $args[0]) { $movePx = [int]$args[0] }
$note = ''
if ($args.Count -ge 2 -and $args[1]) { $note = ' (DPI=' + $args[1] + ')' }

$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path -Parent (Split-Path -Parent $here)
$petPs1 = Join-Path $repo 'desktop\kun-pet-desktop.ps1'
$cwd = Join-Path ([IO.Path]::GetTempPath()) ('kun-drag-test-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force -Path $cwd | Out-Null

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class DragWin {
    [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
    public delegate bool EnumProc(IntPtr h, IntPtr p);
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
    [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, System.Text.StringBuilder s, int n);
    [DllImport("user32.dll")] public static extern uint SendInput(uint n, INPUT[] i, int sz);
    [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public MOUSEINPUT mi; }
    [StructLayout(LayoutKind.Sequential)] public struct MOUSEINPUT { public int dx, dy; public uint mouseData, dwFlags, time; public IntPtr dwExtraInfo; }
    public const uint INPUT_MOUSE = 0, MOUSEEVENTF_LEFTDOWN = 0x0002, MOUSEEVENTF_LEFTUP = 0x0004, MOUSEEVENTF_MOVE = 0x0001, MOUSEEVENTF_ABSOLUTE = 0x8000;
    public static INPUT MakeMouse(uint flags, int dx, int dy) {
        var i = new INPUT(); i.type = INPUT_MOUSE;
        i.mi = new MOUSEINPUT { dx = dx, dy = dy, mouseData = 0, dwFlags = flags, time = 0, dwExtraInfo = IntPtr.Zero };
        return i;
    }
}
"@

$script:foundWnd = [IntPtr]::Zero
function Find-PetWindow {
    [DragWin]::EnumWindows({ param($h, $p)
        $pid2 = 0
        [DragWin]::GetWindowThreadProcessId($h, [ref]$pid2) | Out-Null
        if (-not [DragWin]::IsWindowVisible($h)) { return $true }
        $sb = New-Object System.Text.StringBuilder 256
        [DragWin]::GetWindowText($h, $sb, 256) | Out-Null
        if ($sb.ToString() -eq 'Kun Pet') { $script:foundWnd = $h; return $false }
        return $true
    }, [IntPtr]::Zero) | Out-Null
    return $script:foundWnd
}

function Get-Rect($h) {
    $r = New-Object DragWin+RECT
    [DragWin]::GetWindowRect($h, [ref]$r) | Out-Null
    return $r
}

# 1) 启动桌宠（独立 cwd）
Write-Host ('启动桌宠 cwd=' + $cwd)
$petEsc = $petPs1 -replace "'", "''"
$innerCmd = "Set-Location -LiteralPath '" + $cwd + "'; `$cwd='" + $cwd + "'; `$c=[IO.File]::ReadAllText('" + $petEsc + "',[Text.Encoding]::UTF8); & ([ScriptBlock]::Create(`$c))"
Start-Process -FilePath 'powershell.exe' -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-Command',$innerCmd) -WindowStyle Hidden

# 2) 等窗口出现（最多 20 秒）
$h = [IntPtr]::Zero
for ($i = 0; $i -lt 40; $i++) {
    Start-Sleep -Milliseconds 500
    $h = Find-PetWindow
    if ($h -ne [IntPtr]::Zero) { break }
}
if ($h -eq [IntPtr]::Zero) {
    Write-Host '[FAIL] 20 秒内没找到桌宠窗口 (Kun Pet)'
    Remove-Item -LiteralPath $cwd -Recurse -Force -ErrorAction SilentlyContinue
    exit 1
}
Write-Host ('找到桌宠窗口 hwnd=' + $h)

# 3) 等窗口稳定
Start-Sleep -Seconds 1

# 4) 记录起点，模拟拖拽
$r0 = Get-Rect $h
# 取鲸鱼身体实心区：窗口水平中心、距底部 70px（petShell 140 高且贴窗口底部，鲸鱼在其下半）。
# 窗口几何中心可能落在透明气泡/空隙上 —— AllowsTransparency=True 下透明区不响应鼠标。
$cx = [int](($r0.L + $r0.R) / 2)
$cy = [int]($r0.B - 70)
Write-Host ('起点 rect=(' + $r0.L + ',' + $r0.T + ',' + $r0.R + ',' + $r0.B + ') 中心=(' + $cx + ',' + $cy + ')')

# SendInput 绝对坐标模式（65535 归一化），比 SetCursorPos+mouse_event 更可靠地
# 把事件注入到光标下的窗口。虚拟屏 1920x1080，坐标按整个虚拟屏归一化。
$vsW = 1920; $vsH = 1080
function Abs-X([int]$sx) { return [int]([math]::Round($sx * 65535.0 / ($vsW - 1))) }
function Abs-Y([int]$sy) { return [int]([math]::Round($sy * 65535.0 / ($vsH - 1))) }
# 先移动并按下
[DragWin]::SendInput(1, @([DragWin]::MakeMouse([DragWin]::MOUSEEVENTF_MOVE -bor [DragWin]::MOUSEEVENTF_ABSOLUTE, (Abs-X $cx), (Abs-Y $cy))), [Runtime.InteropServices.Marshal]::SizeOf([type][DragWin+INPUT])) | Out-Null
Start-Sleep -Milliseconds 200
[DragWin]::SendInput(1, @([DragWin]::MakeMouse([DragWin]::MOUSEEVENTF_LEFTDOWN, 0, 0)), [Runtime.InteropServices.Marshal]::SizeOf([type][DragWin+INPUT])) | Out-Null
Start-Sleep -Milliseconds 150
for ($s = 1; $s -le 8; $s++) {
    $nx = $cx - [int]($movePx * $s / 8)
    [DragWin]::SendInput(1, @([DragWin]::MakeMouse([DragWin]::MOUSEEVENTF_MOVE -bor [DragWin]::MOUSEEVENTF_ABSOLUTE, (Abs-X $nx), (Abs-Y $cy))), [Runtime.InteropServices.Marshal]::SizeOf([type][DragWin+INPUT])) | Out-Null
    Start-Sleep -Milliseconds 60
}
Start-Sleep -Milliseconds 150
[DragWin]::SendInput(1, @([DragWin]::MakeMouse([DragWin]::MOUSEEVENTF_LEFTUP, 0, 0)), [Runtime.InteropServices.Marshal]::SizeOf([type][DragWin+INPUT])) | Out-Null
Start-Sleep -Milliseconds 400

# 5) 测窗口位移
$r1 = Get-Rect $h
$dx = ($r1.L - $r0.L)
$dy = ($r1.T - $r0.T)
Write-Host ('终点 rect=(' + $r1.L + ',' + $r1.T + ',' + $r1.R + ',' + $r1.B + ') 位移=(' + $dx + ',' + $dy + ')')
$ratio = 0.0
if ($movePx -ne 0) { $ratio = [math]::Round($dx / $movePx, 3) }
Write-Host ('鼠标位移=' + $movePx + ' 窗口位移X=' + $dx + ' 比值=' + $ratio + $note)

# 6) 判定（允许少量误差；向左拖，dx 应为负，|dx|≈movePx）
$pass = ([math]::Abs($dx) -ge $movePx - 12) -and ([math]::Abs($dx) -le $movePx + 12)
if ($pass) { Write-Host ('[ok] 比值≈1.0 窗口跟随鼠标 1:1' + $note) }
else { Write-Host ('[FAIL] 窗口位移偏离鼠标位移过多：dx=' + $dx + ' mouse=' + $movePx) }

# 7) 清理
$pid2 = 0
[DragWin]::GetWindowThreadProcessId($h, [ref]$pid2) | Out-Null
if ($pid2) { Stop-Process -Id $pid2 -Force -ErrorAction SilentlyContinue }
Start-Sleep -Milliseconds 300
Remove-Item -LiteralPath $cwd -Recurse -Force -ErrorAction SilentlyContinue

if ($pass) { exit 0 } else { exit 1 }
