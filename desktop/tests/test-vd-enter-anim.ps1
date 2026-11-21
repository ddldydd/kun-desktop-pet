# Runtime smoke test for the configurable virtual-desktop enter animations
# (vdEnterAnim: off / simple / bounce / run-in / teleport / random).
#
# How it works: the real animation functions (Play-DesktopEnterAnimation +
# Invoke-VdEnter*) are extracted from kun-pet-desktop.ps1 via the PS parser,
# so the test always exercises the shipped code, not a copy. They run against
# a minimal WPF window that replicates the transform chain (rootLayer +
# enterOffset + enterScale). Wander / Set-Action / logging are stubbed.
#
# Run: powershell -NoProfile -STA -ExecutionPolicy Bypass -File tests\test-vd-enter-anim.ps1

$ErrorActionPreference = 'Stop'
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$mainScript = Join-Path (Split-Path -Parent $here) 'kun-pet-desktop.ps1'

$script:checks = 0
$script:fails  = 0
function Check([string]$name, [bool]$cond) {
    $script:checks++
    if ($cond) { Write-Host ("  [ok]   " + $name) }
    else       { Write-Host ("  [FAIL] " + $name); $script:fails++ }
}

# ---- extract the shipped functions by name from the main script ----
$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($mainScript, [ref]$tokens, [ref]$errors)
if ($errors.Count -gt 0) { throw ('parse errors in main script: ' + $errors.Count) }
$wanted = @('Play-DesktopEnterAnimation', 'Invoke-VdEnterSimple', 'Invoke-VdEnterBounce',
            'Invoke-VdEnterTeleport', 'Invoke-VdEnterDrop', 'Invoke-VdEnterRunIn',
            'Test-VdEnterBusy', 'Stop-VdEnterWindowAnim', 'Add-EnterBeginTime')
$funcs = $ast.FindAll({ param($a) $a -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $wanted -contains $a.Name }, $true)
Check 'extract: all 9 enter-anim functions found' ($funcs.Count -eq $wanted.Count)
foreach ($f in $funcs) { Invoke-Expression $f.Extent.Text }
# top-level constants live outside functions in the main script, so set them here too
$script:vdEnterDelayMs = 260
$script:vdEnterRunPaceX = 1.4
$script:vdEnterRunMaxMs = 3200

# ---- fake environment ----
$script:state = @{ vdEnterAnim = 'simple' }
$script:actions = New-Object System.Collections.ArrayList
function Set-Action([string]$action, [int]$holdMs) {
    [void]$script:actions.Add(@{ dir = $action; holdMs = $holdMs })
}
function Get-VirtualScreenBounds { return @{ Left = 0.0; Top = 0.0; Right = 1920.0; Bottom = 1040.0 } }
function Write-Log([string]$m) { $script:lastLog = $m }
$script:lastLog = ''
$script:tickErrors = New-Object System.Collections.ArrayList
function Note-TickError([string]$tag, [object]$err) {
    [void]$script:tickErrors.Add($tag)
    Write-Host ('  [tick-err] ' + $tag + ': ' + $err.Exception.Message)
}

Add-Type -AssemblyName PresentationFramework, WindowsBase
$script:rootLayerEl = New-Object System.Windows.Controls.Grid
$script:enterOffsetEl = New-Object System.Windows.Media.TranslateTransform
$script:enterScaleEl = New-Object System.Windows.Media.ScaleTransform
$script:rootLayerEl.RenderTransform = New-Object System.Windows.Media.TransformGroup
[void]$script:rootLayerEl.RenderTransform.Children.Add($script:enterOffsetEl)
[void]$script:rootLayerEl.RenderTransform.Children.Add($script:enterScaleEl)
# stand-in for the pet body element: run-in measures its rect inside the window
$script:petShellEl = New-Object System.Windows.Controls.Grid
[void]$script:rootLayerEl.Children.Add($script:petShellEl)

$script:window = New-Object System.Windows.Window
$script:window.Width = 120; $script:window.Height = 120
$script:window.Left = 500.0; $script:window.Top = 500.0
$script:rootLayerEl.Width = 120; $script:rootLayerEl.Height = 120
$script:window.Content = $script:rootLayerEl
$script:window.Show()
$script:window.UpdateLayout()

# pump the dispatcher so WPF animation clocks advance (console host has no message loop)
function Wait-Dispatcher([int]$ms) {
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($sw.ElapsedMilliseconds -lt $ms) {
        try { $script:window.Dispatcher.Invoke([action]{}, [System.Windows.Threading.DispatcherPriority]::Background) } catch { }
        Start-Sleep -Milliseconds 15
    }
}

$finalLeft = 500.0

# ---- off: must not touch Opacity at all ----
$script:state.vdEnterAnim = 'off'
$script:rootLayerEl.Opacity = 0.37
Play-DesktopEnterAnimation
Check 'off: opacity untouched' ([math]::Abs($script:rootLayerEl.Opacity - 0.37) -lt 0.001)
$script:rootLayerEl.Opacity = 1.0

# ---- each real style: opacity pre-darkened, back to 1 after the anim ----
# NOTE: while a previous HoldEnd animation is active, the *current* Opacity still
# reads the old held value right after BeginAnimation (first eased frame lands on
# the next render). The deterministic signal is the BASE value, which the
# pre-darkening assignment sets to 0 synchronously. Visual correctness in the real
# flow comes from MoveTo + assignment + BeginAnimation happening in one dispatcher
# callback, so no frame renders in between.
foreach ($style in @('simple', 'bounce', 'teleport')) {
    $script:state.vdEnterAnim = $style
    $script:rootLayerEl.Opacity = 1.0
    Play-DesktopEnterAnimation
    Check ($style + ': pre-darkened (base opacity = 0)') ($script:rootLayerEl.GetAnimationBaseValue([System.Windows.UIElement]::OpacityProperty) -eq 0.0)
    Wait-Dispatcher 1200
    Check ($style + ': opacity restored to 1') ([math]::Abs($script:rootLayerEl.Opacity - 1.0) -lt 0.001)
    Check ($style + ': scale settled at 1') ([math]::Abs($script:enterScaleEl.ScaleX - 1.0) -lt 0.01)
    Check ($style + ': no tick error') ($script:tickErrors.Count -eq 0)
}

