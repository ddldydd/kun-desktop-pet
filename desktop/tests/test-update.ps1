# 更新模块自测：版本比较、文件筛选（防路径穿越）、内容校验、原子替换与回滚。
# 全部用本地临时目录与内存数据，**不联网**（真联网的验证另有脚本）。
#
# 用法：
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\desktop\tests\test-update.ps1
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
# 字节数组里是否存在「裸 LF」（前面不是 CR）
function Test-BytesHaveLoneLf([byte[]]$b) {
    if ($null -eq $b) { return $false }
    for ($i = 0; $i -lt $b.Length; $i++) {
        if ($b[$i] -eq 10 -and ($i -eq 0 -or $b[$i - 1] -ne 13)) { return $true }
    }
    return $false
}

$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
$desktop = Split-Path -Parent $here
$modulePath = Join-Path $desktop 'kun-pet-update.ps1'
if (-not (Test-Path -LiteralPath $modulePath)) {
    Write-Host ("找不到模块: " + $modulePath) -ForegroundColor Red
    exit 1
}
. $modulePath

Write-Host ""
Write-Host "=== 1. 版本比较 ===" -ForegroundColor Cyan
CheckTrue '2.1.0 > 2.0.0' (Test-UpdateNewer '2.0.0' '2.1.0')
CheckTrue '2.0.1 > 2.0.0' (Test-UpdateNewer '2.0.0' '2.0.1')
CheckTrue '2.10.0 > 2.9.0（按数字比，不是字符串）' (Test-UpdateNewer '2.9.0' '2.10.0')
CheckTrue '3.0.0 > 2.99.99' (Test-UpdateNewer '2.99.99' '3.0.0')
CheckTrue '相同版本不算更新' (-not (Test-UpdateNewer '2.1.0' '2.1.0'))
CheckTrue '旧版本不算更新（不降级）' (-not (Test-UpdateNewer '2.1.0' '2.0.0'))
CheckTrue '带 v 前缀可比较 v2.1.0 > 2.0.0' (Test-UpdateNewer '2.0.0' 'v2.1.0')
CheckTrue '预发布后缀可比较 2.1.0-beta.1 > 2.0.0' (Test-UpdateNewer '2.0.0' '2.1.0-beta.1')
CheckTrue '2 段 vs 3 段：2.1 > 2.0.9' (Test-UpdateNewer '2.0.9' '2.1')
CheckTrue '垃圾版本号不抛异常' ($null -ne (Test-UpdateNewer 'garbage' 'also-garbage'))
CheckTrue '本地为空 / 远端有值 → 视为更新' (Test-UpdateNewer '' '1.0.0')
CheckTrue '远端为空 → 不算更新（避免误触发）' (-not (Test-UpdateNewer '1.0.0' ''))

Write-Host ""
Write-Host "=== 2. 清单解析与白名单（防路径穿越）===" -ForegroundColor Cyan
$goodManifest = @{
    version = '2.2.0'
    notes = @('修了个 bug')
    files = @('kun-pet-desktop.ps1', 'kun-pet-update.ps1', 'version.json', '启动桌宠.vbs')
} | ConvertTo-Json -Depth 4 | ConvertFrom-Json
Check '取到版本号' (Get-ManifestVersion $goodManifest) '2.2.0'
Check '白名单内的文件全部保留' (@(Get-ManifestFiles $goodManifest).Count) 4

