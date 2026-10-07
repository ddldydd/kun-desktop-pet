# Kun Like Pet - "is the desktop pet already showing?" probe.
# Used by KunPet-autostart.cmd to avoid launching a second pet.
# Exit code 1 = pet is up (caller should do nothing).
# Exit code 0 = no pet window found (caller should launch).
# The pet is a WPF window owned by powershell.exe; the MainWindowHandle is
# always 0 for it (tool-window/layered), so we enumerate real windows and
# recognise the pet by its small visible window size.

$code = @'
using System;
using System.Collections.Generic;
using System.Runtime.InteropServices;
public class KunPetProbe {
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern bool GetWindowRect(IntPtr h, out RECT r);
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int L, T, R, B; }
  public static bool SmallVisibleWindow(uint target) {
    bool found = false;
    EnumWindows((h, p) => {
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (pid != target) return true;
      if (!IsWindowVisible(h)) return true;
      RECT r; GetWindowRect(h, out r);
      int w = r.R - r.L;
      if (w >= 120 && w <= 400) { found = true; return false; }
      return true;
    }, IntPtr.Zero);
    return found;
  }
}
'@

try { Add-Type -TypeDefinition $code -Language CSharp | Out-Null } catch { exit 0 }

$pets = @(Get-CimInstance Win32_Process -Filter "Name='powershell.exe'" -ErrorAction SilentlyContinue |
  Where-Object { $_.CommandLine -and $_.CommandLine -match 'kun-pet' -and $_.CommandLine -match '\.ps1' })

foreach ($p in $pets) {
  if ([KunPetProbe]::SmallVisibleWindow([uint32]$p.ProcessId)) { exit 1 }
}
exit 0
