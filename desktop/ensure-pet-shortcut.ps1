# Fallback desktop shortcut used when make-shortcut.ps1 is not next to the pet
# yet (the first in-app update can replace kun-pet-desktop.ps1 without shipping
# the helper scripts). Draws a small pet, writes a classic DIB icon outside the
# project folder, and creates 启动桌宠.lnk.
param(
    [Parameter(Mandatory = $true)][string]$PetDir,
    [string]$DesktopDir = ''
)
$ErrorActionPreference = 'Stop'
$petDir = (Resolve-Path -LiteralPath $PetDir).Path
$vbs = Join-Path $petDir '启动桌宠.vbs'
if (-not (Test-Path -LiteralPath $vbs)) { throw "launcher not found: $vbs" }
if (-not $DesktopDir) { $DesktopDir = [Environment]::GetFolderPath('Desktop') }
if (-not $DesktopDir) { throw 'desktop folder unavailable' }
if (-not (Test-Path -LiteralPath $DesktopDir)) {
    New-Item -ItemType Directory -Path $DesktopDir -Force | Out-Null
}

Add-Type -AssemblyName System.Drawing

function New-Solid([int]$r, [int]$g, [int]$b) {
    return [System.Drawing.Color]::FromArgb(255, $r, $g, $b)
}

function New-ProceduralPet([int]$size, [System.Drawing.Color]$badge) {
    $bmp = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $g = [System.Drawing.Graphics]::FromImage($bmp)
    try {
        $g.Clear([System.Drawing.Color]::Transparent)
        $g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::HighQuality
        $inset = [Math]::Max(1, [int]($size * 0.06))
        $bb = New-Object System.Drawing.SolidBrush $badge
        try { $g.FillEllipse($bb, $inset, $inset, ($size - (2 * $inset) - 1), ($size - (2 * $inset) - 1)) }
        finally { $bb.Dispose() }
        $body = New-Solid 255 176 64
        $belly = New-Solid 255 236 210
        $ink = New-Solid 40 48 60
        $bodyBrush = New-Object System.Drawing.SolidBrush $body
        $bellyBrush = New-Object System.Drawing.SolidBrush $belly
        $inkBrush = New-Object System.Drawing.SolidBrush $ink
        $white = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::White)
        $cheek = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(230, 255, 140, 160))
        try {
            $cx = $size / 2.0
            $bodyW = $size * 0.58
            $bodyH = $size * 0.46
            $bodyX = $cx - ($bodyW / 2.0)
            $bodyY = $size * 0.32
            $g.FillEllipse($bodyBrush, ($cx - $bodyW * 0.42), ($size * 0.16), ($bodyW * 0.26), ($bodyH * 0.40))
            $g.FillEllipse($bodyBrush, ($cx + $bodyW * 0.16), ($size * 0.16), ($bodyW * 0.26), ($bodyH * 0.40))
            $g.FillEllipse($bodyBrush, $bodyX, $bodyY, $bodyW, $bodyH)
            $g.FillEllipse($bellyBrush, ($cx - $bodyW * 0.26), ($bodyY + $bodyH * 0.38), ($bodyW * 0.52), ($bodyH * 0.40))
            $eye = [Math]::Max(2, [int]($size * 0.07))
            $eyeY = [int]($bodyY + $bodyH * 0.28)
            $g.FillEllipse($inkBrush, [int]($cx - $bodyW * 0.22), $eyeY, $eye, [int]($eye * 1.15))
            $g.FillEllipse($inkBrush, [int]($cx + $bodyW * 0.08), $eyeY, $eye, [int]($eye * 1.15))
            $gl = [Math]::Max(1, [int]($eye * 0.35))
            $g.FillEllipse($white, [int]($cx - $bodyW * 0.22 + $eye * 0.15), ($eyeY + 1), $gl, $gl)
            $g.FillEllipse($white, [int]($cx + $bodyW * 0.08 + $eye * 0.15), ($eyeY + 1), $gl, $gl)
            $cheekW = [Math]::Max(3, [int]($size * 0.09))
            $g.FillEllipse($cheek, [int]($cx - $bodyW * 0.38), [int]($eyeY + $eye), $cheekW, [int]($cheekW * 0.7))
            $g.FillEllipse($cheek, [int]($cx + $bodyW * 0.20), [int]($eyeY + $eye), $cheekW, [int]($cheekW * 0.7))
        } finally {
            $bodyBrush.Dispose(); $bellyBrush.Dispose(); $inkBrush.Dispose(); $white.Dispose(); $cheek.Dispose()
        }
    } finally { $g.Dispose() }
    return $bmp
}

