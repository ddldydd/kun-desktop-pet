@echo off
rem Kun Like Pet - desktop pet launcher (double-click to run).
rem Prefer the .vbs twin: it shows no console window at all; this .bat also hides
rem the window but cmd.exe may flash briefly.
rem
rem -STA is required by WPF and by the tray icon.
rem $cwd is passed explicitly and the working directory is switched: when the
rem script runs via ScriptBlock::Create, $PSScriptRoot is empty, and it is what
rem locates kun-pet-settings.json (otherwise autostart and double-click would
rem each read their own copy).
rem
rem Everything here except the command line is intentionally ASCII: cmd.exe
rem decodes .bat files using the OEM/ANSI code page, so non-ASCII bytes can get
rem mangled on some systems.
start "" /min powershell.exe -NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -Command "Set-Location -LiteralPath '%~dp0.'; $cwd='%~dp0.'; $c=[IO.File]::ReadAllText('%~dp0kun-pet-desktop.ps1',[Text.Encoding]::UTF8); & ([ScriptBlock]::Create($c))"
exit /b 0
