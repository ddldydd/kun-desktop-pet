' Kun Like Pet - silent launcher (no console window)
' Double-click this file to start the desktop pet.
' -STA is required by WPF and the tray icon.
Option Explicit
Dim fso, sh, base, ps1, cmd
Set fso = CreateObject("Scripting.FileSystemObject")
Set sh = CreateObject("WScript.Shell")
base = fso.GetParentFolderName(WScript.ScriptFullName)
ps1 = base & "\kun-pet-desktop.ps1"
' Pass $cwd explicitly and switch the working directory: $PSScriptRoot is empty
' when the script runs via ScriptBlock::Create, and it is what locates
' kun-pet-settings.json (otherwise autostart and double-click would each read
' their own copy).
cmd = "powershell.exe -NoProfile -STA -ExecutionPolicy Bypass -Command ""Set-Location -LiteralPath '" & base & "'; $cwd='" & base & "'; $c=[IO.File]::ReadAllText('" & ps1 & "',[Text.Encoding]::UTF8); & ([ScriptBlock]::Create($c))"""
sh.Run cmd, 0, False
