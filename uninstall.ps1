<#
  Kun Like 桌宠 —— 卸载脚本

  默认只做最保守的两件事：
    1. 结束**安装目录里**正在运行的桌宠进程
    2. 删除安装目录（默认 %USERPROFILE%\kun-desktop-pet）

  其他东西默认不动，需要时显式加开关：
    -RemoveAssets      删掉 ~/.petdex/pets 下由本仓库自带的素材（ikkun / haiyue-classic）
    -RemovePlugin      删掉 DSH profile 里的 @local/kun-pet 插件与 cordis.patch.yml 里的 insert
    -RemoveAutostart   删掉「启动」文件夹里的 KunPet-autostart.cmd 与 KunPet-pet-running.ps1
    -KeepFiles         只结束进程，不删安装目录

  用法：
    powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1 -RemoveAssets -RemovePlugin -RemoveAutostart
#>
[CmdletBinding()]
param(
    [string]$Target = (Join-Path $env:USERPROFILE 'kun-desktop-pet'),
    [switch]$RemoveAssets,
    [switch]$RemovePlugin,
    [string]$Profile = 'desktop',
    [switch]$RemoveAutostart,
    [switch]$KeepFiles
)

$ErrorActionPreference = 'Continue'

function Info([string]$m) { Write-Host ("  " + $m) }
function Ok([string]$m) { Write-Host ("[ok] " + $m) -ForegroundColor Green }
function Warn([string]$m) { Write-Host ("[!] " + $m) -ForegroundColor Yellow }

Write-Host ""
Write-Host "Kun Like 桌宠 · 卸载" -ForegroundColor Cyan
Write-Host "====================" -ForegroundColor Cyan

$targetFull = $null
try { $targetFull = [IO.Path]::GetFullPath($Target) } catch { Warn ("安装路径不合法: " + $Target) }

# ---------------- 1. 结束进程 ----------------
# 只结束**脚本位于本次要卸载的目录**里的那只桌宠。
# 早期版本只要命令行提到 kun-pet 就杀，会误伤别的安装目录里正在跑的桌宠，
# 所以这里必须比对命令行里的脚本绝对路径。
Write-Host ""
Write-Host "1) 结束桌宠进程" -ForegroundColor Cyan

$scriptPath = $null
if ($targetFull) { $scriptPath = Join-Path $targetFull 'kun-pet-desktop.ps1' }

$killed = 0
$skipped = 0
$procs = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
    Where-Object { $_.CommandLine -and $_.CommandLine -match 'kun-pet-desktop\.ps1' })

foreach ($p in $procs) {
    $mine = $true
    if ($scriptPath) {
        # 命令行里应出现本安装目录下的脚本绝对路径（启动器与 -File 两种方式都会带上）。
        $mine = $p.CommandLine.IndexOf($scriptPath, [StringComparison]::OrdinalIgnoreCase) -ge 0
        if (-not $mine) {
            # 命令行里带的是**别的** kun-pet-desktop.ps1 路径 => 不是我们要动的这只。
            # 只有连路径都提取不到时才按本目录处理。
            $other = [regex]::Matches($p.CommandLine, '[A-Za-z]:\\[^"'']*kun-pet-desktop\.ps1')
            if ($other.Count -eq 0) { $mine = $true }
        }
    }
    if ($mine) {
        try { Stop-Process -Id $p.ProcessId -Force -ErrorAction Stop; $killed++ } catch { }
    } else {
        $skipped++
    }
}

if ($killed -gt 0) { Ok ("已结束 " + $killed + " 个桌宠进程") }
elseif ($skipped -gt 0) { Info '没有属于本目录的桌宠在运行' }
else { Info '没有正在运行的桌宠' }

if ($skipped -gt 0) {
    Warn ("另有 " + $skipped + " 个桌宠来自别的安装目录，未结束（请单独卸载那边）。")
}

