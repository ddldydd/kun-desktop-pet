# Add a UTF-8 BOM to .ps1 files that contain non-ASCII characters.
#
# WHY THIS IS REQUIRED (measured, not guessed):
#   Windows PowerShell 5.1 reads a .ps1 with no BOM using the system ANSI code page
#   (GBK on a Chinese Windows). Two consequences:
#     1) every Chinese string/comment is mojibake (bubbles show garbage);
#     2) worse, some GBK byte pairs swallow the following quote character, which is a
#        hard SYNTAX ERROR and the script will not run at all.
#   Measured: install.ps1 / uninstall.ps1 / tests/test-pi-source.ps1 all fail to parse
#   when run via `powershell -File`. The VBS launcher only survives because it reads
#   the script itself with [IO.File]::ReadAllText(path, UTF8) and runs it from a
#   ScriptBlock.
#
#   docs/troubleshooting.md already claims "repo files carry a UTF-8 BOM", so a BOM was
#   always the intent - the files simply never had one. This script fixes that.
#
# NOTE: this file is intentionally 100% ASCII so it can run before any BOM is added.
#
# Usage:
#   powershell -NoProfile -ExecutionPolicy Bypass -File .\tools\add-bom.ps1 -Path <dir-or-file>...
#   add -WhatIfOnly to only report.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, ValueFromRemainingArguments = $true)]
    [string[]]$Path,
    [switch]$WhatIfOnly
)

$utf8Bom = New-Object System.Text.UTF8Encoding($true)

function Test-HasBom([byte[]]$bytes) {
    return ($bytes.Length -ge 3 -and $bytes[0] -eq 0xEF -and $bytes[1] -eq 0xBB -and $bytes[2] -eq 0xBF)
}

function Test-IsAscii([string]$text) {
    foreach ($ch in $text.ToCharArray()) { if ([int]$ch -gt 127) { return $false } }
    return $true
}

$files = New-Object System.Collections.ArrayList
foreach ($p in $Path) {
    if (-not (Test-Path -LiteralPath $p)) { Write-Host ("skip (not found): " + $p); continue }
    $item = Get-Item -LiteralPath $p
    if ($item.PSIsContainer) {
        foreach ($f in Get-ChildItem -LiteralPath $p -Recurse -Filter *.ps1 -File) { [void]$files.Add($f) }
    } else {
        [void]$files.Add($item)
    }
}

$added = 0; $already = 0; $ascii = 0
foreach ($f in $files) {
    $bytes = [IO.File]::ReadAllBytes($f.FullName)
    if (Test-HasBom $bytes) { $already++; continue }

    # No BOM: the file really is UTF-8, so decode as UTF-8 before rewriting.
    $text = [Text.Encoding]::UTF8.GetString($bytes)
    if (Test-IsAscii $text) { $ascii++; continue }

    if ($WhatIfOnly) {
        Write-Host ("[needs BOM] " + $f.FullName)
        continue
    }
    # Write back with BOM; content is byte-identical apart from the BOM.
    [IO.File]::WriteAllText($f.FullName, $text, $utf8Bom)
    $added++
    Write-Host ("[BOM added] " + $f.FullName)
}

Write-Output ("added: {0} | already had BOM: {1} | pure ASCII skipped: {2} | scanned: {3}" -f $added, $already, $ascii, $files.Count)
