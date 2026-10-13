<#
  Kun Like 桌宠 —— 一键安装脚本

  做的事：
    1. 把 desktop/ 下的桌宠本体复制到安装目录（默认 %USERPROFILE%\kun-desktop-pet）
    2. 把 assets/pets/ 下的形象素材装到 ~/.petdex/pets/（已存在则不覆盖）
    3. 可选：安装 DSH 插件 @local/kun-pet（需要 -InstallPlugin）
    4. 可选：安装 pi 扩展（需要 -InstallPiExtension），让桌宠也能跟随 pi coding agent
    5. 可选：注册开机自启（需要 -Autostart）

  用法：
    powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1
    powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Autostart -InstallPlugin
    powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -InstallPiExtension
    powershell -NoProfile -ExecutionPolicy Bypass -File .\install.ps1 -Target D:\pets\kun -Start

  说明：本脚本只用 Windows 自带的 PowerShell 5.1 功能，不依赖任何第三方模块。
#>
[CmdletBinding()]
param(
    # 桌宠装到哪（默认用户目录下，避免路径里有空格/权限问题）
    [string]$Target = (Join-Path $env:USERPROFILE 'kun-desktop-pet'),

    # 不安装形象素材（用桌宠内置的矢量形象）
    [switch]$SkipAssets,

    # 安装 DSH 插件 @local/kun-pet
    [switch]$InstallPlugin,

    # 插件装到哪个 DSH profile
    [string]$Profile = 'desktop',

    # 安装 pi coding agent 扩展（让桌宠能收到「pi 正在等你确认」等精确状态）
    [switch]$InstallPiExtension,

    # 注册开机自启
    [switch]$Autostart,

    # 覆盖已存在的桌宠文件（永远不会覆盖 kun-pet-settings.json）
    [switch]$Force,

    # 装完立刻启动桌宠
    [switch]$Start
)

$ErrorActionPreference = 'Stop'

function Info([string]$m) { Write-Host ("  " + $m) }
function Ok([string]$m) { Write-Host ("[ok] " + $m) -ForegroundColor Green }
function Warn([string]$m) { Write-Host ("[!] " + $m) -ForegroundColor Yellow }
function Die([string]$m) { Write-Host ("[x] " + $m) -ForegroundColor Red; exit 1 }

Write-Host ""
Write-Host "Kun Like 桌宠 · 安装" -ForegroundColor Cyan
Write-Host "====================" -ForegroundColor Cyan

# ---------------- 0. 定位仓库根目录 ----------------
$repo = $PSScriptRoot
if (-not $repo) { $repo = (Get-Location).Path }

$srcDesktop = Join-Path $repo 'desktop'
$srcAssets = Join-Path $repo 'assets\pets'
$srcPlugin = Join-Path $repo 'plugin'
$srcAuto = Join-Path $repo 'tools\autostart'
$srcPiExt = Join-Path $repo 'pi-extension'

if (-not (Test-Path (Join-Path $srcDesktop 'kun-pet-desktop.ps1'))) {
    Die ("没找到 desktop\kun-pet-desktop.ps1 —— 请在仓库根目录运行本脚本（当前: " + $repo + "）")
}

# 只支持 Windows：桌宠是 WPF 程序
if ($env:OS -ne 'Windows_NT') { Die '本桌宠只支持 Windows。' }