# ---------------- 2. 安装目录 ----------------
Write-Host ""
Write-Host "2) 安装目录" -ForegroundColor Cyan
if ($KeepFiles) {
    Info '已按 -KeepFiles 保留文件'
} elseif (-not $targetFull -or -not (Test-Path $targetFull)) {
    Info ("目录不存在，跳过: " + $Target)
} else {
    # 安全校验：绝不去删看起来不像桌宠目录的东西。
    $marker = Join-Path $targetFull 'kun-pet-desktop.ps1'
    if (-not (Test-Path $marker)) {
        Warn ("该目录里没有 kun-pet-desktop.ps1，为安全起见不删除: " + $targetFull)
        Warn '确认无误后请手动删除。'
    } else {
        Remove-Item -LiteralPath $targetFull -Recurse -Force
        Ok ("已删除 " + $targetFull)
    }
}

# ---------------- 3. 形象素材 ----------------
Write-Host ""
Write-Host "3) 形象素材" -ForegroundColor Cyan
if (-not $RemoveAssets) {
    Info '未删除（需要时加 -RemoveAssets）。素材仍在 ~/.petdex/pets/'
} else {
    foreach ($slug in @('ikkun', 'haiyue-classic')) {
        $d = Join-Path $env:USERPROFILE ('.petdex\pets\' + $slug)
        if (Test-Path $d) { Remove-Item -LiteralPath $d -Recurse -Force; Ok ("已删除素材 " + $slug) }
        else { Info ("素材不存在，跳过: " + $slug) }
    }
    Info '注意：素材是第三方作品，删掉后如需再用请重新下载。'
}

# ---------------- 4. DSH 插件 ----------------
Write-Host ""
Write-Host "4) DSH 插件" -ForegroundColor Cyan
if (-not $RemovePlugin) {
    Info '未删除（需要时加 -RemovePlugin）'
} else {
    $pluginDir = Join-Path $env:USERPROFILE ('.dsh\profiles\' + $Profile + '\node_modules\@local\kun-pet')
    if (Test-Path $pluginDir) { Remove-Item -LiteralPath $pluginDir -Recurse -Force; Ok ("已删除插件 " + $pluginDir) }
    else { Info ("插件不存在，跳过: " + $pluginDir) }

    $patch = Join-Path $env:USERPROFILE ('.dsh\profiles\' + $Profile + '\cordis.patch.yml')
    if (Test-Path $patch) {
        $text = [IO.File]::ReadAllText($patch, [Text.Encoding]::UTF8)
        # 删掉本仓库追加的那段 insert（连同它上面那行注释）
        $pattern = "(?s)\r?\n# ---- Kun Like 桌宠（@local/kun-pet）----\r?\n- insert:\r?\n    - id: kun-pet\r?\n      name: '@local/kun-pet'\r?\n      config: \{\}\r?\n"
        if ($text -match $pattern) {
            $bak = $patch + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
            Copy-Item -LiteralPath $patch -Destination $bak -Force
            $new = [regex]::Replace($text, $pattern, "`n")
            [IO.File]::WriteAllText($patch, $new, (New-Object Text.UTF8Encoding($false)))
            Ok '已从 cordis.patch.yml 移除 kun-pet（原文件已备份）'
        } else {
            Warn 'cordis.patch.yml 里没找到本仓库添加的那段，未改动。请手动检查是否有 kun-pet。'
        }
        Warn '重启 DSH 后生效。'
    }
}

# ---------------- 5. 开机自启 ----------------
Write-Host ""
Write-Host "5) 开机自启" -ForegroundColor Cyan
if (-not $RemoveAutostart) {
    Info '未删除（需要时加 -RemoveAutostart）'
} else {
    $startup = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
    foreach ($f in @('KunPet-autostart.cmd', 'KunPet-pet-running.ps1')) {
        $p = Join-Path $startup $f
        if (Test-Path $p) { Remove-Item -LiteralPath $p -Force; Ok ("已删除 " + $f) }
        else { Info ("不存在，跳过: " + $f) }
    }
}

Write-Host ""
Write-Host "卸载完成 ✓" -ForegroundColor Green
Write-Host ""