# 关键安全测试：清单来自网络，是不可信输入。
# 若直接拿它拼路径，'..\..\x.ps1' 就能写到桌宠目录外面。
$evilManifest = @{
    version = '9.9.9'
    files = @(
        'kun-pet-desktop.ps1',
        '..\..\evil.ps1',
        '../../evil2.ps1',
        'C:\Windows\System32\evil.ps1',
        'sub/dir/file.ps1',
        'run-me.ps1',
        'kun-pet-settings.json',
        'kun-pet-desktop.log',
        'not-in-whitelist.ps1'
    )
} | ConvertTo-Json -Depth 4 | ConvertFrom-Json
$picked = @(Get-ManifestFiles $evilManifest)
Check '只保留了白名单内的 1 个' $picked.Count 1
Check '保留的是 kun-pet-desktop.ps1' $picked[0] 'kun-pet-desktop.ps1'
CheckTrue '路径穿越 ..\..\evil.ps1 被拒' (-not ($picked -contains '..\..\evil.ps1'))
CheckTrue '绝对路径被拒' (-not ($picked -contains 'C:\Windows\System32\evil.ps1'))
CheckTrue '带子目录的路径被拒' (-not ($picked -contains 'sub/dir/file.ps1'))
CheckTrue '用户配置 kun-pet-settings.json 永远不可被更新覆盖' (-not ($picked -contains 'kun-pet-settings.json'))
CheckTrue '日志 kun-pet-desktop.log 永远不可被更新覆盖' (-not ($picked -contains 'kun-pet-desktop.log'))
Check '清单缺 files 字段 → 空列表' (@(Get-ManifestFiles (@{ version = '1.0' } | ConvertTo-Json | ConvertFrom-Json)).Count) 0
Check '清单为 $null → 空列表（不抛异常）' (@(Get-ManifestFiles $null).Count) 0

Write-Host ""
Write-Host "=== 3. 下载内容校验（挡掉 HTML 错误页 / 空响应）===" -ForegroundColor Cyan
# 正常脚本
$okScript = "function Foo { 'bar' }`nWrite-Output 'hello world this is a script'"
CheckTrue '正常 .ps1 通过' ((Test-UpdateContent 'kun-pet-desktop.ps1' $okScript).ok)
# **带 BOM 的脚本必须通过** —— 本仓库所有 .ps1 都带 BOM（CI 会强制检查），
# 从网络取回并解码后开头就是 U+FEFF；不剥掉的话 Parser 会报「意外的标记」，
# 于是**每个真实文件都被误判为不合格**、更新功能整体失效（实测踩到过）。
$bomScript = ([string][char]0xFEFF) + $okScript
CheckTrue '带 UTF-8 BOM 的 .ps1 必须通过（仓库约定就是带 BOM）' ((Test-UpdateContent 'kun-pet-desktop.ps1' $bomScript).ok)
CheckTrue '带 BOM 的 JSON 也要通过' ((Test-UpdateContent 'version.json' (([string][char]0xFEFF) + '{"version":"1.0.0"}')).ok)
# HTML 错误页：内容合法但不是脚本 —— 装上去桌宠就起不来
$html = "<!DOCTYPE html><html><body>404 Not Found</body></html>"
CheckTrue 'HTML 错误页被拒（.ps1）' (-not (Test-UpdateContent 'kun-pet-desktop.ps1' $html).ok)
CheckTrue 'HTML 错误页被拒（.vbs）' (-not (Test-UpdateContent '启动桌宠.vbs' $html).ok)
# 语法坏掉的脚本
$broken = "function Foo { `n  if (`$x -eq { `n"   # 故意坏
CheckTrue '语法错误的 .ps1 被拒' (-not (Test-UpdateContent 'kun-pet-desktop.ps1' $broken).ok)
# 空内容
CheckTrue '空内容被拒' (-not (Test-UpdateContent 'kun-pet-desktop.ps1' '').ok)
CheckTrue '过短内容被拒' (-not (Test-UpdateContent 'kun-pet-desktop.ps1' 'x').ok)
# 404 文本
CheckTrue '"404: Not Found" 被拒' (-not (Test-UpdateContent 'kun-pet-pi-source.ps1' '404: Not Found').ok)
# JSON
CheckTrue '合法 JSON 通过' ((Test-UpdateContent 'version.json' '{"version":"1.0.0"}').ok)
CheckTrue '坏 JSON 被拒' (-not (Test-UpdateContent 'version.json' '{not json').ok)
# vbs 正常
CheckTrue '正常 .vbs 通过' ((Test-UpdateContent '启动桌宠.vbs' "Option Explicit`r`nDim x").ok)