# ---- drop: falls from above with a bounce, window-level animation + busy guard ----
$script:state.vdEnterAnim = 'drop'
$script:rootLayerEl.Opacity = 1.0
$finalTop = [double]$script:window.Top
Play-DesktopEnterAnimation
Check 'drop: pre-darkened (base opacity = 0)' ($script:rootLayerEl.GetAnimationBaseValue([System.Windows.UIElement]::OpacityProperty) -eq 0.0)
$msd = [int]($script:vdEnterBusyUntil - (Get-Date)).TotalMilliseconds
Check ('drop: busy covers delay+fall (1100-1300ms, got ' + $msd + ')') ($msd -gt 1100 -and $msd -lt 1300)
Wait-Dispatcher 1400
Check 'drop: opacity restored to 1' ([math]::Abs($script:rootLayerEl.Opacity - 1.0) -lt 0.001)
Check 'drop: window landed on final Top' ([math]::Abs($script:window.Top - $finalTop) -lt 0.5)
Check 'drop: busy expired after timeout' (-not (Test-VdEnterBusy))

# ---- run-in: real window move + walking action + busy window ----
$script:state.vdEnterAnim = 'run-in'
$script:rootLayerEl.Opacity = 1.0
$script:actions.Clear()
Play-DesktopEnterAnimation
Check 'run-in: pre-darkened (base opacity = 0)' ($script:rootLayerEl.GetAnimationBaseValue([System.Windows.UIElement]::OpacityProperty) -eq 0.0)
Check 'run-in: busy window active' (Test-VdEnterBusy)
# test geometry: pet body = full 120px window, pet center left of mid -> left-edge entry,
# dist 626px > maxDist (105px/s * 3.2s = 336px) -> start pulled inward, run capped at 3200ms
# busy = delay 260 + run 3200 + slack 300 = 3760
$ms = [int]($script:vdEnterBusyUntil - (Get-Date)).TotalMilliseconds
Check ('run-in: busy covers delay+run (3600-3900ms, got ' + $ms + ')') ($ms -gt 3600 -and $ms -lt 3900)
Check 'run-in: walking action set' ($script:actions.Count -ge 1 -and $script:actions[0].dir -in @('running-left', 'running-right'))
Check 'run-in: action hold >= delay+run duration' ([int]$script:actions[0].holdMs -ge 3500)
Wait-Dispatcher 3800
Check 'run-in: opacity restored to 1' ([math]::Abs($script:rootLayerEl.Opacity - 1.0) -lt 0.001)
Check 'run-in: window landed on final Left' ([math]::Abs($script:window.Left - $finalLeft) -lt 0.5)
Start-Sleep -Milliseconds 200
Check 'run-in: busy expired after timeout' (-not (Test-VdEnterBusy))

# ---- Stop-VdEnterRunIn: drag takeover stops the Left animation ----
Play-DesktopEnterAnimation
Check 'run-in (2nd): busy active again' (Test-VdEnterBusy)
Stop-VdEnterWindowAnim
Check 'run-in: stop clears busy' (-not (Test-VdEnterBusy))
Check 'run-in: stop removes Left animation (value = base)' ([math]::Abs($script:window.Left - $finalLeft) -lt 0.5)
Wait-Dispatcher 400
Check 'run-in: opacity not stuck at 0 after stop' ([math]::Abs($script:rootLayerEl.Opacity - 1.0) -lt 0.01)

# ---- random: always resolves to a real style, never off ----
$seen = @{}
for ($i = 0; $i -lt 24; $i++) {
    $script:state.vdEnterAnim = 'random'
    Play-DesktopEnterAnimation
    Wait-Dispatcher 30
    if ($script:lastLog -match 'enter animation \((\S+) #') { $seen[$Matches[1]] = $true }
    Wait-Dispatcher 500
}
$bad = @($seen.Keys | Where-Object { $_ -notin @('simple', 'bounce', 'run-in', 'teleport', 'drop') })
Check ('random: only real styles observed (got: ' + (($seen.Keys | Sort-Object) -join ',') + ')') ($bad.Count -eq 0 -and $seen.Count -ge 2)
Check 'random: no tick errors across 24 runs' ($script:tickErrors.Count -eq 0)

# ---- unknown value falls back to simple ----
$script:state.vdEnterAnim = 'bogus-value'
$script:rootLayerEl.Opacity = 1.0
Play-DesktopEnterAnimation
Check 'unknown: falls back, pre-darkened (base opacity = 0)' ($script:rootLayerEl.GetAnimationBaseValue([System.Windows.UIElement]::OpacityProperty) -eq 0.0)
Wait-Dispatcher 1200
Check 'unknown: opacity restored to 1' ([math]::Abs($script:rootLayerEl.Opacity - 1.0) -lt 0.001)

try { $script:window.Close() } catch { }

Write-Host ''
if ($script:fails -eq 0) { Write-Host ('ALL PASS: ' + $script:checks + ' checks') }
else { Write-Host ('FAILED: ' + $script:fails + ' / ' + $script:checks); exit 1 }
