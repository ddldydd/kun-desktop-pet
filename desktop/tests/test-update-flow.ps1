# 端到端验证 Invoke-PetUpdate 的完整决策流程（版本比较 → 下载 → 校验 → 安装）。
# 手法：覆盖 Get-UpdateBytes（模拟网络），其余全部走**真实产品代码**与真实磁盘操作。
# 这样不需要真的改动远端，也能验证「有新版就装、没新版就跳过、坏内容就放弃」。
$ErrorActionPreference = 'Continue'
$desktop = $args[0]
. (Join-Path $desktop 'kun-pet-update.ps1')

$script:fail = 0; $script:pass = 0
function Check([string]$n, $a, $e) {
    $x = if ($null -eq $a) { '<null>' } else { [string]$a }
    $y = if ($null -eq $e) { '<null>' } else { [string]$e }
    if ($x -eq $y) { $script:pass++; Write-Host ("  [ok]   " + $n) -ForegroundColor Green }
    else { $script:fail++; Write-Host ("  [FAIL] {0} 期望={1} 实际={2}" -f $n, $y, $x) -ForegroundColor Red }
}
function CheckTrue([string]$n, $c) { Check $n $(if ($c) { 'True' } else { 'False' }) 'True' }

# ---- 用假网络替换 Get-UpdateBytes ----
# 通过 Invoke-PetUpdate 的 $fetcher 参数注入，而**不是**在测试里重定义同名函数。
# 后者依赖 PowerShell 的作用域解析规则，在「模块被 dot-source + CI 的 Linux/pwsh7」
# 组合下行为不一致（本地过、CI 挂 —— 实测踩到过）。显式传参不依赖任何作用域规则。
$script:fakeRemote = @{}
$script:fakeFetch = {
    param([string]$url, [int]$timeoutSec)
    # url 形如 <base>/desktop/<name>
    $name = $url.Substring($url.LastIndexOf('/') + 1)
    if ($script:fakeRemote.ContainsKey($name)) {
        $v = $script:fakeRemote[$name]
        if ($null -eq $v) { return $null }         # 模拟下载失败
        return [Text.Encoding]::UTF8.GetBytes([string]$v)
    }
    return $null
}

# 取一个可用的临时目录。
# 不能直接用 $env:TEMP：**Linux 上没有 TEMP**（只有 TMPDIR），Windows 上 TEMP
# 也可能被清空。GetTempPath() 本身在 TEMP 为空时也会抛（Windows 实测），
# 所以这里再套一层兜底，取不到就用当前目录 —— 测试必须能在任何环境下起来，
# 否则 CI 上会直接崩（实测踩到过：本地过、CI 挂）。
function Get-TestTempRoot {
    foreach ($try in @(
        { [IO.Path]::GetTempPath() },
        { $env:TEMP }, { $env:TMP }, { $env:TMPDIR }
    )) {
        try {
            $v = & $try
            if ($v -and ([string]$v).Trim()) { return ([string]$v).Trim() }
        } catch { }
    }
    return (Get-Location).Path
}
$tmp = Join-Path (Get-TestTempRoot) ('kun-flow-' + [guid]::NewGuid().ToString('N').Substring(0,6))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
$script:remoteBase = $script:updRawBase   # 随便一个 base，假网络不看它

Write-Host ""
Write-Host "=== 场景 A：远端有新版本 → 应更新成功 ==="  -ForegroundColor Cyan
[IO.File]::WriteAllText((Join-Path $tmp 'kun-pet-desktop.ps1'), 'OLD v2.0.0', (New-Object Text.UTF8Encoding($false)))
$script:fakeRemote = @{}
$script:fakeRemote['version.json'] = '{"version":"9.9.0","notes":["测试更新"],"files":["kun-pet-desktop.ps1"]}'
$script:fakeRemote['kun-pet-desktop.ps1'] = "function Ok { 'NEW v9.9.0 content here' }`n# filler line to pass length check"
$r = Invoke-PetUpdate $tmp '2.0.0' $tmp $script:fakeFetch
Check '状态 = updated' $r.status 'updated'
CheckTrue 'ok = true' $r.ok
Check '远端版本' $r.remoteVersion '9.9.0'
Check '替换了 1 个文件' (@($r.files).Count) 1
CheckTrue '磁盘内容已更新' (([IO.File]::ReadAllText((Join-Path $tmp 'kun-pet-desktop.ps1'))).Contains('NEW v9.9.0'))
CheckTrue '有备份目录' ([bool]$r.backupDir)
CheckTrue '备份里是旧内容' (([IO.File]::ReadAllText((Join-Path $r.backupDir 'kun-pet-desktop.ps1'))) -eq 'OLD v2.0.0')

