# 终极验证：用**真实 GitHub 源**跑一次完整的「检查更新」决策流程。
# 手法：复制当前 live 桌宠到临时目录，把它的版本号改成一个更旧的（2.0.0），
#      然后调用 Invoke-PetUpdate —— 它应该真的从 GitHub 下载并更新到 2.1.0。
# 全程在临时目录，不碰用户正在跑的桌宠。
$live = $args[0]
$ErrorActionPreference = 'Continue'

function Get-TestTempRoot {
    foreach ($try in @(
        { [IO.Path]::GetTempPath() },
        { $env:TEMP }, { $env:TMP }, { $env:TMPDIR }
    )) {
        try { $v = & $try; if ($v -and ([string]$v).Trim()) { return ([string]$v).Trim() } } catch { }
    }
    return (Get-Location).Path
}
$tmp = Join-Path (Get-TestTempRoot) ('kun-final-' + [guid]::NewGuid().ToString('N').Substring(0,6))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
Write-Host ("临时「旧版」安装目录: " + $tmp)

# 造一个旧版：从 live 拷脚本，再把内容标记成 OLD 并写成更旧的版本号
foreach ($f in @('kun-pet-desktop.ps1','kun-pet-pi-source.ps1','kun-pet-wander.ps1','kun-pet-update.ps1','启动桌宠.vbs','version.json')) {
    Copy-Item -LiteralPath (Join-Path $live $f) -Destination (Join-Path $tmp $f) -Force
}
# 把本地 version.json 改成 2.0.0（模拟「用户装的是旧版」）
$localVj = Join-Path $tmp 'version.json'
[IO.File]::WriteAllText($localVj, '{"version":"2.0.0"}', (New-Object Text.UTF8Encoding($false)))
# 在桌宠脚本最前面塞一行标记，用于确认「文件真的被替换了」
$marker = Join-Path $tmp 'kun-pet-pi-source.ps1'
$orig = [IO.File]::ReadAllText($marker, [Text.Encoding]::UTF8)
[IO.File]::WriteAllText($marker, ($orig + "`n# I-AM-OLD-MARKER`n"), (New-Object Text.UTF8Encoding($true)))

. (Join-Path $live 'kun-pet-update.ps1')
$before = Get-Content $localVj -Raw -Encoding UTF8
Write-Host ("更新前 本地 version.json: " + $before.Trim())
Write-Host ("标记还在吗: " + ([IO.File]::ReadAllText($marker, [Text.Encoding]::UTF8).Contains('I-AM-OLD-MARKER')))
Write-Host ""
Write-Host "=== 执行 Invoke-PetUpdate（真实联网）==="
$sw = [Diagnostics.Stopwatch]::StartNew()
$r = Invoke-PetUpdate $tmp '2.0.0' $tmp
$sw.Stop()
Write-Host ("  状态        : " + $r.status)
Write-Host ("  ok          : " + $r.ok)
Write-Host ("  本地版本    : " + $r.localVersion)
Write-Host ("  远端版本    : " + $r.remoteVersion)
Write-Host ("  耗时        : " + [math]::Round($sw.Elapsed.TotalSeconds,1) + " 秒")
Write-Host ("  替换文件数  : " + (@($r.files).Count))
Write-Host ("  备份目录    : " + $r.backupDir)
Write-Host ("  错误        : " + $r.error)
Write-Host ""
Write-Host "=== 结果核对 ==="
$after = Get-Content $localVj -Raw -Encoding UTF8
Write-Host ("更新后 本地 version.json: " + $after.Trim())
Write-Host ("  版本已变成 2.1.0 : " + ($after -match '2\.1\.0'))
Write-Host ("  旧标记已被覆盖掉   : " + (-not ([IO.File]::ReadAllText($marker, [Text.Encoding]::UTF8).Contains('I-AM-OLD-MARKER'))))
# 落盘的文件必须仍是可解析的脚本（BOM 保留）
$errs = $null
[void][System.Management.Automation.Language.Parser]::ParseFile($marker, [ref]$null, [ref]$errs)
Write-Host ("  更新后脚本可解析   : " + ($null -eq $errs -or $errs.Count -eq 0))
$b = [IO.File]::ReadAllBytes($marker)
Write-Host ("  更新后仍有 BOM     : " + ($b[0] -eq 0xEF -and $b[1] -eq 0xBB -and $b[2] -eq 0xBF))
Write-Host ("  备份里是旧内容     : " + ([IO.File]::ReadAllText((Join-Path $r.backupDir 'kun-pet-pi-source.ps1'), [Text.Encoding]::UTF8).Contains('I-AM-OLD-MARKER')))
Write-Host ""
Write-Host "=== 再跑一次：应判定「已是最新」，不再改动 ==="
$r2 = Invoke-PetUpdate $tmp '2.1.0' $tmp
Write-Host ("  状态: " + $r2.status + "（期望 up-to-date）")
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
