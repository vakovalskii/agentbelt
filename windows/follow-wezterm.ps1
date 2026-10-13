# Keeps the toolbelt window glued to the right side of the WezTerm window, so the pair behaves
# like iTerm2 with its toolbelt: the belt follows the terminal when it moves or resizes, matches
# its height, minimizes and restores with it, and sits right above it in the window stack (other
# apps cover both, Alt+Tab to WezTerm brings both). A maximized WezTerm is narrowed to leave room.
# One instance per session (named mutex); runs until logoff and survives belt restarts.
Add-Type -TypeDefinition @"
using System;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;

public static class BeltFollow {
  [StructLayout(LayoutKind.Sequential)] public struct RECT { public int Left, Top, Right, Bottom; }
  [StructLayout(LayoutKind.Sequential)] public struct MONITORINFO { public int cbSize; public RECT rcMonitor, rcWork; public uint dwFlags; }
  public delegate bool EnumProc(IntPtr h, IntPtr p);
  [DllImport("user32.dll")] static extern bool EnumWindows(EnumProc cb, IntPtr p);
  [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
  [DllImport("user32.dll")] static extern bool IsWindow(IntPtr h);
  [DllImport("user32.dll")] static extern bool IsIconic(IntPtr h);
  [DllImport("user32.dll")] static extern bool IsZoomed(IntPtr h);
  [DllImport("user32.dll")] static extern int GetWindowText(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern int GetClassName(IntPtr h, StringBuilder s, int n);
  [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
  [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
  [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
  [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
  [DllImport("user32.dll")] static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int w, int hh, uint f);
  [DllImport("user32.dll")] static extern bool ShowWindow(IntPtr h, int cmd);
  [DllImport("user32.dll")] static extern IntPtr MonitorFromWindow(IntPtr h, uint flags);
  [DllImport("user32.dll")] static extern bool GetMonitorInfo(IntPtr m, ref MONITORINFO mi);
  [DllImport("user32.dll")] static extern bool SetProcessDpiAwarenessContext(IntPtr ctx);
  [DllImport("dwmapi.dll")] static extern int DwmGetWindowAttribute(IntPtr h, int attr, out RECT r, int size);

  const uint GW_HWNDPREV = 3, SWP_NOSIZE = 1, SWP_NOMOVE = 2, SWP_NOACTIVATE = 0x10, SWP_NOOWNERZORDER = 0x200;
  const int SW_RESTORE = 9, SW_SHOWMINNOACTIVE = 7, SW_SHOWNOACTIVATE = 4;
  static readonly IntPtr HWND_NOTOPMOST = new IntPtr(-2);

  static string Proc(IntPtr h) {
    uint pid; GetWindowThreadProcessId(h, out pid);
    try { return Process.GetProcessById((int)pid).ProcessName.ToLowerInvariant(); } catch { return ""; }
  }
  static string Title(IntPtr h) { var s = new StringBuilder(256); GetWindowText(h, s, 256); return s.ToString(); }

  // Visible frame (without the invisible resize border Windows adds around top-level windows).
  static RECT Frame(IntPtr h) {
    RECT r; if (DwmGetWindowAttribute(h, 9, out r, Marshal.SizeOf(typeof(RECT))) != 0) GetWindowRect(h, out r); return r;
  }

  // Topmost-in-z-order WezTerm window (the one used last) and the belt window.
  static void Find(out IntPtr wez, out IntPtr belt) {
    IntPtr w = IntPtr.Zero, b = IntPtr.Zero;
    EnumWindows((h, p) => {
      if (!IsWindowVisible(h)) return true;
      if (b == IntPtr.Zero && Title(h) == "agentbelt" && Proc(h) == "msedge") b = h;
      else if (w == IntPtr.Zero && Proc(h) == "wezterm-gui" && Title(h).Length > 0) w = h;
      return w == IntPtr.Zero || b == IntPtr.Zero;
    }, IntPtr.Zero);
    wez = w; belt = b;
  }

  public static void Run(int defaultWidth) {
    try { SetProcessDpiAwarenessContext(new IntPtr(-4)); } catch {}  // physical pixels everywhere
    IntPtr lastBelt = IntPtr.Zero;
    bool beltHidden = true, fillNext = false;  // true: bring a minimized belt back on start
    while (true) {
      Thread.Sleep(80);
      IntPtr wez, belt; Find(out wez, out belt);
      if (belt == IntPtr.Zero || wez == IntPtr.Zero) { Thread.Sleep(400); continue; }
      if (belt != lastBelt) { SetWindowPos(belt, HWND_NOTOPMOST, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE); lastBelt = belt; }

      if (IsIconic(wez)) {
        if (!IsIconic(belt)) { ShowWindow(belt, SW_SHOWMINNOACTIVE); beltHidden = true; }
        continue;
      }
      if (IsIconic(belt)) {
        // restored together with WezTerm; a belt minimized on its own stays down
        if (beltHidden) { ShowWindow(belt, SW_SHOWNOACTIVATE); beltHidden = false; }
        continue;
      }
      beltHidden = false;

      RECT wf = Frame(wez), bf = Frame(belt), bw, ww;
      GetWindowRect(belt, out bw); GetWindowRect(wez, out ww);
      int bw0 = bf.Right - bf.Left; if (bw0 < 400) bw0 = defaultWidth;  // came back from minimized too narrow
      var mi = new MONITORINFO(); mi.cbSize = Marshal.SizeOf(mi);
      GetMonitorInfo(MonitorFromWindow(wez, 2), ref mi);
      RECT work = mi.rcWork;

      // maximized WezTerm: un-maximize, then fill the screen minus the belt strip
      if (IsZoomed(wez)) { ShowWindow(wez, SW_RESTORE); fillNext = true; continue; }
      if (fillNext) {
        fillNext = false;
        int l = work.Left - (wf.Left - ww.Left), t = work.Top - (wf.Top - ww.Top);
        int r = work.Right - bw0 + (ww.Right - wf.Right), b = work.Bottom + (ww.Bottom - wf.Bottom);
        SetWindowPos(wez, IntPtr.Zero, l, t, r - l, b - t, SWP_NOACTIVATE | 4 /*NOZORDER*/ | SWP_NOOWNERZORDER);
        continue;
      }
      // no room on the right: narrow WezTerm so the belt fits beside it
      if (wf.Right + bw0 > work.Right) {
        int newRight = work.Right - bw0;
        if (newRight - wf.Left >= 400) {
          SetWindowPos(wez, IntPtr.Zero, ww.Left, ww.Top, (ww.Right - ww.Left) - (wf.Right - newRight), ww.Bottom - ww.Top,
                       SWP_NOACTIVATE | 4 /*NOZORDER*/ | SWP_NOOWNERZORDER);
          continue;
        }
      }

      // belt frame flush with the terminal frame; translate back to window coords (invisible borders)
      int x = wf.Right + (bw.Left - bf.Left), y = wf.Top + (bw.Top - bf.Top);
      int w = bw0 + (bw.Right - bw.Left) - (bf.Right - bf.Left);
      int hgt = (wf.Bottom - wf.Top) + (bw.Bottom - bw.Top) - (bf.Bottom - bf.Top);
      bool moved = Math.Abs(bw.Left - x) > 1 || Math.Abs(bw.Top - y) > 1 || Math.Abs((bw.Bottom - bw.Top) - hgt) > 1;

      // stack: belt directly above WezTerm, unless the belt itself is in front (being used)
      IntPtr fg = GetForegroundWindow();
      IntPtr above = GetWindow(wez, GW_HWNDPREV);
      bool restack = fg != belt && above != belt;
      if (fg == belt && GetWindow(belt, 2 /*GW_HWNDNEXT*/) != wez) {
        SetWindowPos(wez, belt, 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
      }
      if (moved || restack) {
        IntPtr after = restack ? (above == IntPtr.Zero ? IntPtr.Zero : above) : IntPtr.Zero;
        uint f = SWP_NOACTIVATE | SWP_NOOWNERZORDER | (restack ? 0u : 4u /*NOZORDER*/) | (moved ? 0u : SWP_NOMOVE | SWP_NOSIZE);
        SetWindowPos(belt, after, x, y, w, hgt, f);
      }
    }
  }
}
"@
$created = $false
$mutex = New-Object System.Threading.Mutex($true, "Local\agentbelt-follow-wezterm", [ref]$created)
if (-not $created) { exit 0 }
[BeltFollow]::Run(460)
