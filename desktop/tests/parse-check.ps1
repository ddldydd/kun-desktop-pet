# 语法解析检查：不执行脚本，只确认所有 .ps1 能被 PowerShell 5.1 解析。
# 用法：powershell -NoProfile -ExecutionPolicy Bypass -File tests/parse-check.ps1
$ErrorActionPreference = 'Stop'
$here = $PSScriptRoot
if (-not $here) { $here = Split-Path -Parent $MyInvocation.MyCommand.Path }
$root = Split-Path -Parent $here

$failed = $false
foreach ($name in @('kun-pet-desktop.ps1', 'kun-pet-ui.ps1', 'kun-pet-wander.ps1', 'kun-pet-pi-source.ps1', 'kun-pet-update.ps1')) {
    $path = Join-Path $root $name
    if (-not (Test-Path -LiteralPath $path)) { Write-Host ("[skip] " + $name) ; continue }
    $errors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($path, [ref]$null, [ref]$errors)
    if ($errors -and $errors.Count -gt 0) {
        $failed = $true
        foreach ($e in $errors) {
            Write-Host ("[FAIL] {0}: {1} @line {2}" -f $name, $e.Message, $e.Extent.StartLineNumber) -ForegroundColor Red
        }
    } else {
        Write-Host ("[ok]   " + $name) -ForegroundColor Green
    }
}
if ($failed) { exit 1 } else { Write-Host 'parse OK: all files'; exit 0 }
