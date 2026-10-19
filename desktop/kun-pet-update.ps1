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
        'kun-pet-ui.ps1',
        'version.json',
        '启动桌宠.vbs',
        '启动桌宠.bat',
        'start-pet.vbs',
        'make-shortcut.ps1',
        'make-icon.ps1'
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
#
# $fetcher 可选：一个 (url) => byte[] 的委托，用于**测试注入假网络**。
# 为什么不靠「测试里重定义同名函数」来替换网络：PowerShell 的函数解析带作用域，
# 在「模块被 dot-source 进来的脚本里重定义」和「CI 的 Linux + pwsh7」组合下
# 行为不一致（本地通过、CI 失败，实测踩到过）。显式传参不依赖任何作用域规则。
function Invoke-PetUpdate([string]$targetDir, [string]$currentVersion, [string]$backupRoot, $fetcher = $null) {
    $out = @{
        ok = $false; status = 'failed'; localVersion = [string]$currentVersion
        remoteVersion = ''; files = @(); backupDir = $null; error = ''; notes = @()
    }
    # 取字节：优先用注入的 fetcher，其次走真实网络
    $fetch = {
        param([string]$url, [int]$timeout)
        if ($null -ne $fetcher) { return (& $fetcher $url $timeout) }
        return (Get-UpdateBytes $url $timeout)
    }
    try {
        $base = [string]$script:updRawBase
        if (-not $base) { $out.error = '未配置更新源'; return $out }

        # 1) 取版本清单
        $manifestBytes = & $fetch ($base + '/desktop/version.json') 30
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
            $bytes = & $fetch $url 30
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


# 安装、升级、以及之后每次启动，都保证桌面有「启动桌宠」快捷方式。
# 已经指向 KunPet 宠物图标的快捷方式保持不动，避免每次打开都换一只。
# 旁边有 make-shortcut.ps1 时用它（从已安装的宠物里随机挑一张）。
# 老版本就地升级时，旧的更新白名单可能还没把那个脚本下载下来，
# 这时用内嵌的备用脚本画一只小宠物，桌面上仍然会出现可双击的图标。
# 备用脚本的正文来自 ensure-pet-shortcut.ps1，改完那个文件后要重新生成下面的 Base64。
$script:petShortcutFallbackB64 = 'IyBGYWxsYmFjayBkZXNrdG9wIHNob3J0Y3V0IHVzZWQgd2hlbiBtYWtlLXNob3J0Y3V0LnBzMSBpcyBub3QgbmV4dCB0byB0aGUgcGV0CiMgeWV0ICh0aGUgZmlyc3QgaW4tYXBwIHVwZGF0ZSBjYW4gcmVwbGFjZSBrdW4tcGV0LWRlc2t0b3AucHMxIHdpdGhvdXQgc2hpcHBpbmcKIyB0aGUgaGVscGVyIHNjcmlwdHMpLiBEcmF3cyBhIHNtYWxsIHBldCwgd3JpdGVzIGEgY2xhc3NpYyBESUIgaWNvbiBvdXRzaWRlIHRoZQojIHByb2plY3QgZm9sZGVyLCBhbmQgY3JlYXRlcyDlkK/liqjmoYzlrqAubG5rLgpwYXJhbSgKICAgIFtQYXJhbWV0ZXIoTWFuZGF0b3J5ID0gJHRydWUpXVtzdHJpbmddJFBldERpciwKICAgIFtzdHJpbmddJERlc2t0b3BEaXIgPSAnJwopCiRFcnJvckFjdGlvblByZWZlcmVuY2UgPSAnU3RvcCcKJHBldERpciA9IChSZXNvbHZlLVBhdGggLUxpdGVyYWxQYXRoICRQZXREaXIpLlBhdGgKJHZicyA9IEpvaW4tUGF0aCAkcGV0RGlyICflkK/liqjmoYzlrqAudmJzJwppZiAoLW5vdCAoVGVzdC1QYXRoIC1MaXRlcmFsUGF0aCAkdmJzKSkgeyB0aHJvdyAibGF1bmNoZXIgbm90IGZvdW5kOiAkdmJzIiB9CmlmICgtbm90ICREZXNrdG9wRGlyKSB7ICREZXNrdG9wRGlyID0gW0Vudmlyb25tZW50XTo6R2V0Rm9sZGVyUGF0aCgnRGVza3RvcCcpIH0KaWYgKC1ub3QgJERlc2t0b3BEaXIpIHsgdGhyb3cgJ2Rlc2t0b3AgZm9sZGVyIHVuYXZhaWxhYmxlJyB9CmlmICgtbm90IChUZXN0LVBhdGggLUxpdGVyYWxQYXRoICREZXNrdG9wRGlyKSkgewogICAgTmV3LUl0ZW0gLUl0ZW1UeXBlIERpcmVjdG9yeSAtUGF0aCAkRGVza3RvcERpciAtRm9yY2UgfCBPdXQtTnVsbAp9CgpBZGQtVHlwZSAtQXNzZW1ibHlOYW1lIFN5c3RlbS5EcmF3aW5nCgpmdW5jdGlvbiBOZXctU29saWQoW2ludF0kciwgW2ludF0kZywgW2ludF0kYikgewogICAgcmV0dXJuIFtTeXN0ZW0uRHJhd2luZy5Db2xvcl06OkZyb21BcmdiKDI1NSwgJHIsICRnLCAkYikKfQoKZnVuY3Rpb24gTmV3LVByb2NlZHVyYWxQZXQoW2ludF0kc2l6ZSwgW1N5c3RlbS5EcmF3aW5nLkNvbG9yXSRiYWRnZSkgewogICAgJGJtcCA9IE5ldy1PYmplY3QgU3lzdGVtLkRyYXdpbmcuQml0bWFwICRzaXplLCAkc2l6ZSwgKFtTeXN0ZW0uRHJhd2luZy5JbWFnaW5nLlBpeGVsRm9ybWF0XTo6Rm9ybWF0MzJicHBBcmdiKQogICAgJGcgPSBbU3lzdGVtLkRyYXdpbmcuR3JhcGhpY3NdOjpGcm9tSW1hZ2UoJGJtcCkKICAgIHRyeSB7CiAgICAgICAgJGcuQ2xlYXIoW1N5c3RlbS5EcmF3aW5nLkNvbG9yXTo6VHJhbnNwYXJlbnQpCiAgICAgICAgJGcuU21vb3RoaW5nTW9kZSA9IFtTeXN0ZW0uRHJhd2luZy5EcmF3aW5nMkQuU21vb3RoaW5nTW9kZV06OkhpZ2hRdWFsaXR5CiAgICAgICAgJGluc2V0ID0gW01hdGhdOjpNYXgoMSwgW2ludF0oJHNpemUgKiAwLjA2KSkKICAgICAgICAkYmIgPSBOZXctT2JqZWN0IFN5c3RlbS5EcmF3aW5nLlNvbGlkQnJ1c2ggJGJhZGdlCiAgICAgICAgdHJ5IHsgJGcuRmlsbEVsbGlwc2UoJGJiLCAkaW5zZXQsICRpbnNldCwgKCRzaXplIC0gKDIgKiAkaW5zZXQpIC0gMSksICgkc2l6ZSAtICgyICogJGluc2V0KSAtIDEpKSB9CiAgICAgICAgZmluYWxseSB7ICRiYi5EaXNwb3NlKCkgfQogICAgICAgICRib2R5ID0gTmV3LVNvbGlkIDI1NSAxNzYgNjQKICAgICAgICAkYmVsbHkgPSBOZXctU29saWQgMjU1IDIzNiAyMTAKICAgICAgICAkaW5rID0gTmV3LVNvbGlkIDQwIDQ4IDYwCiAgICAgICAgJGJvZHlCcnVzaCA9IE5ldy1PYmplY3QgU3lzdGVtLkRyYXdpbmcuU29saWRCcnVzaCAkYm9keQogICAgICAgICRiZWxseUJydXNoID0gTmV3LU9iamVjdCBTeXN0ZW0uRHJhd2luZy5Tb2xpZEJydXNoICRiZWxseQogICAgICAgICRpbmtCcnVzaCA9IE5ldy1PYmplY3QgU3lzdGVtLkRyYXdpbmcuU29saWRCcnVzaCAkaW5rCiAgICAgICAgJHdoaXRlID0gTmV3LU9iamVjdCBTeXN0ZW0uRHJhd2luZy5Tb2xpZEJydXNoIChbU3lzdGVtLkRyYXdpbmcuQ29sb3JdOjpXaGl0ZSkKICAgICAgICAkY2hlZWsgPSBOZXctT2JqZWN0IFN5c3RlbS5EcmF3aW5nLlNvbGlkQnJ1c2ggKFtTeXN0ZW0uRHJhd2luZy5Db2xvcl06OkZyb21BcmdiKDIzMCwgMjU1LCAxNDAsIDE2MCkpCiAgICAgICAgdHJ5IHsKICAgICAgICAgICAgJGN4ID0gJHNpemUgLyAyLjAKICAgICAgICAgICAgJGJvZHlXID0gJHNpemUgKiAwLjU4CiAgICAgICAgICAgICRib2R5SCA9ICRzaXplICogMC40NgogICAgICAgICAgICAkYm9keVggPSAkY3ggLSAoJGJvZHlXIC8gMi4wKQogICAgICAgICAgICAkYm9keVkgPSAkc2l6ZSAqIDAuMzIKICAgICAgICAgICAgJGcuRmlsbEVsbGlwc2UoJGJvZHlCcnVzaCwgKCRjeCAtICRib2R5VyAqIDAuNDIpLCAoJHNpemUgKiAwLjE2KSwgKCRib2R5VyAqIDAuMjYpLCAoJGJvZHlIICogMC40MCkpCiAgICAgICAgICAgICRnLkZpbGxFbGxpcHNlKCRib2R5QnJ1c2gsICgkY3ggKyAkYm9keVcgKiAwLjE2KSwgKCRzaXplICogMC4xNiksICgkYm9keVcgKiAwLjI2KSwgKCRib2R5SCAqIDAuNDApKQogICAgICAgICAgICAkZy5GaWxsRWxsaXBzZSgkYm9keUJydXNoLCAkYm9keVgsICRib2R5WSwgJGJvZHlXLCAkYm9keUgpCiAgICAgICAgICAgICRnLkZpbGxFbGxpcHNlKCRiZWxseUJydXNoLCAoJGN4IC0gJGJvZHlXICogMC4yNiksICgkYm9keVkgKyAkYm9keUggKiAwLjM4KSwgKCRib2R5VyAqIDAuNTIpLCAoJGJvZHlIICogMC40MCkpCiAgICAgICAgICAgICRleWUgPSBbTWF0aF06Ok1heCgyLCBbaW50XSgkc2l6ZSAqIDAuMDcpKQogICAgICAgICAgICAkZXllWSA9IFtpbnRdKCRib2R5WSArICRib2R5SCAqIDAuMjgpCiAgICAgICAgICAgICRnLkZpbGxFbGxpcHNlKCRpbmtCcnVzaCwgW2ludF0oJGN4IC0gJGJvZHlXICogMC4yMiksICRleWVZLCAkZXllLCBbaW50XSgkZXllICogMS4xNSkpCiAgICAgICAgICAgICRnLkZpbGxFbGxpcHNlKCRpbmtCcnVzaCwgW2ludF0oJGN4ICsgJGJvZHlXICogMC4wOCksICRleWVZLCAkZXllLCBbaW50XSgkZXllICogMS4xNSkpCiAgICAgICAgICAgICRnbCA9IFtNYXRoXTo6TWF4KDEsIFtpbnRdKCRleWUgKiAwLjM1KSkKICAgICAgICAgICAgJGcuRmlsbEVsbGlwc2UoJHdoaXRlLCBbaW50XSgkY3ggLSAkYm9keVcgKiAwLjIyICsgJGV5ZSAqIDAuMTUpLCAoJGV5ZVkgKyAxKSwgJGdsLCAkZ2wpCiAgICAgICAgICAgICRnLkZpbGxFbGxpcHNlKCR3aGl0ZSwgW2ludF0oJGN4ICsgJGJvZHlXICogMC4wOCArICRleWUgKiAwLjE1KSwgKCRleWVZICsgMSksICRnbCwgJGdsKQogICAgICAgICAgICAkY2hlZWtXID0gW01hdGhdOjpNYXgoMywgW2ludF0oJHNpemUgKiAwLjA5KSkKICAgICAgICAgICAgJGcuRmlsbEVsbGlwc2UoJGNoZWVrLCBbaW50XSgkY3ggLSAkYm9keVcgKiAwLjM4KSwgW2ludF0oJGV5ZVkgKyAkZXllKSwgJGNoZWVrVywgW2ludF0oJGNoZWVrVyAqIDAuNykpCiAgICAgICAgICAgICRnLkZpbGxFbGxpcHNlKCRjaGVlaywgW2ludF0oJGN4ICsgJGJvZHlXICogMC4yMCksIFtpbnRdKCRleWVZICsgJGV5ZSksICRjaGVla1csIFtpbnRdKCRjaGVla1cgKiAwLjcpKQogICAgICAgIH0gZmluYWxseSB7CiAgICAgICAgICAgICRib2R5QnJ1c2guRGlzcG9zZSgpOyAkYmVsbHlCcnVzaC5EaXNwb3NlKCk7ICRpbmtCcnVzaC5EaXNwb3NlKCk7ICR3aGl0ZS5EaXNwb3NlKCk7ICRjaGVlay5EaXNwb3NlKCkKICAgICAgICB9CiAgICB9IGZpbmFsbHkgeyAkZy5EaXNwb3NlKCkgfQogICAgcmV0dXJuICRibXAKfQoKZnVuY3Rpb24gQ29udmVydFRvLURpYkVudHJ5KFtTeXN0ZW0uRHJhd2luZy5CaXRtYXBdJGJtcCkgewogICAgJHcgPSAkYm1wLldpZHRoCiAgICAkaCA9ICRibXAuSGVpZ2h0CiAgICAkcmVjdCA9IE5ldy1PYmplY3QgU3lzdGVtLkRyYXdpbmcuUmVjdGFuZ2xlIDAsIDAsICR3LCAkaAogICAgJGRhdGEgPSAkYm1wLkxvY2tCaXRzKCRyZWN0LCBbU3lzdGVtLkRyYXdpbmcuSW1hZ2luZy5JbWFnZUxvY2tNb2RlXTo6UmVhZE9ubHksIFtTeXN0ZW0uRHJhd2luZy5JbWFnaW5nLlBpeGVsRm9ybWF0XTo6Rm9ybWF0MzJicHBBcmdiKQogICAgdHJ5IHsKICAgICAgICAkc3RyaWRlID0gJGRhdGEuU3RyaWRlCiAgICAgICAgJHBpeGVscyA9IE5ldy1PYmplY3QgYnl0ZVtdICgkc3RyaWRlICogJGgpCiAgICAgICAgW1N5c3RlbS5SdW50aW1lLkludGVyb3BTZXJ2aWNlcy5NYXJzaGFsXTo6Q29weSgkZGF0YS5TY2FuMCwgJHBpeGVscywgMCwgJHBpeGVscy5MZW5ndGgpCiAgICB9IGZpbmFsbHkgeyAkYm1wLlVubG9ja0JpdHMoJGRhdGEpIH0KICAgICRtYXNrU3RyaWRlID0gW2ludF0oW01hdGhdOjpGbG9vcigoJHcgKyAzMSkgLyAzMikgKiA0KQogICAgJG1hc2sgPSBOZXctT2JqZWN0IGJ5dGVbXSAoJG1hc2tTdHJpZGUgKiAkaCkKICAgICRhbmRCaXQgPSBbYnl0ZVtdXSgweDgwLCAweDQwLCAweDIwLCAweDEwLCAweDA4LCAweDA0LCAweDAyLCAweDAxKQogICAgJG1zID0gTmV3LU9iamVjdCBTeXN0ZW0uSU8uTWVtb3J5U3RyZWFtCiAgICAkYncgPSBOZXctT2JqZWN0IFN5c3RlbS5JTy5CaW5hcnlXcml0ZXIgJG1zCiAgICAkYncuV3JpdGUoW1VJbnQzMl00MCkKICAgICRidy5Xcml0ZShbSW50MzJdJHcpCiAgICAkYncuV3JpdGUoW0ludDMyXSgkaCAqIDIpKQogICAgJGJ3LldyaXRlKFtVSW50MTZdMSkKICAgICRidy5Xcml0ZShbVUludDE2XTMyKQogICAgJGJ3LldyaXRlKFtVSW50MzJdMCkKICAgICRidy5Xcml0ZShbVUludDMyXSgoJHcgKiAkaCAqIDQpICsgKCRtYXNrU3RyaWRlICogJGgpKSkKICAgICRidy5Xcml0ZShbSW50MzJdMCkKICAgICRidy5Xcml0ZShbSW50MzJdMCkKICAgICRidy5Xcml0ZShbVUludDMyXTApCiAgICAkYncuV3JpdGUoW1VJbnQzMl0wKQogICAgZm9yICgkeSA9ICRoIC0gMTsgJHkgLWdlIDA7ICR5LS0pIHsKICAgICAgICAkcm93U3RhcnQgPSAkeSAqICRzdHJpZGUKICAgICAgICAkbWFza1JvdyA9ICgkaCAtIDEgLSAkeSkgKiAkbWFza1N0cmlkZQogICAgICAgIGZvciAoJHggPSAwOyAkeCAtbHQgJHc7ICR4KyspIHsKICAgICAgICAgICAgJGkgPSAkcm93U3RhcnQgKyAoJHggKiA0KQogICAgICAgICAgICAkYSA9ICRwaXhlbHNbJGkgKyAzXQogICAgICAgICAgICBpZiAoJGEgLWx0IDE2KSB7CiAgICAgICAgICAgICAgICAkbWkgPSAkbWFza1JvdyArIFtpbnRdW01hdGhdOjpGbG9vcigkeCAvIDguMCkKICAgICAgICAgICAgICAgICRtYXNrWyRtaV0gPSBbYnl0ZV0oJG1hc2tbJG1pXSAtYm9yICRhbmRCaXRbJHggJSA4XSkKICAgICAgICAgICAgICAgICRidy5Xcml0ZShbYnl0ZV0wKTsgJGJ3LldyaXRlKFtieXRlXTApOyAkYncuV3JpdGUoW2J5dGVdMCk7ICRidy5Xcml0ZShbYnl0ZV0wKQogICAgICAgICAgICB9IGVsc2UgewogICAgICAgICAgICAgICAgJGJ3LldyaXRlKFtieXRlXSRwaXhlbHNbJGldKQogICAgICAgICAgICAgICAgJGJ3LldyaXRlKFtieXRlXSRwaXhlbHNbJGkgKyAxXSkKICAgICAgICAgICAgICAgICRidy5Xcml0ZShbYnl0ZV0kcGl4ZWxzWyRpICsgMl0pCiAgICAgICAgICAgICAgICAkYncuV3JpdGUoW2J5dGVdJGEpCiAgICAgICAgICAgIH0KICAgICAgICB9CiAgICB9CiAgICAkYncuV3JpdGUoJG1hc2spCiAgICAkYncuRmx1c2goKQogICAgJGJ5dGVzID0gJG1zLlRvQXJyYXkoKQogICAgJGJ3LkRpc3Bvc2UoKQogICAgcmV0dXJuICwkYnl0ZXMKfQoKZnVuY3Rpb24gU2F2ZS1QZXRJY28oJGltYWdlcywgW3N0cmluZ10kcGF0aCkgewogICAgJGVudHJpZXMgPSBOZXctT2JqZWN0IFN5c3RlbS5Db2xsZWN0aW9ucy5HZW5lcmljLkxpc3RbYnl0ZVtdXQogICAgZm9yZWFjaCAoJGJtcCBpbiAkaW1hZ2VzKSB7IFt2b2lkXSRlbnRyaWVzLkFkZCgoQ29udmVydFRvLURpYkVudHJ5ICRibXApKSB9CiAgICAkbXMgPSBOZXctT2JqZWN0IFN5c3RlbS5JTy5NZW1vcnlTdHJlYW0KICAgICRidyA9IE5ldy1PYmplY3QgU3lzdGVtLklPLkJpbmFyeVdyaXRlciAkbXMKICAgICRidy5Xcml0ZShbVUludDE2XTApCiAgICAkYncuV3JpdGUoW1VJbnQxNl0xKQogICAgJGJ3LldyaXRlKFtVSW50MTZdJGVudHJpZXMuQ291bnQpCiAgICAkb2Zmc2V0ID0gNiArICgxNiAqICRlbnRyaWVzLkNvdW50KQogICAgZm9yICgkbiA9IDA7ICRuIC1sdCAkZW50cmllcy5Db3VudDsgJG4rKykgewogICAgICAgICRkaW0gPSAkaW1hZ2VzWyRuXS5XaWR0aAogICAgICAgICRiID0gaWYgKCRkaW0gLWdlIDI1NikgeyBbYnl0ZV0wIH0gZWxzZSB7IFtieXRlXSRkaW0gfQogICAgICAgICRidy5Xcml0ZSgkYikKICAgICAgICAkYncuV3JpdGUoJGIpCiAgICAgICAgJGJ3LldyaXRlKFtieXRlXTApCiAgICAgICAgJGJ3LldyaXRlKFtieXRlXTApCiAgICAgICAgJGJ3LldyaXRlKFtVSW50MTZdMSkKICAgICAgICAkYncuV3JpdGUoW1VJbnQxNl0zMikKICAgICAgICAkYncuV3JpdGUoW1VJbnQzMl0kZW50cmllc1skbl0uTGVuZ3RoKQogICAgICAgICRidy5Xcml0ZShbVUludDMyXSRvZmZzZXQpCiAgICAgICAgJG9mZnNldCArPSAkZW50cmllc1skbl0uTGVuZ3RoCiAgICB9CiAgICBmb3JlYWNoICgkZSBpbiAkZW50cmllcykgeyAkYncuV3JpdGUoJGUpIH0KICAgICRidy5GbHVzaCgpCiAgICBbU3lzdGVtLklPLkZpbGVdOjpXcml0ZUFsbEJ5dGVzKCRwYXRoLCAkbXMuVG9BcnJheSgpKQogICAgJGJ3LkRpc3Bvc2UoKQp9CgokY29kZSA9IEAnCnVzaW5nIFN5c3RlbTsKdXNpbmcgU3lzdGVtLlJ1bnRpbWUuSW50ZXJvcFNlcnZpY2VzOwp1c2luZyBTeXN0ZW0uVGV4dDsKCltDb21JbXBvcnQsIEd1aWQoIjAwMDIxNDAxLTAwMDAtMDAwMC1DMDAwLTAwMDAwMDAwMDA0NiIpXQpwdWJsaWMgY2xhc3MgUGV0U2hlbGxMaW5rIHsgfQoKW0NvbUltcG9ydCwgSW50ZXJmYWNlVHlwZShDb21JbnRlcmZhY2VUeXBlLkludGVyZmFjZUlzSVVua25vd24pLCBHdWlkKCIwMDAyMTRGOS0wMDAwLTAwMDAtQzAwMC0wMDAwMDAwMDAwNDYiKV0KcHVibGljIGludGVyZmFjZSBJUGV0U2hlbGxMaW5rVwp7CiAgICB2b2lkIEdldFBhdGgoW091dCwgTWFyc2hhbEFzKFVubWFuYWdlZFR5cGUuTFBXU3RyKV0gU3RyaW5nQnVpbGRlciBwc3pGaWxlLCBpbnQgY2NoLCBJbnRQdHIgcGZkLCB1aW50IGZGbGFncyk7CiAgICB2b2lkIEdldElETGlzdChvdXQgSW50UHRyIHBwaWRsKTsKICAgIHZvaWQgU2V0SURMaXN0KEludFB0ciBwaWRsKTsKICAgIHZvaWQgR2V0RGVzY3JpcHRpb24oW091dCwgTWFyc2hhbEFzKFVubWFuYWdlZFR5cGUuTFBXU3RyKV0gU3RyaW5nQnVpbGRlciBwc3pOYW1lLCBpbnQgY2NoKTsKICAgIHZvaWQgU2V0RGVzY3JpcHRpb24oW01hcnNoYWxBcyhVbm1hbmFnZWRUeXBlLkxQV1N0cildIHN0cmluZyBwc3pOYW1lKTsKICAgIHZvaWQgR2V0V29ya2luZ0RpcmVjdG9yeShbT3V0LCBNYXJzaGFsQXMoVW5tYW5hZ2VkVHlwZS5MUFdTdHIpXSBTdHJpbmdCdWlsZGVyIHBzekRpciwgaW50IGNjaCk7CiAgICB2b2lkIFNldFdvcmtpbmdEaXJlY3RvcnkoW01hcnNoYWxBcyhVbm1hbmFnZWRUeXBlLkxQV1N0cildIHN0cmluZyBwc3pEaXIpOwogICAgdm9pZCBHZXRBcmd1bWVudHMoW091dCwgTWFyc2hhbEFzKFVubWFuYWdlZFR5cGUuTFBXU3RyKV0gU3RyaW5nQnVpbGRlciBwc3pBcmdzLCBpbnQgY2NoKTsKICAgIHZvaWQgU2V0QXJndW1lbnRzKFtNYXJzaGFsQXMoVW5tYW5hZ2VkVHlwZS5MUFdTdHIpXSBzdHJpbmcgcHN6QXJncyk7CiAgICB2b2lkIEdldEhvdGtleShvdXQgc2hvcnQgcHdIb3RrZXkpOwogICAgdm9pZCBTZXRIb3RrZXkoc2hvcnQgd0hvdGtleSk7CiAgICB2b2lkIEdldFNob3dDbWQob3V0IGludCBwaVNob3dDbWQpOwogICAgdm9pZCBTZXRTaG93Q21kKGludCBpU2hvd0NtZCk7CiAgICB2b2lkIEdldEljb25Mb2NhdGlvbihbT3V0LCBNYXJzaGFsQXMoVW5tYW5hZ2VkVHlwZS5MUFdTdHIpXSBTdHJpbmdCdWlsZGVyIHBzekljb25QYXRoLCBpbnQgY2NoLCBvdXQgaW50IHBpSWNvbik7CiAgICB2b2lkIFNldEljb25Mb2NhdGlvbihbTWFyc2hhbEFzKFVubWFuYWdlZFR5cGUuTFBXU3RyKV0gc3RyaW5nIHBzekljb25QYXRoLCBpbnQgaUljb24pOwogICAgdm9pZCBTZXRSZWxhdGl2ZVBhdGgoW01hcnNoYWxBcyhVbm1hbmFnZWRUeXBlLkxQV1N0cildIHN0cmluZyBwc3pQYXRoUmVsLCB1aW50IGR3UmVzZXJ2ZWQpOwogICAgdm9pZCBSZXNvbHZlKEludFB0ciBod25kLCB1aW50IGZGbGFncyk7CiAgICB2b2lkIFNldFBhdGgoW01hcnNoYWxBcyhVbm1hbmFnZWRUeXBlLkxQV1N0cildIHN0cmluZyBwc3pGaWxlKTsKfQoKW0NvbUltcG9ydCwgSW50ZXJmYWNlVHlwZShDb21JbnRlcmZhY2VUeXBlLkludGVyZmFjZUlzSVVua25vd24pLCBHdWlkKCIwMDAwMDEwYi0wMDAwLTAwMDAtQzAwMC0wMDAwMDAwMDAwNDYiKV0KcHVibGljIGludGVyZmFjZSBJUGV0UGVyc2lzdEZpbGUKewogICAgdm9pZCBHZXRDbGFzc0lEKG91dCBHdWlkIHBDbGFzc0lEKTsKICAgIFtQcmVzZXJ2ZVNpZ10gaW50IElzRGlydHkoKTsKICAgIHZvaWQgTG9hZChbTWFyc2hhbEFzKFVubWFuYWdlZFR5cGUuTFBXU3RyKV0gc3RyaW5nIHBzekZpbGVOYW1lLCB1aW50IGR3TW9kZSk7CiAgICB2b2lkIFNhdmUoW01hcnNoYWxBcyhVbm1hbmFnZWRUeXBlLkxQV1N0cildIHN0cmluZyBwc3pGaWxlTmFtZSwgW01hcnNoYWxBcyhVbm1hbmFnZWRUeXBlLkJvb2wpXSBib29sIGZSZW1lbWJlcik7CiAgICB2b2lkIFNhdmVDb21wbGV0ZWQoW01hcnNoYWxBcyhVbm1hbmFnZWRUeXBlLkxQV1N0cildIHN0cmluZyBwc3pGaWxlTmFtZSk7CiAgICB2b2lkIEdldEN1ckZpbGUoW01hcnNoYWxBcyhVbm1hbmFnZWRUeXBlLkxQV1N0cildIG91dCBzdHJpbmcgcHBzekZpbGVOYW1lKTsKfQoKcHVibGljIHN0YXRpYyBjbGFzcyBQZXRMbmsKewogICAgW0RsbEltcG9ydCgic2hlbGwzMi5kbGwiKV0KICAgIHN0YXRpYyBleHRlcm4gdm9pZCBTSENoYW5nZU5vdGlmeSh1aW50IHdFdmVudElkLCB1aW50IHVGbGFncywgSW50UHRyIGR3SXRlbTEsIEludFB0ciBkd0l0ZW0yKTsKCiAgICBwdWJsaWMgc3RhdGljIHZvaWQgQ3JlYXRlKHN0cmluZyBsbmtQYXRoLCBzdHJpbmcgdGFyZ2V0LCBzdHJpbmcgYXJncywgc3RyaW5nIHdvcmtEaXIsIHN0cmluZyBpY29uUGF0aCwgc3RyaW5nIGRlc2MpCiAgICB7CiAgICAgICAgSVBldFNoZWxsTGlua1cgbGluayA9IChJUGV0U2hlbGxMaW5rVyluZXcgUGV0U2hlbGxMaW5rKCk7CiAgICAgICAgbGluay5TZXRQYXRoKHRhcmdldCk7CiAgICAgICAgbGluay5TZXRBcmd1bWVudHMoYXJncyk7CiAgICAgICAgbGluay5TZXRXb3JraW5nRGlyZWN0b3J5KHdvcmtEaXIpOwogICAgICAgIGxpbmsuU2V0RGVzY3JpcHRpb24oZGVzYyk7CiAgICAgICAgbGluay5TZXRJY29uTG9jYXRpb24oaWNvblBhdGgsIDApOwogICAgICAgIGxpbmsuU2V0U2hvd0NtZCgxKTsKICAgICAgICAoKElQZXRQZXJzaXN0RmlsZSlsaW5rKS5TYXZlKGxua1BhdGgsIHRydWUpOwogICAgICAgIE1hcnNoYWwuUmVsZWFzZUNvbU9iamVjdChsaW5rKTsKICAgIH0KCiAgICBwdWJsaWMgc3RhdGljIHN0cmluZyBSZWFkKHN0cmluZyBsbmtQYXRoKQogICAgewogICAgICAgIElQZXRTaGVsbExpbmtXIGxpbmsgPSAoSVBldFNoZWxsTGlua1cpbmV3IFBldFNoZWxsTGluaygpOwogICAgICAgICgoSVBldFBlcnNpc3RGaWxlKWxpbmspLkxvYWQobG5rUGF0aCwgMCk7CiAgICAgICAgdmFyIHNiQSA9IG5ldyBTdHJpbmdCdWlsZGVyKDEwMjQpOyBsaW5rLkdldEFyZ3VtZW50cyhzYkEsIDEwMjQpOwogICAgICAgIHZhciBzYkkgPSBuZXcgU3RyaW5nQnVpbGRlcigxMDI0KTsgaW50IGlkeDsgbGluay5HZXRJY29uTG9jYXRpb24oc2JJLCAxMDI0LCBvdXQgaWR4KTsKICAgICAgICBNYXJzaGFsLlJlbGVhc2VDb21PYmplY3QobGluayk7CiAgICAgICAgcmV0dXJuIHNiQS5Ub1N0cmluZygpICsgIlxuIiArIHNiSS5Ub1N0cmluZygpICsgIiwiICsgaWR4OwogICAgfQoKICAgIHB1YmxpYyBzdGF0aWMgdm9pZCBOb3RpZnkoc3RyaW5nIHBhdGgpCiAgICB7CiAgICAgICAgSW50UHRyIHAgPSBNYXJzaGFsLlN0cmluZ1RvQ29UYXNrTWVtVW5pKHBhdGgpOwogICAgICAgIHRyeSB7IFNIQ2hhbmdlTm90aWZ5KDB4MDAwMDIwMDAsIDB4MDAwNSwgcCwgSW50UHRyLlplcm8pOyB9CiAgICAgICAgZmluYWxseSB7IE1hcnNoYWwuRnJlZUNvVGFza01lbShwKTsgfQogICAgfQp9CidACmlmICgtbm90ICgnUGV0TG5rJyAtYXMgW3R5cGVdKSkgeyBBZGQtVHlwZSAtVHlwZURlZmluaXRpb24gJGNvZGUgLUxhbmd1YWdlIENTaGFycCB9CgokcGFsZXR0ZSA9IEAoCiAgICAoTmV3LVNvbGlkIDI0NiAyMTQgMjI0KSwKICAgIChOZXctU29saWQgMjE0IDIzMiAyNDYpLAogICAgKE5ldy1Tb2xpZCAyMzIgMjQ2IDIxNCksCiAgICAoTmV3LVNvbGlkIDI0NiAyMzIgMjE0KSwKICAgIChOZXctU29saWQgMjI0IDIxNCAyNDYpLAogICAgKE5ldy1Tb2xpZCAyMTQgMjQ2IDIzOCkKKQokYmFkZ2UgPSAkcGFsZXR0ZVsoR2V0LVJhbmRvbSAtTWluaW11bSAwIC1NYXhpbXVtICRwYWxldHRlLkNvdW50KV0KJGJtcHMgPSBOZXctT2JqZWN0IFN5c3RlbS5Db2xsZWN0aW9ucy5HZW5lcmljLkxpc3RbU3lzdGVtLkRyYXdpbmcuQml0bWFwXQp0cnkgewogICAgZm9yZWFjaCAoJHMgaW4gQCgxNiwgMzIsIDQ4LCAyNTYpKSB7IFt2b2lkXSRibXBzLkFkZCgoTmV3LVByb2NlZHVyYWxQZXQgJHMgJGJhZGdlKSkgfQogICAgJHNoZWxsSWNvbkRpciA9IEpvaW4tUGF0aCAkZW52OkxPQ0FMQVBQREFUQSAnS3VuUGV0JwogICAgaWYgKC1ub3QgKFRlc3QtUGF0aCAtTGl0ZXJhbFBhdGggJHNoZWxsSWNvbkRpcikpIHsKICAgICAgICBOZXctSXRlbSAtSXRlbVR5cGUgRGlyZWN0b3J5IC1QYXRoICRzaGVsbEljb25EaXIgLUZvcmNlIHwgT3V0LU51bGwKICAgIH0KICAgIEdldC1DaGlsZEl0ZW0gLUxpdGVyYWxQYXRoICRzaGVsbEljb25EaXIgLUZpbHRlciAna3VuLXBldC0qLmljbycgLUZpbGUgLUVycm9yQWN0aW9uIFNpbGVudGx5Q29udGludWUgfAogICAgICAgIFJlbW92ZS1JdGVtIC1Gb3JjZSAtRXJyb3JBY3Rpb24gU2lsZW50bHlDb250aW51ZQogICAgJHNoZWxsSWNvID0gSm9pbi1QYXRoICRzaGVsbEljb25EaXIgKCdrdW4tcGV0LXswfS5pY28nIC1mIChHZXQtRGF0ZSAtRm9ybWF0ICd5eXl5TU1kZEhIbW1zcycpKQogICAgU2F2ZS1QZXRJY28gJGJtcHMgJHNoZWxsSWNvCn0gZmluYWxseSB7CiAgICBmb3JlYWNoICgkYm1wIGluICRibXBzKSB7IGlmICgkYm1wKSB7ICRibXAuRGlzcG9zZSgpIH0gfQp9CgokbG5rUGF0aCA9IEpvaW4tUGF0aCAkRGVza3RvcERpciAn5ZCv5Yqo5qGM5a6gLmxuaycKJHdzY3JpcHQgPSBKb2luLVBhdGggJGVudjpXSU5ESVIgJ1N5c3RlbTMyXHdzY3JpcHQuZXhlJwpbUGV0TG5rXTo6Q3JlYXRlKCRsbmtQYXRoLCAkd3NjcmlwdCwgKCciJyArICR2YnMgKyAnIicpLCAkcGV0RGlyLCAkc2hlbGxJY28sICdLdW4gTGlrZSBkZXNrdG9wIHBldCcpCltQZXRMbmtdOjpOb3RpZnkoJGxua1BhdGgpCltQZXRMbmtdOjpOb3RpZnkoJHNoZWxsSWNvKQoKJG9sZCA9IEpvaW4tUGF0aCAkRGVza3RvcERpciAn5Z2k5qGM5a6gLmxuaycKaWYgKFRlc3QtUGF0aCAtTGl0ZXJhbFBhdGggJG9sZCkgewogICAgdHJ5IHsKICAgICAgICAkciA9IFtQZXRMbmtdOjpSZWFkKCRvbGQpCiAgICAgICAgaWYgKCRyLkluZGV4T2YoJHZicywgW1N0cmluZ0NvbXBhcmlzb25dOjpPcmRpbmFsSWdub3JlQ2FzZSkgLWdlIDApIHsKICAgICAgICAgICAgUmVtb3ZlLUl0ZW0gLUxpdGVyYWxQYXRoICRvbGQgLUZvcmNlCiAgICAgICAgICAgIFtQZXRMbmtdOjpOb3RpZnkoJG9sZCkKICAgICAgICB9CiAgICB9IGNhdGNoIHsgfQp9CgokcmVhZGJhY2sgPSBbUGV0TG5rXTo6UmVhZCgkbG5rUGF0aCkKaWYgKCRyZWFkYmFjay5JbmRleE9mKCdcS3VuUGV0XGt1bi1wZXQtJywgW1N0cmluZ0NvbXBhcmlzb25dOjpPcmRpbmFsSWdub3JlQ2FzZSkgLWx0IDApIHsKICAgIHRocm93ICdpY29uIHBhdGggd2FzIG5vdCBzdG9yZWQgaW4gdGhlIHNob3J0Y3V0Jwp9CldyaXRlLU91dHB1dCAoImNyZWF0ZWQ9IiArICRsbmtQYXRoKQpXcml0ZS1PdXRwdXQgJ1JFU1VMVCBidWlsdGluJwpXcml0ZS1PdXRwdXQgJ1ZFUklGWT1QQVNTJwo='

function Ensure-PetDesktopShortcut {
    param([string]$PetDir)
    try {
        if (-not $PetDir) { return }
        $vbsName = -join @(
            [char]0x542F, [char]0x52A8, [char]0x684C, [char]0x5BA0, '.vbs'
        )
        $lnkName = -join @(
            [char]0x542F, [char]0x52A8, [char]0x684C, [char]0x5BA0, '.lnk'
        )
        $legacyName = -join @(
            [char]0x5764, [char]0x684C, [char]0x5BA0, '.lnk'
        )
        $vbs = Join-Path $PetDir $vbsName
        if (-not (Test-Path -LiteralPath $vbs)) { return }
        $desktop = [Environment]::GetFolderPath('Desktop')
        if (-not $desktop) { return }
        $lnkPath = Join-Path $desktop $lnkName
        $legacy = Join-Path $desktop $legacyName
        $ready = $false
        if (Test-Path -LiteralPath $lnkPath) {
            try {
                $wsh = New-Object -ComObject WScript.Shell
                $lnk = $wsh.CreateShortcut($lnkPath)
                $icon = [string]$lnk.IconLocation
                $args = [string]$lnk.Arguments
                if ($icon -like '*\KunPet\kun-pet-*' -and $args.IndexOf($vbs, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    $ready = $true
                }
            } catch { }
        }
        if (Test-Path -LiteralPath $legacy) {
            try {
                $wsh2 = New-Object -ComObject WScript.Shell
                $old = $wsh2.CreateShortcut($legacy)
                $oldArgs = [string]$old.Arguments
                if ($oldArgs.IndexOf($vbs, [StringComparison]::OrdinalIgnoreCase) -ge 0) {
                    Remove-Item -LiteralPath $legacy -Force -ErrorAction SilentlyContinue
                }
            } catch { }
        }
        if ($ready) { return }
        $psExe = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
        $maker = Join-Path $PetDir 'make-shortcut.ps1'
        if (Test-Path -LiteralPath $maker) {
            Start-Process -FilePath $psExe -ArgumentList @(
                '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $maker,
                '-PetDir', $PetDir, '-Ensure'
            ) -WindowStyle Hidden | Out-Null
            return
        }
        $dir = Join-Path $env:LOCALAPPDATA 'KunPet'
        if (-not (Test-Path -LiteralPath $dir)) {
            New-Item -ItemType Directory -Path $dir -Force | Out-Null
        }
        $fallback = Join-Path $dir 'ensure-pet-shortcut.ps1'
        $sibling = Join-Path $PetDir 'ensure-pet-shortcut.ps1'
        $utf8 = New-Object System.Text.UTF8Encoding $true
        if (Test-Path -LiteralPath $sibling) {
            $raw = [System.IO.File]::ReadAllText($sibling, [System.Text.Encoding]::UTF8)
        } else {
            $raw = [System.Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($script:petShortcutFallbackB64))
        }
        [System.IO.File]::WriteAllText($fallback, $raw, $utf8)
        Start-Process -FilePath $psExe -ArgumentList @(
            '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', $fallback, '-PetDir', $PetDir
        ) -WindowStyle Hidden | Out-Null
    } catch { }
}
