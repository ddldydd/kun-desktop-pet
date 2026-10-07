@echo off
rem ============================================================
rem  Kun Like Pet - autostart entry
rem  Puts the pet on the Windows desktop right after logon.
rem
rem  Disable autostart: delete this file (the pet itself is unaffected).
rem
rem  This file and its helper are deliberately 100% ASCII, because
rem  cmd.exe can mangle non-ASCII bytes on some code pages.
rem
rem  NOTE: the path below is written by install.ps1 at install time.
rem        If you move the pet folder, re-run install.ps1 -Autostart
rem        or edit the path by hand.
rem ============================================================

rem Ask the helper whether the pet is already up (it verifies the real
rem window, so unrelated shells that merely mention the pet path cannot
rem suppress the launch). If the helper is unavailable, fall through and
rem launch anyway - the pet script owns a single-instance mutex.
if exist "%~dp0KunPet-pet-running.ps1" (
  powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0KunPet-pet-running.ps1" >nul 2>nul
  if errorlevel 1 exit /b 0
)

start "" /b wscript.exe //nologo "{{PET_VBS}}"
exit /b 0
