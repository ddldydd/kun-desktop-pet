# Convert given files to UTF-8 with BOM (PowerShell 5.1 requires BOM to read UTF-8 correctly)
param([string[]]$Files)
foreach ($f in $Files) {
    $text = [System.IO.File]::ReadAllText($f, [System.Text.Encoding]::UTF8)
    [System.IO.File]::WriteAllText($f, $text, (New-Object System.Text.UTF8Encoding($true)))
    Write-Host ("BOM added: " + $f)
}