Write-Host ""
Write-Host "=== 场景 B：已是最新版 → 不应改动磁盘 ===" -ForegroundColor Cyan
[IO.File]::WriteAllText((Join-Path $tmp 'kun-pet-desktop.ps1'), 'KEEP ME', (New-Object Text.UTF8Encoding($false)))
$r2 = Invoke-PetUpdate $tmp '9.9.0' $tmp $script:fakeFetch
Check '状态 = up-to-date' $r2.status 'up-to-date'
CheckTrue 'ok = true' $r2.ok
Check '磁盘内容未被动过' ([IO.File]::ReadAllText((Join-Path $tmp 'kun-pet-desktop.ps1'))) 'KEEP ME'

Write-Host ""
Write-Host "=== 场景 C：下载到的内容是 HTML 错误页 → 拒绝且不改磁盘 ===" -ForegroundColor Cyan
[IO.File]::WriteAllText((Join-Path $tmp 'kun-pet-desktop.ps1'), 'PROTECT ME', (New-Object Text.UTF8Encoding($false)))
$script:fakeRemote = @{}
$script:fakeRemote['version.json'] = '{"version":"9.9.9","files":["kun-pet-desktop.ps1"]}'
$script:fakeRemote['kun-pet-desktop.ps1'] = '<!DOCTYPE html><html><body>404 Not Found</body></html>'
$r3 = Invoke-PetUpdate $tmp '1.0.0' $tmp $script:fakeFetch
Check '状态 = failed' $r3.status 'failed'
CheckTrue 'ok = false' (-not $r3.ok)
CheckTrue '错误信息提到校验' ([string]$r3.error -match '校验|网页|HTML')
Check '磁盘内容**未被破坏**' ([IO.File]::ReadAllText((Join-Path $tmp 'kun-pet-desktop.ps1'))) 'PROTECT ME'

Write-Host ""
Write-Host "=== 场景 D：某个文件下载失败 → 整体放弃，不改磁盘 ===" -ForegroundColor Cyan
[IO.File]::WriteAllText((Join-Path $tmp 'kun-pet-desktop.ps1'), 'STILL PROTECTED', (New-Object Text.UTF8Encoding($false)))
$script:fakeRemote = @{}
$script:fakeRemote['version.json'] = '{"version":"9.9.9","files":["kun-pet-desktop.ps1","kun-pet-update.ps1"]}'
$script:fakeRemote['kun-pet-desktop.ps1'] = "function A { 'ok content long enough to pass' }"
$script:fakeRemote['kun-pet-update.ps1'] = $null      # 模拟这个文件下载失败
$r4 = Invoke-PetUpdate $tmp '1.0.0' $tmp $script:fakeFetch
Check '状态 = failed' $r4.status 'failed'
CheckTrue '错误信息提到下载失败' ([string]$r4.error -match '下载失败')
Check '磁盘内容**未被破坏**' ([IO.File]::ReadAllText((Join-Path $tmp 'kun-pet-desktop.ps1'))) 'STILL PROTECTED'

Write-Host ""
Write-Host "=== 场景 E：拿不到版本清单（断网）→ 优雅失败 ===" -ForegroundColor Cyan
$script:fakeRemote = @{}    # 什么都没有 = 全部 404
$r5 = Invoke-PetUpdate $tmp '1.0.0' $tmp $script:fakeFetch
Check '状态 = failed' $r5.status 'failed'
CheckTrue '错误信息提到版本清单/网络' ([string]$r5.error -match '版本清单|网络')

Write-Host ""
Write-Host "=== 场景 F：清单被投毒（路径穿越 + 覆盖用户配置）→ 只装白名单内的 ===" -ForegroundColor Cyan
$outside = Join-Path (Split-Path -Parent $tmp) 'kun-EVIL-should-not-exist.ps1'
if (Test-Path $outside) { Remove-Item $outside -Force }
[IO.File]::WriteAllText((Join-Path $tmp 'kun-pet-desktop.ps1'), 'OLD', (New-Object Text.UTF8Encoding($false)))
[IO.File]::WriteAllText((Join-Path $tmp 'kun-pet-settings.json'), '{"wander":true}', (New-Object Text.UTF8Encoding($false)))
$script:fakeRemote = @{}
$script:fakeRemote['version.json'] = '{"version":"9.9.9","files":["kun-pet-desktop.ps1","../kun-EVIL-should-not-exist.ps1","kun-pet-settings.json"]}'
$script:fakeRemote['kun-pet-desktop.ps1'] = "function A { 'legit new content long enough' }"
$r6 = Invoke-PetUpdate $tmp '1.0.0' $tmp $script:fakeFetch
Check '只替换了 1 个（白名单内那个）' (@($r6.files).Count) 1
CheckTrue '没有在桌宠目录外写出文件' (-not (Test-Path -LiteralPath $outside))
Check '用户配置仍是原内容（未被覆盖）' ([IO.File]::ReadAllText((Join-Path $tmp 'kun-pet-settings.json'))) '{"wander":true}'

Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
Write-Host ""
if ($script:fail -eq 0) { Write-Host ("全部通过：{0} 项" -f $script:pass) -ForegroundColor Green; exit 0 }
else { Write-Host ("失败 {0} 项 / 通过 {1} 项" -f $script:fail, $script:pass) -ForegroundColor Red; exit 1 }
