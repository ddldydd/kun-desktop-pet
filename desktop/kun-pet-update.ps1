# =====================================================================
#  Kun Like 桌宠 · 更新模块
# =====================================================================
#  让已安装的桌宠能一键更新到最新版。
#
#  更新源：GitHub raw（逐文件）
#    https://raw.githubusercontent.com/<owner>/<repo>/<branch>/desktop/<file>
#
#  为什么不用 zip / git clone（实测结论）：
#    codeload.github.com（zip 下载源）在本机**直连与代理都失败**，
#    而 raw.githubusercontent.com 稳定可达（HTTP 200）且能正确保留 UTF-8 BOM。
#    所以只能逐文件取。文件总量不大（desktop/ 下几个脚本，约 260KB）。
#
#  ---- 安全设计（这是本模块的重点）----
#  1) **先全部下载到临时目录，校验通过后才替换**。
#     绝不出现「替换了一半、程序坏了」。只要有一个文件下载失败或校验不过，
#     整体放弃，磁盘上原封不动。
#  2) **校验包含语法解析**：用 PowerShell 自带 Parser 解析每个下载到的 .ps1。
#     这一步能挡住「网络返回了 HTML 错误页」这类情况 —— 它内容合法但根本不是脚本，
#     真替换上去桌宠就起不来了。
#  3) **不碰用户数据**：kun-pet-settings.json / *.log 永不覆盖（白名单外的一律不动）。
#  4) **替换前备份**：整份当前文件拷进 backup-<版本>-<时间戳>/，可回滚。
#  5) **失败自动回滚**：替换过程中任何异常都把备份复原回去。
#
#  纯函数（版本比较 / 文件筛选 / 校验）都不碰网络与磁盘，可脱离桌宠自测，
#  见 tests/test-update.ps1。
# =====================================================================

# 更新源（可被主脚本覆盖，便于测试或换分支）
if (-not $script:updRawBase) {
    $script:updRawBase = 'https://raw.githubusercontent.com/ddldydd/kun-desktop-pet/main'
}
# 只允许更新这些文件（**白名单**）：白名单外的一律不动。
# 特别地 kun-pet-settings.json（用户配置）与 *.log 永远不在里面。
if (-not $script:updAllowedFiles) {
    $script:updAllowedFiles = @(
        'kun-pet-desktop.ps1',
        'kun-pet-pi-source.ps1',
        'kun-pet-wander.ps1',
        'kun-pet-update.ps1',
        'version.json',
        '启动桌宠.vbs',
        '启动桌宠.bat',
        'start-pet.vbs'
    )
}

function Set-UpdateSource([string]$rawBase) {
    if ($rawBase) { $script:updRawBase = $rawBase.TrimEnd('/') }
}
function Get-UpdateSource { return [string]$script:updRawBase }
function Get-UpdateAllowedFiles { return @($script:updAllowedFiles) }

# ---------------- 版本号 ----------------
# 把 'v2.1.0' / '2.1.0' / '2.1.0-beta.1' 解析成可比较的整数数组。
# 只取前 3 段数字；解析不出数字的段落按 0 处理（**不抛异常** ——
# 版本文件坏了不该让桌宠崩溃，只该让「检查更新」失败）。
function ConvertTo-VersionParts([string]$v) {
    $parts = @(0, 0, 0)
    if (-not $v) { return $parts }
    $s = ([string]$v).Trim()
    if ($s.StartsWith('v') -or $s.StartsWith('V')) { $s = $s.Substring(1) }
    # 去掉预发布后缀（-beta.1 / +build 之类）
    $s = ($s -split '[-+]')[0]
    $segs = @($s -split '\.')
    for ($i = 0; $i -lt 3; $i++) {
        if ($i -lt $segs.Count) {
            $n = 0
            if ([int]::TryParse([string]$segs[$i], [ref]$n)) {
                if ($n -lt 0) { $n = 0 }
                $parts[$i] = $n
            }
        }
    }
    return $parts
}

