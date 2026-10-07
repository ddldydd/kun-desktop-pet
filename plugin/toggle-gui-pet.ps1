<#
  Harness in-page pet - on/off switch (ASCII only, on purpose).

  What it does: toggles the pet overlay inside the Harness web UI
  (the client half of the @local/kun-pet plugin). The host half
  (state machine + /kun-pet/state + /kun-pet/approval) is left alone,
  so the desktop pet kun-pet-desktop keeps its approval list and its
  "which tool is running" detail.

  This script is deliberately 100% ASCII: PowerShell 5.1 decodes a
  .ps1 file using the ANSI code page unless it carries a UTF-8 BOM,
  and mixed encodings corrupt the script. ASCII avoids that whole
  class of failure.

  Usage:
    powershell -NoProfile -ExecutionPolicy Bypass -File toggle-gui-pet.ps1 status
    powershell -NoProfile -ExecutionPolicy Bypass -File toggle-gui-pet.ps1 disable
    powershell -NoProfile -ExecutionPolicy Bypass -File toggle-gui-pet.ps1 restore

  Refresh the Harness page (F5) after switching.
#>
param(
    [ValidateSet('status', 'disable', 'restore')]
    [string]$Action = 'status',

    # Full path to the installed plugin's client.js (optional)
    [string]$ClientPath
)

# Where the plugin lives. Override with -ClientPath if your profile differs.
# Default mirrors install.ps1 -Profile desktop.
$target = $ClientPath
if (-not $target) {
    $target = Join-Path $env:USERPROFILE '.dsh\profiles\desktop\node_modules\@local\kun-pet\client.js'
}
$backup = Join-Path $PSScriptRoot 'client-original.js'

# Semantic signatures. Comparing behaviour instead of whole text blocks
# keeps working even if surrounding comments are edited later. Both are
# ASCII-only on purpose: the option line in between carries non-ASCII text
# (the pet label), so matching across it by character class is fragile.
$sigOn  = "ctx.slots.inject('shell.overlay', () => ctx.slots.register("
$sigOff = "ctx.slots.inject('shell.overlay', () => null);"

# The registration call, in its original (pet visible) form. The live file
# has this call flush at column 0; the pattern below matches it verbatim.
# (?s) is essential: in .NET regex, "." does not match a newline by default,
# and this call spans three lines.
$registerPattern = "(?s)" + [regex]::Escape($sigOn) + ".*?" + [regex]::Escape("KunPet,`n        ));")

# The replacement: inject the slot but never fill it, so nothing renders.
# The author's own comments above stay untouched.
$registerOff = "ctx.slots.inject('shell.overlay', () => null);"

if (-not (Test-Path -LiteralPath $target)) {
    Write-Host ("[x] plugin file not found: " + $target) -ForegroundColor Red
    exit 2
}

$text = [IO.File]::ReadAllText($target, [Text.Encoding]::UTF8)
$norm = $text -replace "`r`n", "`n"

if ($norm.Contains($sigOff)) { $state = 'disabled' }
elseif ($norm.Contains($sigOn)) { $state = 'enabled' }
else { $state = 'unknown' }

Write-Host ("in-page pet state: " + $state)

switch ($Action) {
    'status' { exit 0 }

    'disable' {
        if ($state -eq 'disabled') { Write-Host "already disabled; nothing to do"; exit 0 }
        if ($state -ne 'enabled') {
            Write-Host "[x] client.js does not look like the expected file; no change made" -ForegroundColor Red
            exit 3
        }
        if (-not (Test-Path -LiteralPath $backup)) {
            [IO.File]::WriteAllText($backup, $text, (New-Object Text.UTF8Encoding($false)))
            Write-Host ("backup created: " + $backup)
        }
        if (-not [regex]::IsMatch($norm, $registerPattern)) {
            Write-Host "[x] could not locate the registration block; no change made" -ForegroundColor Red
            exit 3
        }
        $new = [regex]::Replace($norm, $registerPattern, $registerOff, 1)
        [IO.File]::WriteAllText($target, $new, (New-Object Text.UTF8Encoding($false)))
        Write-Host "[ok] in-page pet disabled (host half untouched). Refresh the Harness page." -ForegroundColor Green
    }

    'restore' {
        if ($state -eq 'enabled') { Write-Host "already enabled; nothing to do"; exit 0 }
        if (-not (Test-Path -LiteralPath $backup)) {
            Write-Host ("[x] backup missing, cannot restore: " + $backup) -ForegroundColor Red
            exit 2
        }
        Copy-Item -LiteralPath $backup -Destination $target -Force
        Write-Host "[ok] in-page pet restored. Refresh the Harness page." -ForegroundColor Green
    }
}
