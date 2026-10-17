@echo off
rem ============================================================
rem  Kun Like Pet - one-click installer (double-click to run)
rem ============================================================
rem  IMPORTANT: everything in this file is intentionally ASCII.
rem  cmd.exe decodes .cmd/.bat with the OEM/ANSI code page, so
rem  non-ASCII bytes in the CONTENT can get mangled on some
rem  systems. (Same reason the desktop .bat launcher is ASCII-only.)
rem  The FILE NAME may be Chinese; the CONTENT must stay ASCII.
rem ============================================================

setlocal
cd /d "%~dp0"

rem ---------------- code page ----------------
rem install.ps1 prints Chinese text encoded as UTF-8. A Chinese
rem Windows console defaults to GBK (936), so that text would render
rem as mojibake and the user could not tell what is happening
rem (observed in testing). Switch this console window to UTF-8 and
rem restore the previous page at the end.
rem This affects only THIS window - it is not a system-wide change.
rem If it fails we carry on: the install still works, only the text
rem on screen would look garbled.
set "OLDCP="
for /f "tokens=2 delims=:" %%a in ('chcp') do set "OLDCP=%%a"
set "OLDCP=%OLDCP: =%"
chcp 65001 >nul 2>&1

echo.
echo Kun Like Pet - installer
echo ========================
echo.
echo This will install the pet and start it.
echo   install dir : %USERPROFILE%\kun-desktop-pet
echo.

rem -ExecutionPolicy Bypass : must work even when the system policy is
rem                           Restricted (verified on such a machine).
rem -NoProfile               : avoid user-profile side effects.
rem -Recommended : one switch that expands to the recommended defaults
rem                (assets + plugin/extension if present + start).
rem                Passing three separate switches here would break as soon as
rem                the user repeats one of them: PowerShell then fails with
rem                "ParameterAlreadyBound" (seen in testing).
rem Deliberately NOT autostart: writing a startup entry should be the
rem user's explicit choice, not a side effect of double-clicking.
powershell.exe -NoProfile -ExecutionPolicy Bypass -File "%~dp0install.ps1" -Recommended %*
set RC=%ERRORLEVEL%

echo.
if not "%RC%"=="0" (
  echo [x] Installer exited with code %RC%.
  echo     Read the messages above for the reason.
) else (
  echo Done. The pet should now be on your desktop.
  echo   A desktop shortcut to start the pet was also created.
  echo   Cannot see it? Press Win+D, or right-click the tray icon
  echo   and pick "reset position".
  echo.
  echo To update later: right-click the pet ^> "check for updates".
)
echo.
echo Press any key to close...
pause >nul

rem restore the console code page we changed above
if not "%OLDCP%"=="" chcp %OLDCP% >nul 2>&1

exit /b %RC%