# 目标目录若就是仓库的 desktop/，直接拒绝，避免把仓库改乱
$targetFull = $null
try { $targetFull = [IO.Path]::GetFullPath($Target) } catch { Die ("安装路径不合法: " + $Target) }
if ($targetFull.TrimEnd('\') -eq ([IO.Path]::GetFullPath($srcDesktop)).TrimEnd('\')) {
    Die '安装目录不能是仓库里的 desktop\ 目录，请换一个路径（例如 %USERPROFILE%\kun-desktop-pet）。'
}

Write-Host ""
Info ("仓库目录 : " + $repo)
Info ("安装到   : " + $targetFull)

# ---------------- 1. 复制桌宠本体 ----------------
Write-Host ""
Write-Host "1) 安装桌宠本体" -ForegroundColor Cyan

if (-not (Test-Path $targetFull)) {
    New-Item -ItemType Directory -Force -Path $targetFull | Out-Null
    Ok ("已创建目录 " + $targetFull)
}

# kun-pet-settings.json 是你的配置（形象/位置/大小），任何情况下都不覆盖
$neverOverwrite = @('kun-pet-settings.json')

$copied = 0
foreach ($f in Get-ChildItem -Path $srcDesktop -File) {
    $dest = Join-Path $targetFull $f.Name
    if ((Test-Path $dest) -and -not $Force) {
        Info ("跳过已存在: " + $f.Name + "（要覆盖请加 -Force）")
        continue
    }
    if ((Test-Path $dest) -and ($neverOverwrite -contains $f.Name)) {
        Info ("保留你的配置: " + $f.Name)
        continue
    }
    Copy-Item -LiteralPath $f.FullName -Destination $dest -Force
    $copied++
}
Ok ("桌宠文件已就位（复制 " + $copied + " 个）")

$petScript = Join-Path $targetFull 'kun-pet-desktop.ps1'
$petVbs = Join-Path $targetFull '启动桌宠.vbs'
if (-not (Test-Path $petVbs)) { $petVbs = Join-Path $targetFull 'start-pet.vbs' }

# ---------------- 2. 形象素材 ----------------
Write-Host ""
Write-Host "2) 安装形象素材" -ForegroundColor Cyan

if ($SkipAssets) {
    Info '已按 -SkipAssets 跳过（桌宠会用内置矢量形象）'
} elseif (-not (Test-Path $srcAssets)) {
    Warn ("仓库里没有 assets\pets 目录，跳过")
} else {
    $petdexRoot = Join-Path $env:USERPROFILE '.petdex\pets'
    if (-not (Test-Path $petdexRoot)) { New-Item -ItemType Directory -Force -Path $petdexRoot | Out-Null }

    foreach ($petDir in Get-ChildItem -Path $srcAssets -Directory) {
        $dest = Join-Path $petdexRoot $petDir.Name
        if ((Test-Path $dest) -and -not $Force) {
            Info ("已存在，未改动: " + $petDir.Name)
            continue
        }
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
        Copy-Item -Path (Join-Path $petDir.FullName '*') -Destination $dest -Recurse -Force
        Ok ("素材已装: " + $petDir.Name + "  ->  " + $dest)
    }
    Info ("素材目录: " + $petdexRoot)
    Info '（桌面右键菜单 → 宠物，即可切换形象）'
}

# ---------------- 3. DSH 插件（可选） ----------------
Write-Host ""
Write-Host "3) DSH 插件" -ForegroundColor Cyan

if (-not $InstallPlugin) {
    Info '未安装（需要时加 -InstallPlugin）。'
    Info '装了它才有「任务进展气泡」与「桌宠上直接同意/拒绝」。'
} else {
    $profileDir = Join-Path $env:USERPROFILE ('.dsh\profiles\' + $Profile)
    if (-not (Test-Path $profileDir)) {
        Warn ("profile 目录不存在: " + $profileDir)
        Warn '先启动一次 DSH 让它生成 profile，或换 -Profile <名字>。插件未安装。'
    } else {
        $dest = Join-Path $profileDir 'node_modules\@local\kun-pet'
        New-Item -ItemType Directory -Force -Path $dest | Out-Null
        foreach ($f in @('index.js', 'client.js', 'package.json')) {
            Copy-Item -LiteralPath (Join-Path $srcPlugin $f) -Destination (Join-Path $dest $f) -Force
        }
        Ok ("插件文件已装: " + $dest)

        # 把 insert 追加到 profile 的 cordis.patch.yml（已存在则不动）
        $patch = Join-Path $profileDir 'cordis.patch.yml'
        $insertBlock = @(
            '',
            '# ---- Kun Like 桌宠（@local/kun-pet）----',
            '- insert:',
            '    - id: kun-pet',
            "      name: '@local/kun-pet'",
            '      config: {}'
        ) -join "`n"

        $patchText = ''
        if (Test-Path $patch) { $patchText = [IO.File]::ReadAllText($patch, [Text.Encoding]::UTF8) }

        if ($patchText -match '(?m)^\s*name:\s*[''"]?@local/kun-pet') {
            Info 'cordis.patch.yml 里已经有 kun-pet 了，不重复添加。'
        } else {
            if (Test-Path $patch) {
                $bak = $patch + '.bak-' + (Get-Date -Format 'yyyyMMdd-HHmmss')
                Copy-Item -LiteralPath $patch -Destination $bak -Force
                Info ("已备份原配置: " + (Split-Path -Leaf $bak))
            }
            $newText = $patchText
            if ($newText.Length -gt 0 -and -not $newText.EndsWith("`n")) { $newText += "`n" }
            $newText += $insertBlock + "`n"
            [IO.File]::WriteAllText($patch, $newText, (New-Object Text.UTF8Encoding($false)))
            Ok '已把 kun-pet 写进 cordis.patch.yml'
        }

        Warn 'profile 只在 DSH 启动时读取一次：请重启一次 DSH，插件才会生效。'
        Info '重启后可自查: Invoke-RestMethod http://127.0.0.1:19387/kun-pet/state'
    }
}

# ---------------- 3.5 pi coding agent 扩展（可选） ----------------
Write-Host ""
Write-Host "3.5) pi coding agent 扩展" -ForegroundColor Cyan

if (-not $InstallPiExtension) {
    Info '未安装（需要时加 -InstallPiExtension）。'
    Info '不装也能跟随 pi：桌宠会只读 pi 的会话文件，覆盖「在干活 / 收尾 / 出错」。'
    Info '装了才补上「pi 正在等你确认」——这一项会话文件里没有，只有扩展能提供。'
} else {
    # pi 的扩展目录：~/.pi/agent/extensions/（与 model-config.ts 等扩展同目录）
    $piExtDir = Join-Path $env:USERPROFILE '.pi\agent\extensions'
    $piAgentDir = Join-Path $env:USERPROFILE '.pi\agent'

    if (-not (Test-Path $srcPiExt)) {
        Warn ("仓库里没有 pi-extension 目录，跳过: " + $srcPiExt)
    } elseif (-not (Test-Path $piAgentDir)) {
        Warn ("没找到 pi 的配置目录: " + $piAgentDir)
        Warn '先装好 pi 并至少运行一次（会生成 ~/.pi/agent），再回来执行本步。扩展未安装。'
    } else {
        if (-not (Test-Path $piExtDir)) { New-Item -ItemType Directory -Force -Path $piExtDir | Out-Null }
        $extDest = Join-Path $piExtDir 'kun-pet.ts'
        if ((Test-Path $extDest) -and -not $Force) {
            Warn ("已存在，未覆盖: " + $extDest + "（要覆盖请加 -Force）")
        } else {
            Copy-Item -LiteralPath (Join-Path $srcPiExt 'kun-pet.ts') -Destination $extDest -Force
            Ok ("pi 扩展已装: " + $extDest)
        }
        Info '在 pi 里执行 /reload 让扩展生效（或重开 pi）。'
        Info ('状态文件会写在: ' + (Join-Path $piAgentDir 'kun-pet-state.json'))
        Info '桌宠日志里出现 "pi channel: ext" 就说明扩展通道生效了。'
        Info '卸载：删掉上面那个 kun-pet.ts 即可（桌宠会自动退回会话文件通道）。'
    }
}

# ---------------- 4. 开机自启（可选） ----------------
Write-Host ""
Write-Host "4) 开机自启" -ForegroundColor Cyan

if (-not $Autostart) {
    Info '未注册（需要时加 -Autostart，或手动把启动器放进 shell:startup）。'
} else {
    $startup = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\Startup'
    if (-not (Test-Path $startup)) { New-Item -ItemType Directory -Force -Path $startup | Out-Null }

    # 探测脚本：原样复制（纯 ASCII）
    Copy-Item -LiteralPath (Join-Path $srcAuto 'KunPet-pet-running.ps1') `
              -Destination (Join-Path $startup 'KunPet-pet-running.ps1') -Force

    # 自启入口：把桌宠启动器的绝对路径填进模板
    $tpl = [IO.File]::ReadAllText((Join-Path $srcAuto 'KunPet-autostart.cmd'), [Text.Encoding]::ASCII)
    $cmd = $tpl.Replace('{{PET_VBS}}', $petVbs)
    [IO.File]::WriteAllText((Join-Path $startup 'KunPet-autostart.cmd'), $cmd, (New-Object Text.ASCIIEncoding))
    Ok ("已注册开机自启: " + $startup)
    Info '（登录后自动出现；删掉 KunPet-autostart.cmd 即可关闭自启）'
}

# ---------------- 5. 启动 ----------------
Write-Host ""
if ($Start) {
    Write-Host "5) 启动桌宠" -ForegroundColor Cyan
    try {
        Start-Process -FilePath 'wscript.exe' -ArgumentList '//nologo', ('"' + $petVbs + '"')
        Ok '桌宠已启动（没有立刻看到属正常，可能被其他窗口压住：按 Win+D 或右键菜单「重置位置」）'
    } catch {
        Warn ("启动失败: " + $_.Exception.Message)
        Info ('请手动双击: ' + $petVbs)
    }
    Write-Host ""
}

Write-Host "安装完成 ✓" -ForegroundColor Green
Write-Host ""
Write-Host ("  启动方式 : 双击 " + $petVbs) -ForegroundColor Gray
Write-Host ("  配置文件 : " + (Join-Path $targetFull 'kun-pet-settings.json')) -ForegroundColor Gray
Write-Host ("  日志     : " + (Join-Path $targetFull 'kun-pet-desktop.log')) -ForegroundColor Gray
Write-Host ("  卸载     : powershell -NoProfile -ExecutionPolicy Bypass -File .\uninstall.ps1") -ForegroundColor Gray
Write-Host ""