Write-Host ""
Write-Host "=== 4. 原子替换 + 备份 + 回滚（真实文件操作，临时目录）===" -ForegroundColor Cyan
$tmp = Join-Path ([System.IO.Path]::GetTempPath()) ('kun-upd-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
try {
    # 造一个「当前安装」：两个脚本 + 一个用户配置（必须不被碰）
    [IO.File]::WriteAllText((Join-Path $tmp 'kun-pet-desktop.ps1'), 'OLD DESKTOP v1', (New-Object Text.UTF8Encoding($false)))
    [IO.File]::WriteAllText((Join-Path $tmp 'kun-pet-update.ps1'), 'OLD UPDATE v1', (New-Object Text.UTF8Encoding($false)))
    $userCfg = Join-Path $tmp 'kun-pet-settings.json'
    [IO.File]::WriteAllText($userCfg, '{"wander":true}', (New-Object Text.UTF8Encoding($false)))

    $staged = @{
        'kun-pet-desktop.ps1' = @{ bytes = [Text.Encoding]::UTF8.GetBytes('NEW DESKTOP v2') }
        'kun-pet-update.ps1'  = @{ bytes = [Text.Encoding]::UTF8.GetBytes('NEW UPDATE v2') }
    }
    $r = Install-UpdateFiles $staged $tmp $tmp '2.2.0'
    CheckTrue '安装返回 ok' ($r.ok)
    Check '替换了 2 个文件' (@($r.replaced).Count) 2
    Check '新内容已生效（desktop）' ([IO.File]::ReadAllText((Join-Path $tmp 'kun-pet-desktop.ps1'))) 'NEW DESKTOP v2'
    Check '新内容已生效（update）' ([IO.File]::ReadAllText((Join-Path $tmp 'kun-pet-update.ps1'))) 'NEW UPDATE v2'
    CheckTrue '用户配置**未被改动**' (([IO.File]::ReadAllText($userCfg)) -eq '{"wander":true}')
    CheckTrue '备份目录已创建' (Test-Path -LiteralPath $r.backupDir)
    Check '备份里是旧内容' ([IO.File]::ReadAllText((Join-Path $r.backupDir 'kun-pet-desktop.ps1'))) 'OLD DESKTOP v1'
    CheckTrue '没有残留 .new-tmp' (@(Get-ChildItem $tmp -Filter '*.new-tmp' -ErrorAction SilentlyContinue).Count -eq 0)

    # 回滚验证：手工改坏，再从备份恢复（模拟失败回滚的效果）
    [IO.File]::WriteAllText((Join-Path $tmp 'kun-pet-desktop.ps1'), 'BROKEN', (New-Object Text.UTF8Encoding($false)))
    foreach ($n in @(Get-ChildItem -LiteralPath $r.backupDir -File | Select-Object -ExpandProperty Name)) {
        Copy-Item -LiteralPath (Join-Path $r.backupDir $n) -Destination (Join-Path $tmp $n) -Force
    }
    Check '从备份恢复后内容回到旧版' ([IO.File]::ReadAllText((Join-Path $tmp 'kun-pet-desktop.ps1'))) 'OLD DESKTOP v1'

    Write-Host ""
    Write-Host "=== 5. 替换失败必须自动回滚 ===" -ForegroundColor Cyan
    # 造一个「替换必然失败」的场景：第二个文件的目标名被一个**非空目录**占住
    #（File.Replace 的目标是目录时会失败）。
    # 注意：早先我用「**空**目录」注入失败，结果对空目录竟然替换成功了，
    # 测试因此假通过 —— 注入失败的手段本身必须先确认真能失败。
    $tmp2 = Join-Path ([System.IO.Path]::GetTempPath()) ('kun-upd2-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory -Force -Path $tmp2 | Out-Null
    $orig = 'ORIGINAL CONTENT'
    [IO.File]::WriteAllText((Join-Path $tmp2 'kun-pet-desktop.ps1'), $orig, (New-Object Text.UTF8Encoding($false)))
    $blockDir = Join-Path $tmp2 'kun-pet-update.ps1'
    New-Item -ItemType Directory -Force -Path $blockDir | Out-Null
    [IO.File]::WriteAllText((Join-Path $blockDir 'occupied.txt'), 'x', (New-Object Text.UTF8Encoding($false)))   # 确保非空

    $staged2 = @{
        'kun-pet-desktop.ps1' = @{ bytes = [Text.Encoding]::UTF8.GetBytes('NEW SHOULD BE ROLLED BACK') }
        'kun-pet-update.ps1'  = @{ bytes = [Text.Encoding]::UTF8.GetBytes('NEW UPDATE') }
    }
    $r2 = Install-UpdateFiles $staged2 $tmp2 $tmp2 '9.9.9'
    CheckTrue '替换失败时 ok=false' (-not $r2.ok)
    CheckTrue '错误信息非空' ([bool]$r2.error)
    CheckTrue '触发了回滚' ($r2.rolledBack)
    Check '回滚后第一个文件恢复原内容' ([IO.File]::ReadAllText((Join-Path $tmp2 'kun-pet-desktop.ps1'))) $orig
    CheckTrue '失败后没有残留 .new-tmp' (@(Get-ChildItem $tmp2 -Filter '*.new-tmp' -File -ErrorAction SilentlyContinue).Count -eq 0)
    CheckTrue '失败后没有残留 .old-tmp' (@(Get-ChildItem $tmp2 -Filter '*.old-tmp' -File -ErrorAction SilentlyContinue).Count -eq 0)
    Remove-Item $tmp2 -Recurse -Force -ErrorAction SilentlyContinue

    Write-Host ""
    Write-Host "=== 6. 边界：空 staged / 目录不存在 ===" -ForegroundColor Cyan
    $r3 = Install-UpdateFiles @{} $tmp $tmp '1.0.0'
    CheckTrue '空 staged → 失败且不报错崩溃' (-not $r3.ok)
    $r4 = Install-UpdateFiles $staged (Join-Path $tmp 'no-such-dir') $tmp '1.0.0'
    CheckTrue '目标目录不存在 → 失败' (-not $r4.ok)
} finally {
    Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
}

Write-Host ""
Write-Host "=== 7. 守护：desktop/ 下每个文件都必须能被更新到 ===" -ForegroundColor Cyan
# 这条守护来自一个真实疏漏：新增了 kun-pet-ui.ps1，却忘了把它加进更新白名单
# 与 version.json 的 files 清单 —— 结果用户更新后会得到一个「引用了没被下载的
# 文件」的桌宠。这种错只能靠自动检查发现，人眼很容易漏。
$testsDir = $PSScriptRoot
if (-not $testsDir) { $testsDir = Split-Path -Parent $MyInvocation.MyCommand.Path }
$desktopDir = Split-Path -Parent $testsDir
$vjPath = Join-Path $desktopDir 'version.json'
CheckTrue 'version.json 存在' (Test-Path -LiteralPath $vjPath)
if (Test-Path -LiteralPath $vjPath) {
    $vjText = [IO.File]::ReadAllText($vjPath, [Text.Encoding]::UTF8)
    if ($vjText.Length -gt 0 -and $vjText[0] -eq [char]0xFEFF) { $vjText = $vjText.Substring(1) }
    $vj = $null
    try { $vj = $vjText | ConvertFrom-Json } catch { }
    CheckTrue 'version.json 是合法 JSON' ($null -ne $vj)
    if ($null -ne $vj) {
        $manifestFiles = @(Get-ManifestFiles $vj)
        $onDisk = @(Get-ChildItem -LiteralPath $desktopDir -File | Select-Object -ExpandProperty Name)
        # ① 磁盘上每个文件都应出现在清单里（漏了就不会被更新）
        foreach ($f in $onDisk) {
            CheckTrue ("desktop/ 的文件在更新清单里: " + $f) ($manifestFiles -contains $f)
        }
        # ② 清单里每个文件都应真实存在（否则下载必失败 → 更新整体放弃）
        foreach ($f in $manifestFiles) {
            CheckTrue ("清单里的文件确实存在: " + $f) ($onDisk -contains $f)
        }
        # ③ 主脚本 dot-source 的模块必须都在清单里
        $mainPath = Join-Path $desktopDir 'kun-pet-desktop.ps1'
        if (Test-Path -LiteralPath $mainPath) {
            $mainText = [IO.File]::ReadAllText($mainPath, [Text.Encoding]::UTF8)
            foreach ($mod in @('kun-pet-pi-source.ps1', 'kun-pet-wander.ps1', 'kun-pet-update.ps1', 'kun-pet-ui.ps1')) {
                if ($mainText.Contains($mod)) {
                    CheckTrue ("被引用的模块在更新清单里: " + $mod) ($manifestFiles -contains $mod)
                }
            }
        }
    }
}

Write-Host ""
Write-Host "=== 9. 启动器落盘必须 CRLF（更新写入磁盘时的行尾归一）===" -ForegroundColor Cyan
# 背景：更新源是 GitHub raw，返回的是仓库里的原始字节（.vbs/.bat 在仓库里是 LF），
# 直接落盘会把启动器写成 LF —— 实测确认过（更新一次后 启动桌宠.vbs 变成 LF）。
# CI 里那条「启动器必须是 CRLF」的检查要防的就是这类破坏，所以这里钉住转换函数。
function Get-AsciiBytes([string]$s) { return [System.Text.Encoding]::ASCII.GetBytes($s) }
$lfText = "@echo off`nrem a`nrem b`n"
$crlfText = "@echo off`r`nrem a`r`n"
$bLf = Get-AsciiBytes $lfText
$bCrlf = Get-AsciiBytes $crlfText
$out1 = ConvertTo-CrlfIfLauncher 'start.bat' $bLf
CheckTrue 'LF 的 .bat 落盘前变成 CRLF' ((Test-BytesHaveLoneLf $out1) -eq $false)
CheckTrue '转换后每个 LF 多一个 CR（3 个）' ($out1.Length -eq ($bLf.Length + 3))
$out2 = ConvertTo-CrlfIfLauncher 'start.vbs' $bLf
CheckTrue '.vbs 同样转换' ($out2.Length -eq ($bLf.Length + 3))
$out3 = ConvertTo-CrlfIfLauncher 'tool.cmd' $bLf
CheckTrue '.cmd 同样转换' ($out3.Length -eq ($bLf.Length + 3))
$out4 = ConvertTo-CrlfIfLauncher 'x.bat' $bCrlf
CheckTrue '已经是 CRLF 的不重复加 CR（幂等）' ($out4.Length -eq $bCrlf.Length)
$bPs1 = Get-AsciiBytes $lfText
CheckTrue '.ps1 一个字节都不动（仓库约定 LF）' ((ConvertTo-CrlfIfLauncher 'kun-pet-ui.ps1' $bPs1).Length -eq $bPs1.Length)
CheckTrue '.json 不动' ((ConvertTo-CrlfIfLauncher 'version.json' $bPs1).Length -eq $bPs1.Length)
$emptyOk = $true
try { [void](ConvertTo-CrlfIfLauncher 'a.bat' ([byte[]]@())) } catch { $emptyOk = $false }
CheckTrue '空字节数组不抛异常' $emptyOk

Write-Host ""
Write-Host "=== 10. 端到端：更新写入磁盘后启动器仍是 CRLF（不联网）===" -ForegroundColor Cyan
$tmpDir = Join-Path ([IO.Path]::GetTempPath()) ('kun-crlf-' + [guid]::NewGuid().ToString('N').Substring(0, 6))
New-Item -ItemType Directory -Force -Path $tmpDir | Out-Null
try {
    $stagedCrlf = @{}
    $stagedCrlf['l.bat'] = @{ bytes = (Get-AsciiBytes "@echo off`nrem a`n") }
    $stagedCrlf['l.vbs'] = @{ bytes = (Get-AsciiBytes "Option Explicit`nWScript.Quit`n") }
    $stagedCrlf['m.ps1'] = @{ bytes = (Get-AsciiBytes "function X { }`n") }
    $rr = Install-UpdateFiles $stagedCrlf $tmpDir $tmpDir '9.9.9'
    CheckTrue '安装成功' ($rr.ok)
    CheckTrue '落盘的 .bat 是 CRLF' ((Test-BytesHaveLoneLf ([IO.File]::ReadAllBytes((Join-Path $tmpDir 'l.bat')))) -eq $false)
    CheckTrue '落盘的 .vbs 是 CRLF' ((Test-BytesHaveLoneLf ([IO.File]::ReadAllBytes((Join-Path $tmpDir 'l.vbs')))) -eq $false)
    CheckTrue '落盘的 .ps1 保持 LF（没被误改）' (Test-BytesHaveLoneLf ([IO.File]::ReadAllBytes((Join-Path $tmpDir 'm.ps1'))))
} finally {
    Remove-Item -LiteralPath $tmpDir -Recurse -Force -ErrorAction SilentlyContinue
}
Write-Host ""
if ($script:fail -eq 0) { Write-Host ("全部通过：{0} 项" -f $script:pass) -ForegroundColor Green; exit 0 }
else { Write-Host ("失败 {0} 项 / 通过 {1} 项" -f $script:fail, $script:pass) -ForegroundColor Red; exit 1 }
