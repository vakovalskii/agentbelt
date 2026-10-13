# Opt-in, not started by open-belt.ps1: Windows re-lays the whole desktop around an app bar
# (maximized windows, Alt+Tab) and that felt broken. Run by hand if a reserved strip is wanted.
# Docks the toolbelt window to the right edge as a Windows app bar: the shell reserves the strip,
# so maximized windows (browser, WezTerm) stop at its left edge instead of covering it, the way the
# toolbelt sits beside the terminal on macOS. Runs as long as the window lives, then frees the strip.
param([int]$Width = 460, [int]$WaitSeconds = 30)
Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
using System.Text;
public static class BeltDock {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct APPBARDATA {
    public int cbSize; public IntPtr hWnd; public uint uCallbackMessage; public uint uEdge; public RECT rc; public IntPtr lParam; }
  [DllImport("shell32.dll")] public static extern UIntPtr SHAppBarMessage(uint msg, ref APPBARDATA d);
  [DllImport("user32.dll")] public static extern bool MoveWindow(IntPtr h, int x, int y, int w, int hh, bool r);
  [DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] public static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] public static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] public static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] public static extern int GetSystemMetrics(int i);
  [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hh, uint f);
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  public static IntPtr Find(string title, uint[] pids) {
    IntPtr found = IntPtr.Zero;
    EnumWindows((h, p) => {
      if (!IsWindowVisible(h)) return true;
      var sb = new StringBuilder(256); GetWindowText(h, sb, 256);
      uint pid; GetWindowThreadProcessId(h, out pid);
      if (sb.ToString() == title && Array.IndexOf(pids, pid) >= 0) { found = h; return false; }
      return true;
    }, IntPtr.Zero);
    return found;
  }
  public static APPBARDATA Dock(IntPtr h, int width) {
    var d = new APPBARDATA(); d.cbSize = Marshal.SizeOf(d); d.hWnd = h; d.uCallbackMessage = 0x8000 + 77;
    SHAppBarMessage(1, ref d);                       // ABM_REMOVE a stale bar left by a killed docker
    SHAppBarMessage(0, ref d);                       // ABM_NEW
    d.uEdge = 2;                                     // ABE_RIGHT
    d.rc.Top = 0; d.rc.Bottom = GetSystemMetrics(1); d.rc.Right = GetSystemMetrics(0); d.rc.Left = d.rc.Right - width;
    SHAppBarMessage(2, ref d);                       // ABM_QUERYPOS (moves it off a docked taskbar)
    d.rc.Left = d.rc.Right - width;
    SHAppBarMessage(3, ref d);                       // ABM_SETPOS
    ShowWindow(h, 9);                                // SW_RESTORE: a minimized window ignores the move
    SetWindowPos(h, new IntPtr(-1), d.rc.Left, d.rc.Top, d.rc.Right - d.rc.Left, d.rc.Bottom - d.rc.Top, 0x0040); // HWND_TOPMOST, SHOWWINDOW
    return d;
  }
  public static void Undock(APPBARDATA d) { SHAppBarMessage(1, ref d); } // ABM_REMOVE
}
"@
$profile = Join-Path $env:LOCALAPPDATA "agentbelt\edge-profile"
$hwnd = [IntPtr]::Zero
$deadline = (Get-Date).AddSeconds($WaitSeconds)
while ($hwnd -eq [IntPtr]::Zero -and (Get-Date) -lt $deadline) {
    $pids = @(Get-CimInstance Win32_Process -Filter "Name='msedge.exe'" |
        Where-Object { $_.CommandLine -like "*$profile*" } | ForEach-Object { [uint32]$_.ProcessId })
    if ($pids.Count) { $hwnd = [BeltDock]::Find("agentbelt", [uint32[]]$pids) }
    if ($hwnd -eq [IntPtr]::Zero) { Start-Sleep -Milliseconds 500 }
}
if ($hwnd -eq [IntPtr]::Zero) { exit 1 }
$bar = [BeltDock]::Dock($hwnd, $Width)
try { while ([BeltDock]::IsWindow($hwnd)) { Start-Sleep -Seconds 2 } }
finally { [BeltDock]::Undock($bar) }