# $true 表示 $remote 比 $local 新。
function Test-UpdateNewer([string]$local, [string]$remote) {
    $l = ConvertTo-VersionParts $local
    $r = ConvertTo-VersionParts $remote
    for ($i = 0; $i -lt 3; $i++) {
        if ($r[$i] -gt $l[$i]) { return $true }
        if ($r[$i] -lt $l[$i]) { return $false }
    }
    return $false   # 相等 → 不算「更新」
}

# 从版本清单（version.json 解析出来的对象）里取版本号；取不到返回空串。
function Get-ManifestVersion($manifest) {
    try {
        if ($null -eq $manifest) { return '' }
        $v = $manifest.version
        if ($null -eq $v) { return '' }
        return ([string]$v).Trim()
    } catch { return '' }
}

# 从清单里取「可更新的文件列表」，并与白名单求交集。
# 清单是外部数据（网络来的），**不能**直接拿它当路径用 ——
# 万一清单里写了 '..\..\windows\system32\x.ps1' 就会变成路径穿越。
# 这里用白名单做交集，等于同时做了「来源不可信」的防护。
function Get-ManifestFiles($manifest) {
    $result = New-Object System.Collections.ArrayList
    try {
        if ($null -eq $manifest -or $null -eq $manifest.files) { return @() }
        foreach ($f in @($manifest.files)) {
            $name = ([string]$f).Trim()
            if (-not $name) { continue }
            # 只允许「纯文件名」，不允许带任何目录分隔符（防路径穿越）
            if ($name.Contains('/') -or $name.Contains('\')) { continue }
            if ($name -eq '.' -or $name -eq '..') { continue }
            if ($script:updAllowedFiles -contains $name) {
                [void]$result.Add($name)
            }
        }
    } catch { }
    return @($result)
}

# ---------------- 下载与校验 ----------------
# 下载一个文件到内存（返回字节数组）。失败返回 $null。
# 用 Invoke-WebRequest 的 RawContentStream 拿**原始字节**，
# 而不是 .Content（那是解码后的字符串，BOM 与二进制内容会被改动）。
function Get-UpdateBytes([string]$url, [int]$timeoutSec = 30) {
    try {
        $resp = Invoke-WebRequest -Uri $url -TimeoutSec $timeoutSec -UseBasicParsing -ErrorAction Stop
        if ($null -eq $resp) { return $null }
        # 优先用 RawContentStream（真实字节）
        if ($null -ne $resp.RawContentStream) {
            $ms = New-Object System.IO.MemoryStream
            $resp.RawContentStream.CopyTo($ms)
            return $ms.ToArray()
        }
        # 兜底：没有 RawContentStream 时按 UTF8 编码回字节
        if ($null -ne $resp.Content) {
            return [System.Text.Encoding]::UTF8.GetBytes([string]$resp.Content)
        }
        return $null
    } catch {
        return $null
    }
}

# 校验一个下载到的 .ps1 内容是否「像脚本」。
# 三道关（前两道来自实测踩坑）：
#   ① 不能是空/过短（挡掉空响应）
#   ② **不能是 HTML**（关键！）—— 网络出错时服务器常返回 HTML 错误页，
#      而 HTML 里的尖括号**恰好是合法的 PowerShell 语法**
#      （`<` 是重定向、`>` 是输出重定向），Parser 居然解析通过。
#      实测确认：只靠 Parser 挡不住，必须显式识别 HTML。
#      真装上去桌宠就起不来了。
#   ③ 必须能过 Parser（挡掉真正的语法错误）
# 返回 @{ ok; reason }
function Test-UpdateScriptContent([string]$text, [string]$name) {
    if (-not $text -or $text.Trim().Length -lt 20) {
        return @{ ok = $false; reason = "$name 内容为空或过短" }
    }
    # ① 先剥掉开头的 UTF-8 BOM（解码成字符串后就是 U+FEFF）。
    # 这一步**必须有**：本仓库所有 .ps1 都带 BOM（这是仓库约定，且 CI 会强制检查），
    # 而 Parser 看到字符串开头的 U+FEFF 会报
    # 「表达式中存在意外的标记」——不剥的话**每一个真实文件都会被误判为不合格**，
    # 更新功能整体失效（实测踩到过）。
    $body = $text
    if ($body.Length -gt 0 -and $body[0] -eq [char]0xFEFF) { $body = $body.Substring(1) }

    # ② 挡 HTML / XML / 明显不是脚本的文本
    $head = $body.TrimStart()
    if ($head -match '(?i)^<!doctype\s+html' -or
        $head -match '(?i)^<html' -or
        $head -match '(?i)^<\?xml' -or
        $head -match '(?i)^<head' -or
        $head -match '(?i)^<body') {
        return @{ ok = $false; reason = "$name 看起来是网页（HTML）而不是脚本" }
    }
    if ($head -match '(?i)^404:\s*not\s*found') {
        return @{ ok = $false; reason = "$name 返回 404 Not Found" }
    }
    # 首行就是个尖括号标签，也判为网页
    $firstLine = ($head -split "`r?`n")[0]
    if ($firstLine -match '^\s*<\w+[^>]*>\s*$') {
        return @{ ok = $false; reason = "$name 首行是 HTML 标签，不是脚本" }
    }
    # ③ Parser（对剥掉 BOM 的正文解析）
    $errs = $null
    try {
        [void][System.Management.Automation.Language.Parser]::ParseInput($body, [ref]$null, [ref]$errs)
    } catch {
        return @{ ok = $false; reason = "$name 无法解析：$($_.Exception.Message)" }
    }
    if ($errs -and $errs.Count -gt 0) {
        return @{ ok = $false; reason = "$name 语法错误（可能不是脚本）：$($errs[0].Message)" }
    }
    return @{ ok = $true; reason = '' }
}

# 校验 .vbs / .bat：只做「非空 + 不是 HTML」的轻检查。
function Test-UpdateTextContent([string]$text, [string]$name) {
    if (-not $text -or $text.Trim().Length -lt 5) {
        return @{ ok = $false; reason = "$name 内容为空" }
    }
    # 网络出错时常见返回 HTML；这类内容不该被当成脚本装上去
    $head = $text.TrimStart()
    if ($head.StartsWith('<!DOCTYPE') -or $head.StartsWith('<html') -or $head.StartsWith('<HTML') -or $head.StartsWith('<?xml')) {
        return @{ ok = $false; reason = "$name 看起来是网页而不是脚本（下载源可能出错）" }
    }
    if ($text -match '^\s*404:\s*Not Found' -or $text -match '^\s*Not Found\s*$') {
        return @{ ok = $false; reason = "$name 返回 404 Not Found" }
    }
    return @{ ok = $true; reason = '' }
}

# 按扩展名分派校验
function Test-UpdateContent([string]$name, [string]$text) {
    if ($name -like '*.ps1') { return Test-UpdateScriptContent $text $name }
    if ($name -like '*.vbs' -or $name -like '*.bat') { return Test-UpdateTextContent $text $name }
    if ($name -like '*.json') {
        if (-not $text -or $text.Trim().Length -lt 2) { return @{ ok = $false; reason = "$name 内容为空" } }
        # 网络取回的 JSON 通常带 BOM，要先剥掉再解析，否则 ConvertFrom-Json 会失败
        $jt = $text
        if ($jt.Length -gt 0 -and $jt[0] -eq [char]0xFEFF) { $jt = $jt.Substring(1) }
        try { $null = $jt | ConvertFrom-Json } catch { return @{ ok = $false; reason = "$name 不是合法 JSON" } }
        return @{ ok = $true; reason = '' }
    }
    return @{ ok = $true; reason = '' }
}

# ---------------- 原子替换与回滚 ----------------
# 把一组「已下载并校验过」的文件装进目标目录。
#
#   $staged : @{ 文件名 = @{ bytes = <byte[]>; } }
#   $targetDir : 桌宠所在目录
#   $backupRoot : 备份父目录（备份放在 <backupRoot>/backup-<版本>-<时间戳>/）
#
# 返回 @{ ok; backupDir; replaced; error; rolledBack }
#
# 流程：先整份备份 → 逐文件写临时文件再改名（File.Replace/Rename 是原子的）
#      → 任一环节失败就按备份整体回滚。
function Install-UpdateFiles($staged, [string]$targetDir, [string]$backupRoot, [string]$version) {
    $result = @{ ok = $false; backupDir = $null; replaced = @(); error = ''; rolledBack = $false }
    $backupDir = $null
    try {
        if ($null -eq $staged -or $staged.Count -eq 0) {
            $result.error = '没有要安装的文件'
            return $result
        }
        if (-not (Test-Path -LiteralPath $targetDir)) {
            $result.error = "目标目录不存在：$targetDir"
            return $result
        }

        # ---- 1) 整份备份 ----
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $safeVer = ($version -replace '[^\w\.\-]', '')   # 防版本号里带奇怪字符拼进路径
        if (-not $safeVer) { $safeVer = 'unknown' }
        if (-not $backupRoot) { $backupRoot = $targetDir }
        $backupDir = Join-Path $backupRoot ("backup-v{0}-{1}" -f $safeVer, $stamp)
        New-Item -ItemType Directory -Force -Path $backupDir | Out-Null

        # 备份**将被替换的那些**文件（不整目录拷，避免把 settings/log 也拷进去）
        $backedUp = @{}
        foreach ($name in $staged.Keys) {
            $dst = Join-Path $targetDir $name
            if (Test-Path -LiteralPath $dst) {
                Copy-Item -LiteralPath $dst -Destination (Join-Path $backupDir $name) -Force
                $backedUp[$name] = $true
            }
        }
        $result.backupDir = $backupDir

        # ---- 2) 逐文件原子替换 ----
        foreach ($name in $staged.Keys) {
            $bytes = $staged[$name].bytes
            $dst = Join-Path $targetDir $name
            $tmp = Join-Path $targetDir ($name + '.new-tmp')
            # 先把新内容完整写到同目录的 .tmp（同卷，改名/替换才是原子的）
            [System.IO.File]::WriteAllBytes($tmp, $bytes)
            if ([System.IO.File]::Exists($dst)) {
                # 目标已存在 → 用 File.Replace 做**原子替换**
                # （Windows 上底层是 ReplaceFile）。
                # 不能用「先 Remove-Item 再 Move-Item」：那中间有个窗口期目标文件不存在，
                # 一旦此时进程被杀/断电，用户就丢了这个文件。
                #
                # 第 3 个参数（被替换文件的备份）**不能传 $null**：Windows PowerShell 5.1
                # 会抛「The path is empty. (Parameter 'path')」（实测确认）。
                # 给一个真实路径，用完即删。
                $swapBackup = Join-Path $targetDir ($name + '.old-tmp')
                [System.IO.File]::Replace($tmp, $dst, $swapBackup)
                try { if ([System.IO.File]::Exists($swapBackup)) { [System.IO.File]::Delete($swapBackup) } } catch { }
            } else {
                # 目标不存在（首次安装/新增文件）→ 直接改名
                [System.IO.File]::Move($tmp, $dst)
            }
            $result.replaced += $name
        }

        $result.ok = $true
        return $result
    } catch {
        $result.error = $_.Exception.Message
        # ---- 3) 回滚 ----
        if ($backupDir -and (Test-Path -LiteralPath $backupDir)) {
            try {
                foreach ($name in @(Get-ChildItem -LiteralPath $backupDir -File | Select-Object -ExpandProperty Name)) {
                    Copy-Item -LiteralPath (Join-Path $backupDir $name) -Destination (Join-Path $targetDir $name) -Force
                }
                $result.rolledBack = $true
            } catch {
                # 回滚也失败：保留 backupDir 让用户能手工恢复，并在 error 里说明
                $result.error = $result.error + ' | 自动回滚也失败，备份在：' + $backupDir
            }
        }
        return $result
    } finally {
        # 清掉可能残留的中间文件（.new-tmp 写在目标旁，.old-tmp 是 File.Replace 的中间产物）
        try {
            foreach ($pat in @('*.new-tmp', '*.old-tmp')) {
                foreach ($tmp in @(Get-ChildItem -LiteralPath $targetDir -Filter $pat -File -ErrorAction SilentlyContinue)) {
                    Remove-Item -LiteralPath $tmp.FullName -Force -ErrorAction SilentlyContinue
                }
            }
        } catch { }
    }
}

# ---------------- 组装一次完整更新（网络 + 磁盘）----------------
# 这是给桌宠调用的入口。返回
#   @{ ok; status; localVersion; remoteVersion; files; backupDir; error; notes }
#   status: 'up-to-date' | 'updated' | 'failed'
function Invoke-PetUpdate([string]$targetDir, [string]$currentVersion, [string]$backupRoot) {
    $out = @{
        ok = $false; status = 'failed'; localVersion = [string]$currentVersion
        remoteVersion = ''; files = @(); backupDir = $null; error = ''; notes = @()
    }
    try {
        $base = [string]$script:updRawBase
        if (-not $base) { $out.error = '未配置更新源'; return $out }

        # 1) 取版本清单
        $manifestBytes = Get-UpdateBytes ($base + '/desktop/version.json') 30
        if ($null -eq $manifestBytes -or $manifestBytes.Length -eq 0) {
            $out.error = '无法获取版本清单（网络不可达或更新源不可用）'
            return $out
        }
        $manifestText = [System.Text.Encoding]::UTF8.GetString($manifestBytes)
        if ($manifestText.Length -gt 0 -and $manifestText[0] -eq [char]0xFEFF) { $manifestText = $manifestText.Substring(1) }
        $manifest = $null
        try { $manifest = $manifestText | ConvertFrom-Json } catch { }
        if ($null -eq $manifest) { $out.error = '版本清单不是合法 JSON'; return $out }

        $remote = Get-ManifestVersion $manifest
        if (-not $remote) { $out.error = '版本清单里没有 version 字段'; return $out }
        $out.remoteVersion = $remote
        try { if ($manifest.notes) { $out.notes = @($manifest.notes) } } catch { }

        # 2) 比较版本
        if (-not (Test-UpdateNewer $currentVersion $remote)) {
            $out.ok = $true; $out.status = 'up-to-date'
            return $out
        }

        # 3) 下载清单里列出的文件（与白名单求交集）
        $names = @(Get-ManifestFiles $manifest)
        if ($names.Count -eq 0) { $out.error = '版本清单里没有可更新的文件'; return $out }

        $staged = @{}
        foreach ($name in $names) {
            $url = $base + '/desktop/' + $name
            $bytes = Get-UpdateBytes $url 30
            if ($null -eq $bytes -or $bytes.Length -eq 0) {
                $out.error = "下载失败：$name（已放弃本次更新，磁盘未改动）"
                return $out
            }
            $text = [System.Text.Encoding]::UTF8.GetString($bytes)
            $check = Test-UpdateContent $name $text
            if (-not $check.ok) {
                $out.error = "校验失败：$($check.reason)（已放弃本次更新，磁盘未改动）"
                return $out
            }
            $staged[$name] = @{ bytes = $bytes }
        }

        # 4) 安装
        $inst = Install-UpdateFiles $staged $targetDir $backupRoot $remote
        $out.files = @($inst.replaced)
        $out.backupDir = $inst.backupDir
        if ($inst.ok) {
            $out.ok = $true; $out.status = 'updated'
        } else {
            $out.error = $inst.error
            if ($inst.rolledBack) { $out.error = $out.error + '（已自动回滚到更新前的版本）' }
        }
        return $out
    } catch {
        $out.error = $_.Exception.Message
        return $out
    }
}