function ConvertTo-DibEntry([System.Drawing.Bitmap]$bmp) {
    $w = $bmp.Width
    $h = $bmp.Height
    $rect = New-Object System.Drawing.Rectangle 0, 0, $w, $h
    $data = $bmp.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $stride = $data.Stride
        $pixels = New-Object byte[] ($stride * $h)
        [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $pixels, 0, $pixels.Length)
    } finally { $bmp.UnlockBits($data) }
    $maskStride = [int]([Math]::Floor(($w + 31) / 32) * 4)
    $mask = New-Object byte[] ($maskStride * $h)
    $andBit = [byte[]](0x80, 0x40, 0x20, 0x10, 0x08, 0x04, 0x02, 0x01)
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter $ms
    $bw.Write([UInt32]40)
    $bw.Write([Int32]$w)
    $bw.Write([Int32]($h * 2))
    $bw.Write([UInt16]1)
    $bw.Write([UInt16]32)
    $bw.Write([UInt32]0)
    $bw.Write([UInt32](($w * $h * 4) + ($maskStride * $h)))
    $bw.Write([Int32]0)
    $bw.Write([Int32]0)
    $bw.Write([UInt32]0)
    $bw.Write([UInt32]0)
    for ($y = $h - 1; $y -ge 0; $y--) {
        $rowStart = $y * $stride
        $maskRow = ($h - 1 - $y) * $maskStride
        for ($x = 0; $x -lt $w; $x++) {
            $i = $rowStart + ($x * 4)
            $a = $pixels[$i + 3]
            if ($a -lt 16) {
                $mi = $maskRow + [int][Math]::Floor($x / 8.0)
                $mask[$mi] = [byte]($mask[$mi] -bor $andBit[$x % 8])
                $bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([byte]0)
            } else {
                $bw.Write([byte]$pixels[$i])
                $bw.Write([byte]$pixels[$i + 1])
                $bw.Write([byte]$pixels[$i + 2])
                $bw.Write([byte]$a)
            }
        }
    }
    $bw.Write($mask)
    $bw.Flush()
    $bytes = $ms.ToArray()
    $bw.Dispose()
    return ,$bytes
}

function Save-PetIco($images, [string]$path) {
    $entries = New-Object System.Collections.Generic.List[byte[]]
    foreach ($bmp in $images) { [void]$entries.Add((ConvertTo-DibEntry $bmp)) }
    $ms = New-Object System.IO.MemoryStream
    $bw = New-Object System.IO.BinaryWriter $ms
    $bw.Write([UInt16]0)
    $bw.Write([UInt16]1)
    $bw.Write([UInt16]$entries.Count)
    $offset = 6 + (16 * $entries.Count)
    for ($n = 0; $n -lt $entries.Count; $n++) {
        $dim = $images[$n].Width
        $b = if ($dim -ge 256) { [byte]0 } else { [byte]$dim }
        $bw.Write($b)
        $bw.Write($b)
        $bw.Write([byte]0)
        $bw.Write([byte]0)
        $bw.Write([UInt16]1)
        $bw.Write([UInt16]32)
        $bw.Write([UInt32]$entries[$n].Length)
        $bw.Write([UInt32]$offset)
        $offset += $entries[$n].Length
    }
    foreach ($e in $entries) { $bw.Write($e) }
    $bw.Flush()
    [System.IO.File]::WriteAllBytes($path, $ms.ToArray())
    $bw.Dispose()
}

$code = @'
using System;
using System.Runtime.InteropServices;
using System.Text;

[ComImport, Guid("00021401-0000-0000-C000-000000000046")]
public class PetShellLink { }

[ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("000214F9-0000-0000-C000-000000000046")]
public interface IPetShellLinkW
{
    void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszFile, int cch, IntPtr pfd, uint fFlags);
    void GetIDList(out IntPtr ppidl);
    void SetIDList(IntPtr pidl);
    void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszName, int cch);
    void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string pszName);
    void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszDir, int cch);
    void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string pszDir);
    void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszArgs, int cch);
    void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string pszArgs);
    void GetHotkey(out short pwHotkey);
    void SetHotkey(short wHotkey);
    void GetShowCmd(out int piShowCmd);
    void SetShowCmd(int iShowCmd);
    void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] StringBuilder pszIconPath, int cch, out int piIcon);
    void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string pszIconPath, int iIcon);
    void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string pszPathRel, uint dwReserved);
    void Resolve(IntPtr hwnd, uint fFlags);
    void SetPath([MarshalAs(UnmanagedType.LPWStr)] string pszFile);
}

[ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("0000010b-0000-0000-C000-000000000046")]
public interface IPetPersistFile
{
    void GetClassID(out Guid pClassID);
    [PreserveSig] int IsDirty();
    void Load([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, uint dwMode);
    void Save([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, [MarshalAs(UnmanagedType.Bool)] bool fRemember);
    void SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string pszFileName);
    void GetCurFile([MarshalAs(UnmanagedType.LPWStr)] out string ppszFileName);
}

public static class PetLnk
{
    [DllImport("shell32.dll")]
    static extern void SHChangeNotify(uint wEventId, uint uFlags, IntPtr dwItem1, IntPtr dwItem2);

    public static void Create(string lnkPath, string target, string args, string workDir, string iconPath, string desc)
    {
        IPetShellLinkW link = (IPetShellLinkW)new PetShellLink();
        link.SetPath(target);
        link.SetArguments(args);
        link.SetWorkingDirectory(workDir);
        link.SetDescription(desc);
        link.SetIconLocation(iconPath, 0);
        link.SetShowCmd(1);
        ((IPetPersistFile)link).Save(lnkPath, true);
        Marshal.ReleaseComObject(link);
    }

    public static string Read(string lnkPath)
    {
        IPetShellLinkW link = (IPetShellLinkW)new PetShellLink();
        ((IPetPersistFile)link).Load(lnkPath, 0);
        var sbA = new StringBuilder(1024); link.GetArguments(sbA, 1024);
        var sbI = new StringBuilder(1024); int idx; link.GetIconLocation(sbI, 1024, out idx);
        Marshal.ReleaseComObject(link);
        return sbA.ToString() + "\n" + sbI.ToString() + "," + idx;
    }

    public static void Notify(string path)
    {
        IntPtr p = Marshal.StringToCoTaskMemUni(path);
        try { SHChangeNotify(0x00002000, 0x0005, p, IntPtr.Zero); }
        finally { Marshal.FreeCoTaskMem(p); }
    }
}
'@
if (-not ('PetLnk' -as [type])) { Add-Type -TypeDefinition $code -Language CSharp }

$palette = @(
    (New-Solid 246 214 224),
    (New-Solid 214 232 246),
    (New-Solid 232 246 214),
    (New-Solid 246 232 214),
    (New-Solid 224 214 246),
    (New-Solid 214 246 238)
)
$badge = $palette[(Get-Random -Minimum 0 -Maximum $palette.Count)]
$bmps = New-Object System.Collections.Generic.List[System.Drawing.Bitmap]
try {
    foreach ($s in @(16, 32, 48, 256)) { [void]$bmps.Add((New-ProceduralPet $s $badge)) }
    $shellIconDir = Join-Path $env:LOCALAPPDATA 'KunPet'
    if (-not (Test-Path -LiteralPath $shellIconDir)) {
        New-Item -ItemType Directory -Path $shellIconDir -Force | Out-Null
    }
    Get-ChildItem -LiteralPath $shellIconDir -Filter 'kun-pet-*.ico' -File -ErrorAction SilentlyContinue |
        Remove-Item -Force -ErrorAction SilentlyContinue
    $shellIco = Join-Path $shellIconDir ('kun-pet-{0}.ico' -f (Get-Date -Format 'yyyyMMddHHmmss'))
    Save-PetIco $bmps $shellIco
} finally {
    foreach ($bmp in $bmps) { if ($bmp) { $bmp.Dispose() } }
}

$lnkPath = Join-Path $DesktopDir '启动桌宠.lnk'
$wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
[PetLnk]::Create($lnkPath, $wscript, ('"' + $vbs + '"'), $petDir, $shellIco, 'Kun Like desktop pet')
[PetLnk]::Notify($lnkPath)
[PetLnk]::Notify($shellIco)

$old = Join-Path $DesktopDir '坤桌宠.lnk'
if (Test-Path -LiteralPath $old) {
    try {
        $r = [PetLnk]::Read($old)
        if ($r.IndexOf($vbs, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            Remove-Item -LiteralPath $old -Force
            [PetLnk]::Notify($old)
        }
    } catch { }
}

$readback = [PetLnk]::Read($lnkPath)
if ($readback.IndexOf('\KunPet\kun-pet-', [StringComparison]::OrdinalIgnoreCase) -lt 0) {
    throw 'icon path was not stored in the shortcut'
}
Write-Output ("created=" + $lnkPath)
Write-Output 'RESULT builtin'
Write-Output 'VERIFY=PASS'
