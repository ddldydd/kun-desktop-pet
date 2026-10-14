# 真实网络端到端验证：从 GitHub 取回**真实文件**并走完整校验。
# 只读（下载到内存/temp），不写桌宠目录。
$ErrorActionPreference = 'Continue'
$desktop = $args[0]
. (Join-Path $desktop 'kun-pet-update.ps1')

$base = Get-UpdateSource
Write-Host ("更新源: " + $base)
Write-Host ""
Write-Host "=== 1) 逐个下载 + 校验（这正是更新时会走的路径）==="
$allOk = $true
foreach ($n in @('kun-pet-desktop.ps1','kun-pet-pi-source.ps1','kun-pet-wander.ps1','启动桌宠.vbs','start-pet.vbs','启动桌宠.bat')) {
    $b = Get-UpdateBytes ($base + '/desktop/' + $n) 30
    if ($null -eq $b) { Write-Host ("  {0,-26} 下载失败" -f $n); $allOk = $false; continue }
    $t = [Text.Encoding]::UTF8.GetString($b)
    $c = Test-UpdateContent $n $t
    if (-not $c.ok) { $allOk = $false }
    Write-Host ("  {0,-26} {1,7} 字节  校验={2} {3}" -f $n, $b.Length, $(if($c.ok){'通过'}else{'拒绝'}), $c.reason)
}
Write-Host ("  全部通过: " + $allOk)

Write-Host ""
Write-Host "=== 2) 下载到的 BOM 是否保留（决定装上去会不会乱码）==="
$b = Get-UpdateBytes ($base + '/desktop/kun-pet-pi-source.ps1') 30
Write-Host ("  前 3 字节: {0:X2} {1:X2} {2:X2}  (EF BB BF = UTF-8 BOM)" -f $b[0],$b[1],$b[2])

Write-Host ""
Write-Host "=== 3) 端到端：伪造一个「远端更新」在隔离目录跑完整流程 ==="
# 用一个临时 raw 源（本地 HTTP 服务太麻烦）改为直接调 Install-UpdateFiles 验证替换；
# 下载部分上面已验证。这里验证「下载到的真实字节 → 写入磁盘 → 内容与远端一致」。
$tmp = Join-Path $env:TEMP ('kun-e2e-' + [guid]::NewGuid().ToString('N').Substring(0,6))
New-Item -ItemType Directory -Force -Path $tmp | Out-Null
# 先放一个「旧版」
foreach ($n in @('kun-pet-pi-source.ps1','kun-pet-wander.ps1')) {
    [IO.File]::WriteAllText((Join-Path $tmp $n), "OLD $n", (New-Object Text.UTF8Encoding($false)))
}
$staged = @{}
foreach ($n in @('kun-pet-pi-source.ps1','kun-pet-wander.ps1')) {
    $staged[$n] = @{ bytes = (Get-UpdateBytes ($base + '/desktop/' + $n) 30) }
}
$r = Install-UpdateFiles $staged $tmp $tmp '9.9.9'
Write-Host ("  安装 ok=" + $r.ok + "  替换 " + (@($r.replaced).Count) + " 个  备份=" + (Split-Path -Leaf $r.backupDir))
# 校验落盘内容与远端字节**完全一致**
foreach ($n in @('kun-pet-pi-source.ps1','kun-pet-wander.ps1')) {
    $localBytes = [IO.File]::ReadAllBytes((Join-Path $tmp $n))
    $same = ($localBytes.Length -eq $staged[$n].bytes.Length)
    if ($same) {
        for ($i = 0; $i -lt $localBytes.Length; $i++) { if ($localBytes[$i] -ne $staged[$n].bytes[$i]) { $same = $false; break } }
    }
    Write-Host ("  {0,-26} 落盘字节与远端一致={1}  ({2} 字节)" -f $n, $same, $localBytes.Length)
}
# 落盘后的文件必须仍能被 PowerShell 当脚本解析（BOM 还在、没被改写）
$errs = $null
[void][System.Management.Automation.Language.Parser]::ParseFile((Join-Path $tmp 'kun-pet-pi-source.ps1'), [ref]$null, [ref]$errs)
Write-Host ("  落盘文件可解析: " + ($null -eq $errs -or $errs.Count -eq 0))
Remove-Item $tmp -Recurse -Force -ErrorAction SilentlyContinue
