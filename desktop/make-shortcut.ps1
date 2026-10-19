# Kun Like Pet - create or refresh the desktop launcher shortcut.
# Uses IShellLink directly. WScript.Shell Save() silently dropped IconLocation
# on this machine, so the shortcut kept the blank script-file icon.
#
# The icon file that Explorer actually loads is copied to %LOCALAPPDATA%\KunPet.
# An otherwise valid .ico that stays inside this project folder (under
# default-workspace) is ignored by the shortcut icon loader and the shortcut
# falls back to the blank script icon. A short path outside that folder loads.
#
# -Ensure is what install and startup call: create the shortcut if it is
# missing, and give an older blank shortcut a pet icon once. A shortcut that
# already points at a KunPet icon is left alone.
param(
    [string]$PetDir = $PSScriptRoot,
    [string]$Name   = '启动桌宠',
    [switch]$StartMenu,
    [switch]$Ensure
)
$ErrorActionPreference = 'Stop'

$petDir = (Resolve-Path -LiteralPath $PetDir).Path
$vbs = Join-Path $petDir '启动桌宠.vbs'
if (-not (Test-Path -LiteralPath $vbs)) { throw "launcher not found: $vbs" }

$code = @'
using System;
using System.Runtime.InteropServices;
using System.Drawing;
using System.Drawing.Imaging;

[ComImport, Guid("00021401-0000-0000-C000-000000000046")]
public class CShellLink { }

[ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("000214F9-0000-0000-C000-000000000046")]
public interface IShellLinkW
{
    void GetPath([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder pszFile, int cch, IntPtr pfd, uint fFlags);
    void GetIDList(out IntPtr ppidl);
    void SetIDList(IntPtr pidl);
    void GetDescription([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder pszName, int cch);
    void SetDescription([MarshalAs(UnmanagedType.LPWStr)] string pszName);
    void GetWorkingDirectory([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder pszDir, int cch);
    void SetWorkingDirectory([MarshalAs(UnmanagedType.LPWStr)] string pszDir);
    void GetArguments([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder pszArgs, int cch);
    void SetArguments([MarshalAs(UnmanagedType.LPWStr)] string pszArgs);
    void GetHotkey(out short pwHotkey);
    void SetHotkey(short wHotkey);
    void GetShowCmd(out int piShowCmd);
    void SetShowCmd(int iShowCmd);
    void GetIconLocation([Out, MarshalAs(UnmanagedType.LPWStr)] System.Text.StringBuilder pszIconPath, int cch, out int piIcon);
    void SetIconLocation([MarshalAs(UnmanagedType.LPWStr)] string pszIconPath, int iIcon);
    void SetRelativePath([MarshalAs(UnmanagedType.LPWStr)] string pszPathRel, uint dwReserved);
    void Resolve(IntPtr hwnd, uint fFlags);
    void SetPath([MarshalAs(UnmanagedType.LPWStr)] string pszFile);
}

[ComImport, InterfaceType(ComInterfaceType.InterfaceIsIUnknown), Guid("0000010b-0000-0000-C000-000000000046")]
public interface IPersistFile
{
    void GetClassID(out Guid pClassID);
    [PreserveSig] int IsDirty();
    void Load([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, uint dwMode);
    void Save([MarshalAs(UnmanagedType.LPWStr)] string pszFileName, [MarshalAs(UnmanagedType.Bool)] bool fRemember);
    void SaveCompleted([MarshalAs(UnmanagedType.LPWStr)] string pszFileName);
    void GetCurFile([MarshalAs(UnmanagedType.LPWStr)] out string ppszFileName);
}

public static class Lnk
{
    [DllImport("shell32.dll")]
    static extern void SHChangeNotify(uint wEventId, uint uFlags, IntPtr dwItem1, IntPtr dwItem2);

    public static void Create(string lnkPath, string target, string args, string workDir, string iconPath, string desc)
    {
        IShellLinkW link = (IShellLinkW)new CShellLink();
        link.SetPath(target);
        link.SetArguments(args);
        link.SetWorkingDirectory(workDir);
        link.SetDescription(desc);
        link.SetIconLocation(iconPath, 0);
        link.SetShowCmd(1);
        ((IPersistFile)link).Save(lnkPath, true);
        Marshal.ReleaseComObject(link);
    }

    public static string Read(string lnkPath)
    {
        IShellLinkW link = (IShellLinkW)new CShellLink();
        ((IPersistFile)link).Load(lnkPath, 0);
        var sbT = new System.Text.StringBuilder(1024); link.GetPath(sbT, 1024, IntPtr.Zero, 0);
        var sbA = new System.Text.StringBuilder(1024); link.GetArguments(sbA, 1024);
        var sbW = new System.Text.StringBuilder(1024); link.GetWorkingDirectory(sbW, 1024);
        var sbI = new System.Text.StringBuilder(1024); int idx; link.GetIconLocation(sbI, 1024, out idx);
        var sbD = new System.Text.StringBuilder(1024); link.GetDescription(sbD, 1024);
        Marshal.ReleaseComObject(link);
        return "TargetPath       : " + sbT + "\nArguments        : " + sbA + "\nWorkingDirectory : " + sbW
             + "\nIconLocation     : " + sbI + "," + idx + "\nDescription      : " + sbD;
    }

    public static void Notify(string path)
    {
        IntPtr p = Marshal.StringToCoTaskMemUni(path);
        try { SHChangeNotify(0x00002000, 0x0005, p, IntPtr.Zero); }
        finally { Marshal.FreeCoTaskMem(p); }
    }
}

public static class ShellShot
{
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    public struct SHFILEINFO
    {
        public IntPtr hIcon;
        public int iIcon;
        public uint dwAttributes;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szDisplayName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 80)] public string szTypeName;
    }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr SHGetFileInfo(string pszPath, uint dwFileAttributes, ref SHFILEINFO psfi, uint cbFileInfo, uint uFlags);

    public static int Save(string lnkPath, string pngPath)
    {
        SHFILEINFO fi = new SHFILEINFO();
        SHGetFileInfo(lnkPath, 0, ref fi, (uint)Marshal.SizeOf(typeof(SHFILEINFO)), 0x100);
        if (fi.hIcon == IntPtr.Zero) return 0;
        using (Icon ic = Icon.FromHandle(fi.hIcon))
        using (Bitmap bmp = ic.ToBitmap())
        {
            bmp.Save(pngPath, ImageFormat.Png);
        }
        return fi.iIcon;
    }
}
'@
if (-not ('Lnk' -as [type])) {
    Add-Type -TypeDefinition $code -ReferencedAssemblies System.Drawing -Language CSharp
}

function Remove-LegacyShortcut([string]$desktopDir) {
    if ($Name -eq '坤桌宠') { return }
    $old = Join-Path $desktopDir '坤桌宠.lnk'
    if (-not (Test-Path -LiteralPath $old)) { return }
    try {
        $r = [Lnk]::Read($old)
        if ($r.IndexOf($vbs, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
            Remove-Item -LiteralPath $old -Force
            [Lnk]::Notify($old)
            Write-Output ("removed-legacy=" + $old)
        }
    } catch { }
}

$desktopDir = [Environment]::GetFolderPath('Desktop')
$primaryLnk = Join-Path $desktopDir ($Name + '.lnk')
if ($Ensure -and (Test-Path -LiteralPath $primaryLnk)) {
    $existing = ''
    try { $existing = [Lnk]::Read($primaryLnk) } catch { }
    $hasPetIcon = $existing.IndexOf('\KunPet\kun-pet-', [StringComparison]::OrdinalIgnoreCase) -ge 0
    $pointsHere = $existing.IndexOf($vbs, [StringComparison]::OrdinalIgnoreCase) -ge 0
    if ($hasPetIcon -and $pointsHere) {
        Remove-LegacyShortcut $desktopDir
        Write-Output 'RESULT kept'
        Write-Output 'VERIFY=PASS'
        exit 0
    }
}

$iconScript = Join-Path $petDir 'make-icon.ps1'
if (-not (Test-Path -LiteralPath $iconScript)) { throw "icon script not found: $iconScript" }
& $iconScript -OutDir (Join-Path $petDir 'assets')
$ico = Join-Path $petDir 'assets\kun-pet-icon.ico'
if (-not (Test-Path -LiteralPath $ico)) { throw "icon not found: $ico" }

# Explorer will not use an icon that lives in this project directory. Keep the
# preview next to the scripts, and give the shortcut a fresh copy outside it.
$shellIconDir = Join-Path $env:LOCALAPPDATA 'KunPet'
if (-not (Test-Path -LiteralPath $shellIconDir)) { New-Item -ItemType Directory -Path $shellIconDir -Force | Out-Null }
Get-ChildItem -LiteralPath $shellIconDir -Filter 'kun-pet-*.ico' -File -ErrorAction SilentlyContinue |
    Remove-Item -Force -ErrorAction SilentlyContinue
$shellIco = Join-Path $shellIconDir ('kun-pet-{0}.ico' -f (Get-Date -Format 'yyyyMMddHHmmss'))
Copy-Item -LiteralPath $ico -Destination $shellIco -Force

$targets = @([Environment]::GetFolderPath('Desktop'))
if ($StartMenu) { $targets += (Join-Path ([Environment]::GetFolderPath('Programs')) 'Kun Pet') }

$wscript = Join-Path $env:WINDIR 'System32\wscript.exe'
$desktopLnk = $null
foreach ($t in $targets) {
    if (-not (Test-Path -LiteralPath $t)) { New-Item -ItemType Directory -Path $t -Force | Out-Null }
    $lnkPath = Join-Path $t ($Name + '.lnk')
    [Lnk]::Create($lnkPath, $wscript, ('"' + $vbs + '"'), $petDir, $shellIco, 'Kun Like desktop pet')
    [Lnk]::Notify($lnkPath)
    [Lnk]::Notify($shellIco)
    Write-Output ("created=" + $lnkPath)
    if (-not $desktopLnk) { $desktopLnk = $lnkPath }
}

$readback = [Lnk]::Read($desktopLnk)
Write-Output $readback
if ($readback -notlike '*\KunPet\kun-pet-*') { throw 'icon path was not stored in the shortcut' }

$shot = Join-Path $env:TEMP 'kun-pet-shortcut-shell.png'
$iconIndex = [ShellShot]::Save($desktopLnk, $shot)
Write-Output ("shell-index=$iconIndex")
if ($iconIndex -eq 0) { throw 'Explorer ignored the pet icon and kept the blank script icon' }
$img = [System.Drawing.Bitmap]::FromFile($shot)
try {
    $rect = New-Object System.Drawing.Rectangle 0, 0, $img.Width, $img.Height
    $data = $img.LockBits($rect, [System.Drawing.Imaging.ImageLockMode]::ReadOnly, [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    try {
        $stride = $data.Stride
        $pixels = New-Object byte[] ($stride * $img.Height)
        [System.Runtime.InteropServices.Marshal]::Copy($data.Scan0, $pixels, 0, $pixels.Length)
    } finally { $img.UnlockBits($data) }
    $colored = 0
    for ($y = 0; $y -lt $img.Height; $y += 2) {
        $row = $y * $stride
        for ($x = 0; $x -lt $img.Width; $x += 2) {
            $i = $row + ($x * 4)
            $b = $pixels[$i]; $g = $pixels[$i + 1]; $r = $pixels[$i + 2]
            $max = [Math]::Max($r, [Math]::Max($g, $b))
            $min = [Math]::Min($r, [Math]::Min($g, $b))
            # FromHbitmap drops alpha, so a blank document is almost all white/gray
            # and a pet icon is full of saturated pixels.
            if ($max -gt 48 -and ($max - $min) -gt 28) { $colored++ }
        }
    }
} finally { $img.Dispose() }

Write-Output ("shell-colored=$colored")
# 32px shortcut icons only have a few dozen saturated samples. A blank
# document icon stays near zero.
if ($colored -lt 8) { throw "Explorer still drew a generic icon (colored samples=$colored)" }
Remove-Item -LiteralPath $shot -Force -ErrorAction SilentlyContinue

Remove-LegacyShortcut $desktopDir

$metaPath = Join-Path $petDir 'assets\kun-pet-icon.json'
$petId = 'generated'
if (Test-Path -LiteralPath $metaPath) {
    try {
        $m = Get-Content -LiteralPath $metaPath -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($m.id) { $petId = [string]$m.id }
    } catch { }
}
Write-Output ("RESULT pet={0}" -f $petId)
Write-Output 'VERIFY=PASS'
