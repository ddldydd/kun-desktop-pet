# 桌面快捷方式端到端验证（Windows 实机，不接 CI）：
#   install.ps1 安装后应在桌面创建「启动桌宠.lnk」→ 幂等 → -NoShortcut 跳过 → uninstall 删除。
# 手法：用 -Target 临时目录 + -SkipAssets + 不带 -Start，全程不碰真实安装目录与真实素材。
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\desktop\tests\test-shortcut.ps1
$ErrorActionPreference = 'Continue'
$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
$repo = Split-Path -Parent (Split-Path -Parent $here)
$install = Join-Path $repo 'install.ps1'
$uninstall = Join-Path $repo 'uninstall.ps1'

function Get-TestTempRoot {
    foreach ($try in @({ [IO.Path]::GetTempPath() }, { $env:TEMP }, { $env:TMP }, { $env:TMPDIR })) {
        try { $v = & $try; if ($v -and ([string]$v).Trim()) { return ([string]$v).Trim() } } catch { }
    }
    return (Get-Location).Path
}

$script:pass = 0
$script:fail = 0
function CheckTrue([string]$name, $c) {
    if ($c) { $script:pass++; Write-Host ("  [ok]   " + $name) -ForegroundColor Green }
    else { $script:fail++; Write-Host ("  [FAIL] " + $name) -ForegroundColor Red }
}

# 用 Start-Process 同步调用脚本：本宿主沙箱下 & powershell.exe -File 不同步
# （$LASTEXITCODE 为空、输出丢失、检查时点太早），必须 -Wait 并断言 ExitCode。
function Run-PS([string]$file, [string[]]$argList) {
    $proc = Start-Process -FilePath 'powershell.exe' -Wait -NoNewWindow -PassThru `
        -ArgumentList (@('-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $file) + $argList)
    if ($proc.ExitCode -ne 0) {
        Write-Host ("  子进程退出码异常: " + $proc.ExitCode + "  (" + $file + ")") -ForegroundColor Red
        $script:fail++
    }
    return $proc.ExitCode
}

$desktop = [Environment]::GetFolderPath('Desktop')
$lnkPath = Join-Path $desktop '启动桌宠.lnk'
$hadBefore = Test-Path -LiteralPath $lnkPath
if ($hadBefore) {
    $backup = "$lnkPath.bak-" + [guid]::NewGuid().ToString('N').Substring(0, 6)
    Copy-Item -LiteralPath $lnkPath -Destination $backup -Force
    Write-Host ("检测到已存在的快捷方式，先备份: " + $backup)
}
Remove-Item -LiteralPath $lnkPath -Force -ErrorAction SilentlyContinue

$tmp = Join-Path (Get-TestTempRoot) ('kun-shortcut-test-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
Write-Host ""
Write-Host "=== 1) 全新安装（临时目录 + -SkipAssets，不带 -Start）==="
[void](Run-PS $install @('-Target', $tmp, '-SkipAssets'))

Write-Host ""
Write-Host "=== 读回快捷方式 ==="
if (-not (Test-Path -LiteralPath $lnkPath)) {
    CheckTrue '桌面出现 启动桌宠.lnk' $false
} else {
    CheckTrue '桌面出现 启动桌宠.lnk' $true
    $wsh = New-Object -ComObject WScript.Shell
    $lnk = $wsh.CreateShortcut($lnkPath)
    $expArgs = '"' + (Join-Path $tmp '启动桌宠.vbs') + '"'
    Write-Host ("  TargetPath      : " + $lnk.TargetPath)
    Write-Host ("  Arguments       : " + $lnk.Arguments)
    Write-Host ("  WorkingDirectory: " + $lnk.WorkingDirectory)
    # WScript.Shell 的 Save() 会把 'wscript.exe' 规范化成全路径
    # （如 C:\WINDOWS\system32\wscript.exe），所以只按路径末尾匹配。
    CheckTrue 'TargetPath 指向 wscript.exe' ($lnk.TargetPath -and ($lnk.TargetPath -like '*\wscript.exe'))
    CheckTrue 'Arguments = 引号包裹的 vbs 路径' ($lnk.Arguments -eq $expArgs)
    CheckTrue 'WorkingDirectory = 安装目录' ($lnk.WorkingDirectory.TrimEnd('\') -eq $tmp.TrimEnd('\'))
    CheckTrue 'IconLocation 指向 KunPet 宠物图标' ([string]$lnk.IconLocation -like '*\KunPet\kun-pet-*')
}

Write-Host ""
Write-Host "=== 2) 再装一次（幂等）==="
[void](Run-PS $install @('-Target', $tmp, '-SkipAssets'))
$count = @(Get-ChildItem -LiteralPath $desktop -Filter '启动桌宠.lnk' -ErrorAction SilentlyContinue).Count
CheckTrue '桌面上只有一个 启动桌宠.lnk' ($count -eq 1)
if (Test-Path -LiteralPath $lnkPath) {
    $wsh = New-Object -ComObject WScript.Shell
    $lnk = $wsh.CreateShortcut($lnkPath)
    CheckTrue '重复安装后仍指向正确' ($lnk.Arguments -eq $expArgs)
    CheckTrue '重复安装后仍是宠物图标' ([string]$lnk.IconLocation -like '*\KunPet\kun-pet-*')
}

Write-Host ""
Write-Host "=== 3) -NoShortcut 不创建 ==="
Remove-Item -LiteralPath $lnkPath -Force -ErrorAction SilentlyContinue
[void](Run-PS $install @('-Target', $tmp, '-SkipAssets', '-NoShortcut'))
CheckTrue '-NoShortcut 后不创建快捷方式' (-not (Test-Path -LiteralPath $lnkPath))

Write-Host ""
Write-Host "=== 4) 卸载后快捷方式消失 ==="
[void](Run-PS $install @('-Target', $tmp, '-SkipAssets'))   # 先把快捷方式建回来
if (-not (Test-Path -LiteralPath $lnkPath)) { CheckTrue '卸载前快捷方式存在' $false }
[void](Run-PS $uninstall @('-Target', $tmp, '-KeepFiles'))
CheckTrue '卸载后快捷方式消失' (-not (Test-Path -LiteralPath $lnkPath))

Write-Host ""
Write-Host "=== 清理 ==="
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue
if ($hadBefore) {
    Copy-Item -LiteralPath $backup -Destination $lnkPath -Force
    Remove-Item -LiteralPath $backup -Force -ErrorAction SilentlyContinue
    Write-Host '已还原安装前的快捷方式。'
} else {
    Remove-Item -LiteralPath $lnkPath -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host ("通过 " + $script:pass + " / 失败 " + $script:fail)
if ($script:fail -gt 0) { exit 1 } else { exit 0 }
