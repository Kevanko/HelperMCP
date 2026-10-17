# HelperMCP agent for Windows 10/11 (PowerShell 5.1+). Runs in memory, installs nothing.
#   [Net.ServicePointManager]::SecurityProtocol=3072; irm RELAY/h | iex
$prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Stop'  # restored at the end: iex runs in the user's session
# Windows PowerShell 5.1 started from PowerShell 7 inherits a module path pointing at 7's modules and then fails to load even
# built-in ones (ConvertTo-SecureString, ...): use 5.1's own module folders.
if ($PSVersionTable.PSVersion.Major -le 5 -and "$env:PSModulePath" -match 'PowerShell[\\/]7') { $env:PSModulePath = @((Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules'), (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'), (Join-Path $PSHOME 'Modules')) -join ';' }
$RELAY = if ($env:HELPER_RELAY) { $env:HELPER_RELAY } else { '__RELAY__' }
$ru = $env:HELPER_LANG -eq 'ru'   # the console speaks English; HELPER_LANG=ru for Russian
function T($r, $e) { if ($ru) { $r } else { $e } }
$AskTools = 'run', 'start_process', 'fetch_file', 'write_file', 'edit_file', 'push_file', 'fsop', 'util', 'ui_click', 'ui_set', 'click', 'move', 'drag', 'type_text', 'press_key', 'scroll', 'actions', 'mcp_start', 'mcp_call'
$NodeVersion = 'v22.11.0'; $NodeMin = 20   # Playwright & co. need Node >= 20
$script:NodeDir = $null; $script:NodeBin = $null
$script:TmpDirs = @(); $script:OverlayProc = $null; $script:OverlayIn = $null
$script:ExtraPath = @()   # dirs of portable runtimes (node, uv) put in front of PATH for everything we start
$script:Started = @()    # processes launched with start_process (listed by sysinfo, left running on exit)
$Children = @{}   # name -> other MCP servers running on this PC
$MaxOut = 100000

Add-Type -AssemblyName System.Windows.Forms, System.Drawing
Add-Type -Namespace H -Name U__BUILD__ -MemberDefinition @'
[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);
[DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
[DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr h);
[DllImport("user32.dll")] public static extern bool IsWindow(IntPtr h);
[DllImport("user32.dll")] public static extern IntPtr GetAncestor(IntPtr h, uint f);
[StructLayout(LayoutKind.Sequential)] public struct FLASHWINFO { public uint cbSize; public IntPtr hwnd; public uint dwFlags; public uint uCount; public uint dwTimeout; }
[DllImport("user32.dll")] public static extern bool FlashWindowEx(ref FLASHWINFO f);
[DllImport("kernel32.dll")] public static extern IntPtr GetStdHandle(int n);
[DllImport("kernel32.dll")] public static extern bool GetConsoleMode(IntPtr h, out uint m);
[DllImport("kernel32.dll")] public static extern bool SetConsoleMode(IntPtr h, uint m);
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint a, uint b, IntPtr c, uint d);
[DllImport("user32.dll")] public static extern void mouse_event(uint f, uint dx, uint dy, uint d, UIntPtr e);
[DllImport("user32.dll")] public static extern void keybd_event(byte vk, byte scan, uint flags, UIntPtr e);
'@
[void][H.U__BUILD__]::SetProcessDPIAware()   # real pixels, not scaled ones
Add-Type -ReferencedAssemblies Accessibility, System.Drawing -TypeDefinition @"
using System; using System.Runtime.InteropServices;
namespace V__BUILD__ {
  public static class Caret {   // where the text caret is: classic controls tell GetGUIThreadInfo, browsers and Electron answer the accessibility caret object
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
    [StructLayout(LayoutKind.Sequential)] struct GTI { public int cbSize; public int flags; public IntPtr hwndActive, hwndFocus, hwndCapture, hwndMenuOwner, hwndMoveSize, hwndCaret; public RECT rc; }
    [StructLayout(LayoutKind.Sequential)] struct PT { public int X, Y; }
    [DllImport("user32.dll")] static extern bool GetGUIThreadInfo(uint tid, ref GTI g);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool ClientToScreen(IntPtr h, ref PT p);
    [DllImport("oleacc.dll")] static extern int AccessibleObjectFromWindow(IntPtr h, uint id, ref Guid iid, [MarshalAs(UnmanagedType.Interface)] out object o);
    public static int[] Get() {   // x, y, height of the caret on the screen, or null
      IntPtr fg = GetForegroundWindow(); if (fg == IntPtr.Zero) return null;
      uint pid; uint tid = GetWindowThreadProcessId(fg, out pid);
      var g = new GTI(); g.cbSize = Marshal.SizeOf(typeof(GTI)); IntPtr target = fg;
      if (GetGUIThreadInfo(tid, ref g)) {
        if (g.hwndCaret != IntPtr.Zero && g.rc.B > g.rc.T) { var p = new PT { X = g.rc.L, Y = g.rc.T }; ClientToScreen(g.hwndCaret, ref p); return new[] { p.X, p.Y, g.rc.B - g.rc.T }; }
        if (g.hwndFocus != IntPtr.Zero) target = g.hwndFocus;
      }
      try {
        Guid iid = new Guid("618736E0-3C3D-11CF-810C-00AA00389B71"); object o;
        if (AccessibleObjectFromWindow(target, 0xFFFFFFF8, ref iid, out o) == 0 && o != null) {
          int l, t, w, h; ((Accessibility.IAccessible)o).accLocation(out l, out t, out w, out h, 0);
          if (h > 0 && (l != 0 || t != 0)) return new[] { l, t, h };
        }
      } catch { }
      return null;
    }
  }
  public static class Kb {   // typing as real Unicode key strokes: down and up in one call (no auto-repeat doubles under load), any keyboard layout
    [StructLayout(LayoutKind.Sequential)] struct KI { public ushort vk, scan; public uint flags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] struct MI { public int dx, dy; public uint data, flags, time; public IntPtr extra; }
    [StructLayout(LayoutKind.Explicit)] struct U { [FieldOffset(0)] public MI m; [FieldOffset(0)] public KI k; }
    [StructLayout(LayoutKind.Sequential)] struct IN { public uint type; public U u; }
    [DllImport("user32.dll")] static extern uint SendInput(uint n, IN[] i, int size);
    static IN K(ushort vk, ushort scan, uint flags) { var x = new IN(); x.type = 1; x.u.k = new KI { vk = vk, scan = scan, flags = flags }; return x; }
    public static void Type(string s) {
      foreach (char c in s) {
        IN[] ev;
        if (c == (char)10) ev = new[] { K(0x0D, 0, 0), K(0x0D, 0, 2) };
        else if (c == (char)9) ev = new[] { K(0x09, 0, 0), K(0x09, 0, 2) };
        else if (c == (char)13) continue;
        else ev = new[] { K(0, c, 4), K(0, c, 4 | 2) };
        SendInput((uint)ev.Length, ev, Marshal.SizeOf(typeof(IN)));
      }
    }
  }
  public static class Probe {   // a coarse grey picture of a part of the screen: enough to tell whether anything changed
    public static byte[] Grab(int x, int y, int w, int h, int gw, int gh, int[] mask) {
      var r = new byte[gw * gh]; if (w <= 0 || h <= 0) return r;
      using (var bmp = new System.Drawing.Bitmap(w, h, System.Drawing.Imaging.PixelFormat.Format32bppArgb)) {
        using (var g = System.Drawing.Graphics.FromImage(bmp)) g.CopyFromScreen(x, y, 0, 0, bmp.Size);
        var bd = bmp.LockBits(new System.Drawing.Rectangle(0, 0, w, h), System.Drawing.Imaging.ImageLockMode.ReadOnly, System.Drawing.Imaging.PixelFormat.Format32bppArgb);
        var px = new byte[bd.Stride * h]; Marshal.Copy(bd.Scan0, px, 0, px.Length); bmp.UnlockBits(bd);
        for (int j = 0; j < gh; j++) for (int i = 0; i < gw; i++) {
          int sx = (int)((i + 0.5) * w / gw), sy = (int)((j + 0.5) * h / gh), ax = x + sx, ay = y + sy; bool skip = false;
          for (int m = 0; m + 3 < mask.Length; m += 4) if (ax >= mask[m] && ay >= mask[m + 1] && ax < mask[m] + mask[m + 2] && ay < mask[m + 1] + mask[m + 3]) { skip = true; break; }
          if (skip) continue;
          int o = sy * bd.Stride + sx * 4; r[j * gw + i] = (byte)((px[o] + 2 * px[o + 1] + px[o + 2]) / 4 | 1);
        }
      }
      return r;
    }
    public static byte[] Or(byte[] a, byte[] b) { if (a == null) return b; if (b == null || b.Length != a.Length) return a; var r = new byte[a.Length]; for (int i = 0; i < a.Length; i++) r[i] = (byte)(a[i] | b[i]); return r; }
    public static byte[] Noise(byte[] a, byte[] b) { var n = new byte[a.Length]; for (int i = 0; i < a.Length && i < b.Length; i++) if (Math.Abs(a[i] - b[i]) > 20) n[i] = 1; return n; }   // cells that change by themselves (a spinner, a video, a clock)
    public static double DiffN(byte[] a, byte[] b, byte[] noise) { if (a == null || b == null || a.Length != b.Length) return 1; int n = 0, c = 0; for (int i = 0; i < a.Length; i++) { if (a[i] == 0 || b[i] == 0 || (noise != null && noise[i] != 0)) continue; n++; if (Math.Abs(a[i] - b[i]) > 20) c++; } return n == 0 ? 0 : (double)c / n; }
    public static int CountN(byte[] a, byte[] b, byte[] noise) { if (a == null || b == null || a.Length != b.Length) return 0; int c = 0; for (int i = 0; i < a.Length; i++) { if (a[i] == 0 || b[i] == 0 || (noise != null && noise[i] != 0)) continue; if (Math.Abs(a[i] - b[i]) > 20) c++; } return c; }
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] static extern bool GetWindowRect(IntPtr h, out RECT r);
    [StructLayout(LayoutKind.Sequential)] struct RECT { public int L, T, R, B; }
    public static int[] FgRect() { RECT r; var h = GetForegroundWindow(); if (h == IntPtr.Zero || !GetWindowRect(h, out r)) return null; return new[] { r.L, r.T, r.R - r.L, r.B - r.T }; }
    public static double Diff(byte[] a, byte[] b) { if (a == null || b == null || a.Length != b.Length) return 1; int n = 0, c = 0; for (int i = 0; i < a.Length; i++) { if (a[i] == 0 || b[i] == 0) continue; n++; if (Math.Abs(a[i] - b[i]) > 20) c++; } return n == 0 ? 0 : (double)c / n; }
  }
  public static class Unglow {   // the edge glow is a known translucent layer: take it out of a screenshot by arithmetic instead of hiding it (no blinking)
    public static void Run(byte[] px, int w, int h, int cx, int cy, int[] mons, int s, int[] cols) {
      var a8 = new int[s];
      for (int d = 0; d < s; d++) { double t = (d + 0.5) / s; double a = t <= 0.35 ? 0.59 + (0.18 - 0.59) * t / 0.35 : 0.18 * (1 - (t - 0.35) / 0.65); a8[d] = (int)(255 * a); }
      Func<int, int, int> depth = (sx, sy) => {
        for (int m = 0; m + 3 < mons.Length; m += 4) {
          int mx = mons[m], my = mons[m + 1], mw = mons[m + 2], mh = mons[m + 3];
          if (sx < mx || sy < my || sx >= mx + mw || sy >= my + mh) continue;
          return Math.Min(Math.Min(sx - mx, sy - my), Math.Min(mx + mw - 1 - sx, my + mh - 1 - sy));
        }
        return int.MaxValue;
      };
      int best = 0; long bestErr = long.MaxValue;   // which colour is really on the screen: the right one never takes a channel below zero
      for (int k = 0; k + 2 < cols.Length; k += 3) {
        long err = 0;
        for (int y = 0; y < h; y += 3) for (int x = 0; x < w; x += 3) {
          int d = depth(cx + x, cy + y); if (d >= s / 3) continue;
          int a = a8[d], i = (y * w + x) * 4;
          int e0 = px[i] - cols[k + 2] * a / 255, e1 = px[i + 1] - cols[k + 1] * a / 255, e2 = px[i + 2] - cols[k] * a / 255;
          if (e0 < 0) err -= e0; if (e1 < 0) err -= e1; if (e2 < 0) err -= e2;
        }
        if (err < bestErr) { bestErr = err; best = k; }
      }
      int R = cols[best], G = cols[best + 1], B = cols[best + 2];
      for (int y = 0; y < h; y++) for (int x = 0; x < w; x++) {
        int d = depth(cx + x, cy + y); if (d >= s) continue;
        int a = a8[d]; if (a >= 250) continue; int i = (y * w + x) * 4; int k = 255 - a;
        px[i] = (byte)Math.Max(0, Math.Min(255, (px[i] - B * a / 255) * 255 / k));
        px[i + 1] = (byte)Math.Max(0, Math.Min(255, (px[i + 1] - G * a / 255) * 255 / k));
        px[i + 2] = (byte)Math.Max(0, Math.Min(255, (px[i + 2] - R * a / 255) * 255 / k));
      }
    }
  }
}
"@
$script:OkRGB = @(76, 141, 255); $script:Phase = 'ok'; $script:LastOp = [DateTime]::UtcNow; $script:LastQuiet = $null
$GlowDepth = [int](70 * ([Drawing.Graphics]::FromHwnd([IntPtr]::Zero).DpiX / 96))
# ---- did an action change anything? A coarse picture around the target and of the whole screen before and after (the overlay's own label and glow are left out)
function Probe-Mask { $m = @(); foreach ($scr in [Windows.Forms.Screen]::AllScreens) { $b = $scr.Bounds; $d = $GlowDepth + 2
        $m += $b.X, $b.Y, $b.Width, $d; $m += $b.X, ($b.Y + $b.Height - $d), $b.Width, $d; $m += $b.X, $b.Y, $d, $b.Height; $m += ($b.X + $b.Width - $d), $b.Y, $d, $b.Height
        $m += ($b.X + $b.Width / 2 - 420), $b.Y, 840, 100 }   # the label with its clock
    [int[]]$m }
function Probe-Take($rect, $extra) {   # $rect = x, y, w, h of the part that matters (null: only the whole screen); twice, so what moves by itself is left out
    $v = [Windows.Forms.SystemInformation]::VirtualScreen; $mask = [int[]](@(Probe-Mask) + @($extra | Where-Object { $null -ne $_ }))
    $gl = { if ($rect) { $gw = [int][Math]::Min(320, [Math]::Max(16, $rect[2] / 3)); $gh = [int][Math]::Min(240, [Math]::Max(8, $rect[3] / 3)); [V__BUILD__.Probe]::Grab([int]$rect[0], [int]$rect[1], [int]$rect[2], [int]$rect[3], $gw, $gh, $mask) } else { $null } }
    $ga = { [V__BUILD__.Probe]::Grab($v.Left, $v.Top, $v.Width, $v.Height, 256, [int](256 * $v.Height / $v.Width), $mask) }
    $l1 = & $gl; $a1 = & $ga; Start-Sleep -Milliseconds 140; $l2 = & $gl; $a2 = & $ga
    @{ rect = $rect; loc = $l2; all = $a2; nloc = $(if ($l1) { [V__BUILD__.Probe]::Noise($l1, $l2) } else { $null }); nall = [V__BUILD__.Probe]::Noise($a1, $a2) }
}
function Arrow-Mask { $p = [Windows.Forms.Cursor]::Position; @(($p.X - 110), ($p.Y - 110), 260, 260) }   # the AI's arrow where the mouse rests (it slides to the caret while typing)
function Around($x, $y, $w, $h) { @([int]($x - $w / 2), [int]($y - $h / 2), [int]$w, [int]$h) }
function Caret-Mask($c) { if (-not $c) { return @() }; $k = $GlowDepth / 70.0   # the blinking caret, and the AI's arrow with its typing dots right under it
    @(($c[0] - 3), ($c[1] - 2), 8, ($c[2] + 4), ($c[0] - 8), ($c[1] + $c[2]), [int](110 * $k), [int](70 * $k)) }
function Get-CaretSafe { try { [V__BUILD__.Caret]::Get() } catch { $null } }
function Caret-Moved($c0, $c1) { ($c0 -and $c1 -and ([Math]::Abs($c0[0] - $c1[0]) + [Math]::Abs($c0[1] - $c1[1])) -gt 2) -or ([bool]$c0 -ne [bool]$c1) }
function Probe-Report($before, $after, $what, $moved) {   # -> a short line for the AI: what changed, or a loud NO CHANGE
    $nl = [V__BUILD__.Probe]::Or($before.nloc, $after.nloc); $na = [V__BUILD__.Probe]::Or($before.nall, $after.nall)
    $cl = if ($before.loc -and $after.loc) { [V__BUILD__.Probe]::CountN($before.loc, $after.loc, $nl) } else { -1 }
    $ca = [V__BUILD__.Probe]::CountN($before.all, $after.all, $na)
    $key = if ($cl -ge 0) { $cl } else { $ca }   # the part that matters decides; the rest of the screen may be busy with other things
    if ($key -lt 3 -and $moved) { return "text cursor moved (nothing else changed where it matters)" }
    if ($key -lt 3) { return "NO CHANGE: nothing changed where it should after this $what. It probably did not work (wrong window or field focused, a covered or disabled control). Do not continue: look first (screenshot or watch)." }
    'screen changed: ' + $(if ($cl -ge 0) { "at the target $cl cells, " } else { '' }) + "whole screen $ca cells"
}

# Files without the PowerShell pipeline (it is slow on big folders): tree, find, line ranges, exact edits; and argument quoting by the Windows rules.
Add-Type -ReferencedAssemblies System.Drawing, System.Windows.Forms -TypeDefinition @"
using System; using System.IO; using System.Text; using System.Text.RegularExpressions; using System.Collections.Generic; using System.Diagnostics; using System.Runtime.InteropServices;
using System.Drawing; using System.Drawing.Imaging; using System.Net; using System.Net.Sockets; using System.Net.NetworkInformation; using System.Threading;
namespace F__BUILD__ {
  public static class Fs {
    static readonly HashSet<string> Skip = new HashSet<string>(StringComparer.OrdinalIgnoreCase) { ".git", "node_modules", "__pycache__", "`$Recycle.Bin", "System Volume Information" };
    public static string Human(long n) { double d = n; string[] u = { "B", "K", "M", "G", "T" }; int i = 0; while (d >= 1024 && i < 4) { d /= 1024; i++; } return i == 0 ? n + "B" : d.ToString("0.0", System.Globalization.CultureInfo.InvariantCulture) + u[i]; }
    static Regex Glob(string g) { if (string.IsNullOrEmpty(g)) return null; return new Regex("^" + Regex.Escape(g).Replace("\\*", ".*").Replace("\\?", ".") + "$", RegexOptions.IgnoreCase); }
    static bool IsLink(FileSystemInfo f) { return (f.Attributes & FileAttributes.ReparsePoint) != 0; }

    public static string Tree(string root, int depth, string pattern, int max) {
      var sb = new StringBuilder(); var rx = Glob(pattern); int lines = 1, more = 0;
      sb.Append(Path.GetFullPath(root)).Append('\n');
      Action<DirectoryInfo, int> walk = null;
      walk = (d, lvl) => {
        FileSystemInfo[] ents;
        try { ents = d.GetFileSystemInfos(); } catch (Exception e) { sb.Append(new string(' ', lvl * 2)).Append('[').Append(e.Message).Append("]\n"); return; }
        Array.Sort(ents, (a, b) => { bool da = a is DirectoryInfo, db = b is DirectoryInfo; return da != db ? (da ? -1 : 1) : string.Compare(a.Name, b.Name, StringComparison.OrdinalIgnoreCase); });
        foreach (var e in ents) {
          var di = e as DirectoryInfo;
          if (di == null && rx != null && !rx.IsMatch(e.Name)) continue;
          if (lines > max) { more++; continue; }
          lines++;
          sb.Append(new string(' ', lvl * 2));
          if (di != null) {
            string n; try { n = di.GetFileSystemInfos().Length.ToString(); } catch { n = "?"; }
            sb.Append(e.Name).Append("/  (").Append(n).Append(")").Append(IsLink(e) ? "  -> link" : "").Append('\n');
            if (lvl < depth && !Skip.Contains(e.Name) && !IsLink(e)) walk(di, lvl + 1);
          } else sb.Append(e.Name).Append("  ").Append(Human(((FileInfo)e).Length)).Append('\n');
        }
      };
      walk(new DirectoryInfo(root), 1);
      if (more > 0) sb.Append("... ").Append(more).Append(" more (raise max, lower depth or use find)\n");
      return sb.ToString().TrimEnd();
    }

    public static string Find(string root, string name, string text, int max, int depth) {
      var rx = Glob(string.IsNullOrEmpty(name) ? "*" : name); var tr = string.IsNullOrEmpty(text) ? null : new Regex(text, RegexOptions.IgnoreCase);
      var outp = new List<string>(); var sw = Stopwatch.StartNew(); string stop = null;
      var stack = new Stack<KeyValuePair<DirectoryInfo, int>>(); stack.Push(new KeyValuePair<DirectoryInfo, int>(new DirectoryInfo(root), 0));
      while (stack.Count > 0 && stop == null) {
        var cur = stack.Pop(); FileSystemInfo[] ents;
        try { ents = cur.Key.GetFileSystemInfos(); } catch { continue; }
        foreach (var e in ents) {
          if (sw.Elapsed.TotalSeconds > 25) { stop = "... stopped after 25 s (narrow the path)"; break; }
          var di = e as DirectoryInfo;
          if (di != null) { if (cur.Value + 1 < depth && !Skip.Contains(e.Name) && !IsLink(e)) stack.Push(new KeyValuePair<DirectoryInfo, int>(di, cur.Value + 1)); continue; }
          if (!rx.IsMatch(e.Name)) continue;
          var fi = (FileInfo)e;
          if (tr == null) outp.Add(fi.FullName + "  " + Human(fi.Length));
          else {
            if (fi.Length > 5000000) continue;
            byte[] raw; try { raw = File.ReadAllBytes(fi.FullName); } catch { continue; }
            if (Array.IndexOf(raw, (byte)0, 0, Math.Min(raw.Length, 4096)) >= 0 && !(raw.Length > 1 && raw[0] == 0xFF && raw[1] == 0xFE)) continue;
            var lines = Decode(raw).Text.Split('\n');
            for (int i = 0; i < lines.Length && outp.Count < max; i++)
              if (tr.IsMatch(lines[i])) { var l = lines[i].Trim(); outp.Add(fi.FullName + ":" + (i + 1) + ": " + (l.Length > 160 ? l.Substring(0, 160) : l)); }
          }
          if (outp.Count >= max) { stop = "... stopped at " + max + " results (raise max or narrow path / name)"; break; }
        }
      }
      if (stop != null) outp.Add(stop);
      return outp.Count == 0 ? "nothing found" : string.Join("\n", outp);
    }

    public class Doc { public string Text; public Encoding Enc; public byte[] Bom; }
    public static Doc Decode(byte[] raw) {
      if (raw.Length >= 3 && raw[0] == 0xEF && raw[1] == 0xBB && raw[2] == 0xBF) return new Doc { Text = new UTF8Encoding(false).GetString(raw, 3, raw.Length - 3), Enc = new UTF8Encoding(false), Bom = new byte[] { 0xEF, 0xBB, 0xBF } };
      if (raw.Length >= 2 && raw[0] == 0xFF && raw[1] == 0xFE) return new Doc { Text = Encoding.Unicode.GetString(raw, 2, raw.Length - 2), Enc = Encoding.Unicode, Bom = new byte[] { 0xFF, 0xFE } };
      if (raw.Length >= 2 && raw[0] == 0xFE && raw[1] == 0xFF) return new Doc { Text = Encoding.BigEndianUnicode.GetString(raw, 2, raw.Length - 2), Enc = Encoding.BigEndianUnicode, Bom = new byte[] { 0xFE, 0xFF } };
      try { return new Doc { Text = new UTF8Encoding(false, true).GetString(raw), Enc = new UTF8Encoding(false), Bom = new byte[0] }; }
      catch { var d = Encoding.Default; return new Doc { Text = d.GetString(raw), Enc = d, Bom = new byte[0] }; }   // an ANSI file stays ANSI
    }

    public static string ReadRange(string path, int offset, int count, int tail) {
      var L = Decode(File.ReadAllBytes(path)).Text.Replace("\r\n", "\n").Split('\n');
      int n = L.Length; if (n > 0 && L[n - 1] == "") n--;
      int start = tail > 0 ? Math.Max(0, n - tail) : Math.Max(0, offset - 1); int cnt = tail > 0 ? tail : (count > 0 ? count : 200);
      var sb = new StringBuilder(); int end = Math.Min(n, start + cnt);
      for (int i = start; i < end; i++) sb.Append(i + 1).Append('\t').Append(L[i]).Append('\n');
      sb.Append("[lines ").Append(start + 1).Append('-').Append(end).Append(" of ").Append(n).Append(']');
      return sb.ToString();
    }

    static int Count(string s, string sub) { int n = 0, i = 0; while ((i = s.IndexOf(sub, i, StringComparison.Ordinal)) >= 0) { n++; i += sub.Length; } return n; }
    public static string Edit(string path, string old, string neu, bool all) {
      var d = Decode(File.ReadAllBytes(path)); var t = d.Text;
      if (!t.Contains(old) && t.Contains("\r\n") && !old.Contains("\r\n")) { old = old.Replace("\n", "\r\n"); neu = neu.Replace("\n", "\r\n"); }   // the AI writes \n, the file has CRLF
      int n = string.IsNullOrEmpty(old) ? 0 : Count(t, old);
      if (n == 0) throw new Exception("old text not found (it must match exactly, spaces and line breaks included; read_file with offset/lines to copy it)");
      if (n > 1 && !all) throw new Exception("old text found " + n + " times: add surrounding lines to make it unique, or all=true");
      var body = d.Enc.GetBytes(t.Replace(old, neu)); var outb = new byte[d.Bom.Length + body.Length];
      Buffer.BlockCopy(d.Bom, 0, outb, 0, d.Bom.Length); Buffer.BlockCopy(body, 0, outb, d.Bom.Length, body.Length);
      File.WriteAllBytes(path, outb);
      return "replaced " + n;
    }

    [DllImport("user32.dll", CharSet = CharSet.Unicode)] static extern IntPtr SendMessageTimeout(IntPtr h, uint msg, UIntPtr w, string l, uint flags, uint timeout, out UIntPtr r);
    public static void Broadcast() { UIntPtr r; SendMessageTimeout((IntPtr)0xffff, 0x1A, UIntPtr.Zero, "Environment", 2, 3000, out r); }   // WM_SETTINGCHANGE: Explorer and new programs see a changed PATH

    // one argument for a Windows command line, by the rules of CommandLineToArgvW / the MS C runtime: quotes, backslashes before quotes, spaces
    public static string Quote(string a) {
      if (a.Length > 0 && a.IndexOfAny(new[] { ' ', '\t', '\n', '\v', '"' }) < 0) return a;
      var sb = new StringBuilder("\"");
      for (int i = 0; ; i++) {
        int bs = 0; while (i < a.Length && a[i] == '\\') { bs++; i++; }
        if (i == a.Length) { sb.Append('\\', bs * 2); break; }
        if (a[i] == '"') sb.Append('\\', bs * 2 + 1).Append('"'); else sb.Append('\\', bs).Append(a[i]);
      }
      return sb.Append('"').ToString();
    }
  }

  // Fast system facts without WMI (Get-CimInstance is ~1 s): memory, and a rich process snapshot with real CPU %, the exe path,
  // who signed it and a "!" for anything that looks out of place (running from Temp/AppData/Downloads, or no publisher) - so one call finds a resource hog or something nasty.
  public static class Sys {
    [StructLayout(LayoutKind.Sequential)] struct MEMORYSTATUSEX { public uint dwLength, dwMemoryLoad; public ulong ullTotalPhys, ullAvailPhys, ullTotalPageFile, ullAvailPageFile, ullTotalVirtual, ullAvailVirtual, ullAvailExtendedVirtual; }
    [DllImport("kernel32.dll")] static extern bool GlobalMemoryStatusEx(ref MEMORYSTATUSEX m);
    [DllImport("kernel32.dll", SetLastError = true)] static extern IntPtr OpenProcess(uint access, bool inherit, int pid);
    [DllImport("kernel32.dll")] static extern bool CloseHandle(IntPtr h);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool QueryFullProcessImageName(IntPtr h, int flags, System.Text.StringBuilder buf, ref int size);

    public static string Mem() {   // "ram X.X of Y.Y GB free (Z% used); page ..."
      var m = new MEMORYSTATUSEX { dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX)) }; GlobalMemoryStatusEx(ref m);
      double gb = 1024.0 * 1024 * 1024;
      return string.Format(System.Globalization.CultureInfo.InvariantCulture, "ram {0:0.0} of {1:0.0} GB free ({2}% used); commit {3:0.0} of {4:0.0} GB free",
        m.ullAvailPhys / gb, m.ullTotalPhys / gb, m.dwMemoryLoad, m.ullAvailPageFile / gb, m.ullTotalPageFile / gb);
    }
    public static int MemLoad() { var m = new MEMORYSTATUSEX { dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX)) }; GlobalMemoryStatusEx(ref m); return (int)m.dwMemoryLoad; }

    [DllImport("kernel32.dll")] static extern bool GetSystemTimes(out long idle, out long kernel, out long user);
    // the live "System" panel: called every 2 s by the stream thread; CPU % per process comes from the change since the previous call (no sleeping)
    static Dictionary<int, TimeSpan> sPrev; static DateTime sT; static long sI, sK, sU; static readonly Dictionary<int, string[]> sInfo = new Dictionary<int, string[]>();
    static string J(string x) { var b = new System.Text.StringBuilder("\""); foreach (char c in x ?? "") { if (c == '"' || c == '\\') b.Append('\\').Append(c); else if (c < 32) b.AppendFormat("\\u{0:x4}", (int)c); else b.Append(c); } return b.Append('"').ToString(); }
    public static string Snap(int top) {
      long i, k, u; GetSystemTimes(out i, out k, out u); var now = DateTime.UtcNow; double cpu = 0;
      if (sT != default(DateTime)) { double tot = (k - sK) + (u - sU), idle = i - sI; cpu = tot <= 0 ? 0 : Math.Round((tot - idle) / tot * 100.0); }
      double dt = sT == default(DateTime) ? 0 : (now - sT).TotalMilliseconds * Environment.ProcessorCount;
      sI = i; sK = k; sU = u;
      var cur = new Dictionary<int, TimeSpan>(); var rows = new List<double[]>(); var names = new Dictionary<int, string>();
      foreach (var p in System.Diagnostics.Process.GetProcesses()) {
        try { var t = p.TotalProcessorTime; cur[p.Id] = t; TimeSpan a; double c = dt > 0 && sPrev != null && sPrev.TryGetValue(p.Id, out a) ? Math.Max(0, (t - a).TotalMilliseconds / dt * 100.0) : 0; rows.Add(new double[] { p.Id, c, p.WorkingSet64 }); names[p.Id] = p.ProcessName; }
        catch { } finally { p.Dispose(); }
      }
      sPrev = cur; sT = now;
      var byCpu = new List<double[]>(rows); byCpu.Sort((x, y) => y[1].CompareTo(x[1]));
      var byMem = new List<double[]>(rows); byMem.Sort((x, y) => y[2].CompareTo(x[2]));
      var pick = new List<double[]>(); var seen = new HashSet<int>();
      foreach (var r in byCpu) { if (pick.Count >= top || r[1] < 0.5) break; if (seen.Add((int)r[0])) pick.Add(r); }   // what is busy now...
      foreach (var r in byMem) { if (pick.Count >= top + 4) break; if (seen.Add((int)r[0])) pick.Add(r); }            // ...and what holds the most memory
      if (sInfo.Count > 3000) sInfo.Clear();
      var m = new MEMORYSTATUSEX { dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX)) }; GlobalMemoryStatusEx(ref m);
      var inv = System.Globalization.CultureInfo.InvariantCulture; var sb = new System.Text.StringBuilder();
      sb.AppendFormat(inv, "{{\"cpu\":{0},\"mem\":{1},\"ramFree\":{2},\"ramTotal\":{3},\"n\":{4},\"p\":[", cpu, m.dwMemoryLoad, m.ullAvailPhys, m.ullTotalPhys, rows.Count);
      for (int n = 0; n < pick.Count; n++) {
        int pid = (int)pick[n][0]; string[] f;
        if (!sInfo.TryGetValue(pid, out f)) {   // the exe path and the publisher once per process, not every 2 s
          string path = PathOf(pid), company = "";
          if (path.Length > 0) { try { company = (System.Diagnostics.FileVersionInfo.GetVersionInfo(path).CompanyName ?? "").Trim(); } catch { } }
          f = new[] { path, company, Looks(path, company) ? "!" : "" }; sInfo[pid] = f;
        }
        if (n > 0) sb.Append(',');
        sb.AppendFormat(inv, "[{0},{1},{2:0.0},{3},{4},{5},{6}]", pid, J(names[pid]), pick[n][1], (long)pick[n][2], J(f[1]), J(f[0]), J(f[2]));
      }
      return sb.Append("]").Append(SnapExtra()).Append("}").ToString();
    }

    // ---- full process table, per-core load, system counters, network and disk throughput (the viewer's System tabs and the AI's system tool)
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)] struct PROCESSENTRY32 { public uint dwSize, cntUsage, th32ProcessID; public IntPtr th32DefaultHeapID; public uint th32ModuleID, cntThreads, th32ParentProcessID; public int pcPriClassBase; public uint dwFlags; [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string szExeFile; }
    [DllImport("kernel32.dll")] static extern IntPtr CreateToolhelp32Snapshot(uint flags, uint pid);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32First(IntPtr h, ref PROCESSENTRY32 e);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)] static extern bool Process32Next(IntPtr h, ref PROCESSENTRY32 e);
    [DllImport("ntdll.dll")] static extern int NtQuerySystemInformation(int cls, IntPtr buf, int len, out int ret);
    [StructLayout(LayoutKind.Sequential)] struct PERFINFO { public uint cb; public UIntPtr CommitTotal, CommitLimit, CommitPeak, PhysicalTotal, PhysicalAvailable, SystemCache, KernelTotal, KernelPaged, KernelNonpaged, PageSize; public uint HandleCount, ProcessCount, ThreadCount; }
    [DllImport("psapi.dll")] static extern bool GetPerformanceInfo(out PERFINFO p, int size);
    [DllImport("kernel32.dll")] static extern ulong GetTickCount64();

    static Dictionary<int, int[]> Toolhelp() {   // pid -> { parent pid, threads }
      var d = new Dictionary<int, int[]>(); thNames = new Dictionary<int, string>(); var h = CreateToolhelp32Snapshot(2, 0); if (h == (IntPtr)(-1)) return d;
      var e = new PROCESSENTRY32 { dwSize = (uint)Marshal.SizeOf(typeof(PROCESSENTRY32)) };
      for (bool ok = Process32First(h, ref e); ok; ok = Process32Next(h, ref e)) { d[(int)e.th32ProcessID] = new[] { (int)e.th32ParentProcessID, (int)e.cntThreads }; thNames[(int)e.th32ProcessID] = e.szExeFile; }
      CloseHandle(h); return d;
    }
    static Dictionary<int, string> thNames;
    public static string Chain(int pid) {   // who started whom: parent, grandparent ... (names and pids), "|"-separated
      var d = Toolhelp(); var o = new List<string>(); var seen = new HashSet<int> { pid }; int cur = pid;
      while (o.Count < 8) { int[] x; if (!d.TryGetValue(cur, out x) || x[0] <= 0 || !seen.Add(x[0])) break; cur = x[0]; string n; o.Add((thNames.TryGetValue(cur, out n) ? n : "exited") + " (" + cur + ")"); }
      return string.Join("|", o.ToArray());
    }
    static string[] Info(int pid) {   // exe path, publisher, ! flag: once per process
      string[] f; if (sInfo.TryGetValue(pid, out f)) return f;
      string path = PathOf(pid), company = "";
      if (path.Length > 0) { try { company = (System.Diagnostics.FileVersionInfo.GetVersionInfo(path).CompanyName ?? "").Trim(); } catch { } }
      f = new[] { path, company, Looks(path, company) ? "!" : "" }; sInfo[pid] = f; return f;
    }

    static Dictionary<int, TimeSpan> aPrev; static DateTime aT;
    // every process: [pid, parent, name, cpu %, working set, private bytes, threads, handles, path, publisher, flag]; CPU % is the change since the previous call
    public static string ProcsAll() {
      var inv = System.Globalization.CultureInfo.InvariantCulture; var th = Toolhelp();
      Func<Dictionary<int, TimeSpan>> sample = () => { var c = new Dictionary<int, TimeSpan>(); foreach (var p in System.Diagnostics.Process.GetProcesses()) { try { c[p.Id] = p.TotalProcessorTime; } catch { } finally { p.Dispose(); } } return c; };
      if (aPrev == null || (DateTime.UtcNow - aT).TotalSeconds > 15) { aPrev = sample(); aT = DateTime.UtcNow; System.Threading.Thread.Sleep(300); }
      var now = DateTime.UtcNow; double dt = (now - aT).TotalMilliseconds * Environment.ProcessorCount; var cur = new Dictionary<int, TimeSpan>(); var rows = new List<object[]>();
      if (sInfo.Count > 3000) sInfo.Clear();
      foreach (var p in System.Diagnostics.Process.GetProcesses()) {
        try {
          int pid = p.Id; TimeSpan t = TimeSpan.Zero; bool ok = false; try { t = p.TotalProcessorTime; ok = true; } catch { }
          double c = 0; TimeSpan a; if (ok) { cur[pid] = t; if (dt > 0 && aPrev.TryGetValue(pid, out a)) c = Math.Max(0, (t - a).TotalMilliseconds / dt * 100.0); }
          int[] x; th.TryGetValue(pid, out x); var f = Info(pid); long priv = 0; int hc = 0; try { priv = p.PrivateMemorySize64; hc = p.HandleCount; } catch { }
          rows.Add(new object[] { pid, x != null ? x[0] : 0, pid == 0 ? "Idle" : p.ProcessName, Math.Round(c, 1), p.WorkingSet64, priv, x != null ? x[1] : 0, hc, f[0], f[1], f[2] });
        } catch { } finally { p.Dispose(); }
      }
      aPrev = cur; aT = now; rows.Sort((x, y) => ((double)y[3]).CompareTo((double)x[3]) != 0 ? ((double)y[3]).CompareTo((double)x[3]) : ((long)y[4]).CompareTo((long)x[4]));
      var sb = new System.Text.StringBuilder("{\"n\":" + rows.Count + ",\"p\":[");
      for (int i = 0; i < rows.Count; i++) { var r = rows[i]; if (i > 0) sb.Append(','); sb.AppendFormat(inv, "[{0},{1},{2},{3:0.0},{4},{5},{6},{7},{8},{9},{10}]", r[0], r[1], J((string)r[2]), r[3], r[4], r[5], r[6], r[7], J((string)r[8]), J((string)r[9]), J((string)r[10])); }
      return sb.Append("]}").ToString();
    }

    static long[] CoreTimes() {   // per core: idle, busy (kernel + user, kernel already includes idle)
      int n = Environment.ProcessorCount, sz = 48 * n; IntPtr b = Marshal.AllocHGlobal(sz);
      try { int r; if (NtQuerySystemInformation(8, b, sz, out r) != 0) return null; var o = new long[n * 2]; for (int i = 0; i < n; i++) { long idle = Marshal.ReadInt64(b, i * 48), k = Marshal.ReadInt64(b, i * 48 + 8), u = Marshal.ReadInt64(b, i * 48 + 16); o[i * 2] = idle; o[i * 2 + 1] = k + u; } return o; }
      catch { return null; } finally { Marshal.FreeHGlobal(b); }
    }
    static long[] cPrev;
    static double[] Cores() {   // per-core busy % since the previous call
      var c = CoreTimes(); if (c == null) return new double[0]; var p = cPrev; cPrev = c; if (p == null || p.Length != c.Length) return new double[c.Length / 2];
      var o = new double[c.Length / 2]; for (int i = 0; i < o.Length; i++) { double tot = c[i * 2 + 1] - p[i * 2 + 1], idle = c[i * 2] - p[i * 2]; o[i] = tot <= 0 ? 0 : Math.Round(Math.Max(0, Math.Min(100, (tot - idle) / tot * 100.0))); }
      return o;
    }
    static string Arr(double[] a) { return "[" + string.Join(",", Array.ConvertAll(a, v => v.ToString(System.Globalization.CultureInfo.InvariantCulture))) + "]"; }

    static Dictionary<string, long[]> nPrev = new Dictionary<string, long[]>(); static DateTime nT;
    // network throughput per adapter that is up: [name, received bytes/s, sent bytes/s, link speed bit/s], change since the previous call
    static string Net(out long rxAll, out long txAll) {
      var inv = System.Globalization.CultureInfo.InvariantCulture; var now = DateTime.UtcNow; double dt = nT == default(DateTime) ? 0 : (now - nT).TotalSeconds; var cur = new Dictionary<string, long[]>(); var sb = new System.Text.StringBuilder("["); rxAll = 0; txAll = 0; int n = 0;
      foreach (var ni in System.Net.NetworkInformation.NetworkInterface.GetAllNetworkInterfaces()) {
        if (ni.OperationalStatus != System.Net.NetworkInformation.OperationalStatus.Up || ni.NetworkInterfaceType == System.Net.NetworkInformation.NetworkInterfaceType.Loopback) continue;
        try {
          var s = ni.GetIPv4Statistics(); long rx = s.BytesReceived, tx = s.BytesSent; cur[ni.Id] = new[] { rx, tx }; long[] p; long r = 0, t = 0;
          if (dt > 0 && nPrev.TryGetValue(ni.Id, out p)) { r = (long)Math.Max(0, (rx - p[0]) / dt); t = (long)Math.Max(0, (tx - p[1]) / dt); }
          rxAll += r; txAll += t; if (n++ > 0) sb.Append(','); sb.AppendFormat(inv, "[{0},{1},{2},{3}]", J(ni.Name), r, t, ni.Speed);
        } catch { }
      }
      nPrev = cur; nT = now; return sb.Append("]").ToString();
    }

    static volatile System.Diagnostics.PerformanceCounter[] dc; static volatile bool dcBusy;
    // the whole-machine performance picture, sampled over ~0.35 s: CPU, every core, memory, commit, handles / threads / processes, disks and network throughput
    public static string Perf() {
      var inv = System.Globalization.CultureInfo.InvariantCulture; Cores(); long rx, tx; Net(out rx, out tx); double cpu0 = 0;
      long i1, k1, u1; GetSystemTimes(out i1, out k1, out u1);
      if (dc == null && !dcBusy) { dcBusy = true; var th = new System.Threading.Thread(() => { try { var l = new[] { new System.Diagnostics.PerformanceCounter("PhysicalDisk", "Disk Read Bytes/sec", "_Total"), new System.Diagnostics.PerformanceCounter("PhysicalDisk", "Disk Write Bytes/sec", "_Total"), new System.Diagnostics.PerformanceCounter("PhysicalDisk", "% Disk Time", "_Total"), new System.Diagnostics.PerformanceCounter("PhysicalDisk", "Avg. Disk Queue Length", "_Total") }; foreach (var c in l) c.NextValue(); dc = l; } catch { } dcBusy = false; }); th.IsBackground = true; th.Start(); }
      else if (dc != null) { try { foreach (var c in dc) c.NextValue(); } catch { dc = null; } }
      System.Threading.Thread.Sleep(350);
      long i2, k2, u2; GetSystemTimes(out i2, out k2, out u2); double tot = (k2 - k1) + (u2 - u1); cpu0 = tot <= 0 ? 0 : Math.Round((tot - (i2 - i1)) / tot * 100.0);
      var cores = Cores(); var netj = Net(out rx, out tx); var m = new MEMORYSTATUSEX { dwLength = (uint)Marshal.SizeOf(typeof(MEMORYSTATUSEX)) }; GlobalMemoryStatusEx(ref m);
      PERFINFO pi; pi.cb = (uint)Marshal.SizeOf(typeof(PERFINFO)); bool okp = GetPerformanceInfo(out pi, (int)pi.cb); ulong pg = okp ? pi.PageSize.ToUInt64() : 4096;
      string disk = "null"; try { if (dc != null) disk = string.Format(inv, "{{\"rd\":{0:0},\"wr\":{1:0},\"busy\":{2:0},\"q\":{3:0.00}}}", dc[0].NextValue(), dc[1].NextValue(), Math.Min(100, dc[2].NextValue()), dc[3].NextValue()); } catch { }
      var up = TimeSpan.FromMilliseconds((double)GetTickCount64());
      return string.Format(inv, "{{\"cpu\":{0},\"cores\":{1},\"ram\":{{\"total\":{2},\"avail\":{3},\"load\":{4}}},\"commit\":{{\"used\":{5},\"limit\":{6},\"peak\":{7}}},\"cache\":{8},\"kpaged\":{9},\"knon\":{10},\"procs\":{11},\"threads\":{12},\"handles\":{13},\"up\":{14},\"net\":{15},\"rx\":{16},\"tx\":{17},\"disk\":{18},\"cpus\":{19}}}",
        cpu0, Arr(cores), m.ullTotalPhys, m.ullAvailPhys, m.dwMemoryLoad, okp ? (long)(pi.CommitTotal.ToUInt64() * pg) : 0, okp ? (long)(pi.CommitLimit.ToUInt64() * pg) : 0, okp ? (long)(pi.CommitPeak.ToUInt64() * pg) : 0,
        okp ? (long)(pi.SystemCache.ToUInt64() * pg) : 0, okp ? (long)(pi.KernelPaged.ToUInt64() * pg) : 0, okp ? (long)(pi.KernelNonpaged.ToUInt64() * pg) : 0, okp ? pi.ProcessCount : 0, okp ? pi.ThreadCount : 0, okp ? pi.HandleCount : 0, (long)up.TotalSeconds, netj, rx, tx, disk, Environment.ProcessorCount);
    }

    // the S frame carries the cores and the network speed too
    public static string SnapExtra() {
      long rx, tx; var n = Net(out rx, out tx); return ",\"cores\":" + Arr(Cores()) + ",\"rx\":" + rx + ",\"tx\":" + tx;
    }

    public static double CpuLoad(int ms) {   // whole-machine CPU busy %, sampled over ms (kernel time already includes idle)
      long i0, k0, u0, i1, k1, u1; GetSystemTimes(out i0, out k0, out u0); System.Threading.Thread.Sleep(ms); GetSystemTimes(out i1, out k1, out u1);
      double tot = (k1 - k0) + (u1 - u0), idle = i1 - i0; return tot <= 0 ? 0 : Math.Round((tot - idle) / tot * 100.0, 0);
    }

    static string PathOf(int pid) {
      IntPtr h = OpenProcess(0x1000, false, pid); if (h == IntPtr.Zero) return "";   // PROCESS_QUERY_LIMITED_INFORMATION
      try { int n = 512; var sb = new System.Text.StringBuilder(n); return QueryFullProcessImageName(h, 0, sb, ref n) ? sb.ToString() : ""; } finally { CloseHandle(h); }
    }
    static readonly string[] Shady = { "\\temp\\", "\\downloads\\", "\\`$recycle", "\\appdata\\local\\temp\\" };
    static bool Looks(string path, string company) {
      if (string.IsNullOrEmpty(path)) return false;   // a protected system process, not suspicious by itself
      string p = path.ToLowerInvariant();
      foreach (var s in Shady) if (p.Contains(s)) return true;
      if (!string.IsNullOrEmpty(company)) return false;
      foreach (var ok in Normal) if (p.Contains(ok)) return false;
      return true;   // no publisher and not in a normal install place (ponytail: a name check, not Authenticode; WinVerifyTrust if it must be exact)
    }
    static readonly string[] Normal = { "c:\\windows\\", "\\program files", "\\steamapps\\", "\\steamlibrary\\", "\\epic games\\", "\\riot games\\", "\\games\\", "\\windowsapps\\" };   // games often ship without a publisher name

    public static string Procs(int top, int sampleMs, bool all) {
      var cpu0 = new Dictionary<int, TimeSpan>(); var t0 = DateTime.UtcNow;
      var s0 = System.Diagnostics.Process.GetProcesses();   // two fresh snapshots: reading TotalProcessorTime a second time on the same object is cached, and Refresh() on every process is slow
      foreach (var p in s0) { try { cpu0[p.Id] = p.TotalProcessorTime; } catch { } p.Dispose(); }
      System.Threading.Thread.Sleep(sampleMs);
      int cores = Environment.ProcessorCount; var rows = new List<double[]>(); var info = new Dictionary<int, string[]>(); var names = new Dictionary<int, string>();
      double dt = (DateTime.UtcNow - t0).TotalMilliseconds * cores;
      var procs = System.Diagnostics.Process.GetProcesses();
      foreach (var p in procs) {
        try {
          double cpu = 0; TimeSpan a; if (cpu0.TryGetValue(p.Id, out a)) cpu = Math.Max(0, (p.TotalProcessorTime - a).TotalMilliseconds / dt * 100.0);
          rows.Add(new double[] { p.Id, cpu, p.WorkingSet64 }); names[p.Id] = p.ProcessName;
        } catch { }
      }
      foreach (var p in procs) { try { p.Dispose(); } catch { } }
      var byCpu = new List<double[]>(rows); byCpu.Sort((x, y) => y[1].CompareTo(x[1]));
      var byMem = new List<double[]>(rows); byMem.Sort((x, y) => y[2].CompareTo(x[2]));
      var show = new HashSet<int>();   // resolve the exe path + publisher only for what we show: doing it for all ~400 is the slow part
      if (all) foreach (var r in rows) show.Add((int)r[0]);
      else { for (int i = 0; i < Math.Min(top, byCpu.Count); i++) show.Add((int)byCpu[i][0]); for (int i = 0; i < Math.Min(top, byMem.Count); i++) show.Add((int)byMem[i][0]); }
      foreach (int pid in show) {
        string path = PathOf(pid), company = "";
        if (path.Length > 0) { try { var fv = System.Diagnostics.FileVersionInfo.GetVersionInfo(path); company = (fv.CompanyName ?? "").Trim(); } catch { } }
        info[pid] = new[] { names.ContainsKey(pid) ? names[pid] : "", path, company, Looks(path, company) ? "!" : " " };
      }
      var sb = new System.Text.StringBuilder();
      sb.Append("cpu% / mem / pid  name  [publisher]  path   (! = runs from a temp/download/unsigned location, look closer)\n");
      var inv = System.Globalization.CultureInfo.InvariantCulture;
      Action<List<double[]>, int> dump = (list, n) => {
        foreach (var r in list.GetRange(0, Math.Min(n, list.Count))) {
          int pid = (int)r[0]; var f = info[pid];
          sb.AppendFormat(inv, "{0}{1,5:0.0}% {2,8} {3,-6} {4}  {5}{6}\n", f[3], r[1], Fs.Human((long)r[2]), pid, f[0], f[2].Length > 0 ? "[" + f[2] + "] " : "", f[1]);
        }
      };
      if (all) dump(byCpu, byCpu.Count);
      else { sb.Append("-- top by CPU --\n"); dump(byCpu, top); sb.Append("-- top by memory --\n"); dump(byMem, top); }
      int flagged = 0; foreach (var kv in info) if (kv.Value[3] == "!") flagged++;
      sb.AppendFormat("{0} processes running; of the {1} shown, {2} flagged with !  (use a bigger top, or the full list, to look wider)", rows.Count, show.Count, flagged);
      return sb.ToString();
    }
  }

  // The live picture for the viewer, like a video call: its own thread films the screen ~15 times a second, compares it with the last frame in
  // 64x64 tiles and sends only the tiles that changed (a full picture when much changed, on request and every 10 s) over one long upload.
  // ponytail: JPEG tiles, not H.264; a portable ffmpeg (gdigrab + libx264 -tune zerolatency) could feed V frames the same way if more is needed
  public static class Live {
    public static string Relay, Token; public static volatile string Err = "";
    static volatile bool run, key; static volatile int mon = -1; static Thread th;
    public static void Start(int m) { if (m != mon) key = true; mon = m; run = true; if (th == null || !th.IsAlive) { th = new Thread(Loop) { IsBackground = true, Priority = ThreadPriority.BelowNormal }; th.Start(); } }
    public static void Stop() { run = false; }
    public static void Key() { key = true; }
    public static bool Running { get { return th != null && th.IsAlive && run; } }

    static string Mons() {   // [[x,y,w,h,primary], ...] in the order the monitor numbers use
      var sb = new StringBuilder("["); var scr = System.Windows.Forms.Screen.AllScreens;
      for (int i = 0; i < scr.Length; i++) { var b = scr[i].Bounds; if (i > 0) sb.Append(','); sb.Append('[').Append(b.X).Append(',').Append(b.Y).Append(',').Append(b.Width).Append(',').Append(b.Height).Append(',').Append(scr[i].Primary ? 1 : 0).Append(']'); }
      return sb.Append(']').ToString();
    }
    static void Loop() { while (run) { try { Session(); } catch (Exception e) { Err = e.Message; } if (run) Thread.Sleep(1000); } }

    static ImageCodecInfo Jpg = Array.Find(ImageCodecInfo.GetImageEncoders(), c => c.MimeType == "image/jpeg");
    static byte[] Jpeg(Bitmap b, long q) { using (var ms = new MemoryStream()) { var ep = new EncoderParameters(1); ep.Param[0] = new EncoderParameter(System.Drawing.Imaging.Encoder.Quality, q); b.Save(ms, Jpg, ep); return ms.ToArray(); } }
    static void Put16(MemoryStream m, int v) { m.WriteByte((byte)(v >> 8)); m.WriteByte((byte)v); }
    static void Put32(MemoryStream m, int v) { m.WriteByte((byte)(v >> 24)); m.WriteByte((byte)(v >> 16)); m.WriteByte((byte)(v >> 8)); m.WriteByte((byte)v); }
    static void Send(Stream st, char type, byte[] p) { var h = new byte[] { (byte)(p.Length >> 24), (byte)(p.Length >> 16), (byte)(p.Length >> 8), (byte)p.Length, (byte)type }; st.Write(h, 0, 5); st.Write(p, 0, p.Length); st.Flush(); }

    [StructLayout(LayoutKind.Sequential)] struct CURSORINFO { public int cbSize, flags; public IntPtr hCursor; public int x, y; }
    [StructLayout(LayoutKind.Sequential)] struct ICONINFO { public bool fIcon; public int xHot, yHot; public IntPtr hbmMask, hbmColor; }
    [DllImport("user32.dll")] static extern bool GetCursorInfo(ref CURSORINFO ci);
    [DllImport("user32.dll")] static extern bool GetIconInfo(IntPtr h, out ICONINFO ii);
    [DllImport("user32.dll")] static extern bool DrawIconEx(IntPtr hdc, int x, int y, IntPtr icon, int w, int h, int step, IntPtr brush, int flags);
    [DllImport("gdi32.dll")] static extern bool DeleteObject(IntPtr o);
    static void DrawCursor(Graphics g, Rectangle area) {   // the real pointer is not in a screen copy: draw it, so the viewer sees what the friend points at
      var ci = new CURSORINFO { cbSize = Marshal.SizeOf(typeof(CURSORINFO)) };
      if (!GetCursorInfo(ref ci) || (ci.flags & 1) == 0 || ci.hCursor == IntPtr.Zero) return;
      ICONINFO ii; int hx = 0, hy = 0; if (GetIconInfo(ci.hCursor, out ii)) { hx = ii.xHot; hy = ii.yHot; if (ii.hbmMask != IntPtr.Zero) DeleteObject(ii.hbmMask); if (ii.hbmColor != IntPtr.Zero) DeleteObject(ii.hbmColor); }
      var dc = g.GetHdc(); try { DrawIconEx(dc, ci.x - area.Left - hx, ci.y - area.Top - hy, ci.hCursor, 0, 0, 0, IntPtr.Zero, 3); } finally { g.ReleaseHdc(dc); }
    }

    static bool TileDiff(int[] a, int[] b, int w, int h, int x0, int y0) {
      int x1 = Math.Min(w, x0 + 64), y1 = Math.Min(h, y0 + 64);
      for (int y = y0; y < y1; y++) { int i = y * w + x0, e = y * w + x1; for (; i < e; i++) if (a[i] != b[i]) return true; }
      return false;
    }

    static void Session() {
      var rq = (HttpWebRequest)WebRequest.Create(Relay + "/a/stream");
      rq.Method = "POST"; rq.SendChunked = true; rq.AllowWriteStreamBuffering = false; rq.Timeout = 15000; rq.ReadWriteTimeout = 20000; rq.KeepAlive = false;
      rq.Headers["Authorization"] = "Bearer " + Token; rq.ContentType = "application/octet-stream"; rq.ServicePoint.Expect100Continue = false;
      using (var st = rq.GetRequestStream()) {
        int[] pa = null, ca = null; int curMon = -2, fw = 0, fh = 0; long q = 60; double sc = 1; var lastKey = DateTime.MinValue; Rectangle area = Rectangle.Empty;
        try { Sys.Snap(10); } catch { } var lastSys = DateTime.UtcNow;   // primes the CPU counters
        while (run) {
          var t0 = DateTime.UtcNow;
          if (mon != curMon) {
            curMon = mon; var scr = System.Windows.Forms.Screen.AllScreens;
            area = curMon >= 0 && curMon < scr.Length ? scr[curMon].Bounds : System.Windows.Forms.SystemInformation.VirtualScreen;
            sc = Math.Max(1.0, Math.Max(area.Width / 1920.0, area.Height / 1200.0)); fw = (int)(area.Width / sc); fh = (int)(area.Height / sc); pa = null;
          }
          Bitmap frame;
          try {
            var full = new Bitmap(area.Width, area.Height, PixelFormat.Format32bppRgb);
            using (var g = Graphics.FromImage(full)) { g.CopyFromScreen(area.Left, area.Top, 0, 0, area.Size, CopyPixelOperation.SourceCopy); DrawCursor(g, area); }
            if (sc > 1.0) { frame = new Bitmap(fw, fh, PixelFormat.Format32bppRgb); using (var g = Graphics.FromImage(frame)) { g.InterpolationMode = System.Drawing.Drawing2D.InterpolationMode.Bilinear; g.DrawImage(full, 0, 0, fw, fh); } full.Dispose(); }
            else frame = full;
          } catch (Exception e) { Err = "capture: " + e.Message; Thread.Sleep(500); continue; }   // locked screen, UAC prompt: wait for the desktop to come back
          using (frame) {
            if (ca == null || ca.Length != fw * fh) ca = new int[fw * fh];
            var bd = frame.LockBits(new Rectangle(0, 0, fw, fh), ImageLockMode.ReadOnly, PixelFormat.Format32bppRgb);
            try { Marshal.Copy(bd.Scan0, ca, 0, fw * fh); } finally { frame.UnlockBits(bd); }
            bool full_ = key || pa == null || pa.Length != ca.Length || (DateTime.UtcNow - lastKey).TotalSeconds > 10;
            byte[] tiles = null;
            if (!full_) {
              int tw = (fw + 63) / 64, tht = (fh + 63) / 64, nd = 0; var dirty = new bool[tw * tht];
              for (int ty = 0; ty < tht; ty++) for (int tx = 0; tx < tw; tx++) if (TileDiff(pa, ca, fw, fh, tx * 64, ty * 64)) { dirty[ty * tw + tx] = true; nd++; }
              if (nd * 2 > tw * tht) full_ = true;
              else if (nd > 0) {
                var rects = new List<Rectangle>(); var open = new Dictionary<int, int>();   // (first tile, last tile) of a run -> its rectangle, to grow it down
                for (int ty = 0; ty < tht; ty++) {
                  var next = new Dictionary<int, int>();
                  for (int tx = 0; tx < tw; tx++) {
                    if (!dirty[ty * tw + tx]) continue;
                    int x0 = tx; while (tx + 1 < tw && dirty[ty * tw + tx + 1]) tx++;   // a run of changed tiles in this row is one picture...
                    int k = x0 * 4096 + tx, ri;
                    if (open.TryGetValue(k, out ri)) { var r0 = rects[ri]; r0.Height += 64; rects[ri] = r0; }   // ...and grows down while the row below changed the same way
                    else { ri = rects.Count; rects.Add(new Rectangle(x0 * 64, ty * 64, (tx - x0 + 1) * 64, 64)); }
                    next[k] = ri;
                  }
                  open = next;
                }
                for (int i = 0; i < rects.Count; i++) { var r = rects[i]; r.Intersect(new Rectangle(0, 0, fw, fh)); rects[i] = r; }
                using (var m = new MemoryStream()) {
                  Put16(m, rects.Count);
                  foreach (var r in rects) using (var part = frame.Clone(r, PixelFormat.Format32bppRgb)) { var j = Jpeg(part, q); Put16(m, r.X); Put16(m, r.Y); Put32(m, j.Length); m.Write(j, 0, j.Length); }
                  tiles = m.ToArray();
                }
              }
            }
            var tw0 = DateTime.UtcNow; int sent = 0;
            if (full_) {
              var meta = Encoding.UTF8.GetBytes(string.Format(System.Globalization.CultureInfo.InvariantCulture, "{{\"w\":{0},\"h\":{1},\"ox\":{2},\"oy\":{3},\"sc\":{4},\"mon\":{5},\"mons\":{6}}}", fw, fh, area.Left, area.Top, sc, curMon, Mons()));
              var j = Jpeg(frame, q);
              using (var m = new MemoryStream()) { Put16(m, meta.Length); m.Write(meta, 0, meta.Length); m.Write(j, 0, j.Length); var b = m.ToArray(); Send(st, 'K', b); sent = b.Length; }
              key = false; lastKey = DateTime.UtcNow;
            } else if (tiles != null) { Send(st, 'T', tiles); sent = tiles.Length; }
            var wms = (DateTime.UtcNow - tw0).TotalMilliseconds;   // a slow link shows up as a slow write: lower the quality, raise it again when it is fast
            if (sent > 0) { if (wms > 250 && q > 30) q -= 10; else if (wms < 60 && q < 60) q += 5; }
            var tmp = pa; pa = ca; ca = tmp;
          }
          if ((DateTime.UtcNow - lastSys).TotalMilliseconds >= 2000) { lastSys = DateTime.UtcNow; try { Send(st, 'S', Encoding.UTF8.GetBytes(Sys.Snap(10))); } catch (IOException) { throw; } catch { } }   // the live System panel
          var spent = (DateTime.UtcNow - t0).TotalMilliseconds; Thread.Sleep((int)Math.Max(5, 66 - spent));
        }
      }
      try { rq.GetResponse().Close(); } catch { }
    }
  }

  // The link to the relay. Every request to the relay goes through a tiny local CONNECT proxy that can leave through a chosen network adapter
  // (IP_UNICAST_IF), so a VPN, a DPI-bypass tool (zapret / WinDivert) or a broken default route cannot take the helper down. A watchdog asks the relay
  // for /health every few seconds; when that fails, every route is tried in parallel and the first healthy one wins (physical adapters first, the
  // default route next, a system proxy next, VPN adapters last). It only ever moves to a route that has just worked.
  // ponytail: IPv4 only, https relays only; plain-http relays (tests, LAN) keep the normal connection
  public static class Route {
    [DllImport("iphlpapi.dll")] static extern int GetBestInterface(uint dest, out int index);
    static readonly Regex VpnRx = new Regex("TAP-|TUN|WireGuard|Wintun|VPN|Meta Tunnel|Tailscale|ZeroTier|Hamachi|Cisco|Fortinet|NordLynx|Clash|sing-box|Amnezia|Outline|WARP|Proton|Mullvad|OpenVPN|Radmin|PANGP|GlobalProtect|Npcap", RegexOptions.IgnoreCase);
    static readonly Regex VirtRx = new Regex("Hyper-V|VirtualBox|VMware|vEthernet|WSL|Virtual Adapter|Bluetooth|Teredo|ISATAP|6to4|Pseudo", RegexOptions.IgnoreCase);
    public class Ad { public int If; public string Name = "", Desc = "", Kind = "", Mac = "", Ips = "", Gw = "", Dns = ""; public bool Up, Vpn, Virt, Eth, Dhcp; public long Speed; public int Ms = -2; }
    class Cand { public string Key, Name; public int If; public bool Vpn, Sys; }
    class Hop { public string Key; public int If; public int Port; public TcpListener L; public readonly List<Socket> Conns = new List<Socket>(); }

    static readonly Dictionary<string, Hop> hops = new Dictionary<string, Hop>();
    static readonly object lk = new object();
    static readonly System.Collections.Concurrent.ConcurrentQueue<string> ev = new System.Collections.Concurrent.ConcurrentQueue<string>();
    static readonly List<string> hist = new List<string>();
    static readonly AutoResetEvent wake = new AutoResetEvent(false);
    static readonly IWebProxy sp = WebRequest.GetSystemWebProxy();
    static Uri relay; static string host, lastIp, blockFile; static int port; static volatile bool on, forced;
    static volatile Hop cur; static Cand curC; static DateTime lastOk = DateTime.MinValue, since = DateTime.UtcNow; static int switches;
    public static readonly IWebProxy Proxy = new RP();

    class RP : IWebProxy {
      public ICredentials Credentials { get; set; }
      public Uri GetProxy(Uri u) { var h = cur; if (on && h != null && u.Host == host) return new Uri("http://127.0.0.1:" + h.Port); return sp.GetProxy(u); }
      public bool IsBypassed(Uri u) { if (on && cur != null && u.Host == host) return false; return sp.IsBypassed(u); }
    }

    static void Emit(string type, string msg) {
      ev.Enqueue(type + "|" + msg);
      lock (lk) { hist.Add(DateTime.Now.ToString("HH:mm:ss") + " " + msg); if (hist.Count > 12) hist.RemoveAt(0); }
    }
    public static string[] Drain() { var l = new List<string>(); string s; while (ev.TryDequeue(out s)) l.Add(s); return l.ToArray(); }
    public static void Ok() { lastOk = DateTime.UtcNow; }
    public static void Failed() { forced = true; wake.Set(); }

    public static string Key() { var c = curC; return c != null ? c.Key : ""; }
    public static void Init(string url, string savedKey, string block) {
      try {
        relay = new Uri(url); host = relay.Host; port = relay.Port; blockFile = block;   // block: a test hook, a file naming the routes (def, sys, if14 ...) that must fail while it exists
        if (relay.Scheme != "https" || Environment.GetEnvironmentVariable("HELPER_ROUTE") == "0") return;
        var ord = Order(); if (ord.Count == 0) return;
        var first = ord[0]; foreach (var c in ord) if (c.Key == savedKey) first = c;   // the route that worked last time: no search after a reboot
        on = true; Switch(first, "start", false); forced = true;
        new Thread(Watch) { IsBackground = true, Priority = ThreadPriority.AboveNormal }.Start();
      } catch (Exception e) { on = false; Emit("route", "route layer off: " + e.Message); }
    }

    static List<Ad> Ads() {
      var l = new List<Ad>();
      foreach (var ni in NetworkInterface.GetAllNetworkInterfaces()) {
        if (ni.NetworkInterfaceType == NetworkInterfaceType.Loopback) continue;
        try {
          var ip = ni.GetIPProperties(); var v4 = ip.GetIPv4Properties();
          var a = new Ad { If = v4 != null ? v4.Index : 0, Name = ni.Name, Desc = ni.Description, Up = ni.OperationalStatus == OperationalStatus.Up, Speed = ni.Speed, Dhcp = v4 != null && v4.IsDhcpEnabled };
          a.Mac = BitConverter.ToString(ni.GetPhysicalAddress().GetAddressBytes());
          var ips = new List<string>(); foreach (var u in ip.UnicastAddresses) if (u.Address.AddressFamily == AddressFamily.InterNetwork) ips.Add(u.Address + "/" + u.PrefixLength);
          a.Ips = string.Join(", ", ips.ToArray());
          var gws = new List<string>(); foreach (var g in ip.GatewayAddresses) if (g.Address.AddressFamily == AddressFamily.InterNetwork && !g.Address.Equals(IPAddress.Any)) gws.Add(g.Address.ToString());
          a.Gw = string.Join(", ", gws.ToArray());
          var dns = new List<string>(); foreach (var d in ip.DnsAddresses) if (d.AddressFamily == AddressFamily.InterNetwork) dns.Add(d.ToString());
          a.Dns = string.Join(", ", dns.ToArray());
          string dd = ni.Description + " " + ni.Name; var nt = ni.NetworkInterfaceType.ToString();
          a.Vpn = VpnRx.IsMatch(dd) || ni.NetworkInterfaceType == NetworkInterfaceType.Tunnel || ni.NetworkInterfaceType == NetworkInterfaceType.Ppp;
          a.Virt = !a.Vpn && VirtRx.IsMatch(dd);
          a.Eth = nt.Contains("Ethernet");
          a.Kind = a.Vpn ? "VPN/tunnel" : a.Virt ? "virtual" : ni.NetworkInterfaceType == NetworkInterfaceType.Wireless80211 ? "Wi-Fi" : a.Eth ? "Ethernet" : nt;
          l.Add(a);
        } catch { }
      }
      return l;
    }

    static string RelayIp() {
      if (lastIp != null) return lastIp;
      try { foreach (var a in Dns.GetHostAddresses(host)) if (a.AddressFamily == AddressFamily.InterNetwork) { lastIp = a.ToString(); break; } } catch { }
      return lastIp;
    }

    // physical adapters (Ethernet before Wi-Fi), the default route, the system proxy, then VPN adapters; when the default route already leaves through a physical adapter it goes first
    static List<Cand> Order() {
      var ads = Ads(); var phys = new List<Ad>(); var vpns = new List<Ad>();
      foreach (var a in ads) { if (!a.Up || a.If <= 0) continue; if (a.Vpn) vpns.Add(a); else if (!a.Virt && a.Gw.Length > 0) phys.Add(a); }
      phys.Sort((x, y) => x.Eth != y.Eth ? (x.Eth ? -1 : 1) : y.Speed.CompareTo(x.Speed));
      bool defVpn = false; try { var ip = RelayIp(); int bi; if (ip != null && GetBestInterface(BitConverter.ToUInt32(IPAddress.Parse(ip).GetAddressBytes(), 0), out bi) == 0) foreach (var a in ads) if (a.If == bi && a.Vpn) defVpn = true; } catch { }
      var def = new Cand { Key = "def", Name = "default route", If = 0 };
      var l = new List<Cand>(); if (!defVpn) l.Add(def);
      foreach (var a in phys) l.Add(new Cand { Key = "if" + a.If, Name = a.Name + " (" + a.Kind + ")", If = a.If });
      if (defVpn) l.Add(def);
      try { var u = new Uri("https://" + host + ":" + port + "/"); if (!sp.IsBypassed(u)) l.Add(new Cand { Key = "sys", Name = "system proxy", Sys = true }); } catch { }
      foreach (var a in vpns) l.Add(new Cand { Key = "if" + a.If, Name = a.Name + " (VPN)", If = a.If, Vpn = true });
      return l;
    }

    static Hop HopFor(Cand c) {
      lock (lk) {
        Hop h; if (hops.TryGetValue(c.Key, out h)) return h;
        var l = new TcpListener(IPAddress.Loopback, 0); l.Start(); h = new Hop { Key = c.Key, If = c.If, L = l, Port = ((IPEndPoint)l.LocalEndpoint).Port }; hops[c.Key] = h;
        var hh = h; new Thread(() => { while (true) { Socket s; try { s = hh.L.AcceptSocket(); } catch { return; } ThreadPool.QueueUserWorkItem(_ => Handle(hh, s)); } }) { IsBackground = true }.Start();
        return h;
      }
    }

    static bool HasEnd(byte[] b, int n) { for (int i = 3; i < n; i++) if (b[i] == 10 && b[i - 1] == 13 && b[i - 2] == 10 && b[i - 3] == 13) return true; return false; }
    static void Say(Socket c, string s) { try { c.Send(Encoding.ASCII.GetBytes(s)); } catch { } }

    static Socket Dial(Hop h, string th, int tp) {
      try { if (blockFile != null && File.Exists(blockFile) && File.ReadAllText(blockFile).Contains(h.Key)) throw new Exception("blocked by the test hook"); } catch (IOException) { }
      var ips = new List<IPAddress>();
      if (lastIp != null) ips.Add(IPAddress.Parse(lastIp));
      try { foreach (var a in Dns.GetHostAddresses(th)) if (a.AddressFamily == AddressFamily.InterNetwork && !ips.Contains(a)) ips.Add(a); } catch { }
      Exception last = new Exception("no address for " + th);
      foreach (var ip in ips) {
        Socket s = null;
        try {
          s = new Socket(AddressFamily.InterNetwork, SocketType.Stream, ProtocolType.Tcp); s.NoDelay = true;
          if (h.If > 0) s.SetSocketOption(SocketOptionLevel.IP, (SocketOptionName)31, IPAddress.HostToNetworkOrder(h.If));   // IP_UNICAST_IF: leave through this adapter whatever the routing table says
          try { var ka = new byte[12]; BitConverter.GetBytes(1u).CopyTo(ka, 0); BitConverter.GetBytes(15000u).CopyTo(ka, 4); BitConverter.GetBytes(5000u).CopyTo(ka, 8); s.IOControl(IOControlCode.KeepAliveValues, ka, null); } catch { }
          var ar = s.BeginConnect(ip, tp, null, null);
          if (!ar.AsyncWaitHandle.WaitOne(4000)) { s.Close(); last = new Exception("connect timeout " + ip); continue; }
          s.EndConnect(ar); return s;
        } catch (Exception e) { last = e; try { if (s != null) s.Close(); } catch { } }
      }
      throw last;
    }

    static void Pump(Socket a, Socket b) {
      var buf = new byte[32768];
      try { while (true) { int r = a.Receive(buf); if (r <= 0) break; int off = 0; while (off < r) off += b.Send(buf, off, r - off, SocketFlags.None); } } catch { }
      try { b.Shutdown(SocketShutdown.Send); } catch { }
    }

    static void Handle(Hop h, Socket c) {
      Socket u = null;
      try {
        c.ReceiveTimeout = 5000; var buf = new byte[8192]; int n = 0;
        while (n < buf.Length) { int r = c.Receive(buf, n, buf.Length - n, SocketFlags.None); if (r <= 0) return; n += r; if (HasEnd(buf, n)) break; }
        var line = Encoding.ASCII.GetString(buf, 0, Math.Min(n, 400)).Split('\n')[0].Trim(); var p = line.Split(' ');
        if (p.Length < 2 || p[0] != "CONNECT") { Say(c, "HTTP/1.1 405 Method Not Allowed\r\n\r\n"); return; }
        int ci = p[1].LastIndexOf(':'); string th = p[1].Substring(0, ci); int tp = int.Parse(p[1].Substring(ci + 1));
        if (!string.Equals(th, host, StringComparison.OrdinalIgnoreCase) || tp != port) { Say(c, "HTTP/1.1 403 Forbidden\r\n\r\n"); return; }   // not an open proxy: the relay and nothing else
        u = Dial(h, th, tp); try { lastIp = ((IPEndPoint)u.RemoteEndPoint).Address.ToString(); } catch { }
        Say(c, "HTTP/1.1 200 Connection established\r\n\r\n"); c.ReceiveTimeout = 0;
        lock (h.Conns) { h.Conns.Add(c); h.Conns.Add(u); }
        var uu = u; new Thread(() => Pump(uu, c)) { IsBackground = true }.Start(); Pump(c, u);
      } catch { Say(c, "HTTP/1.1 502 Bad Gateway\r\n\r\n"); }
      finally {
        lock (h.Conns) { h.Conns.Remove(c); if (u != null) h.Conns.Remove(u); }
        try { c.Close(); } catch { } try { if (u != null) u.Close(); } catch { }
      }
    }

    static void CloseAll(Hop h) { lock (h.Conns) { foreach (var s in h.Conns.ToArray()) { try { s.Close(); } catch { } } h.Conns.Clear(); } }   // the old route may be a black hole: break what is stuck on it now

    static int Probe(Cand c, int ms) {
      try {
        var rq = (HttpWebRequest)WebRequest.Create("https://" + host + ":" + port + "/health");
        rq.Proxy = c.Sys ? sp : new WebProxy("127.0.0.1", HopFor(c).Port); rq.Timeout = ms; rq.ReadWriteTimeout = ms; rq.KeepAlive = false; rq.ConnectionGroupName = Guid.NewGuid().ToString(); rq.UserAgent = "helpermcp-probe";
        var sw = System.Diagnostics.Stopwatch.StartNew();
        using (var r = (HttpWebResponse)rq.GetResponse()) return (int)r.StatusCode == 200 ? (int)Math.Max(1, sw.ElapsedMilliseconds) : -1;
      } catch { return -1; }
    }

    static int[] ProbeAll(List<Cand> l, int ms) {
      var res = new int[l.Count]; var ts = new List<Thread>();
      for (int i = 0; i < l.Count; i++) { int k = i; var t = new Thread(() => { res[k] = Probe(l[k], ms); }) { IsBackground = true }; ts.Add(t); t.Start(); }
      foreach (var t in ts) t.Join(ms + 1500);
      return res;
    }

    static void Switch(Cand c, string why, bool tell) {
      Hop old; Cand oc;
      lock (lk) { old = cur; oc = curC; curC = c; cur = c.Sys ? null : HopFor(c); since = DateTime.UtcNow; switches++; }
      if (old != null && old != cur) CloseAll(old);
      lastOk = DateTime.UtcNow;
      if (tell) Emit("route", why + ": " + (oc != null ? oc.Name : "?") + " -> " + c.Name);
    }

    static void Watch() {
      DateTime better = DateTime.UtcNow; DateTime failTold = DateTime.MinValue;
      while (true) {
        wake.WaitOne(4000);
        bool f = forced; forced = false;
        if (!f && (DateTime.UtcNow - lastOk).TotalSeconds < 4) continue;
        var c = curC;
        if (c != null && Probe(c, 3500) > 0) {
          lastOk = DateTime.UtcNow;
          if ((DateTime.UtcNow - better).TotalSeconds > 90) { better = DateTime.UtcNow; TryBetter(); }
          continue;
        }
        try {
          var ord = Order(); var res = ProbeAll(ord, 4000); Cand pick = null;
          for (int i = 0; i < ord.Count && pick == null; i++) if (res[i] > 0) pick = ord[i];
          if (pick != null) Switch(pick, "relay unreachable", true);
          else if ((DateTime.UtcNow - failTold).TotalSeconds > 30) { failTold = DateTime.UtcNow; var sb = new StringBuilder(); for (int i = 0; i < ord.Count; i++) sb.Append(ord[i].Name).Append(" FAIL; "); Emit("route", "no route reaches the relay: " + sb); }
        } catch (Exception e) { Emit("route", "route check failed: " + e.Message); }
      }
    }

    static void TryBetter() {   // back to a more preferred route once it works again
      try {
        var ord = Order(); var c = curC; int at = ord.Count; for (int i = 0; i < ord.Count; i++) if (c != null && ord[i].Key == c.Key) at = i;
        if (at == 0 || at >= ord.Count) return;
        var better = ord.GetRange(0, at); var res = ProbeAll(better, 3500);
        for (int i = 0; i < better.Count; i++) if (res[i] > 0) { Switch(better[i], "preferred route works again", true); return; }
      } catch { }
    }

    public static string Status() { lock (lk) { return on ? "via " + (curC != null ? curC.Name : "?") + " since " + since.ToLocalTime().ToString("HH:mm:ss") + ", " + (switches - 1) + " switch(es)" : "normal connection (route layer off)"; } }

    // every adapter, with a relay check through each one that is up and has a gateway
    public static string Report(bool probe) {
      var ads = Ads(); int best = -1;
      try { var ip = RelayIp(); int bi; if (ip != null && GetBestInterface(BitConverter.ToUInt32(IPAddress.Parse(ip).GetAddressBytes(), 0), out bi) == 0) best = bi; } catch { }
      if (probe && relay != null && relay.Scheme == "https") {
        var cs = new List<Cand>(); var who = new List<Ad>();
        foreach (var a in ads) if (a.Up && a.If > 0 && (a.Gw.Length > 0 || a.Vpn)) { cs.Add(new Cand { Key = "if" + a.If, Name = a.Name, If = a.If }); who.Add(a); }
        var res = ProbeAll(cs, 4000); for (int i = 0; i < who.Count; i++) who[i].Ms = res[i];
      }
      var sb = new StringBuilder();
      sb.Append("agent link: ").Append(Status()).Append('\n');
      foreach (var a in ads) {
        sb.Append(a.Name).Append(" [").Append(a.Up ? "Up" : "Down").Append("] ").Append(a.Kind);
        if (a.Up && a.Speed > 0 && a.Speed < 100000000000L) sb.Append(' ').Append(a.Speed >= 1000000000 ? (a.Speed / 1000000000.0).ToString("0.#") + " Gbit/s" : (a.Speed / 1000000) + " Mbit/s");
        if (a.Ips.Length > 0) sb.Append("; ip ").Append(a.Ips); if (a.Gw.Length > 0) sb.Append("; gw ").Append(a.Gw); if (a.Dns.Length > 0) sb.Append("; dns ").Append(a.Dns);
        if (a.Up) sb.Append(a.Dhcp ? "; dhcp" : "; static"); sb.Append("; mac ").Append(a.Mac);
        if (a.If == best) sb.Append("; DEFAULT ROUTE to the internet");
        if (curC != null && !curC.Sys && curC.If == a.If && on) sb.Append("; AGENT USES THIS");
        if (a.Ms > 0) sb.Append("; relay ok ").Append(a.Ms).Append(" ms"); else if (a.Ms == -1) sb.Append("; relay FAIL");
        sb.Append('\n');
      }
      lock (lk) { if (hist.Count > 0) { sb.Append("route log:\n"); foreach (var h in hist) sb.Append("  ").Append(h).Append('\n'); } }
      return sb.ToString().TrimEnd();
    }
  }
}
"@

Add-Type -TypeDefinition @"
using System; using System.Collections.Concurrent; using System.Threading; using System.IO; using System.Net;
namespace K__BUILD__ {
  public static class Keys {   // one reader for the keyboard: Esc opens a menu (pause / continue / end), the other keys answer the questions
    public static ConcurrentQueue<ConsoleKey> Q = new ConcurrentQueue<ConsoleKey>();
    public static volatile bool Esc, Paused, Final, OpSeen, VT, StRestoreOk, Unattended;      // Esc = the user confirmed the end; Unattended = mode 3, Esc pauses instead of opening the end menu
    public static string Relay, Token, MenuRun, MenuPaused, ConfirmEnd, StPaused, StRestore, Continuing;
    public static System.IO.StreamWriter Overlay;
    static string C(string code, string s) { return VT ? "\u001b[" + code + "m" + s + "\u001b[0m" : s; }
    static void Say(string s) { try { Console.WriteLine(s); } catch { } }
    static void Ov(string line) { try { var o = Overlay; if (o != null) lock (o) o.WriteLine(line); } catch { } }
    // the pinned header: a box over the full width of the console, every line centred and closed on the right
    public static int W() { try { return Math.Max(40, Math.Min(200, Console.WindowWidth - (VT ? 0 : 1))); } catch { return 79; } }
    static string Pad(string t, int w, out int left) { if (t.Length > w) t = t.Substring(0, w); left = (w - t.Length) / 2; return t; }
    public static string Row(string text, string ansi) {
      int w = W() - 2, l; var t = Pad(text, w, out l);
      return C("33", "\u2502") + new string(' ', l) + (VT && ansi != null ? "\u001b[" + ansi + "m" + t + "\u001b[0m" : t) + new string(' ', w - t.Length - l) + C("33", "\u2502");
    }
    public static string CodeRow(string label, string code, string tail) {
      int w = W() - 2; string plain = label + "  " + " " + code + " " + (tail.Length > 0 ? "   " + tail : ""); int l = Math.Max(0, (w - plain.Length) / 2), r = Math.Max(0, w - plain.Length - l);
      return C("33", "\u2502") + new string(' ', l) + C("33", label + "  ") + C("30;43", " " + code + " ") + (tail.Length > 0 ? C("32", "   " + tail) : "") + new string(' ', r) + C("33", "\u2502");
    }
    public static string Top(string title) { int w = W() - 2; string t = " " + title + " "; int l = (w - t.Length) / 2; return C("33", "\u250C" + new string('\u2500', l) + t + new string('\u2500', Math.Max(0, w - l - t.Length)) + "\u2510"); }
    public static string Bottom() { return C("33", "\u2514" + new string('\u2500', W() - 2) + "\u2518"); }
    static void Status(string text, bool ok) { if (!VT) return; try { Console.Write("\u001b7\u001b[5;1H\u001b[2K" + Row(text, ok ? "1;32" : "1;38;5;208") + "\u001b8"); } catch { } }
    public static void Post(string path, string json) {
      try { var rq = (HttpWebRequest)WebRequest.Create(Relay + path); rq.Method = "POST"; rq.Headers["Authorization"] = "Bearer " + Token; rq.ContentType = "application/json"; rq.Timeout = 3000;
        var b = System.Text.Encoding.UTF8.GetBytes(json); rq.ContentLength = b.Length; using (var st = rq.GetRequestStream()) st.Write(b, 0, b.Length); rq.GetResponse().Close(); } catch { }
    }
    static void SetPaused(bool on) {
      Paused = on; Post("/a/state", on ? "{\"paused\":true}" : "{\"paused\":false}"); Ov(on ? "state paused" : (OpSeen ? "state ok" : "state wait"));
      if (on) { Status(StPaused, false); Say(C("38;5;208", "  || " + StPaused)); } else { Status(StRestore, StRestoreOk); Say(C("32", "  \u25B6 " + Continuing)); }
    }
    static void Menu() {
      Say(""); Say(C("1;30;43", "  " + (Paused ? MenuPaused : MenuRun) + "  "));
      while (true) {
        var k = Console.ReadKey(true).Key;
        if (k == ConsoleKey.P && !Paused) { SetPaused(true); return; }
        if (k == ConsoleKey.R && Paused) { SetPaused(false); return; }
        if (k == ConsoleKey.X) {
          Say(C("1;30;43", "  " + ConfirmEnd + "  ")); var k2 = Console.ReadKey(true).Key;
          if (k2 == ConsoleKey.Y || k2 == ConsoleKey.Enter) { Final = true; Esc = true; Post("/a/bye", "{\"final\":true}"); }   // only now the session is over, for good
          return;
        }
        if (k == ConsoleKey.Escape || k == ConsoleKey.N || k == ConsoleKey.Enter) return;
      }
    }
    public static void Start() {
      var t = new Thread(() => { try { while (true) { var k = Console.ReadKey(true); if (k.Key == ConsoleKey.Escape) { if (Unattended) SetPaused(!Paused); else Menu(); } else Q.Enqueue(k.Key); } } catch { } });
      t.IsBackground = true; t.Start();
    }
  }
  public static class Chime {   // soft bells made on the fly (no files shipped)
    public static byte[] Make(double[] f, double[] start, double[] dur, double amp) {
      int sr = 22050; double total = 0; for (int i = 0; i < f.Length; i++) total = Math.Max(total, start[i] + dur[i]);
      int n = (int)(sr * (total + 0.1)); var buf = new double[n];
      for (int k = 0; k < f.Length; k++) { int i0 = (int)(start[k] * sr);
        for (int i = 0; i < (int)(dur[k] * sr) && i0 + i < n; i++) { double t = (double)i / sr; double env = (1 - Math.Exp(-t * 400)) * Math.Exp(-t * 5.5);
          buf[i0 + i] += amp * env * (Math.Sin(2 * Math.PI * f[k] * t) + 0.28 * Math.Sin(4 * Math.PI * f[k] * t) + 0.08 * Math.Sin(2 * Math.PI * 3.01 * f[k] * t)); } }
      var ms = new MemoryStream(); var w = new BinaryWriter(ms);
      w.Write(new char[] { 'R', 'I', 'F', 'F' }); w.Write(36 + n * 2); w.Write(new char[] { 'W', 'A', 'V', 'E', 'f', 'm', 't', ' ' }); w.Write(16); w.Write((short)1); w.Write((short)1); w.Write(sr); w.Write(sr * 2); w.Write((short)2); w.Write((short)16);
      w.Write(new char[] { 'd', 'a', 't', 'a' }); w.Write(n * 2);
      for (int i = 0; i < n; i++) w.Write((short)Math.Max(-32000, Math.Min(32000, buf[i] * 22000)));
      w.Flush(); return ms.ToArray();
    }
  }
}
"@

function Api($path, $data, $token, $timeout = 40) {
    $h = @{}
    if ($token) { $h.Authorization = "Bearer $token" }
    if ($null -ne $data) {
        $b = [Text.Encoding]::UTF8.GetBytes(($data | ConvertTo-Json -Depth 6 -Compress))
        if ($b.Length -gt 2048) {   # weak links: big outputs shrink a lot
            $ms = New-Object IO.MemoryStream; $gz = New-Object IO.Compression.GZipStream($ms, [IO.Compression.CompressionMode]::Compress)
            $gz.Write($b, 0, $b.Length); $gz.Close(); $b = $ms.ToArray(); $h['Content-Encoding'] = 'gzip'
        }
        Invoke-WebRequest -Uri "$RELAY$path" -Method Post -Headers $h -Body $b -ContentType 'application/json; charset=utf-8' -TimeoutSec $timeout -UseBasicParsing
    } else {
        Invoke-WebRequest -Uri "$RELAY$path" -Headers $h -TimeoutSec $timeout -UseBasicParsing
    }
}
function Clip($s) { if ($s.Length -gt $MaxOut) { $s.Substring(0, $MaxOut) + "`n...[truncated]" } else { $s } }

$Scale = 1.0
$script:OriginX = [Windows.Forms.SystemInformation]::VirtualScreen.Left; $script:OriginY = [Windows.Forms.SystemInformation]::VirtualScreen.Top   # real px of the screenshot's top-left

function Do-Screenshot($a) { Do-Screenshot-Inner $a }   # the overlay is never hidden (no blinking); the AI's pictures have the glow taken out by arithmetic
function Do-Screenshot-Inner($a) {
    $s = [Windows.Forms.SystemInformation]::VirtualScreen   # all monitors, or just one with "monitor"
    if ($null -ne $a.monitor) {
        $all = [Windows.Forms.Screen]::AllScreens
        if ([int]$a.monitor -lt 0 -or [int]$a.monitor -ge $all.Count) { throw "No monitor $($a.monitor). Monitors: 0..$($all.Count - 1)" }
        $s = $all[[int]$a.monitor].Bounds
    }
    if ($a.region -and -not $a.view) {   # a part of the screen, in the coordinates of the last screenshot
        $rx = [int]($a.region.x * $Scale) + $script:OriginX; $ry = [int]($a.region.y * $Scale) + $script:OriginY
        $s = New-Object Drawing.Rectangle $rx, $ry, ([Math]::Max(16, [int]($a.region.w * $Scale))), ([Math]::Max(16, [int]($a.region.h * $Scale)))
    }
    $view = [bool]$a.view   # the live viewer's frames must not change the coordinates the AI clicks with
    if (-not $view) { $script:OriginX = $s.Left; $script:OriginY = $s.Top }
    $bmp = New-Object Drawing.Bitmap $s.Width, $s.Height
    $g = [Drawing.Graphics]::FromImage($bmp)
    $g.CopyFromScreen($s.Left, $s.Top, 0, 0, $bmp.Size)
    $g.Dispose()
    if (-not $view -and $script:OverlayProc -and -not $script:OverlayProc.HasExited) {
        try {
            $rect = New-Object Drawing.Rectangle 0, 0, $s.Width, $s.Height; $bd = $bmp.LockBits($rect, 'ReadWrite', 'Format32bppArgb')
            $buf = New-Object byte[] ($bd.Stride * $s.Height); [Runtime.InteropServices.Marshal]::Copy($bd.Scan0, $buf, 0, $buf.Length)
            $ms_ = @(); foreach ($scr in [Windows.Forms.Screen]::AllScreens) { $ms_ += $scr.Bounds.X, $scr.Bounds.Y, $scr.Bounds.Width, $scr.Bounds.Height }
            [V__BUILD__.Unglow]::Run($buf, $s.Width, $s.Height, $s.Left, $s.Top, [int[]]$ms_, $GlowDepth, [int[]]($script:OkRGB + @(255, 138, 30, 61, 220, 132)))
            [Runtime.InteropServices.Marshal]::Copy($buf, 0, $bd.Scan0, $buf.Length); $bmp.UnlockBits($bd)
        } catch { try { $bmp.UnlockBits($bd) } catch { } }
    }
    $cap = if ($a.max_width) { [int]$a.max_width } elseif ($view) { 1280 } else { 1920 }
    $qual = if ($a.quality) { [long]$a.quality } elseif ($view) { 65L } else { 70L }
    $w = [Math]::Min($cap, $s.Width)
    $sc = $s.Width / $w
    if (-not $view) { $script:Scale = $sc }
    $out = New-Object Drawing.Bitmap $w, ([int]($s.Height / $sc))
    $g = [Drawing.Graphics]::FromImage($out)
    $g.InterpolationMode = 'HighQualityBicubic'
    $g.DrawImage($bmp, 0, 0, $out.Width, $out.Height)
    $g.Dispose(); $bmp.Dispose()
    $enc = [Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object MimeType -eq 'image/jpeg'
    $p = New-Object Drawing.Imaging.EncoderParameters 1
    $p.Param[0] = New-Object Drawing.Imaging.EncoderParameter ([Drawing.Imaging.Encoder]::Quality), $qual
    $ms = New-Object IO.MemoryStream
    $out.Save($ms, $enc, $p); $out.Dispose()
    $bytes = $ms.ToArray()
    # the fingerprint ignores the helper's own label, glow and clock: an unchanged screen is recognised as unchanged
    $fp = try { [V__BUILD__.Probe]::Grab($s.Left, $s.Top, $s.Width, $s.Height, 640, [Math]::Max(8, [int](640 * $s.Height / $s.Width)), [int[]](@(Probe-Mask) + @(([Windows.Forms.Cursor]::Position.X - 90), ([Windows.Forms.Cursor]::Position.Y - 90), 220, 220))) } catch { $bytes }   # and the AI's arrow
    $hash = [BitConverter]::ToString([Security.Cryptography.MD5]::Create().ComputeHash([byte[]]$fp)).Replace('-', '').ToLower()
    if ($a.prev -and $a.prev -eq $hash) { return @{ same = $true; h = $hash } }   # nothing changed: send nothing
    @{ jpeg = $bytes; mime = 'image/jpeg'; h = $hash; ox = $s.Left; oy = $s.Top; sc = $sc }
}

# Screenshots go as the raw JPEG body (no base64 inflation), everything else as (gzipped) JSON.
function Post-Result($res, $token) {
    if ($res.ok -and $res.data -is [hashtable] -and $res.data.jpeg) {
        $meta = @{}; foreach ($k in $res.data.Keys) { if ($k -ne 'jpeg' -and $k -ne 'mime') { $meta[$k] = $res.data[$k] } }
        $h = @{ Authorization = "Bearer $token"; 'X-Result-Id' = $res.id; 'X-Result-Meta' = [Uri]::EscapeDataString(($meta | ConvertTo-Json -Compress)) }
        [void](Invoke-WebRequest -Uri "$RELAY/a/result" -Method Post -Headers $h -Body ([byte[]]$res.data.jpeg) -ContentType $res.data.mime -TimeoutSec 60 -UseBasicParsing)
    } else { [void](Api '/a/result' $res $token 60) }
}

# Move the real pointer like a hand would: a slightly curved path, slow start, fast middle, soft landing (cubic-bezier 0.45, 0, 0.15, 1), paced by the clock.
# The overlay arrow follows it and turns its tip into the direction of movement.
function Ease($p) {
    $lo = 0.0; $hi = 1.0
    for ($i = 0; $i -lt 18; $i++) { $t = ($lo + $hi) / 2; if ((3 * [Math]::Pow(1 - $t, 2) * $t * 0.45 + 3 * (1 - $t) * $t * $t * 0.15 + $t * $t * $t) -lt $p) { $lo = $t } else { $hi = $t } }
    $t = ($lo + $hi) / 2; 3 * (1 - $t) * $t * $t + $t * $t * $t
}
function Glide($x, $y, $dur, $straight) {
    $p0 = [Windows.Forms.Cursor]::Position; $cx = $p0.X; $cy = $p0.Y; $dx = $x - $cx; $dy = $y - $cy
    $dist = [Math]::Sqrt($dx * $dx + $dy * $dy); if ($dist -lt 2) { return }
    if (-not $dur) { $dur = [Math]::Min(1.3, 0.34 + $dist * 0.0006) }
    $nx = -$dy / $dist; $ny = $dx / $dist; if ($ny -gt 0) { $nx = -$nx; $ny = -$ny }   # the arc bulges upwards
    $bend = if ($straight) { 0.0 } else { [Math]::Min(90.0, $dist * 0.12) }; $qx = ($cx + $x) / 2 + $nx * $bend; $qy = ($cy + $y) / 2 + $ny * $bend
    $sw = [Diagnostics.Stopwatch]::StartNew()
    while ($true) {
        $q = $sw.Elapsed.TotalSeconds / $dur; if ($q -ge 1.0) { break }
        $k = Ease $q; $m = 1 - $k
        [void][H.U__BUILD__]::SetCursorPos([int]($m * $m * $cx + 2 * $m * $k * $qx + $k * $k * $x), [int]($m * $m * $cy + 2 * $m * $k * $qy + $k * $k * $y)); [Threading.Thread]::Sleep(7)
    }
    [void][H.U__BUILD__]::SetCursorPos([int]$x, [int]$y)
}
function Target($a, $kx = 'x', $ky = 'y') { if ($a.raw) { return @([int]$a.$kx, [int]$a.$ky) }; @(([int]($a.$kx * $Scale) + $script:OriginX), ([int]($a.$ky * $Scale) + $script:OriginY)) }
function Btn($name) { switch ($name) { 'right' { 8, 16 } 'middle' { 32, 64 } default { 2, 4 } } }

function Do-Watch($a) {
    $sec = [Math]::Min(10.0, [Math]::Max(1.0, [double]$(if ($a.seconds) { $a.seconds } else { 3 }))); $fps = [Math]::Min(5.0, [Math]::Max(1.0, [double]$(if ($a.fps) { $a.fps } else { 3 })))
    $s = [Windows.Forms.SystemInformation]::VirtualScreen
    if ($null -ne $a.monitor) { $s = [Windows.Forms.Screen]::AllScreens[[int]$a.monitor].Bounds }
    if ($a.region) { $s = New-Object Drawing.Rectangle ([int]($a.region.x * $Scale) + $script:OriginX), ([int]($a.region.y * $Scale) + $script:OriginY), ([Math]::Max(16, [int]($a.region.w * $Scale))), ([Math]::Max(16, [int]($a.region.h * $Scale))) }
    $n = [Math]::Min(30, [int][Math]::Round($sec * $fps)); $cols = if ($n -le 4) { 2 } elseif ($n -le 9) { 3 } elseif ($n -le 16) { 4 } else { 5 }; $rows = [Math]::Ceiling($n / $cols)
    $tw = [int][Math]::Min(640, 1600 / $cols); $th = [int]($tw * $s.Height / $s.Width); $hd = 18
    $sheet = New-Object Drawing.Bitmap ($cols * $tw), ($rows * ($th + $hd)); $gs = [Drawing.Graphics]::FromImage($sheet); $gs.Clear([Drawing.Color]::FromArgb(2, 10, 6))
    $font = New-Object Drawing.Font 'Consolas', 10; $big = New-Object Drawing.Bitmap $s.Width, $s.Height; $gb = [Drawing.Graphics]::FromImage($big)
    $sw = [Diagnostics.Stopwatch]::StartNew(); $prev = $null; $changes = @(); $lastChange = -1.0
    for ($i = 0; $i -lt $n; $i++) {
        while ($sw.Elapsed.TotalSeconds -lt $i / $fps) { Start-Sleep -Milliseconds 5 }
        $t = $sw.Elapsed.TotalSeconds; $gb.CopyFromScreen($s.Left, $s.Top, 0, 0, $big.Size)
        $cur = [V__BUILD__.Probe]::Grab($s.Left, $s.Top, $s.Width, $s.Height, 160, [Math]::Max(10, [int](160 * $s.Height / $s.Width)), [int[]]@())
        $d = if ($prev) { [V__BUILD__.Probe]::Diff($prev, $cur) } else { 0 }; $prev = $cur; $changes += [Math]::Round($d * 100, 1); if ($d -ge 0.002) { $lastChange = $t }
        $cx = ($i % $cols) * $tw; $cy = [Math]::Floor($i / $cols) * ($th + $hd)
        $gs.InterpolationMode = 'HighQualityBilinear'; $gs.DrawImage($big, $cx, $cy + $hd, $tw, $th)
        $col = if ($i -eq 0) { [Drawing.Color]::FromArgb(127, 174, 143) } elseif ($d -ge 0.002) { [Drawing.Color]::FromArgb(255, 209, 102) } else { [Drawing.Color]::FromArgb(56, 120, 80) }
        $br = New-Object Drawing.SolidBrush $col; $gs.DrawString(('{0:0.0}s  {1}' -f $t, $(if ($i -eq 0) { 'start' } else { "changed $([Math]::Round($d * 100, 1))%" })), $font, $br, ($cx + 4), ($cy + 2))
        $pen = New-Object Drawing.Pen $col, $(if ($d -ge 0.002) { 3 } else { 1 }); $gs.DrawRectangle($pen, $cx + 1, $cy + $hd, $tw - 3, $th - 2)
    }
    $gb.Dispose(); $big.Dispose(); $gs.Dispose()
    $enc = [Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object MimeType -eq 'image/jpeg'; $p = New-Object Drawing.Imaging.EncoderParameters 1
    $p.Param[0] = New-Object Drawing.Imaging.EncoderParameter ([Drawing.Imaging.Encoder]::Quality), 62L; $ms = New-Object IO.MemoryStream; $sheet.Save($ms, $enc, $p); $sheet.Dispose()
    $moving = @($changes | Select-Object -Skip 1 | Where-Object { $_ -ge 0.2 }).Count
    $sum = if (-not $moving) { "nothing moved during $sec s" } elseif ($lastChange -lt $sec - 2 / $fps) { "changes in $moving of $($n - 1) frames, settled after $([Math]::Round($lastChange, 1)) s" } else { "still changing at the end ($moving of $($n - 1) frames changed)" }
    @{ jpeg = $ms.ToArray(); mime = 'image/jpeg'; text = "$n frames over $sec s, $sum. Change per frame (%): $($changes -join ', ')" }
}
# ---- ui_tree / ui_click / ui_set: the controls of a window as text through UI Automation (compiled on first use, so a start costs nothing)
function Ensure-Ui {
    if ($script:UiReady) { return }
    try {
        Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes, WindowsBase
        Add-Type -ReferencedAssemblies UIAutomationClient, UIAutomationTypes, WindowsBase -TypeDefinition @'
using System; using System.Collections.Generic; using System.Diagnostics; using System.Text; using System.Threading; using System.Runtime.InteropServices; using System.Windows.Automation;
namespace A__BUILD__ {
  public static class Ui {   // the controls of a window as text (UI Automation): read, press, fill - no pictures, no coordinates to guess
    [DllImport("user32.dll")] static extern IntPtr GetForegroundWindow();
    [DllImport("kernel32.dll")] static extern IntPtr GetConsoleWindow();
    [DllImport("user32.dll")] static extern IntPtr GetWindow(IntPtr h, uint cmd);
    [DllImport("user32.dll")] static extern bool IsWindowVisible(IntPtr h);
    [DllImport("user32.dll")] static extern int GetWindowTextLength(IntPtr h);
    [DllImport("user32.dll")] static extern uint GetWindowThreadProcessId(IntPtr h, out uint pid);
    public class Node { public AutomationElement El; public string Type = "", Name = "", Aid = "", Val; public string[] Flags = new string[0]; public bool Enabled = true; public int X, Y, W, H; }
    delegate void Job();
    static List<AutomationElement> Cache = new List<AutomationElement>();
    static AutomationElement Picked;
    const string Inter = " button check combo edit link listitem menuitem radio slider spinner tabitem treeitem splitbutton document dataitem headeritem ";

    static CacheRequest Req() {
      CacheRequest r = new CacheRequest();
      r.Add(AutomationElement.NameProperty); r.Add(AutomationElement.ControlTypeProperty); r.Add(AutomationElement.BoundingRectangleProperty);
      r.Add(AutomationElement.IsEnabledProperty); r.Add(AutomationElement.IsOffscreenProperty); r.Add(AutomationElement.HasKeyboardFocusProperty);
      r.Add(AutomationElement.AutomationIdProperty); r.Add(AutomationElement.IsPasswordProperty);
      r.Add(ValuePattern.ValueProperty); r.Add(ValuePattern.IsReadOnlyProperty);
      r.Add(TogglePattern.ToggleStateProperty); r.Add(SelectionItemPattern.IsSelectedProperty); r.Add(ExpandCollapsePattern.ExpandCollapseStateProperty);
      return r;
    }
    static object CP(AutomationElement e, AutomationProperty p) { try { return e.GetCachedPropertyValue(p, true); } catch { return null; } }
    static string Cap(string s, int n) { if (s == null) return ""; s = s.Replace("\r", " ").Replace("\n", " ").Trim(); return s.Length > n ? s.Substring(0, n - 2) + ".." : s; }
    static string TypeName(AutomationElement e) {
      string p = e.Cached.ControlType.ProgrammaticName; int i = p.LastIndexOf('.'); p = (i >= 0 ? p.Substring(i + 1) : p).ToLowerInvariant();
      switch (p) { case "checkbox": return "check"; case "combobox": return "combo"; case "hyperlink": return "link"; case "radiobutton": return "radio"; default: return p; }
    }
    static Node Make(AutomationElement e) {
      Node n = new Node(); n.El = e;
      try {
        n.Type = TypeName(e); n.Name = e.Cached.Name ?? ""; n.Aid = e.Cached.AutomationId ?? ""; n.Enabled = e.Cached.IsEnabled;
        System.Windows.Rect r = e.Cached.BoundingRectangle;
        if (!r.IsEmpty && !double.IsInfinity(r.X) && !double.IsInfinity(r.Y)) { n.X = (int)r.X; n.Y = (int)r.Y; n.W = (int)r.Width; n.H = (int)r.Height; }
        object v = CP(e, ValuePattern.ValueProperty); if (v is string && !e.Cached.IsPassword) n.Val = (string)v;
        List<string> f = new List<string>();
        if (!n.Enabled) f.Add("disabled");
        if (e.Cached.HasKeyboardFocus) f.Add("focused");
        object ro = CP(e, ValuePattern.IsReadOnlyProperty); if (ro is bool && (bool)ro) f.Add("readonly");
        object t = CP(e, TogglePattern.ToggleStateProperty); if (t is ToggleState) { if ((ToggleState)t == ToggleState.On) f.Add("checked"); else if ((ToggleState)t == ToggleState.Indeterminate) f.Add("partial"); }
        object s = CP(e, SelectionItemPattern.IsSelectedProperty); if (s is bool && (bool)s) f.Add("selected");
        object x = CP(e, ExpandCollapsePattern.ExpandCollapseStateProperty); if (x is ExpandCollapseState) { if ((ExpandCollapseState)x == ExpandCollapseState.Collapsed) f.Add("collapsed"); else if ((ExpandCollapseState)x == ExpandCollapseState.Expanded) f.Add("expanded"); }
        n.Flags = f.ToArray();
      } catch { return null; }
      return n;
    }
    static void Visit(AutomationElement e, TreeWalker w, CacheRequest rq, int depth, List<Node> acc, int[] budget, DateTime stop) {
      if (budget[0] <= 0 || DateTime.UtcNow > stop || depth > 60) return;
      budget[0]--;
      Node n = Make(e);
      if (n != null) { bool off = false; try { off = e.Cached.IsOffscreen; } catch { } if (off && depth > 0) return; acc.Add(n); }
      AutomationElement c = null;
      try { c = w.GetFirstChild(e, rq); } catch { }
      while (c != null) {
        Visit(c, w, rq, depth + 1, acc, budget, stop);
        if (budget[0] <= 0 || DateTime.UtcNow > stop) break;
        try { c = w.GetNextSibling(c, rq); } catch { c = null; }
      }
    }
    static List<Node> Collect(AutomationElement win) {
      CacheRequest rq = Req(); List<Node> acc = new List<Node>();
      Visit(win.GetUpdatedCache(rq), TreeWalker.ControlViewWalker, rq, 0, acc, new int[] { 9000 }, DateTime.UtcNow.AddSeconds(8));
      return acc;
    }
    static string ProcName(int pid) { try { return Process.GetProcessById(pid).ProcessName; } catch { return "?"; } }
    static AutomationElement PickWindow(string key) {
      if (string.IsNullOrEmpty(key)) {   // the window in front, skipping our own console and overlay
        IntPtr h = GetForegroundWindow(); uint me = (uint)Process.GetCurrentProcess().Id; IntPtr con = GetConsoleWindow();
        for (int i = 0; i < 60 && h != IntPtr.Zero; i++) {
          uint pid; GetWindowThreadProcessId(h, out pid);
          if (pid != me && h != con && IsWindowVisible(h) && GetWindowTextLength(h) > 0) { try { return AutomationElement.FromHandle(h); } catch { } }
          h = GetWindow(h, 2);
        }
      }
      StringBuilder list = new StringBuilder();
      foreach (AutomationElement w in AutomationElement.RootElement.FindAll(TreeScope.Children, Condition.TrueCondition)) {
        string title = ""; int pid2 = 0; try { title = w.Current.Name ?? ""; pid2 = w.Current.ProcessId; } catch { continue; }
        if (title.Length == 0) continue;
        string pn = ProcName(pid2);
        if (!string.IsNullOrEmpty(key) && (title.IndexOf(key, StringComparison.OrdinalIgnoreCase) >= 0 || pn.IndexOf(key, StringComparison.OrdinalIgnoreCase) >= 0)) return w;
        list.Append(pn).Append(": ").Append(Cap(title, 50)).Append(" | ");
      }
      throw new Exception((string.IsNullOrEmpty(key) ? "No window in front." : "No such window.") + " Open windows: " + list);
    }
    static bool Wanted(Node n, bool all) {
      if (n.W <= 0 || n.H <= 0) return false;
      if (all) return true;
      if (n.Type == "window") return n.Name.Length > 0;
      if (n.Type == "text") return n.Name.Length > 0;
      if (Inter.IndexOf(" " + n.Type + " ", StringComparison.Ordinal) < 0) return false;
      return n.Name.Length > 0 || n.Aid.Length > 0 || !string.IsNullOrEmpty(n.Val) || n.Type == "edit" || n.Type == "document";
    }
    static string Label(Node n) { return n.Name.Length > 0 ? n.Name : (n.Aid.Length > 0 ? "{" + n.Aid + "}" : ""); }
    static int Cx(Node n, double sc, int ox) { return (int)((n.X + n.W / 2.0 - ox) / sc); }
    static int Cy(Node n, double sc, int oy) { return (int)((n.Y + n.H / 2.0 - oy) / sc); }

    public static string Tree(string window, string query, int max, bool all, double sc, int ox, int oy) {
      if (sc <= 0) sc = 1;
      AutomationElement win = PickWindow(window); List<Node> acc = Collect(win);
      string wt = ""; int wp = 0; try { wt = win.Current.Name; wp = win.Current.ProcessId; } catch { }
      Cache = new List<AutomationElement>(); StringBuilder sb = new StringBuilder();
      sb.Append("window \"" + Cap(wt, 80) + "\" (" + ProcName(wp) + ")\n");
      int shown = 0, total = 0, content = 0; bool first = true; double winTop = 0; try { winTop = win.Current.BoundingRectangle.Top; } catch { }
      foreach (Node n in acc) {
        if (first) { first = false; continue; }
        if (!Wanted(n, all)) continue;
        string lab = Label(n);
        if (!string.IsNullOrEmpty(query) && (lab + " " + n.Val + " " + n.Aid).IndexOf(query, StringComparison.OrdinalIgnoreCase) < 0) continue;
        total++; if (shown >= max) continue;
        Cache.Add(n.El); shown++; if (!((n.Type == "button" || n.Type == "menuitem" || n.Type == "splitbutton") && n.Y < winTop + 60)) content++;
        sb.Append(shown).Append(' ').Append(n.Type);
        if (lab.Length > 0) sb.Append(" \"").Append(Cap(lab, 70)).Append('"');
        if (!string.IsNullOrEmpty(n.Val)) sb.Append(" =\"").Append(Cap(n.Val, 60)).Append('"');
        sb.Append(" @").Append(Cx(n, sc, ox)).Append(',').Append(Cy(n, sc, oy));
        foreach (string f in n.Flags) sb.Append(' ').Append(f);
        sb.Append('\n');
      }
      if (shown == 0 || (content == 0 && string.IsNullOrEmpty(query))) return sb + "nothing readable here" + (acc.Count <= 1 || shown > 0 ? " (the window shows no controls of its own to this agent: a game, a custom-drawn app or an administrator window)" : (string.IsNullOrEmpty(query) ? "" : " matches '" + query + "'")) + ": use screenshot.";
      if (total > shown) sb.Append("... ").Append(total - shown).Append(" more (use query or max)\n");
      return sb.ToString();
    }
    static bool TypeOk(string have, string want) {
      if (string.IsNullOrEmpty(want)) return true;
      want = want.ToLowerInvariant().Replace(" ", "");
      switch (want) { case "checkbox": want = "check"; break; case "combobox": want = "combo"; break; case "hyperlink": want = "link"; break; case "radiobutton": want = "radio"; break; case "textbox": case "input": case "field": want = "edit"; break; }
      return have == want || (want == "tab" && have == "tabitem") || (want == "menu" && have == "menuitem") || (want == "item" && have.EndsWith("item"));
    }
    // -> [description, centre x, centre y] (real pixels); the control is remembered for Act / Set
    public static string[] Pick(int id, string name, string type, string window) {
      AutomationElement el = null;
      if (id > 0) {
        if (id > Cache.Count) throw new Exception("No control #" + id + ": run ui_tree first, ids come from the last ui_tree");
        el = Cache[id - 1];
        try { string chk = el.Current.Name; } catch { throw new Exception("Control #" + id + " is gone (the window changed): run ui_tree again"); }
      } else {
        if (string.IsNullOrEmpty(name)) throw new Exception("Give an id (from ui_tree) or a name");
        AutomationElement win = PickWindow(window); List<Node> acc = Collect(win);
        List<Node> best = new List<Node>(); int bestRank = 0; bool first = true;
        foreach (Node n in acc) {
          if (first) { first = false; continue; }
          if (n.W <= 0 || n.H <= 0 || !TypeOk(n.Type, type)) continue;
          int sc = 0;
          if (string.Equals(n.Name, name, StringComparison.OrdinalIgnoreCase) || string.Equals(n.Aid, name, StringComparison.OrdinalIgnoreCase)) sc = 3;
          else if (n.Name.StartsWith(name, StringComparison.OrdinalIgnoreCase)) sc = 2;
          else if (n.Name.IndexOf(name, StringComparison.OrdinalIgnoreCase) >= 0) sc = 1;
          if (sc == 0) continue;
          int rank = sc * 10 + (Inter.IndexOf(" " + n.Type + " ", StringComparison.Ordinal) >= 0 ? 5 : 0) + (n.Enabled ? 1 : 0);
          if (rank > bestRank) { bestRank = rank; best.Clear(); }
          if (rank == bestRank) { bool dup = false; foreach (Node o in best) if (o.Type == n.Type && Math.Abs(o.X - n.X) < 3 && Math.Abs(o.Y - n.Y) < 3) dup = true; if (!dup) best.Add(n); }
        }
        if (best.Count == 0) throw new Exception("No control named '" + name + "'" + (string.IsNullOrEmpty(type) ? "" : " of type " + type) + " in this window: run ui_tree (query) to see what is there, or use screenshot.");
        if (best.Count > 1) {
          Cache = new List<AutomationElement>(); StringBuilder l = new StringBuilder();
          for (int i = 0; i < best.Count && i < 8; i++) { Cache.Add(best[i].El); l.Append("#" + (i + 1) + " " + best[i].Type + " \"" + Cap(Label(best[i]), 40) + "\" at " + best[i].X + "," + best[i].Y + "; "); }
          throw new Exception("Several controls match '" + name + "': " + l + "repeat with id (the numbers above) or a more exact name / type.");
        }
        el = best[0].El;
      }
      Node fresh = Make(el.GetUpdatedCache(Req())); if (fresh == null) throw new Exception("The control cannot be read any more: run ui_tree again");
      Picked = el;
      return new string[] { fresh.Type + " \"" + Cap(Label(fresh), 50) + "\"", (fresh.X + fresh.W / 2).ToString(), (fresh.Y + fresh.H / 2).ToString() };
    }
    static string Guarded(Job j, string ok) {   // Invoke on a button that opens a modal dialog does not return until the dialog closes
      Exception err = null; Thread t = new Thread(delegate() { try { j(); } catch (Exception e) { err = e; } }); t.IsBackground = true; t.Start();
      if (!t.Join(1500)) return ok + " (the app is still busy: a dialog probably opened)";
      if (err != null) throw err;
      return ok;
    }
    // null = the control has no action of its own: the caller clicks its centre
    public static string Act() {
      AutomationElement el = Picked; if (el == null) throw new Exception("nothing picked");
      if (!el.Current.IsEnabled) throw new Exception("the control is disabled");
      object p;
      try {
        if (el.TryGetCurrentPattern(InvokePattern.Pattern, out p)) { InvokePattern ip = (InvokePattern)p; return Guarded(delegate { ip.Invoke(); }, "pressed"); }
        if (el.TryGetCurrentPattern(SelectionItemPattern.Pattern, out p)) { ((SelectionItemPattern)p).Select(); return "selected"; }
        if (el.TryGetCurrentPattern(TogglePattern.Pattern, out p)) { TogglePattern tp = (TogglePattern)p; tp.Toggle(); return "toggled (now " + tp.Current.ToggleState.ToString().ToLowerInvariant() + ")"; }
        if (el.TryGetCurrentPattern(ExpandCollapsePattern.Pattern, out p)) { ExpandCollapsePattern xp = (ExpandCollapsePattern)p; if (xp.Current.ExpandCollapseState == ExpandCollapseState.Expanded) { xp.Collapse(); return "collapsed"; } xp.Expand(); return "expanded"; }
      } catch (Exception) { return null; }
      return null;
    }
    // null = no direct value access: the caller focuses it and types
    public static string Set(string value) {
      AutomationElement el = Picked; if (el == null) throw new Exception("nothing picked");
      bool pw = false; try { pw = el.Current.IsPassword; } catch { }
      object p;
      if (el.TryGetCurrentPattern(ValuePattern.Pattern, out p)) {
        ValuePattern vp = (ValuePattern)p;
        if (vp.Current.IsReadOnly) throw new Exception("the control is read-only");
        Guarded(delegate { vp.SetValue(value); }, "");
        if (pw) return "set (password, not shown)";
        string now = ""; try { now = vp.Current.Value; } catch { }
        return now == value ? "set" : "set, but it now holds \"" + Cap(now, 80) + "\" (the control may reformat the value, or ignore it: check with ui_tree)";
      }
      if (el.TryGetCurrentPattern(RangeValuePattern.Pattern, out p)) {
        double d; if (!double.TryParse(value, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out d)) throw new Exception("this control wants a number");
        RangeValuePattern rp = (RangeValuePattern)p; rp.SetValue(d); return "set to " + rp.Current.Value;
      }
      return null;
    }
    public static void Focus() { if (Picked != null) Picked.SetFocus(); }
    public static int[] WinRect(string window) { System.Windows.Rect r = PickWindow(window).Current.BoundingRectangle; return new int[] { (int)r.X, (int)r.Y, (int)r.Width, (int)r.Height }; }
  }
}
'@
    } catch { throw 'UI Automation is not available on this PC: use screenshot and click.' }
    $script:UiReady = $true
}
function Do-UiTree($a) {
    Ensure-Ui
    $t = [A__BUILD__.Ui]::Tree([string]$a.window, [string]$a.query, (Int-Or $a.max 120), [bool]$a.all, [double]$Scale, [int]$script:OriginX, [int]$script:OriginY)
    if ($a.ocr -or $t -match 'nothing readable here') { try { $t = ($t -replace ': use screenshot\.\s*$', '.') + "`n" + (Ocr-Tree ([string]$a.window) (Int-Or $a.max 120)) } catch { $t += "`n" + $_.Exception.Message } }
    @{ text = $t }
}
function Do-UiClick($a) {
    Ensure-Ui
    try { $p = [A__BUILD__.Ui]::Pick((Int-Or $a.id 0), [string]$a.name, [string]$a.type, [string]$a.window) }
    catch {
        if ($_.Exception.Message -notmatch 'No control named' -or -not $a.name -or $a.id) { throw }
        $o = $null; try { $o = Ocr-Find ([string]$a.name) ([string]$a.window) } catch { if ($_.Exception.Message -match 'Several texts') { throw }; $o = $null }
        if (-not $o) { throw }
        $r = Do-Click @{ x = $o.x; y = $o.y; raw = $true; button = $(if ($a.right) { 'right' } else { 'left' }); double = [bool]$a.double }
        return @{ text = "no control of that name, but the text '$($o.t)' is on the screen (OCR): clicked it; " + $r.text }
    }
    $cx = [int]$p[1]; $cy = [int]$p[2]
    $btn = if ($a.right) { 'right' } else { 'left' }
    if ($a.right -or $a.double) { return @{ text = "$($p[0]): " + (Do-Click @{ x = $cx; y = $cy; raw = $true; button = $btn; double = [bool]$a.double }).text } }
    Overlay-Send 'active'; Glide $cx $cy $null; Start-Sleep -Milliseconds 200
    $pb = Probe-Take (Around $cx $cy 640 400)
    Overlay-Send "click $cx $cy left"
    $how = [A__BUILD__.Ui]::Act()
    if ($null -eq $how) { return @{ text = "$($p[0]): no action of its own, clicked it; " + (Do-Click @{ x = $cx; y = $cy; raw = $true; button = 'left' }).text } }
    Start-Sleep -Milliseconds 700
    @{ text = "$($p[0]): $how; " + (Probe-Report $pb (Probe-Take (Around $cx $cy 640 400)) 'click' $false) }
}
function Do-UiSet($a) {
    Ensure-Ui
    $p = [A__BUILD__.Ui]::Pick((Int-Or $a.id 0), [string]$a.name, '', [string]$a.window); $cx = [int]$p[1]; $cy = [int]$p[2]
    Overlay-Send 'active'; Glide $cx $cy $null
    $r = [A__BUILD__.Ui]::Set([string]$a.value)
    if ($null -eq $r) {   # no value access: focus the control and type
        [A__BUILD__.Ui]::Focus(); Start-Sleep -Milliseconds 150
        [void](Do-PressKey @{ keys = 'ctrl+a' }); return @{ text = "$($p[0]): typed (it has no direct value access); " + (Do-TypeText @{ text = [string]$a.value }).text }
    }
    @{ text = "$($p[0]): $r" }
}
# ---- OCR: the text of a window that shows no controls (a game, a custom-drawn or administrator window), read from its picture with the OCR engine Windows ships
function Ensure-Ocr {
    if ($script:OcrEng) { return }
    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime, System.Drawing
        $null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
        $null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime]
        $null = [Windows.Graphics.Imaging.SoftwareBitmap, Windows.Foundation, ContentType = WindowsRuntime]
        $null = [Windows.Media.Ocr.OcrResult, Windows.Foundation, ContentType = WindowsRuntime]
        $script:AsTask = [System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' } | Select-Object -First 1
        $eng = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
    } catch { throw 'OCR is not available on this PC: use screenshot.' }
    if (-not $eng) { throw 'OCR is not available (no OCR language is installed for this Windows user): use screenshot.' }
    $script:OcrEng = $eng
}
function Await-Op($op, $type) { $t = $script:AsTask.MakeGenericMethod($type).Invoke($null, @($op)); [void]$t.Wait(20000); $t.Result }
function Ocr-Lines($window) {   # -> lines @{ t; x; y; w; h } in real screen pixels, for the window (default: the one in front)
    Ensure-Ocr
    $r = [A__BUILD__.Ui]::WinRect($window); $vs = [Windows.Forms.SystemInformation]::VirtualScreen
    $x = [Math]::Max($r[0], $vs.Left); $y = [Math]::Max($r[1], $vs.Top); $w = [Math]::Min($r[0] + $r[2], $vs.Right) - $x; $h = [Math]::Min($r[1] + $r[3], $vs.Bottom) - $y
    if ($w -lt 8 -or $h -lt 8) { return @() }
    $bmp = New-Object Drawing.Bitmap $w, $h; $g = [Drawing.Graphics]::FromImage($bmp); $g.CopyFromScreen($x, $y, 0, 0, $bmp.Size); $g.Dispose()
    $ms = New-Object IO.MemoryStream; $bmp.Save($ms, [Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose(); $ms.Position = 0
    $ras = [System.IO.WindowsRuntimeStreamExtensions]::AsRandomAccessStream($ms)
    $dec = Await-Op ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($ras)) ([Windows.Graphics.Imaging.BitmapDecoder])
    $sb = Await-Op ($dec.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
    $res = Await-Op ($script:OcrEng.RecognizeAsync($sb)) ([Windows.Media.Ocr.OcrResult])
    foreach ($ln in $res.Lines) {
        $x0 = 1e9; $y0 = 1e9; $x1 = 0; $y1 = 0
        foreach ($wd in $ln.Words) { $b = $wd.BoundingRect; $x0 = [Math]::Min($x0, $b.X); $y0 = [Math]::Min($y0, $b.Y); $x1 = [Math]::Max($x1, $b.X + $b.Width); $y1 = [Math]::Max($y1, $b.Y + $b.Height) }
        @{ t = [string]$ln.Text; x = [int]($x + $x0); y = [int]($y + $y0); w = [int]($x1 - $x0); h = [int]($y1 - $y0) }
    }
}
function Ocr-Tree($window, $max) {
    $o = @(Ocr-Lines $window); if ($o.Count -eq 0) { return "OCR found no text either: use screenshot." }
    $lines = foreach ($l in ($o | Select-Object -First $max)) { 'ocr "' + (Cut $l.t 70) + '" @' + [int](($l.x + $l.w / 2 - $script:OriginX) / $Scale) + ',' + [int](($l.y + $l.h / 2 - $script:OriginY) / $Scale) }
    "text read from the picture (OCR; click {x,y} or ui_click {name:`"text`"} presses it):`n" + ($lines -join "`n")
}
function Ocr-Find($name, $window) {   # -> the one line holding the text (centre in real pixels), $null when none; throws when it is ambiguous
    $o = @(Ocr-Lines $window); if ($o.Count -eq 0) { return $null }
    $ex = @($o | Where-Object { $_.t.Trim() -ieq $name }); $hit = @(if ($ex.Count -ge 1) { $ex } else { $o | Where-Object { $_.t -like "*$name*" } })
    if ($hit.Count -eq 0) { return $null }
    if ($hit.Count -gt 1) { throw ("Several texts on the screen match '$name': " + (($hit | Select-Object -First 6 | ForEach-Object { '"' + (Cut $_.t 40) + '" at ' + [int](($_.x + $_.w / 2 - $script:OriginX) / $Scale) + ',' + [int](($_.y + $_.h / 2 - $script:OriginY) / $Scale) }) -join '; ') + '. Use click {x,y} on the one you mean.') }
    @{ t = $hit[0].t; x = [int]($hit[0].x + $hit[0].w / 2); y = [int]($hit[0].y + $hit[0].h / 2) }
}
function Do-FocusWindow($a) {
    $wins = @(Get-Process | Where-Object { $_.MainWindowHandle -ne 0 -and $_.MainWindowTitle } | Select-Object Id, ProcessName, MainWindowTitle, MainWindowHandle)
    if (-not $a.title -and -not $a.process) { return @{ text = 'open windows: ' + (($wins | ForEach-Object { "$($_.ProcessName): $($_.MainWindowTitle)" }) -join ' | ') } }
    $w = $wins | Where-Object { ($a.process -and $_.ProcessName -like "*$($a.process)*") -or ($a.title -and $_.MainWindowTitle -like "*$($a.title)*") } | Select-Object -First 1
    if (-not $w) { throw "No such window. Open windows: $((($wins | ForEach-Object { "$($_.ProcessName): $($_.MainWindowTitle)" }) -join ' | '))" }
    $sh = New-Object -ComObject WScript.Shell; [void]$sh.AppActivate([int]$w.Id); Start-Sleep -Milliseconds 250
    $ok = [H.U__BUILD__]::GetForegroundWindow() -eq [IntPtr]$w.MainWindowHandle
    if ($ok) { $script:AiFg = [IntPtr]$w.MainWindowHandle; $script:AiAt = [DateTime]::UtcNow; if (-not $script:AiPos) { $script:AiPos = [Windows.Forms.Cursor]::Position } }
    @{ text = $(if ($ok) { "focused: $($w.ProcessName): $($w.MainWindowTitle)" } else { "asked Windows to bring '$($w.MainWindowTitle)' to the front, but another window still has the focus: click its title bar instead" }) }
}
function Do-Trace($a) {   # read along: the pointer goes to the start of the line, then slides under it at reading pace (no click)
    Overlay-Send 'active'; $t1 = Target $a; $t2 = Target $a 'x2' 'y2'
    Glide $t1[0] $t1[1] $null; Start-Sleep -Milliseconds 140
    $d = [Math]::Sqrt([Math]::Pow($t2[0] - $t1[0], 2) + [Math]::Pow($t2[1] - $t1[1], 2))
    Glide $t2[0] $t2[1] ([Math]::Min(4.0, [Math]::Max(0.5, $d / 520.0))) $true
    @{ text = 'ok' }
}
function Do-Move($a) { Overlay-Send 'active'; $t = Target $a; Glide $t[0] $t[1] $null; @{ text = 'ok' } }

function Do-Click($a) {
    $t = Target $a; $btn = if ($a.button) { $a.button } else { 'left' }; $down, $up = Btn $btn
    Overlay-Send 'active'; Glide $t[0] $t[1] $null; Start-Sleep -Milliseconds 320   # the comet tail behind the arrow has faded
    $cc0 = Get-CaretSafe; $pb = Probe-Take (Around $t[0] $t[1] 640 400)
    $n = if ($a.double) { 2 } else { 1 }
    1..$n | ForEach-Object {
        Overlay-Send "click $($t[0]) $($t[1]) $btn"
        [H.U__BUILD__]::mouse_event($down, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 80
        [H.U__BUILD__]::mouse_event($up, 0, 0, 0, [UIntPtr]::Zero); Start-Sleep -Milliseconds 100
    }
    Start-Sleep -Milliseconds 850   # the click ripple is gone and the app has answered
    $after = Probe-Take (Around $t[0] $t[1] 640 400); @{ text = Probe-Report $pb $after 'click' (Caret-Moved $cc0 (Get-CaretSafe)) }
}

# Press at (x,y), glide to (x2,y2) with the button held, release (moving windows, selecting, sliders ...).
function Do-Drag($a) {
    $t1 = Target $a; $t2 = Target $a 'x2' 'y2'; $btn = if ($a.button) { $a.button } else { 'left' }; $down, $up = Btn $btn
    Overlay-Send 'active'; Glide $t1[0] $t1[1] $null; Start-Sleep -Milliseconds 60
    $pb = Probe-Take (Around $t2[0] $t2[1] 640 400)
    [H.U__BUILD__]::mouse_event($down, 0, 0, 0, [UIntPtr]::Zero); Overlay-Send "down $($t1[0]) $($t1[1])"; Start-Sleep -Milliseconds 120
    $d = [Math]::Sqrt([Math]::Pow($t2[0] - $t1[0], 2) + [Math]::Pow($t2[1] - $t1[1], 2))
    Glide $t2[0] $t2[1] ([Math]::Min(1.4, 0.3 + $d * 0.0007)); Start-Sleep -Milliseconds 100
    [H.U__BUILD__]::mouse_event($up, 0, 0, 0, [UIntPtr]::Zero); Overlay-Send "up $($t2[0]) $($t2[1])"
    Start-Sleep -Milliseconds 950
    @{ text = Probe-Report $pb (Probe-Take (Around $t2[0] $t2[1] 640 400)) 'drag' }
}

function Do-Scroll($a) {
    Overlay-Send 'active'
    if ($null -ne $a.x -and $null -ne $a.y) { $t = Target $a; Glide $t[0] $t[1] $null }
    $p0 = [Windows.Forms.Cursor]::Position; $pb = Probe-Take (Around $p0.X $p0.Y 800 600)
    $n = if ($null -ne $a.amount) { [int]$a.amount } else { 3 }   # positive = down
    Overlay-Send "scroll $n"
    $one = [BitConverter]::ToUInt32([BitConverter]::GetBytes([int](-120 * [Math]::Sign($n))), 0)
    1..[Math]::Abs($n) | ForEach-Object { [H.U__BUILD__]::mouse_event(0x0800, 0, 0, $one, [UIntPtr]::Zero); Start-Sleep -Milliseconds 40 }
    Start-Sleep -Milliseconds 780   # the scroll chevrons are gone
    @{ text = Probe-Report $pb (Probe-Take (Around $p0.X $p0.Y 800 600)) 'scroll' }
}

function Pin-Caret { try { $c = [V__BUILD__.Caret]::Get(); if ($c) { Overlay-Send "pin $($c[0] + 2) $($c[1] + $c[2])" } } catch { } }   # the arrow sits right under the caret
function Do-TypeText($a) {
    $c0 = $null; try { $c0 = [V__BUILD__.Caret]::Get() } catch { }
    $tr = if ($c0) { @(($c0[0] - 300), ($c0[1] - 40), 1100, ($c0[2] + 80)) } else { [V__BUILD__.Probe]::FgRect() }   # the line being typed, or the window that has the focus
    $am = Arrow-Mask; $pb = Probe-Take $tr (@(Caret-Mask $c0) + $am)
    Overlay-Send 'typing'; Pin-Caret
    $t = $a.text -replace "`r`n", "`n"
    $step = [Math]::Max(1, [int][Math]::Ceiling($t.Length / 300.0))   # about 26 ms per step: the arrow can follow
    $n = 0
    for ($i = 0; $i -lt $t.Length; $i += $step) {
        Pin-Caret
        $chunk = $t.Substring($i, [Math]::Min($step, $t.Length - $i))
        [V__BUILD__.Kb]::Type($chunk)
        if ($t.Length -gt 1) { Start-Sleep -Milliseconds 18 }
    }
    Pin-Caret; Start-Sleep -Milliseconds 350
    $c1 = $null; try { $c1 = [V__BUILD__.Caret]::Get() } catch { }
    $after = Probe-Take $tr (@(Caret-Mask $c0) + @(Caret-Mask $c1) + $am)
    @{ text = Probe-Report $pb $after 'typing' (Caret-Moved $c0 $c1) }
}

$Vk = @{ ctrl = 0x11; control = 0x11; alt = 0x12; shift = 0x10; win = 0x5B; windows = 0x5B; enter = 0x0D; return = 0x0D
    esc = 0x1B; escape = 0x1B; tab = 0x09; space = 0x20; backspace = 0x08; delete = 0x2E; del = 0x2E; home = 0x24; end = 0x23
    pageup = 0x21; pagedown = 0x22; left = 0x25; up = 0x26; right = 0x27; down = 0x28 }
1..12 | ForEach-Object { $Vk["f$_"] = 0x6F + $_ }
function Do-Look($a) {   # the AI's colour (once per session, the relay keeps it) and a short note in the label
    $out = @()
    if ($a.color -and "$($a.color)" -match '^#?([0-9a-fA-F]{6})$') {
        $hx = $Matches[1]; $rgb = @([Convert]::ToInt32($hx.Substring(0, 2), 16), [Convert]::ToInt32($hx.Substring(2, 2), 16), [Convert]::ToInt32($hx.Substring(4, 2), 16))
        $mx = ($rgb | Measure-Object -Maximum).Maximum; if ($mx -lt 200) { $k = 200.0 / [Math]::Max(1, $mx); $rgb = @($rgb | ForEach-Object { [int][Math]::Min(255, $_ * $k) }) }   # always bright enough to be seen
        $script:OkRGB = $rgb; Overlay-Send "color $($rgb[0]) $($rgb[1]) $($rgb[2])"; $out += 'colour set'
    }
    if ($a.note) { $nt = (Cut ("$($a.note)" -replace '\s+', ' ') 90); $script:Note = $nt; Overlay-Send "note $nt"; Write-Host ('  ' + [char]0x270E + ' ' + $nt) -ForegroundColor Cyan; $out += 'note shown' }
    @{ text = $(if ($out) { $out -join ', ' } else { 'nothing to change' }) }
}
function Do-Hold($a) { $script:Phase = 'hold'; Overlay-Send 'state hold'; Write-Orange ('  || ' + (T 'Помощник на паузе и вернётся' 'The helper is on hold and will be back')); Show-Status; @{ text = 'ok' } }
function Do-TaskDone($a) {
    $script:Phase = 'done'; Overlay-Send 'state done'
    if ($script:Persist) { try { Remove-ItemProperty -Path $RunKey -Name 'HelperMCP' -ErrorAction SilentlyContinue } catch { }; Write-AgentLog 'task done: autostart removed (a reboot will not bring the console back)' }   # a finished job should not reappear after the PC restarts; a new command re-arms it (below)
    Write-Host ('  ' + [char]0x2714 + ' ' + (T 'Помощник закончил работу' 'The helper finished the work')) -ForegroundColor Green; Show-Status; @{ text = 'ok' }
}
function Do-SetMode($a) {   # admin panel only (never offered to the AI): switch confirm / auto / unattended on a live session
    $m = Norm-Mode $a.mode; if (-not $m) { throw "unknown mode '$($a.mode)'" }
    $script:Mode = $m; [K__BUILD__.Keys]::Unattended = ($m -eq 'unattended')
    if ($script:Persist) { Save-Session $script:Code $script:Token $m; if (-not $env:HELPER_NO_AUTOSTART) { Install-Autostart } }
    Write-AgentLog "mode changed to $m (by the administrator)"
    Write-Host ('  ' + (T 'Администратор сменил режим на ' 'The administrator switched the mode to ') + $m) -ForegroundColor Yellow
    Draw-Header $script:Code $false; Show-Status
    @{ text = $m }
}
function Do-PressKey($a) {
    $kc = $null; try { $kc = [V__BUILD__.Caret]::Get() } catch { }; $kr = [V__BUILD__.Probe]::FgRect(); $am = Arrow-Mask; $pb = Probe-Take $kr (@(Caret-Mask $kc) + $am)
    Overlay-Send 'typing'; Pin-Caret
    $codes = foreach ($k in $a.keys.ToLower().Split('+')) {
        if ($Vk.ContainsKey($k)) { [byte]$Vk[$k] }
        elseif ($k.Length -eq 1) { [byte][char]$k.ToUpper() }
        else { throw "Unknown key '$k'" }
    }
    $codes | ForEach-Object { [H.U__BUILD__]::keybd_event($_, 0, 0, [UIntPtr]::Zero) }
    [array]::Reverse($codes)
    $codes | ForEach-Object { [H.U__BUILD__]::keybd_event($_, 0, 2, [UIntPtr]::Zero) }
    Start-Sleep -Milliseconds 450
    $kc2 = $null; try { $kc2 = [V__BUILD__.Caret]::Get() } catch { }
    @{ text = Probe-Report $pb (Probe-Take $kr (@(Caret-Mask $kc) + @(Caret-Mask $kc2) + $am)) "key press ($($a.keys))" (Caret-Moved $kc $kc2) }
}

# A command mentions uv/uvx/npx/npm/node that is not installed? Fetch the portable one first (as if it had always been there).
function Ensure-For($text) {
    foreach ($m in [regex]::Matches([string]$text, '(?:^|[\s;&|(])(uvx|uv|npx|npm|node)(?=[\s;&|)]|$)')) {
        $w = $m.Groups[1].Value
        try { Ensure-Node $w; Ensure-Uv $w } catch { Write-Host "[helper] could not prepare ${w}: $($_.Exception.Message)" }
    }
}

function Do-Run($a) {
    Ensure-For $a.command
    $secs = if ($a.timeout_s) { [int]$a.timeout_s } else { 60 }
    $psi = New-Object Diagnostics.ProcessStartInfo
    $hasArgs = if ($a -is [hashtable]) { $a.ContainsKey('args') } else { [bool]$a.PSObject.Properties['args'] }
    if ($hasArgs -and $null -ne $a.args) {   # no shell: every argument arrives exactly as given (quotes, $, &, %, JSON)
        $exe = Resolve-Exe ([string]$a.command); if (-not $exe) { throw "'$($a.command)' is not recognized as an internal or external command (not found on PATH)" }
        $argl = (@($a.args) | ForEach-Object { [F__BUILD__.Fs]::Quote([string]$_) }) -join ' '
        if ($exe -match '\.(cmd|bat)$') { $psi.FileName = 'cmd.exe'; $psi.Arguments = '/d /s /c "' + [F__BUILD__.Fs]::Quote($exe) + ' ' + $argl + '"' }   # ponytail: cmd still reads % and ^ in batch arguments
        else { $psi.FileName = $exe; $psi.Arguments = $argl }
    } else {
        switch ([string]$a.shell) {
            'cmd' { $f = Join-Path $env:TEMP ("helpermcp-$PID-" + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.cmd'); [IO.File]::WriteAllText($f, "@chcp 65001>nul`r`n" + ($a.command -replace "`r?`n", "`r`n"), (New-Object Text.UTF8Encoding $false)); $script:TmpDirs += $f
                $psi.FileName = 'cmd.exe'; $psi.Arguments = '/d /c "' + $f + '"' }
            'python' { $py = Resolve-Exe 'python'; if (-not $py) { $py = Resolve-Exe 'py' }; if (-not $py) { throw "'python' is not recognized: Python is not installed" }
                $f = Join-Path $env:TEMP ("helpermcp-$PID-" + [guid]::NewGuid().ToString('N').Substring(0, 6) + '.py'); [IO.File]::WriteAllText($f, $a.command, (New-Object Text.UTF8Encoding $false)); $script:TmpDirs += $f
                $psi.FileName = $py; $psi.Arguments = [F__BUILD__.Fs]::Quote($f) }
            { $_ -in 'bash', 'sh' } { $b = Resolve-Exe 'bash'; if (-not $b) { throw "'bash' is not recognized: no Git Bash / WSL on this PC" }; $psi.FileName = $b; $psi.Arguments = '-c ' + [F__BUILD__.Fs]::Quote([string]$a.command) }
            default {
                $cmd = '[Console]::OutputEncoding=[Text.Encoding]::UTF8; $ProgressPreference="SilentlyContinue"; ' + $a.command
                $psi.FileName = if ($a.shell -eq 'pwsh') { $w = Resolve-Exe 'pwsh'; if (-not $w) { throw "'pwsh' is not recognized: PowerShell 7 is not installed" }; $w } else { 'powershell.exe' }
                $psi.Arguments = '-NoProfile -NonInteractive -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
            }
        }
    }
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    if ($script:ExtraPath.Count) { $psi.EnvironmentVariables['PATH'] = ($script:ExtraPath -join ';') + ';' + $env:PATH }
    $psi.EnvironmentVariables['PYTHONUTF8'] = '1'; $psi.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'   # Python tools crash on non-ASCII output otherwise
    if ($a.cwd) { $psi.WorkingDirectory = $a.cwd }
    $p = [Diagnostics.Process]::Start($psi)
    if ($a.stdin) { $p.StandardInput.Write([string]$a.stdin) }
    $p.StandardInput.Close()
    $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
    $deadline = [DateTime]::UtcNow.AddSeconds($secs)
    while (-not $p.WaitForExit(400)) {
        if ([DateTime]::UtcNow -gt $deadline) { Stop-Tree $p; return @{ text = "[timeout after ${secs}s]" } }
        Pump-Light
    }
    [void]$p.WaitForExit()
    @{ text = Clip ("[exit $($p.ExitCode)]`n" + $o.Result + (Plain-Err $e.Result)) }
}
function Plain-Err($t) {   # powershell.exe sends errors as CLIXML when its output is redirected: turn that back into plain lines (and fewer tokens)
    if ($t -notmatch '^#< CLIXML') { return $t }
    $x = (@([regex]::Matches($t, '<S S="Error">(.*?)</S>') | ForEach-Object { $_.Groups[1].Value }) -join '')
    $x = [regex]::Replace($x, '_x([0-9A-Fa-f]{4})_', { param($m) [string][char][Convert]::ToInt32($m.Groups[1].Value, 16) })
    [Net.WebUtility]::HtmlDecode($x).Replace("`r`n", "`n")
}

function Do-ReadFile($a) {
    if ($a.path -match '\.(png|jpe?g|gif|bmp|webp|tiff?)$') {   # an image: return it as an image, scaled down to max_width (default 1600)
        $cap = if ($a.max_width) { [int]$a.max_width } else { 1600 }
        $img = [Drawing.Image]::FromFile((Resolve-Path -LiteralPath $a.path).Path)
        try {
            $w = [Math]::Min($cap, $img.Width); $h = [int]($img.Height * $w / $img.Width)
            $out = New-Object Drawing.Bitmap $w, $h
            $g = [Drawing.Graphics]::FromImage($out); $g.InterpolationMode = 'HighQualityBicubic'; $g.DrawImage($img, 0, 0, $w, $h); $g.Dispose()
            $enc = [Drawing.Imaging.ImageCodecInfo]::GetImageEncoders() | Where-Object MimeType -eq 'image/jpeg'
            $ep = New-Object Drawing.Imaging.EncoderParameters 1
            $ep.Param[0] = New-Object Drawing.Imaging.EncoderParameter ([Drawing.Imaging.Encoder]::Quality), $(if ($a.quality) { [long]$a.quality } else { 80L })
            $ms = New-Object IO.MemoryStream; $out.Save($ms, $enc, $ep); $out.Dispose()
            return @{ jpeg = $ms.ToArray(); mime = 'image/jpeg'; text = "$($img.Width)x$($img.Height) image" }
        } finally { $img.Dispose() }
    }
    if ($a.offset -or $a.lines -or $a.tail) { return @{ text = [F__BUILD__.Fs]::ReadRange((Full $a.path), (Int-Or $a.offset 1), (Int-Or $a.lines 200), (Int-Or $a.tail 0)) } }
    $max = if ($a.max_bytes) { [int]$a.max_bytes } else { 200000 }
    $fs = [IO.File]::Open($a.path, 'Open', 'Read', 'ReadWrite')
    try { $buf = New-Object byte[] ([Math]::Min($max, $fs.Length)); [void]$fs.Read($buf, 0, $buf.Length) } finally { $fs.Dispose() }
    @{ text = [Text.Encoding]::UTF8.GetString($buf) }
}
# Upload a file to the relay and return a download link for the operator.
function Do-FetchFile($a) {
    $f = (Resolve-Path -LiteralPath $a.path).Path
    if (Test-Path -LiteralPath $f -PathType Container) {   # a folder travels as one zip
        $d = Join-Path $env:TEMP ('helpermcp-zip-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); [void](New-Item -ItemType Directory $d); $script:TmpDirs += $d
        $z = Join-Path $d ((Split-Path $f.TrimEnd('\') -Leaf).TrimEnd(':') + '.zip'); Zip-Dir $f $z; $f = $z
    }
    $pp = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
    try {
        $resp = Invoke-WebRequest -Uri ("$RELAY/a/file?name=" + [Uri]::EscapeDataString((Split-Path $f -Leaf))) -Method Post -InFile $f `
            -Headers @{ Authorization = "Bearer $script:Token" } -ContentType 'application/octet-stream' -TimeoutSec 3600 -UseBasicParsing
    } finally { $ProgressPreference = $pp }
    $d = $resp.Content | ConvertFrom-Json
    @{ text = "$($d.url)  ($($d.size) bytes, link valid 24 h)" }
}
function Do-WriteFile($a) {
    $b = if ($a.base64) { [Convert]::FromBase64String([string]$a.content) } else { (New-Object Text.UTF8Encoding $false).GetBytes([string]$a.content) }
    $fs = [IO.File]::Open((Full $a.path), $(if ($a.append) { 'Append' } else { 'Create' }), 'Write')
    try { $fs.Write($b, 0, $b.Length) } finally { $fs.Dispose() }
    @{ text = 'written' }
}
# ---- files: tree, find, exact edits, transfer both ways (the loops are in F__BUILD__.Fs)
function Full($p) { if (-not $p) { $p = '.' }; [Environment]::ExpandEnvironmentVariables($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath([string]$p)) }
function Int-Or($v, $d) { if ($null -ne $v -and "$v" -ne '') { [int]$v } else { $d } }
function Do-Tree($a) { @{ text = [F__BUILD__.Fs]::Tree((Full $a.path), [Math]::Min((Int-Or $a.depth 2), 6), [string]$a.pattern, (Int-Or $a.max 300)) } }
function Do-Find($a) { @{ text = [F__BUILD__.Fs]::Find((Full $a.path), [string]$a.name, [string]$a.text, (Int-Or $a.max 100), (Int-Or $a.depth 20)) } }
function Do-EditFile($a) { @{ text = [F__BUILD__.Fs]::Edit((Full $a.path), [string]$a.old, [string]$a.new, [bool]$a.all) } }
function Do-PushFile($a) {   # operator -> this PC: a relay link from the viewer upload, or any http link
    $dest = Full $a.path; $dir = Split-Path $dest -Parent; if ($dir -and -not (Test-Path -LiteralPath $dir)) { [void](New-Item -ItemType Directory -Force $dir) }
    $rq = [Net.WebRequest]::Create([string]$a.url); $rq.Timeout = 60000; $rq.ReadWriteTimeout = 120000
    $resp = $rq.GetResponse(); $n = 0
    try {
        $in = $resp.GetResponseStream(); $out = [IO.File]::Create($dest + '.part')
        try { $buf = New-Object byte[] 1048576; while (($k = $in.Read($buf, 0, $buf.Length)) -gt 0) { $out.Write($buf, 0, $k); $n += $k; Pump-Light } } finally { $out.Dispose(); $in.Dispose() }
    } finally { $resp.Close() }
    Move-Item -LiteralPath ($dest + '.part') -Destination $dest -Force
    @{ text = "saved $dest ($([F__BUILD__.Fs]::Human($n)))" }
}
function Zip-Dir($src, $dest) {
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    if (Test-Path -LiteralPath $dest) { Remove-Item -LiteralPath $dest -Force }
    [IO.Compression.ZipFile]::CreateFromDirectory($src, $dest, [IO.Compression.CompressionLevel]::Optimal, $true)
}

# ---- the live picture for the viewer (F__BUILD__.Live runs on its own thread; the relay turns it on while someone watches)
function Do-Stream($a) {
    [F__BUILD__.Live]::Relay = $RELAY; [F__BUILD__.Live]::Token = $script:Token
    if ($a.on -eq $false) { [F__BUILD__.Live]::Stop(); return @{ text = 'stopped' } }
    [F__BUILD__.Live]::Start($(if ($null -ne $a.mon) { [int]$a.mon } else { -1 }))
    if ($a.key) { [F__BUILD__.Live]::Key() }
    @{ text = 'streaming' + $(if ([F__BUILD__.Live]::Err) { ' (last error: ' + [F__BUILD__.Live]::Err + ')' } else { '' }) }
}

# ---- the state of the machine in one call
function Do-System($a) {
    $secs = if ($a.sections) { @($a.sections) } else { 'overview', 'disks', 'processes', 'network' }
    $top = Int-Or $a.top 15; $o = New-Object Text.StringBuilder
    $cul = [Threading.Thread]::CurrentThread.CurrentCulture; [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture   # 12.6, not 12,6
    try {
    function Sec($t) { [void]$o.Append("== $t`n") }
    function Line($t) { [void]$o.Append("$t`n") }
    foreach ($s in $secs) {
        try {
            switch ($s) {
                'overview' {
                    Sec 'overview'; $st = Static-Sys; $up = Uptime-TS
                    Line "$($st.os), $env:COMPUTERNAME\$env:USERNAME, admin=$(([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrator'))"
                    Line ("up {0}d {1}h {2}m; cpu {3} ({4} cores) busy {5}%; {6}" -f $up.Days, $up.Hours, $up.Minutes, $st.cpu, $st.cores, [F__BUILD__.Sys]::CpuLoad(150), [F__BUILD__.Sys]::Mem())
                }
                'disks' {
                    Sec 'disks: every drive'
                    $dk = Disks-All
                    foreach ($d in $dk.drives) { if ($d.ready) { Line ("{0} {1} [{2}] {3} {4} free of {5} ({6:0}% free)" -f $d.name, $d.label, $d.type, $d.fs, [F__BUILD__.Fs]::Human($d.free), [F__BUILD__.Fs]::Human($d.total), $(if ($d.total) { 100.0 * $d.free / $d.total } else { 0 })) } else { Line ("{0} [{1}] not ready" -f $d.name, $d.type) } }
                    foreach ($pd in $dk.physical) { Line ("physical: {0} {1} {2} {3} health={4} {5}" -f $pd.name, $pd.media, $pd.bus, [F__BUILD__.Fs]::Human($pd.size), $pd.health, $pd.status) }
                }
                'processes' {
                    Sec "processes: real CPU % (sampled), memory, who signed it, where it runs from"
                    Line ([F__BUILD__.Sys]::Procs($top, 200, $false))
                }
                'network' {
                    Sec 'network: every adapter (system {sections:["reach"]} also tests each against the relay)'
                    Line ([F__BUILD__.Route]::Report($false))
                    $px = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue
                    if ($px.ProxyEnable) { Line "proxy: $($px.ProxyServer)" }
                    if ($px.AutoConfigURL) { Line "proxy auto-config: $($px.AutoConfigURL)" }
                }
                'reach' {
                    Sec 'reach: which adapter gets through to the relay, what may be in the way'
                    Line ([F__BUILD__.Route]::Report($true))
                    $tools = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match $NetToolsRx } | Sort-Object ProcessName | ForEach-Object { "$($_.ProcessName)($($_.Id))" })
                    Line ("VPN / DPI-bypass / proxy / sniffer programs running: " + $(if ($tools.Count) { $tools -join ', ' } else { 'none' }))
                    $svc = @(Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services' -Name -ErrorAction SilentlyContinue | Where-Object { $_ -match '^(WinDivert|npcap|npf|wintun|tap0901|NordLynx|WireGuard|Tailscale|ZeroTier|hamachi|Netfilter|nfsdk|SingBox|WARP|TunnelBear|Cisco|Fortinet|Amnezia)' })
                    Line ("network filter drivers / services installed: " + $(if ($svc.Count) { $svc -join ', ' } else { 'none' }))
                    if ($px = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction SilentlyContinue) { Line ("WinINET proxy: " + $(if ($px.ProxyEnable) { $px.ProxyServer } else { 'off' }) + $(if ($px.AutoConfigURL) { "; PAC $($px.AutoConfigURL)" } else { '' })) }
                    Line ("WinHTTP proxy: " + ((netsh winhttp show proxy 2>$null) -join ' ' -replace '\s+', ' ').Trim())
                    $hf = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'
                    $he = @(Get-Content $hf -ErrorAction SilentlyContinue | Where-Object { $_ -match '^\s*[0-9a-fA-F:.]+\s+\S+' -and $_ -notmatch '^\s*#' -and $_ -notmatch '\slocalhost\s*$' })
                    Line ("hosts file: " + $(if ($he.Count) { "$($he.Count) custom entries: " + ((($he | Select-Object -First 6) | ForEach-Object { $_.Trim() }) -join ' | ') } else { 'no custom entries' }))
                }
                'connections' {
                    Sec 'TCP connections by process (a process talking to many hosts, or to odd ports, is worth a look)'
                    $names = @{}; foreach ($p in [Diagnostics.Process]::GetProcesses()) { $names[$p.Id] = $p.ProcessName }
                    $by = @{}
                    foreach ($l in (netstat -ano -p tcp 2>$null)) {
                        if ($l -match '^\s*TCP\s+(\S+)\s+(\S+)\s+(\S+)\s+(\d+)') {
                            $id = [int]$Matches[4]; if (-not $by.ContainsKey($id)) { $by[$id] = @{ est = 0; lis = 0; rem = New-Object Collections.Generic.List[string] } }
                            if ($Matches[3] -eq 'ESTABLISHED') { $by[$id].est++; $r = $Matches[2]; if ($r -notmatch '^(127\.|\[::1\]|0\.0\.0\.0)' -and $by[$id].rem.Count -lt 4 -and -not $by[$id].rem.Contains($r)) { $by[$id].rem.Add($r) } }
                            elseif ($Matches[3] -eq 'LISTENING') { $by[$id].lis++ }
                        }
                    }
                    foreach ($e in ($by.GetEnumerator() | Sort-Object { $_.Value.est } -Descending | Select-Object -First $top)) { Line ("{0}({1}): {2} established, {3} listening  {4}" -f $names[$e.Key], $e.Key, $e.Value.est, $e.Value.lis, ($e.Value.rem -join ', ')) }
                }
                'drivers' {
                    Sec 'third-party / unsigned kernel drivers (running); Microsoft ones are hidden'
                    $rows = @(driverquery /v /fo csv 2>$null | ConvertFrom-Csv | Where-Object { $_.'Start Mode' -ne 'Disabled' -and $_.State -eq 'Running' -and $_.'Display Name' -notmatch '^(Microsoft|Windows)' })
                    foreach ($d in ($rows | Select-Object -First 50)) { Line ("{0,-28} {1}" -f $d.'Module Name', $d.'Display Name') }
                    Line "$($rows.Count) third-party running"
                }
                'services' {
                    $sv = @(Svc-List); $run = @($sv | Where-Object state -eq 'Running'); $off = @($sv | Where-Object start -eq 'Disabled')
                    Sec ("services: $($sv.Count) total, $($run.Count) running, $(@($sv | Where-Object state -ne 'Running').Count) stopped, $($off.Count) disabled (non-Microsoft running ones below; ! = unusual file)")
                    foreach ($x in ($run | Where-Object { -not $_.ms } | Sort-Object name | Select-Object -First 60)) { $w = Trust-Of $x.exe; Line ("{0}{1} ({2}) [{3}, {4}] {5}" -f $(if ($w) { '! ' } else { '' }), $x.name, $x.disp, $x.start, $x.acct, $x.exe) }
                    $as = @($sv | Where-Object { $_.start -eq 'Auto' -and $_.state -ne 'Running' }); if ($as.Count) { Line ("auto-start but stopped: " + (($as | Select-Object -First 25 | ForEach-Object { $_.name }) -join ', ')) }
                    if ($off.Count) { Line ("disabled: " + (($off | Select-Object -First 40 | ForEach-Object { $_.name }) -join ', ')) }
                }
                'startup' {
                    $su = @(Startup-List); Sec ("startup: $($su.Count) entries (! = file missing, unusual place or a Windows-logon trick; off = disabled in Task Manager)")
                    foreach ($x in $su) { Line ("{0}{1,-8} {2}  {3}  [{4}]{5}{6}" -f $(if ($x.flag) { '! ' } else { '  ' }), $x.kind, $x.name, (Cut $x.cmd 110), $x.where, $(if (-not $x.on) { ' off' } else { '' }), $(if ($x.flag) { '  <- ' + $x.flag } else { '' })) }
                }
                'perf' {
                    Sec 'performance'
                    $pf = [F__BUILD__.Sys]::Perf() | ConvertFrom-Json
                    Line ("cpu {0}% over {1} cores: {2}" -f $pf.cpu, $pf.cpus, (($pf.cores | ForEach-Object { "$_%" }) -join ' '))
                    Line ("ram {0} used of {1} ({2}%), cache {3}, commit {4} of {5}, kernel paged {6} / non-paged {7}" -f [F__BUILD__.Fs]::Human($pf.ram.total - $pf.ram.avail), [F__BUILD__.Fs]::Human($pf.ram.total), $pf.ram.load, [F__BUILD__.Fs]::Human($pf.cache), [F__BUILD__.Fs]::Human($pf.commit.used), [F__BUILD__.Fs]::Human($pf.commit.limit), [F__BUILD__.Fs]::Human($pf.kpaged), [F__BUILD__.Fs]::Human($pf.knon))
                    Line ("{0} processes, {1} threads, {2} handles, up {3}d {4}h {5}m" -f $pf.procs, $pf.threads, $pf.handles, [int][Math]::Floor($pf.up / 86400), [int][Math]::Floor(($pf.up % 86400) / 3600), [int][Math]::Floor(($pf.up % 3600) / 60))
                    if ($pf.disk) { Line ("disk: read {0}/s, write {1}/s, busy {2}%, queue {3}" -f [F__BUILD__.Fs]::Human($pf.disk.rd), [F__BUILD__.Fs]::Human($pf.disk.wr), $pf.disk.busy, $pf.disk.q) }
                    foreach ($n in $pf.net) { Line ("net {0}: down {1}/s, up {2}/s, link {3} Mbit/s" -f $n[0], [F__BUILD__.Fs]::Human($n[1]), [F__BUILD__.Fs]::Human($n[2]), [int]($n[3] / 1000000)) }
                }
                'policy' {
                    $pl = @(Policy-List); Sec ("policies: $($pl.Count) custom values set (registry Policies keys); the ones with a note change how Windows behaves")
                    foreach ($x in ($pl | Sort-Object { -not $_.note }, root, key, name | Select-Object -First 120)) { Line ("{0}{1}\{2}\{3} = {4}{5}" -f $(if ($x.note) { '! ' } else { '  ' }), $x.root, $x.key, $x.name, (Cut $x.value 60), $(if ($x.note) { '   <- ' + $x.note } else { '' })) }
                    if (-not $pl.Count) { Line 'none: no group policy / registry policy has been set on this PC' }
                    $gp = Join-Path $env:SystemRoot 'System32\GroupPolicy\Machine\Registry.pol'; if (Test-Path $gp) { Line ("local group policy file: $gp changed " + (Get-Item $gp).LastWriteTime.ToString('yyyy-MM-dd HH:mm')) }
                    $ac = Activation-Info; Line ("activation: $($ac.status); $($ac.name); channel $($ac.channel)$(if ($ac.kms) { '; KMS ' + $ac.kms })")
                }
                'activation' {
                    Sec 'windows activation'; $ac = Activation-Info
                    Line ("{0}; {1}; channel {2}; key {3}{4}{5}" -f $ac.status, $ac.name, $ac.channel, $ac.key, $(if ($ac.kms) { '; KMS ' + $ac.kms } else { '' }), $(if ($ac.grace) { "; grace left $($ac.grace) min" } else { '' }))
                }
                'health' {
                    Sec 'health check: bad = fix first, warn = look, ok = fine'
                    foreach ($x in @(Health-Check | Sort-Object @{ e = { @{ bad = 0; warn = 1; ok = 2 }[$_.sev] } })) { Line ("[{0}] {1}: {2}{3}" -f $x.sev.ToUpper(), $x.area, $x.msg, $(if ($x.fix) { "  -> $($x.fix)" } else { '' })) }
                }
                'process' {
                    if (-not $a.pid) { Line 'process: give pid'; break }
                    Sec "process $($a.pid) in detail"
                    $pd = Process-Detail ([int]$a.pid)
                    foreach ($pr in $pd.GetEnumerator()) { $v = $pr.Value; if ($v -is [array]) { $v = ($v -join ' | ') }; Line ("{0}: {1}" -f $pr.Key, (Cut ([string]$v) 400)) }
                }
                'apps' {
                    $L = @(Installed-Apps '')
                    Sec "installed programs ($($L.Count)); util {op:apps, name} searches"
                    Line (($L | Select-Object -First 200 | ForEach-Object { $_.Split('|')[0] }) -join '; ')
                }
                'events' {
                    Sec "system errors, last 24 h (newest first, $top)"
                    Get-WinEvent -FilterHashtable @{ LogName = 'System', 'Application'; Level = 1, 2; StartTime = (Get-Date).AddDays(-1) } -MaxEvents $top -ErrorAction SilentlyContinue |
                        ForEach-Object { Line ("{0:MM-dd HH:mm} {1} {2}: {3}" -f $_.TimeCreated, $_.ProviderName, $_.Id, (Cut ([string]$_.Message) 160)) }
                }
                default { Line "== ${s}: unknown section" }
            }
        } catch { Line "($s failed: $($_.Exception.Message))" }
    }
    } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $cul }
    @{ text = $o.ToString().TrimEnd() }
}


# ---- system analysis: services, startup, performance, disks, policies, activation, one health check, one process in detail.
# The same collectors feed the AI (`system` sections, compact text) and the live viewer (`sysdata`, JSON).
function Exe-Of($cmd) {   # the executable path out of a command line
    $c = ([string]$cmd).Trim(); if (-not $c) { return '' }
    if ($c.StartsWith('"')) { $i = $c.IndexOf('"', 1); if ($i -gt 0) { return [Environment]::ExpandEnvironmentVariables($c.Substring(1, $i - 1)) } }
    $m = [regex]::Match($c, '^(.+?\.(exe|dll|bat|cmd|ps1|vbs|js|msc|com|scr|sys))(\s|$)', 'IgnoreCase'); if ($m.Success) { return [Environment]::ExpandEnvironmentVariables($m.Groups[1].Value) }
    [Environment]::ExpandEnvironmentVariables(($c -split '\s+')[0])
}
$ShadyRx = '(?i)\\(temp|tmp)\\|\\downloads\\|\\\$recycle|\\appdata\\local\\temp|\\users\\public\\|\\programdata\\[^\\]+\.(exe|dll)$'
$NormalRx = '(?i)^[a-z]:\\(windows|program files|program files \(x86\)|programdata\\microsoft)\\|\\steamapps\\|\\epic games\\|\\riot games\\|\\windowsapps\\'
function Trust-Of($exe) {   # '', or why this file deserves a look
    if (-not $exe) { return '' }
    if (-not (Test-Path -LiteralPath $exe -ErrorAction SilentlyContinue)) { return 'file missing' }
    if ($exe -match $ShadyRx) { return 'runs from a temp / download / public folder' }
    if ($exe -notmatch $NormalRx) { $co = ''; try { $co = [Diagnostics.FileVersionInfo]::GetVersionInfo($exe).CompanyName } catch { }; if (-not $co) { return 'no publisher, outside the normal install folders' } }
    ''
}
function Svc-List {
    Get-CimInstance Win32_Service -ErrorAction Stop | ForEach-Object {
        $exe = Exe-Of $_.PathName
        [pscustomobject]@{ name = $_.Name; disp = $_.DisplayName; state = [string]$_.State; start = [string]$_.StartMode; pid = [int]$_.ProcessId; acct = [string]$_.StartName; exe = $exe; ms = ($exe -match '(?i)^[a-z]:\\windows\\' -or $exe -match '(?i)\\microsoft\\|\\windows defender\\|\\windowsapps\\') }
    }
}
function Startup-Disabled($hive, $kind, $name) {   # Task Manager's Startup tab keeps its on/off switch here
    try { $b = (Get-ItemProperty "${hive}:\SOFTWARE\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\$kind" -ErrorAction Stop).$name; if ($b -and ($b[0] -band 1)) { return $true } } catch { }
    $false
}
function Startup-List($withTasks = $true) {   # everything that starts by itself: Run keys, startup folders, logon / boot tasks, auto services, Winlogon / IFEO / AppInit tricks
    $rows = New-Object Collections.Generic.List[object]
    function Add-Row($kind, $name, $cmd, $where, $on, $note) { $exe = Exe-Of $cmd; $why = if ($note) { $note } else { Trust-Of $exe }; $rows.Add([pscustomobject]@{ kind = $kind; name = [string]$name; cmd = [string]$cmd; where = $where; on = [bool]$on; exe = $exe; flag = [string]$why }) }
    foreach ($k in @(@('HKLM', 'SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'Run'), @('HKLM', 'SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Run', 'Run32'), @('HKCU', 'SOFTWARE\Microsoft\Windows\CurrentVersion\Run', 'Run'), @('HKLM', 'SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce', ''), @('HKCU', 'SOFTWARE\Microsoft\Windows\CurrentVersion\RunOnce', ''))) {
        $p = Get-ItemProperty "$($k[0]):\$($k[1])" -ErrorAction SilentlyContinue
        if ($p) { foreach ($v in $p.PSObject.Properties) { if ($v.Name -notmatch '^PS(Path|ParentPath|ChildName|Drive|Provider)$') { Add-Row 'run' $v.Name $v.Value "$($k[0]) $($k[1] -replace '^SOFTWARE\\(WOW6432Node\\)?Microsoft\\Windows\\CurrentVersion\\','')" (-not ($k[2] -and (Startup-Disabled $k[0] $k[2] $v.Name))) '' } } }
    }
    foreach ($d in @(@([Environment]::GetFolderPath('Startup'), 'user startup folder'), @([Environment]::GetFolderPath('CommonStartup'), 'all-users startup folder'))) {
        Get-ChildItem -LiteralPath $d[0] -File -ErrorAction SilentlyContinue | Where-Object { $_.Name -ne 'desktop.ini' } | ForEach-Object { $t = $_.FullName; if ($_.Extension -eq '.lnk') { try { $t = (New-Object -ComObject WScript.Shell).CreateShortcut($_.FullName).TargetPath } catch { } }; Add-Row 'folder' $_.BaseName $t $d[1] $true '' }
    }
    $wl = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Winlogon' -ErrorAction SilentlyContinue
    if ($wl) {
        if ($wl.Shell -and $wl.Shell.Trim() -ne 'explorer.exe') { Add-Row 'winlogon' 'Shell' $wl.Shell 'Winlogon' $true 'the Windows shell was replaced (normally explorer.exe)' }
        if ($wl.Userinit -and $wl.Userinit.Trim().TrimEnd(',') -notmatch '(?i)^[a-z]:\\windows\\system32\\userinit\.exe$') { Add-Row 'winlogon' 'Userinit' $wl.Userinit 'Winlogon' $true 'Userinit was changed (normally only userinit.exe)' }
    }
    $ai = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Windows' -ErrorAction SilentlyContinue
    if ($ai -and $ai.AppInit_DLLs) { Add-Row 'winlogon' 'AppInit_DLLs' $ai.AppInit_DLLs 'Windows' $true 'a DLL is injected into every program' }
    foreach ($ifeo in @(Get-ChildItem 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion\Image File Execution Options' -ErrorAction SilentlyContinue)) { $dbg = (Get-ItemProperty $ifeo.PSPath -ErrorAction SilentlyContinue).Debugger; if ($dbg) { Add-Row 'winlogon' $ifeo.PSChildName $dbg 'Image File Execution Options' $true 'a debugger is attached: launching this program starts something else' } }
    if ($withTasks) {
        $td = Join-Path $env:SystemRoot 'System32\Tasks'
        foreach ($f in @(Get-ChildItem -LiteralPath $td -Recurse -File -ErrorAction SilentlyContinue | Where-Object { $_.FullName -notmatch '\\Microsoft\\Windows\\' })) {
            try {
                $x = [xml](Get-Content -LiteralPath $f.FullName -Raw -ErrorAction Stop); $t = $x.Task; $trg = @($t.Triggers.ChildNodes | ForEach-Object { $_.Name })
                if (-not ($trg -contains 'LogonTrigger' -or $trg -contains 'BootTrigger')) { continue }
                $cmd = (@($t.Actions.Exec | ForEach-Object { ($_.Command + ' ' + $_.Arguments).Trim() }) -join ' ; ')
                Add-Row 'task' ($f.FullName.Substring($td.Length + 1)) $cmd ('task at ' + ($(if ($trg -contains 'BootTrigger') { 'boot' } else { 'logon' }))) ($t.Settings.Enabled -ne 'false') ''
            } catch { }
        }
    }
    foreach ($s in @(Svc-List | Where-Object { $_.start -eq 'Auto' -and -not $_.ms })) { Add-Row 'service' $s.name $s.exe ("service (" + $s.state + ", " + $s.acct + ")") $true '' }
    $rows
}
function Disks-All {   # every drive (fixed, removable, network, optical) and the physical disks behind them
    $d = @([IO.DriveInfo]::GetDrives() | ForEach-Object { $r = [ordered]@{ name = $_.Name.TrimEnd('\'); type = [string]$_.DriveType; ready = $_.IsReady; label = ''; fs = ''; total = 0; free = 0 }; if ($_.IsReady) { try { $r.label = $_.VolumeLabel; $r.fs = $_.DriveFormat; $r.total = $_.TotalSize; $r.free = $_.AvailableFreeSpace } catch { } }; [pscustomobject]$r })
    $p = @(); try { $p = @(Get-PhysicalDisk -ErrorAction Stop | ForEach-Object { [pscustomobject]@{ name = $_.FriendlyName; media = [string]$_.MediaType; bus = [string]$_.BusType; size = [int64]$_.Size; health = [string]$_.HealthStatus; status = [string]$_.OperationalStatus } }) } catch { }
    @{ drives = $d; physical = $p }
}
$PolicyNotes = @(   # registry key (under a Policies root) / value -> what it does
    @('Microsoft\Windows\WindowsUpdate\AU', 'NoAutoUpdate', 'automatic Windows updates are switched off by policy'),
    @('Microsoft\Windows\WindowsUpdate\AU', 'AUOptions', 'automatic update behaviour is forced by policy'),
    @('Microsoft\Windows\WindowsUpdate', 'DisableWindowsUpdateAccess', 'the Windows Update page and scans are blocked: updates, and the Store that depends on them, may fail'),
    @('Microsoft\Windows\WindowsUpdate', 'WUServer', 'updates come from a WSUS server, not Microsoft: if it is gone, updates and the Store fail'),
    @('Microsoft\Windows\WindowsUpdate', 'DoNotConnectToWindowsUpdateInternetLocations', 'Windows Update may not reach Microsoft'),
    @('Microsoft\Windows\WindowsUpdate', 'TargetReleaseVersion', 'the Windows version is pinned: no feature updates past it'),
    @('Microsoft\WindowsStore', 'RemoveWindowsStore', 'the Microsoft Store is removed by policy'),
    @('Microsoft\WindowsStore', 'DisableStoreApps', 'Store apps are disabled by policy'),
    @('Microsoft\Windows Defender', 'DisableAntiSpyware', 'Microsoft Defender is disabled by policy'),
    @('Microsoft\Windows Defender\Real-Time Protection', 'DisableRealtimeMonitoring', 'Defender real-time protection is off by policy'),
    @('Microsoft\Windows\System', 'EnableSmartScreen', 'SmartScreen is controlled by policy (0 = off)'),
    @('Microsoft\Windows\System', 'DisableCMD', 'the command prompt is blocked'),
    @('Microsoft\Windows NT\CurrentVersion\Winlogon', 'DisableLockWorkstation', 'locking the PC is blocked'),
    @('Microsoft\Windows\CloudContent', 'DisableWindowsConsumerFeatures', 'consumer features (suggested apps) are off'),
    @('Microsoft\Windows\DataCollection', 'AllowTelemetry', 'telemetry level is forced by policy'),
    @('Microsoft\Windows NT\DNSClient', 'DoHPolicy', 'DNS over HTTPS is forced by policy'),
    @('Microsoft\Windows\NetworkConnectivityStatusIndicator', 'NoActiveProbe', 'Windows does not check for internet: the "no internet" icon may be wrong'),
    @('Microsoft\Windows\Network Connections', 'NC_PersonalFirewallConfig', 'firewall settings are locked by policy'),
    @('Microsoft\WindowsFirewall\StandardProfile', 'EnableFirewall', 'the firewall (private profile) is set by policy'),
    @('Microsoft\WindowsFirewall\PublicProfile', 'EnableFirewall', 'the firewall (public profile) is set by policy'),
    @('Microsoft\Windows\Appx', 'AllowAllTrustedApps', 'sideloading of apps is controlled by policy'),
    @('Microsoft\Windows\Safer', '', 'software restriction (AppLocker / SRP) rules exist'),
    @('Microsoft\Windows\System', 'EnableActivityFeed', 'activity history is controlled by policy'),
    @('Microsoft\Edge', '', 'Microsoft Edge is managed by policy'),
    @('Google\Chrome', '', 'Google Chrome is managed by policy'),
    @('Mozilla\Firefox', '', 'Firefox is managed by policy'))
function Policy-List {   # every custom policy that is set (registry Policies keys), with what the well-known ones mean
    $out = New-Object Collections.Generic.List[object]
    $roots = @(@('HKLM', 'SOFTWARE\Policies'), @('HKCU', 'SOFTWARE\Policies'), @('HKLM', 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies'), @('HKCU', 'SOFTWARE\Microsoft\Windows\CurrentVersion\Policies'), @('HKLM', 'SYSTEM\CurrentControlSet\Policies'))
    foreach ($r in $roots) {
        $base = "$($r[0]):\$($r[1])"; if (-not (Test-Path $base)) { continue }
        foreach ($k in @(Get-Item $base -ErrorAction SilentlyContinue) + @(Get-ChildItem $base -Recurse -ErrorAction SilentlyContinue)) {
            $rel = ($k.Name -replace '^[^\\]+\\', '') -replace ('^' + [regex]::Escape($r[1]) + '\\?'), ''
            foreach ($n in $k.GetValueNames()) {
                if ($n -eq '') { continue }
                $v = $k.GetValue($n); if ($v -is [byte[]]) { $v = '<' + $v.Length + ' bytes>' } elseif ($v -is [array]) { $v = $v -join ',' }
                $note = ''; foreach ($pn in $PolicyNotes) { if ($pn[1] -and $n -eq $pn[1] -and $rel -ieq $pn[0]) { $note = $pn[2]; break } }
                if (-not $note -and $r[1] -like '*CurrentVersion\Policies') { $note = if ($n -eq 'EnableLUA' -and $v -eq 0) { 'UAC is switched off' } elseif ($n -match '^(DisableTaskMgr|DisableRegistryTools|NoControlPanel|NoRun|NoDrives|NoViewOnDrive|NoDispCPL)$' -and $v -ne 0) { "restriction: $n" } else { '' } }
                $out.Add([pscustomobject]@{ root = "$($r[0])\$($r[1])"; key = $rel; name = $n; value = [string]$v; note = $note })
            }
            foreach ($pn in $PolicyNotes) { if (-not $pn[1] -and $rel -ieq $pn[0] -and $k.GetValueNames().Count -ge 0) { $out.Add([pscustomobject]@{ root = "$($r[0])\$($r[1])"; key = $rel; name = '(key present)'; value = ''; note = $pn[2] }) } }
        }
    }
    $out
}
function Activation-Info {
    try {
        $p = Get-CimInstance SoftwareLicensingProduct -Filter "ApplicationId='55c92734-d682-4d71-983e-d6ec3f16059f' AND PartialProductKey IS NOT NULL" -ErrorAction Stop | Select-Object -First 1
        if (-not $p) { return [pscustomobject]@{ status = 'no product key found'; ok = $false; name = ''; channel = ''; kms = ''; grace = 0 } }
        $st = @{ 0 = 'UNLICENSED'; 1 = 'licensed (activated)'; 2 = 'grace period (not activated yet)'; 3 = 'grace period expired'; 4 = 'NON-GENUINE grace'; 5 = 'NOTIFICATION mode (activation required)'; 6 = 'extended grace' }[[int]$p.LicenseStatus]
        [pscustomobject]@{ status = $st; ok = ([int]$p.LicenseStatus -eq 1); name = $p.Name; channel = [string]$p.ProductKeyChannel; kms = [string]$p.KeyManagementServiceMachine; grace = [int]$p.GracePeriodRemaining; key = '*****-' + $p.PartialProductKey }
    } catch { [pscustomobject]@{ status = "could not read: $($_.Exception.Message)"; ok = $false; name = ''; channel = ''; kms = ''; grace = 0 } }
}
function Health-Check {   # a quick tour of the things that usually explain "it just stopped working": findings with severity (bad / warn / ok) and what to do
    $f = New-Object Collections.Generic.List[object]
    function F($sev, $area, $msg, $fix) { $f.Add([pscustomobject]@{ sev = $sev; area = $area; msg = $msg; fix = [string]$fix }) }
    $svc = @{}; try { foreach ($s in (Svc-List)) { $svc[$s.name] = $s } } catch { F 'warn' 'services' "could not list services: $($_.Exception.Message)" '' }
    # Windows Update and the Microsoft Store share the same plumbing
    foreach ($n in 'wuauserv', 'UsoSvc', 'BITS', 'cryptsvc', 'DoSvc', 'WaaSMedicSvc', 'ClipSVC', 'AppXSvc', 'InstallService', 'StateRepository', 'LicenseManager') {
        $s = $svc[$n]; if (-not $s) { continue }
        if ($s.start -eq 'Disabled') { F 'bad' 'update / Store' "service $n ($($s.disp)) is DISABLED" "util {op:service, name:$n, value:start} after setting its start type: sc config $n start= demand" }
    }
    $pol = @(); try { $pol = @(Policy-List) } catch { }
    foreach ($p in $pol) { if ($p.note -and $p.name -ne '(key present)' -and ($p.note -match 'update|Store|Defender|firewall|SmartScreen|UAC|internet|blocked|removed|disabled|off')) { F 'warn' 'policy' "$($p.root)\$($p.key)\$($p.name) = $($p.value): $($p.note)" 'if unintended: remove the value (reg delete) or reset the local policy, then gpupdate /force' } }
    try { $ux = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\WindowsUpdate\UX\Settings' -ErrorAction Stop; if ($ux.PauseUpdatesExpiryTime -and ([DateTime]$ux.PauseUpdatesExpiryTime) -gt (Get-Date)) { F 'warn' 'update' "updates are paused until $($ux.PauseUpdatesExpiryTime)" 'Settings > Windows Update > Resume updates' } } catch { }
    try { $last = (New-Object -ComObject Microsoft.Update.AutoUpdate).Results.LastInstallationSuccessDate; if ($last -and ((Get-Date) - $last).TotalDays -gt 90) { F 'warn' 'update' ("the last successful update install was " + [int]((Get-Date) - $last).TotalDays + " days ago") 'check the Windows Update service, policies and free disk space' } } catch { }
    $act = Activation-Info; if (-not $act.ok) { F 'bad' 'activation' "Windows: $($act.status)" 'slmgr /ato after checking the key; the Store and personalization may be limited' } else { F 'ok' 'activation' "Windows is activated ($($act.channel))" '' }
    # protection
    try { $mp = Get-MpComputerStatus -ErrorAction Stop; if (-not $mp.RealTimeProtectionEnabled) { F 'warn' 'defender' 'Defender real-time protection is OFF' 'turn it on in Windows Security unless another antivirus is installed' }; if ($mp.AntivirusSignatureAge -gt 7) { F 'warn' 'defender' "virus definitions are $($mp.AntivirusSignatureAge) days old" 'Update-MpSignature' } } catch { if ($svc['WinDefend'] -and $svc['WinDefend'].state -ne 'Running') { F 'warn' 'defender' "WinDefend service is $($svc['WinDefend'].state) (fine only if another antivirus is installed)" '' } }
    foreach ($pr in 'DomainProfile', 'StandardProfile', 'PublicProfile') { try { $e = (Get-ItemProperty "HKLM:\SYSTEM\CurrentControlSet\Services\SharedAccess\Parameters\FirewallPolicy\$pr" -ErrorAction Stop).EnableFirewall; if ($e -eq 0) { F 'warn' 'firewall' "firewall is OFF for the $($pr -replace 'Profile','') profile" 'netsh advfirewall set allprofiles state on' } } catch { } }
    try { if ((Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Policies\System' -ErrorAction Stop).EnableLUA -eq 0) { F 'warn' 'uac' 'UAC is switched off' 'turn it back on and reboot' } } catch { }
    # space, reboot, hosts, proxy, devices
    foreach ($d in [IO.DriveInfo]::GetDrives()) { if ($d.DriveType -eq 'Fixed' -and $d.IsReady) { $pct = 100 * $d.AvailableFreeSpace / $d.TotalSize; if ($pct -lt 5 -or $d.AvailableFreeSpace -lt 3GB) { F 'bad' 'disk' ("$($d.Name) has only " + [F__BUILD__.Fs]::Human($d.AvailableFreeSpace) + " free (" + [int]$pct + "%)") 'free space: updates and the Store need several GB' } elseif ($pct -lt 12) { F 'warn' 'disk' ("$($d.Name) is getting full: " + [F__BUILD__.Fs]::Human($d.AvailableFreeSpace) + " free") '' } } }
    $reb = @(); if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Component Based Servicing\RebootPending') { $reb += 'component servicing' }; if (Test-Path 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\WindowsUpdate\Auto Update\RebootRequired') { $reb += 'Windows Update' }; if ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager' -ErrorAction SilentlyContinue).PendingFileRenameOperations) { $reb += 'pending file operations' }
    if ($reb.Count) { F 'warn' 'reboot' ('a reboot is pending (' + ($reb -join ', ') + '): installs and updates can fail until then') 'restart the PC' }
    try { $hf = Join-Path $env:SystemRoot 'System32\drivers\etc\hosts'; foreach ($l in @(Get-Content $hf -ErrorAction Stop | Where-Object { $_ -match '^\s*(0\.0\.0\.0|127\.0\.0\.1|::1)\s+\S*(microsoft|windows|msftconnecttest|live\.com|xboxlive|office|bing|steam|epicgames)' })) { F 'warn' 'hosts' "hosts file blocks: $($l.Trim())" 'delete the line if you did not mean it' } } catch { }
    try { $px = Get-ItemProperty 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Internet Settings' -ErrorAction Stop; if ($px.ProxyEnable -eq 1) { F 'warn' 'proxy' "a system proxy is set: $($px.ProxyServer)" 'if that program (VPN / proxy client) is not running, apps stop reaching the internet: turn the proxy off' } } catch { }
    try { $bad = @(Get-CimInstance Win32_PnPEntity -Filter 'ConfigManagerErrorCode <> 0' -ErrorAction Stop | Select-Object -First 6); foreach ($b in $bad) { F 'warn' 'device' "device problem (code $($b.ConfigManagerErrorCode)): $($b.Name)" 'reinstall or update the driver' } } catch { }
    foreach ($n in 'Dnscache', 'W32Time', 'Winmgmt', 'EventLog', 'Schedule', 'mpssvc', 'BFE') { $s = $svc[$n]; if ($s -and $s.state -ne 'Running' -and $s.start -eq 'Auto') { F 'warn' 'services' "core service $n ($($s.disp)) is $($s.state)" "util {op:service, name:$n, value:start}" } elseif ($s -and $s.start -eq 'Disabled') { F 'bad' 'services' "core service $n ($($s.disp)) is DISABLED" "sc config $n start= auto" } }
    if (-not @($f | Where-Object { $_.sev -ne 'ok' }).Count) { F 'ok' 'summary' 'no common causes found' '' }
    $f
}
function Process-Detail([int]$id) {   # where a process came from, who started it, what it runs, what it talks to
    $p = [Diagnostics.Process]::GetProcessById($id); $o = [ordered]@{ pid = $id; name = $p.ProcessName }
    $c = $null; try { $c = Get-CimInstance Win32_Process -Filter "ProcessId=$id" -ErrorAction Stop } catch { }
    $exe = ''; if ($c -and $c.ExecutablePath) { $exe = [string]$c.ExecutablePath } else { try { $exe = [string]$p.MainModule.FileName } catch { } }
    $o.path = [string]$exe; $o.cmd = if ($c) { [string]$c.CommandLine } else { '' }
    $chain = @([F__BUILD__.Sys]::Chain($id) -split '\|' | Where-Object { $_ })
    $o.parents = $chain
    try { $o.started = $p.StartTime.ToString('yyyy-MM-dd HH:mm:ss'); $o.running_for = [int]((Get-Date) - $p.StartTime).TotalMinutes } catch { }
    if ($c) { try { $own = Invoke-CimMethod -InputObject $c -MethodName GetOwner -ErrorAction Stop; $o.user = if ($own.User) { "$($own.Domain)\$($own.User)" } else { '' } } catch { } }
    $o.threads = $p.Threads.Count; $o.handles = $p.HandleCount; $o.mem_ws = $p.WorkingSet64; $o.mem_private = $p.PrivateMemorySize64
    if ($exe -and (Test-Path -LiteralPath $exe)) {
        $fi = Get-Item -LiteralPath $exe; $o.size = $fi.Length; $o.file_created = $fi.CreationTime.ToString('yyyy-MM-dd HH:mm'); $o.file_modified = $fi.LastWriteTime.ToString('yyyy-MM-dd HH:mm')
        try { $v = [Diagnostics.FileVersionInfo]::GetVersionInfo($exe); $o.company = $v.CompanyName; $o.product = $v.ProductName; $o.version = $v.FileVersion; $o.description = $v.FileDescription } catch { }
        try { $sig = Get-AuthenticodeSignature -LiteralPath $exe -ErrorAction Stop; $o.signature = [string]$sig.Status; $o.signer = if ($sig.SignerCertificate) { ($sig.SignerCertificate.Subject -replace '^.*?CN=([^,]+).*$', '$1') } else { '' } } catch { }
        if ($fi.Length -lt 150MB) { try { $o.sha256 = (Get-FileHash -LiteralPath $exe -Algorithm SHA256 -ErrorAction Stop).Hash } catch { } }
        $o.trust = Trust-Of $exe
    }
    try { $sv = @(Get-CimInstance Win32_Service -Filter "ProcessId=$id" -ErrorAction Stop | ForEach-Object { "$($_.Name) ($($_.DisplayName))" }); if ($sv.Count) { $o.services = $sv } } catch { }
    try { $esc = [regex]::Escape($exe); if ($exe) { $o.autostart = @(Startup-List $false | Where-Object { $_.exe -and $_.exe -ieq $exe } | ForEach-Object { "$($_.where): $($_.name)" }) } } catch { }
    $cn = @(); foreach ($l in (netstat -ano -p tcp 2>$null)) { if ($l -match "^\s*TCP\s+(\S+)\s+(\S+)\s+(\S+)\s+$id\s*$") { $cn += "$($Matches[3]) $($Matches[1]) -> $($Matches[2])" } }
    $o.connections = @($cn | Select-Object -First 25)
    $o
}
function Do-SysData($a) {   # JSON for the live viewer's System tabs
    $kind = [string]$a.kind; $cul = [Threading.Thread]::CurrentThread.CurrentCulture; [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::InvariantCulture
    try {
        $j = switch ($kind) {
            'procs' { [F__BUILD__.Sys]::ProcsAll() }
            'perf' { [F__BUILD__.Sys]::Perf() }
            'services' { ConvertTo-Json -Compress -Depth 4 -InputObject @(Svc-List | Select-Object name, disp, state, start, pid, acct, exe, ms) }
            'startup' { ConvertTo-Json -Compress -Depth 4 -InputObject @(Startup-List) }
            'disks' { ConvertTo-Json -Compress -Depth 5 -InputObject (Disks-All) }
            'policy' { ConvertTo-Json -Compress -Depth 4 -InputObject @(Policy-List) }
            'health' { ConvertTo-Json -Compress -Depth 4 -InputObject @(Health-Check) }
            'activation' { ConvertTo-Json -Compress -Depth 3 -InputObject (Activation-Info) }
            'process' { ConvertTo-Json -Compress -Depth 5 -InputObject (Process-Detail ([int]$a.pid)) }
            'adapters' { [F__BUILD__.Route]::Report($false) | ConvertTo-Json -Compress }
            'reach' { [F__BUILD__.Route]::Report($true) | ConvertTo-Json -Compress }
            default { throw "unknown kind '$kind' (procs, perf, services, startup, disks, policy, health, activation, process, adapters, reach)" }
        }
        @{ text = [string]$j }
    } finally { [Threading.Thread]::CurrentThread.CurrentCulture = $cul }
}


# ---- file operations for the live viewer (and the AI): make, copy, move, rename, delete (to the Recycle Bin), look inside a file without downloading it
function Do-FsOp($a) {
    $op = [string]$a.op; $p = Full ([string]$a.path)
    switch ($op) {
        'mkdir' { [void][IO.Directory]::CreateDirectory($p); return @{ text = "created folder $p" } }
        'newfile' {
            if (Test-Path -LiteralPath $p) { throw "already exists: $p" }
            [void][IO.Directory]::CreateDirectory((Split-Path $p)); [IO.File]::WriteAllBytes($p, [byte[]]@()); return @{ text = "created file $p" }
        }
        { $_ -in 'copy', 'move' } {
            $d = Full ([string]$a.dest); if (Test-Path -LiteralPath $d -PathType Container) { $d = Join-Path $d (Split-Path $p -Leaf) }
            if ($d -ieq $p) { throw 'source and destination are the same' }
            if ((Test-Path -LiteralPath $d) -and -not $a.overwrite) { throw "already exists: $d (overwrite:true replaces it)" }
            if ($op -eq 'copy') { Copy-Item -LiteralPath $p -Destination $d -Recurse -Force:([bool]$a.overwrite) -ErrorAction Stop } else { Move-Item -LiteralPath $p -Destination $d -Force:([bool]$a.overwrite) -ErrorAction Stop }
            return @{ text = "$(if ($op -eq 'copy') { 'copied' } else { 'moved' }) to $d" }
        }
        'rename' {
            $n = [string]$a.name; if (-not $n -or $n -match '[\\/:*?"<>|]') { throw 'bad name' }
            Rename-Item -LiteralPath $p -NewName $n -ErrorAction Stop; return @{ text = "renamed to $n" }
        }
        'delete' {   # the Recycle Bin unless permanent:true
            if (-not (Test-Path -LiteralPath $p)) { throw "not found: $p" }
            if ($a.permanent) { Remove-Item -LiteralPath $p -Recurse -Force -ErrorAction Stop; return @{ text = "deleted for good: $p" } }
            Add-Type -AssemblyName Microsoft.VisualBasic
            if (Test-Path -LiteralPath $p -PathType Container) { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteDirectory($p, 'OnlyErrorDialogs', 'SendToRecycleBin') } else { [Microsoft.VisualBasic.FileIO.FileSystem]::DeleteFile($p, 'OnlyErrorDialogs', 'SendToRecycleBin') }
            return @{ text = "moved to the Recycle Bin: $p" }
        }
        'stat' {
            $i = Get-Item -LiteralPath $p -Force -ErrorAction Stop
            return @{ text = (ConvertTo-Json -Compress @{ path = $i.FullName; dir = [bool]$i.PSIsContainer; size = $(if ($i.PSIsContainer) { 0 } else { $i.Length }); created = $i.CreationTime.ToString('yyyy-MM-dd HH:mm:ss'); modified = $i.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss'); attrs = [string]$i.Attributes }) }
        }
        'preview' {
            $i = Get-Item -LiteralPath $p -Force -ErrorAction Stop; if ($i.PSIsContainer) { throw 'that is a folder' }
            if ($p -match '\.(png|jpe?g|gif|bmp|webp|tiff?)$') { return Do-ReadFile @{ path = $p; max_width = 1100; quality = 72 } }
            $max = Int-Or $a.max 65536; $o = [ordered]@{ size = $i.Length; modified = $i.LastWriteTime.ToString('yyyy-MM-dd HH:mm'); truncated = ($i.Length -gt $max) }
            if ($p -match '\.(zip|jar|apk|docx|xlsx|pptx)$') {
                Add-Type -AssemblyName System.IO.Compression.FileSystem; $z = [IO.Compression.ZipFile]::OpenRead($p)
                try { $o.kind = 'archive'; $o.entries = @($z.Entries | Select-Object -First 300 | ForEach-Object { @($_.FullName, $_.Length) }); $o.count = $z.Entries.Count } finally { $z.Dispose() }
                return @{ text = (ConvertTo-Json -Compress -Depth 4 $o) }
            }
            $fs = [IO.File]::Open($p, 'Open', 'Read', 'ReadWrite')
            try { $buf = New-Object byte[] ([Math]::Min($max, $fs.Length)); [void]$fs.Read($buf, 0, $buf.Length) } finally { $fs.Dispose() }
            $bom16 = $buf.Length -ge 2 -and (($buf[0] -eq 0xFF -and $buf[1] -eq 0xFE) -or ($buf[0] -eq 0xFE -and $buf[1] -eq 0xFF))
            $nul = $false; if (-not $bom16) { for ($k = 0; $k -lt [Math]::Min(4096, $buf.Length); $k++) { if ($buf[$k] -eq 0) { $nul = $true; break } } }
            if ($nul) {
                $o.kind = 'binary'; $sb = New-Object Text.StringBuilder
                for ($r = 0; $r -lt [Math]::Min(512, $buf.Length); $r += 16) { $n = [Math]::Min(16, $buf.Length - $r); $hex = (0..($n - 1) | ForEach-Object { '{0:x2}' -f $buf[$r + $_] }) -join ' '; $asc = -join (0..($n - 1) | ForEach-Object { $c = $buf[$r + $_]; if ($c -ge 32 -and $c -lt 127) { [char]$c } else { '.' } }); [void]$sb.AppendFormat("{0:x8}  {1,-47}  {2}`n", $r, $hex, $asc) }
                $o.text = $sb.ToString()
            } else {
                $o.kind = 'text'; $enc = if ($bom16) { [Text.Encoding]::Unicode } else { New-Object Text.UTF8Encoding $false }; $t = $enc.GetString($buf); $o.text = $t.TrimStart([char]0xFEFF)
            }
            return @{ text = (ConvertTo-Json -Compress -Depth 4 $o) }
        }
        default { throw "unknown op '$op' (mkdir, newfile, copy, move, rename, delete, stat, preview)" }
    }
}

# ---- ready-made operations: right on the first try, no quoting
$ReadOnlyUtil = 'apps', 'crash', 'recent', 'reg_find', 'env_get', 'reg_get', 'clipboard_get', 'net_test', 'ports'
function Installed-Apps($q) {   # "name|version|publisher" from the uninstall keys (fast, no WMI Win32_Product)
    $keys = 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKLM:\SOFTWARE\WOW6432Node\Microsoft\Windows\CurrentVersion\Uninstall\*', 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\*'
    Get-ItemProperty $keys -ErrorAction SilentlyContinue | Where-Object { $_.DisplayName -and (-not $q -or $_.DisplayName -like "*$q*" -or $_.PSChildName -like "*$q*") } |
        Sort-Object DisplayName -Unique | ForEach-Object { "$($_.DisplayName)|$($_.DisplayVersion)|$($_.Publisher)" }
}
function Run-Args($exe, [string[]]$argv, $secs = 1800) { $r = Do-Run @{ command = $exe; args = $argv; timeout_s = $secs }; $r.text }
function Exit-Of($t) { if ($t -match '^\[exit (-?\d+)\]') { [int]$Matches[1] } else { -1 } }
$WingetCodes = @{ -1978335212 = 'no package found with that name or id (search: run winget search <name>)'; -1978335189 = 'already installed, no newer version'; -1978335215 = 'the installer failed (see output)'
    -1978334967 = 'a reboot is needed to finish'; -1978335224 = 'download failed (network)'; -1978335135 = 'already installed' }
function Rot13($s) { -join ($s.ToCharArray() | ForEach-Object { $c = [int]$_; if ($c -ge 65 -and $c -le 90) { [char](($c - 65 + 13) % 26 + 65) } elseif ($c -ge 97 -and $c -le 122) { [char](($c - 97 + 13) % 26 + 97) } else { $_ } }) }
function Crash-Report($name, $days) {   # why a program died: Application Error / Hang / .NET / system events with module, exception code and full path, the events right before, dump files
    $since = (Get-Date).AddDays(-$days); $out = @(); $hits = @()
    $ev = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application'; Id = 1000, 1002, 1026; StartTime = $since } -ErrorAction SilentlyContinue)
    $ev += @(Get-WinEvent -FilterHashtable @{ LogName = 'System'; Id = 41, 1001, 6008; StartTime = $since } -ErrorAction SilentlyContinue)
    foreach ($e in ($ev | Sort-Object TimeCreated -Descending)) {
        $m = $e.Message; if ($name -and $m -notlike "*$name*") { continue }
        $t = $e.TimeCreated.ToString('yyyy-MM-dd HH:mm:ss')
        $line = if ($e.Id -eq 1000 -and $e.Properties.Count -ge 12) { $q = $e.Properties; "$t CRASH $($q[0].Value) $($q[1].Value): module $($q[3].Value) $($q[4].Value), exception 0x$($q[6].Value) at offset $($q[7].Value), pid 0x$($q[8].Value); exe $($q[10].Value); module path $($q[11].Value)" }
                elseif ($e.Id -eq 1002) { "$t HANG $($e.Properties[0].Value) $($e.Properties[1].Value): " + (Cut ($m -replace '\s+', ' ') 220) }
                elseif ($e.Id -eq 1026) { "$t .NET " + (Cut ($m -replace '\s+', ' ') 400) }
                elseif ($e.Id -eq 41) { "$t SYSTEM unexpected shutdown / power loss / bugcheck (Kernel-Power 41)" }
                elseif ($e.Id -eq 1001) { "$t BSOD " + (Cut ($m -replace '\s+', ' ') 300) }
                else { "$t SYSTEM unclean shutdown (6008)" }
        $hits += [pscustomobject]@{ time = $e.TimeCreated; line = $line }
        if ($hits.Count -ge 15) { break }
    }
    if (-not $hits.Count) { $out += "no crash events in the last $days days" + $(if ($name) { " that mention '$name'" } else { '' }) } else { $out += $hits.line }
    if ($hits.Count) {   # what was going on in the minutes before the newest one
        $t0 = $hits[0].time
        $pre = @(Get-WinEvent -FilterHashtable @{ LogName = 'Application', 'System'; Level = 1, 2, 3; StartTime = $t0.AddMinutes(-3); EndTime = $t0 } -MaxEvents 12 -ErrorAction SilentlyContinue | Where-Object { $_.Id -ne 1000 })
        if ($pre.Count) { $out += ''; $out += 'just before the newest one (3 min):'; $out += $pre | ForEach-Object { "  $($_.TimeCreated.ToString('HH:mm:ss')) [$($_.LevelDisplayName)] $($_.ProviderName) #$($_.Id): " + (Cut ($_.Message -replace '\s+', ' ') 160) } }
    }
    $dumps = @(); foreach ($d in 'C:\Windows\Minidump', 'C:\Windows\LiveKernelReports', (Join-Path $env:LOCALAPPDATA 'CrashDumps')) { if (Test-Path $d) { $dumps += Get-ChildItem $d -Recurse -File -Include *.dmp -ErrorAction SilentlyContinue | Where-Object { $_.LastWriteTime -gt $since -and (-not $name -or $_.Name -like "*$name*") } } }
    if ($dumps.Count) { $out += ''; $out += 'dump files (fetch_file to take one):'; $out += $dumps | Sort-Object LastWriteTime -Descending | Select-Object -First 8 | ForEach-Object { "  $($_.LastWriteTime.ToString('yyyy-MM-dd HH:mm')) $([int]($_.Length / 1KB)) KB $($_.FullName)" } }
    $out -join "`n"
}
function Recent-Programs($name, $days) {   # what ran and when: UserAssist (run counts), BAM and Prefetch (administrator), recently opened files
    $since = (Get-Date).AddDays(-$days); $rows = @(); $notes = @()
    try {
        foreach ($g in Get-ChildItem 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\UserAssist' -ErrorAction Stop) {
            $k = Get-Item "Registry::$($g.Name)\Count" -ErrorAction SilentlyContinue; if (-not $k) { continue }
            foreach ($v in $k.GetValueNames()) {
                $b = $k.GetValue($v); if ($b -isnot [byte[]] -or $b.Length -lt 68) { continue }
                $ft = [BitConverter]::ToInt64($b, 60); if ($ft -le 0) { continue }
                $t = [DateTime]::FromFileTime($ft); if ($t -lt $since) { continue }
                $rows += [pscustomobject]@{ time = $t; line = "$($t.ToString('yyyy-MM-dd HH:mm:ss')) ran x$([BitConverter]::ToUInt32($b, 4))  $(Rot13 $v)" }
            }
        }
    } catch { $notes += "UserAssist: $($_.Exception.Message)" }
    try {
        foreach ($u in Get-ChildItem 'HKLM:\SYSTEM\CurrentControlSet\Services\bam\State\UserSettings' -ErrorAction Stop) {
            $k = Get-Item "Registry::$($u.Name)"; foreach ($v in $k.GetValueNames()) { $b = $k.GetValue($v); if ($b -is [byte[]] -and $b.Length -ge 8 -and $v -match '\\') { $t = [DateTime]::FromFileTime([BitConverter]::ToInt64($b, 0)); if ($t -ge $since) { $rows += [pscustomobject]@{ time = $t; line = "$($t.ToString('yyyy-MM-dd HH:mm:ss')) ran (bam)  $v" } } } }
        }
    } catch { $notes += 'BAM: needs administrator' }
    try { foreach ($f in Get-ChildItem 'C:\Windows\Prefetch\*.pf' -ErrorAction Stop | Where-Object { $_.LastWriteTime -ge $since }) { $rows += [pscustomobject]@{ time = $f.LastWriteTime; line = "$($f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')) ran (prefetch)  $($f.Name -replace '-[0-9A-F]{8}\.pf$', '')" } } } catch { $notes += 'Prefetch: needs administrator' }
    try { foreach ($f in Get-ChildItem (Join-Path $env:APPDATA 'Microsoft\Windows\Recent') -Filter *.lnk -ErrorAction Stop | Where-Object { $_.LastWriteTime -ge $since }) { $rows += [pscustomobject]@{ time = $f.LastWriteTime; line = "$($f.LastWriteTime.ToString('yyyy-MM-dd HH:mm:ss')) opened file  $($f.BaseName)" } } } catch { }
    if ($name) { $rows = @($rows | Where-Object { $_.line -like "*$name*" }) }
    $r = @($rows | Sort-Object time -Descending | Select-Object -First 60)
    ($(if ($r.Count) { $r.line } else { "nothing found in the last $days days" + $(if ($name) { " for '$name'" } else { '' }) }) + $(if ($notes.Count) { @('', 'not read: ' + ($notes -join '; ')) } else { @() })) -join "`n"
}
function Reg-Find($root, $text, $what, $max) {   # keys / value names / data under a root; stops after 25 s so a huge hive cannot hang the helper
    $hive = switch -Regex ($root) { '^HKLM' { [Microsoft.Win32.Registry]::LocalMachine } '^HKCR' { [Microsoft.Win32.Registry]::ClassesRoot } '^HKU' { [Microsoft.Win32.Registry]::Users } default { [Microsoft.Win32.Registry]::CurrentUser } }
    $sub = ($root -replace '^(HKCU|HKLM|HKCR|HKU)(\\|$)', ''); $start = if ($sub) { $hive.OpenSubKey($sub) } else { $hive }
    if (-not $start) { throw "no such registry path: $root" }
    $sw = [Diagnostics.Stopwatch]::StartNew(); $script:rf = @(); $script:rfTimeout = $false
    $walk = { param($k, $path)
        if ($script:rf.Count -ge $max) { return }
        if ($sw.Elapsed.TotalSeconds -gt 25) { $script:rfTimeout = $true; return }
        if ($what -in 'all', 'value', 'data') { foreach ($n in $k.GetValueNames()) {
            $d = try { $k.GetValue($n) } catch { $null }; $ds = if ($d -is [byte[]]) { '' } else { (@($d) -join ' ') }
            if (($what -in 'all', 'value' -and $n -like "*$text*") -or ($what -in 'all', 'data' -and $ds -like "*$text*")) { $script:rf += "$path :: $(if ($n) { $n } else { '(default)' }) = $(Cut $ds 150)"; if ($script:rf.Count -ge $max) { return } } } }
        foreach ($s in $k.GetSubKeyNames()) {
            if ($what -in 'all', 'key' -and $s -like "*$text*") { $script:rf += "$path\$s  [key]" }
            $c = try { $k.OpenSubKey($s) } catch { $null }; if ($c) { try { & $walk $c "$path\$s" } finally { $c.Close() } }
            if ($script:rf.Count -ge $max -or $script:rfTimeout) { return } } }
    & $walk $start $root
    $r = @($script:rf | Select-Object -First $max)
    ($(if ($r.Count) { $r } else { "nothing matches '$text' under $root" }) + $(if ($script:rfTimeout) { @('(stopped after 25 s: narrow the path)') } else { @() })) -join "`n"
}
function Do-Util($a) {
    $op = [string]$a.op; $name = [string]$a.name; $val = [string]$a.value; $p = [string]$a.path
    switch ($op) {
        'crash' { return @{ text = (Crash-Report $name $(if ($val -match '^\d+$') { [int]$val } else { 7 })) } }
        'recent' { return @{ text = (Recent-Programs $name $(if ($val -match '^\d+$') { [int]$val } else { 7 })) } }
        'reg_find' { return @{ text = (Reg-Find $(if ($p) { $p } else { 'HKCU\Software' }) $name $(if ($val -in 'key', 'value', 'data') { $val } else { 'all' }) $(if ($a.max) { [int]$a.max } else { 50 })) } }
        'apps' { $L = @(Installed-Apps $name); return @{ text = $(if ($L.Count) { ($L | Select-Object -First 60) -join "`n" } else { "no installed program matches '$name'" }) } }
        { $_ -in 'install', 'uninstall' } {
            if (-not (Resolve-Exe 'winget')) { throw "'winget' is not recognized: winget is missing on this PC" }
            $by = if ($name -match '^[\w-]+\.[\w.-]+$') { '--id' } else { '--name' }
            $argv = @($op, $by, $name, '--exact', '--silent', '--disable-interactivity', '--accept-source-agreements') + $(if ($op -eq 'install') { '--accept-package-agreements' } else { @() })
            $t = Run-Args 'winget' $argv; $c = Exit-Of $t
            $t = ($t -split "`n" | Where-Object { $_ -notmatch '^\s*[-\\|/]\s*$' -and $_ -notmatch '[█▒]' }) -join "`n"   # drop the spinner and progress bars
            if ($c -eq 0) { return @{ text = "ok: $op $name`n$(Cut $t 1500)" } }
            if ($WingetCodes.ContainsKey($c)) { if ($c -in -1978335189, -1978335135) { return @{ text = "ok: $($WingetCodes[$c])" } }; throw "winget: $($WingetCodes[$c])`n$(Cut $t 1500)" }
            throw "[exit $c] $(Cut $t 2000)"
        }
        'kill' {
            $argv = if ($name -match '^\d+$') { @('/PID', $name, '/T', '/F') } else { @('/IM', $(if ($name -match '\.exe$') { $name } else { "$name.exe" }), '/T', '/F') }
            $t = Run-Args 'taskkill' $argv 30; if ((Exit-Of $t) -ne 0) { throw $t }; return @{ text = $t }
        }
        'service' {
            $sv = Get-Service -Name $name -ErrorAction SilentlyContinue; if (-not $sv) { $sv = Get-Service -DisplayName $name -ErrorAction Stop }
            switch ($(if ($val) { $val } else { 'status' })) { 'start' { Start-Service -InputObject $sv } 'stop' { Stop-Service -InputObject $sv -Force } 'restart' { Restart-Service -InputObject $sv -Force } }
            $sv.Refresh(); return @{ text = "$($sv.Name) ($($sv.DisplayName)): $($sv.Status), start $($sv.StartType)" }
        }
        'env_get' {
            if (-not $name) { return @{ text = (Get-ChildItem Env: | ForEach-Object { "$($_.Name)=$(Cut $_.Value 200)" }) -join "`n" } }
            return @{ text = "process: $([Environment]::GetEnvironmentVariable($name, 'Process'))`nuser: $([Environment]::GetEnvironmentVariable($name, 'User'))`nmachine: $([Environment]::GetEnvironmentVariable($name, 'Machine'))" }
        }
        'env_set' { [Environment]::SetEnvironmentVariable($name, $val, 'User'); [Environment]::SetEnvironmentVariable($name, $val, 'Process'); return @{ text = "set $name for the user (new programs see it; this agent too)" } }
        'path_add' {
            $dir = Full $(if ($p) { $p } else { $val }); $k = [Microsoft.Win32.Registry]::CurrentUser.CreateSubKey('Environment')
            try {
                $cur = [string]$k.GetValue('Path', '', [Microsoft.Win32.RegistryValueOptions]::DoNotExpandEnvironmentNames)   # keep %VARS% as they are (setx would expand and cut at 1024)
                if (@($cur -split ';' | Where-Object { $_.TrimEnd('\') -ieq $dir.TrimEnd('\') }).Count) { return @{ text = "already in the user PATH: $dir" } }
                $k.SetValue('Path', ($(if ($cur) { $cur.TrimEnd(';') + ';' } else { '' }) + $dir), [Microsoft.Win32.RegistryValueKind]::ExpandString)
            } finally { $k.Close() }
            [F__BUILD__.Fs]::Broadcast(); $env:PATH = "$env:PATH;$dir"
            return @{ text = "added to the user PATH: $dir (new programs see it; this agent too)" }
        }
        'reg_get' {
            $rp = 'Registry::' + ($p -replace '^HKCU\\', 'HKEY_CURRENT_USER\' -replace '^HKLM\\', 'HKEY_LOCAL_MACHINE\')
            if ($name) { return @{ text = [string](Get-ItemPropertyValue -LiteralPath $rp -Name $name) } }
            $it = Get-Item -LiteralPath $rp
            return @{ text = (@($it.Property | ForEach-Object { "$_ = $($it.GetValue($_))" }) + @(Get-ChildItem -LiteralPath $rp -ErrorAction SilentlyContinue | Select-Object -First 50 | ForEach-Object { "[$($_.PSChildName)]" })) -join "`n" }
        }
        'reg_set' {
            $rp = 'Registry::' + ($p -replace '^HKCU\\', 'HKEY_CURRENT_USER\' -replace '^HKLM\\', 'HKEY_LOCAL_MACHINE\')
            if (-not (Test-Path -LiteralPath $rp)) { [void](New-Item -Path $rp -Force) }
            $type = if ($val -match '^\d{1,9}$') { 'DWord' } else { 'String' }
            New-ItemProperty -LiteralPath $rp -Name $name -Value $(if ($type -eq 'DWord') { [int]$val } else { $val }) -PropertyType $type -Force | Out-Null
            return @{ text = "set $p\$name = $val ($type)" }
        }
        'open' { Start-Process $(if ($a.url) { [string]$a.url } else { Full $p }); return @{ text = 'opened' } }
        'clipboard_get' { return @{ text = (Get-Clipboard -Raw) } }
        'clipboard_set' { Set-Clipboard -Value $val; return @{ text = 'ok' } }
        'dns_flush' { Clear-DnsClientCache; return @{ text = 'DNS cache flushed' } }
        'net_test' {
            $h = if ($a.host) { [string]$a.host } else { $name }; $port = Int-Or $a.port 443
            try { $ips = [Net.Dns]::GetHostAddresses($h) } catch { return @{ text = "dns ${h}: FAILED $($_.Exception.InnerException.Message)" } }
            $ip = @($ips | Where-Object { $_.AddressFamily -eq 'InterNetwork' })[0]; if (-not $ip) { $ip = $ips[0] }
            $c = New-Object Net.Sockets.TcpClient; $sw = [Diagnostics.Stopwatch]::StartNew()
            try { $ok = $c.ConnectAsync($ip, $port).Wait(5000) } catch { $ok = $false } finally { $c.Close() }
            return @{ text = "dns $h -> $(($ips | ForEach-Object { $_.ToString() }) -join ', ')`ntcp ${port}: " + $(if ($ok) { "open ($($sw.ElapsedMilliseconds) ms)" } else { 'FAILED (closed, filtered or timed out)' }) }
        }
        'ports' {
            $L = Get-NetTCPConnection -State Listen -ErrorAction SilentlyContinue | Where-Object { -not $name -or $_.LocalPort -eq [int]$name } | Sort-Object LocalPort -Unique | Select-Object -First 80 |
                ForEach-Object { $pr = Get-Process -Id $_.OwningProcess -ErrorAction SilentlyContinue; "{0}:{1}  pid {2} {3}" -f $_.LocalAddress, $_.LocalPort, $_.OwningProcess, $pr.ProcessName }
            return @{ text = $(if ($L) { $L -join "`n" } else { 'nothing listens there' }) }
        }
        'download' { return Do-PushFile @{ url = $a.url; path = $p } }
        'zip' {
            $src = Full $p; $dest = if ($a.dest) { Full $a.dest } else { $src.TrimEnd('\') + '.zip' }
            if (Test-Path -LiteralPath $src -PathType Container) { Zip-Dir $src $dest }
            else { Add-Type -AssemblyName System.IO.Compression.FileSystem; $z = [IO.Compression.ZipFile]::Open($dest, 'Create'); try { [void][IO.Compression.ZipFileExtensions]::CreateEntryFromFile($z, $src, (Split-Path $src -Leaf)) } finally { $z.Dispose() } }
            return @{ text = "$dest ($([F__BUILD__.Fs]::Human((Get-Item -LiteralPath $dest).Length)))" }
        }
        'unzip' {
            Add-Type -AssemblyName System.IO.Compression.FileSystem
            $src = Full $p; $dest = if ($a.dest) { Full $a.dest } else { [IO.Path]::ChangeExtension($src, $null).TrimEnd('.') }
            [IO.Compression.ZipFile]::ExtractToDirectory($src, $dest); return @{ text = "extracted to $dest" }
        }
        'shortcut' {
            $lnk = Full $(if ($a.dest) { $a.dest } else { Join-Path ([Environment]::GetFolderPath('Desktop')) ((Split-Path $p -Leaf) + '.lnk') })
            $s = (New-Object -ComObject WScript.Shell).CreateShortcut($lnk); $s.TargetPath = (Full $p); if ($val) { $s.Arguments = $val }; $s.Save()
            return @{ text = "shortcut $lnk -> $(Full $p)" }
        }
        default { throw "unknown op $op" }
    }
}

function Do-ListDir($a) {
    $rows = Get-ChildItem -LiteralPath $a.path -Force -ErrorAction SilentlyContinue | Select-Object -First 500 | ForEach-Object {
        '{0} {1,12} {2:yyyy-MM-dd HH:mm:ss} {3}' -f $(if ($_.PSIsContainer) { 'd' } else { '-' }), $(if ($_.PSIsContainer) { 0 } else { $_.Length }), $_.LastWriteTime, $_.Name
    }
    @{ text = ($rows -join "`n") }
}
# static facts never change during a session: read them once from the registry (instant), not WMI (~1 s)
function Static-Sys {
    if ($script:StaticSys) { return $script:StaticSys }
    $cv = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion' -ErrorAction SilentlyContinue
    $name = $cv.ProductName; if ($cv.DisplayVersion) { $name += ' ' + $cv.DisplayVersion }
    $build = "$($cv.CurrentBuild).$($cv.UBR)"; if ([int]($cv.CurrentBuild) -ge 22000 -and $name -match 'Windows 10') { $name = $name -replace 'Windows 10', 'Windows 11' }   # the key still says 10 on 11
    $cpu = (Get-ItemProperty 'HKLM:\HARDWARE\DESCRIPTION\System\CentralProcessor\0' -ErrorAction SilentlyContinue).ProcessorNameString
    $script:StaticSys = @{ os = "$name build $build"; cpu = ($cpu -replace '\s+', ' ').Trim(); cores = [Environment]::ProcessorCount }
    $script:StaticSys
}
function Uptime-TS { [TimeSpan]::FromMilliseconds([Environment]::TickCount64) }
function Do-SysInfo($a) {
    $st = Static-Sys
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrator')
    @{ text = (@{
        os = $st.os; host = $env:COMPUTERNAME; user = $env:USERNAME; admin = $admin
        powershell = $PSVersionTable.PSVersion.ToString(); cpu = $st.cpu; cores = $st.cores
        memory = [F__BUILD__.Sys]::Mem()
        monitors = @([Windows.Forms.Screen]::AllScreens | ForEach-Object -Begin { $i = 0 } -Process { "{0}: {1}x{2} at {3},{4}{5}" -f $i++, $_.Bounds.Width, $_.Bounds.Height, $_.Bounds.X, $_.Bounds.Y, $(if ($_.Primary) { " (primary)" } else { "" }) })
        uptime = (Uptime-TS).ToString('d\.hh\:mm'); lang = (Get-Culture).Name; node = (& { try { (& node -v 2>$null) } catch { $null } }); uv = (& { try { (& uv --version 2>$null) } catch { $null } })
        started = @($script:Started | ForEach-Object { '{0} running={1}' -f $_.Id, (-not $_.HasExited) })
    } | ConvertTo-Json) }
}

# Launch a program detached (GUI apps like Blender/Unity, servers) and return at once; it keeps running after this call.
function Resolve-Exe($cmd) {
    if (Test-Path -LiteralPath $cmd -PathType Leaf) { return (Resolve-Path -LiteralPath $cmd).Path }
    foreach ($d in $script:ExtraPath) { foreach ($e in '.exe', '.cmd', '.bat', '') { $f = Join-Path $d ($cmd + $e); if (Test-Path -LiteralPath $f -PathType Leaf) { return $f } } }
    foreach ($e in '.exe', '.cmd', '.bat', '') { $g = Get-Command ($cmd + $e) -CommandType Application -ErrorAction SilentlyContinue; if ($g) { return @($g)[0].Source } }
    $null
}
function Do-StartProcess($a) {
    Ensure-For ([IO.Path]::GetFileNameWithoutExtension([string]$a.command))
    $exe = Resolve-Exe $a.command
    if (-not $exe) { throw "Command '$($a.command)' not found" }
    $log = Join-Path $env:TEMP ("helpermcp-start-$PID-$($script:Started.Count).log")
    $argl = (@($a.args) | Where-Object { $null -ne $_ } | ForEach-Object { Quote-Arg $_ }) -join ' '
    $psi = New-Object Diagnostics.ProcessStartInfo 'cmd.exe'   # cmd keeps a log of the output; GUI windows still open normally
    $psi.Arguments = '/d /c ""' + $exe + '" ' + $argl + ' > "' + $log + '" 2>&1"'
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    if ($script:ExtraPath.Count) { $psi.EnvironmentVariables['PATH'] = ($script:ExtraPath -join ';') + ';' + $env:PATH }
    $psi.EnvironmentVariables['PYTHONUTF8'] = '1'; $psi.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'
    if ($a.env) { foreach ($q in $a.env.PSObject.Properties) { $psi.EnvironmentVariables[$q.Name] = [string]$q.Value } }
    if ($a.cwd) { $psi.WorkingDirectory = $a.cwd }
    $proc = [Diagnostics.Process]::Start($psi); $script:Started += $proc
    $w = if ($null -ne $a.wait_s) { [Math]::Min([double]$a.wait_s, 30) } else { 2 }
    [void]$proc.WaitForExit([int]($w * 1000))
    $tail = if (Test-Path $log) { $t = Get-Content $log -Raw -ErrorAction SilentlyContinue; if ($t) { $t.Substring([Math]::Max(0, $t.Length - 1500)) } else { '' } } else { '' }
    if ($proc.HasExited) { @{ text = "[exited with code $($proc.ExitCode) right away]`n$tail" } } else { @{ text = "[started pid $($proc.Id), still running]`n$tail" } }
}

# uv/uvx (how most Python MCP servers are started) missing? Download the portable uv into a temp dir.
function Ensure-Uv($cmd) {
    if ($cmd -notmatch '^(uv|uvx)(\.exe)?$' -or (Resolve-Exe $cmd)) { return }
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'aarch64' } else { 'x86_64' }
    $dir = Join-Path $env:TEMP ('helpermcp-uv-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void](New-Item -ItemType Directory $dir); $script:TmpDirs += $dir
    Write-Host '[helper] downloading portable uv ...'
    $zip = Join-Path $dir 'uv.zip'
    $pp = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
    try { Invoke-WebRequest "https://github.com/astral-sh/uv/releases/latest/download/uv-$arch-pc-windows-msvc.zip" -OutFile $zip -UseBasicParsing } finally { $ProgressPreference = $pp }
    Add-Type -AssemblyName System.IO.Compression.FileSystem
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $dir); Remove-Item $zip
    $script:ExtraPath = @($dir) + $script:ExtraPath
}

function Node-Major { try { [int](((& node -v 2>$null) -as [string]).TrimStart('v').Split('.')[0]) } catch { 0 } }

# command="playwright": a real, visible browser with sound, like a normal Playwright MCP on a desktop.
function Playwright-Preset($a) {
    $exe = @("$env:ProgramFiles\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Google\Chrome\Application\chrome.exe",
        "$env:LOCALAPPDATA\Google\Chrome\Application\chrome.exe", "${env:ProgramFiles(x86)}\Microsoft\Edge\Application\msedge.exe",
        "$env:ProgramFiles\Microsoft\Edge\Application\msedge.exe") | Where-Object { $_ -and (Test-Path $_) } | Select-Object -First 1
    $opts = [ordered]@{ headless = $false; chromiumSandbox = $true; ignoreDefaultArgs = @('--mute-audio', '--disable-blink-features=AutomationControlled'); args = @('--autoplay-policy=no-user-gesture-required') }
    if ($exe) { $opts.executablePath = $exe }
    $dir = Join-Path $env:TEMP ('helpermcp-pw-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void](New-Item -ItemType Directory $dir); $script:TmpDirs += $dir
    $cfg = Join-Path $dir 'config.json'
    [IO.File]::WriteAllText($cfg, (@{ browser = @{ browserName = 'chromium'; launchOptions = $opts } } | ConvertTo-Json -Depth 6), (New-Object Text.UTF8Encoding $false))
    @{ command = 'npx'; args = @('-y', '@playwright/mcp@latest', '--config', $cfg) + @($a.args | Where-Object { $null -ne $_ }) }
}

# npx/node/npm missing or older than 20? Download a portable Node into a temp dir (removed on exit).
function Ensure-Node($cmd) {
    if ($cmd -notmatch '^(npx|npm|node)(\.cmd|\.exe)?$' -or $script:NodeBin -or ($cmd -match '^node(\.exe)?$' -and (Resolve-Exe $cmd)) -or (Node-Major) -ge $NodeMin) { return }   # a plain `node script.js` runs on whatever Node is installed; npx/npm packages usually need >= 20
    if (-not [Environment]::Is64BitOperatingSystem) { throw 'Node.js is missing and there is no 32-bit portable build' }
    $arch = if ($env:PROCESSOR_ARCHITECTURE -eq 'ARM64') { 'arm64' } else { 'x64' }
    $script:NodeDir = Join-Path $env:TEMP ('helpermcp-node-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    [void](New-Item -ItemType Directory $script:NodeDir)
    Write-Host '[helper] downloading portable Node.js ...'
    $zip = Join-Path $script:NodeDir 'n.zip'
    $pp = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'   # PS 5.1 progress bar makes downloads ~10x slower
    try { Invoke-WebRequest "https://nodejs.org/dist/$NodeVersion/node-$NodeVersion-win-$arch.zip" -OutFile $zip -UseBasicParsing } finally { $ProgressPreference = $pp }
    Add-Type -AssemblyName System.IO.Compression.FileSystem   # Expand-Archive is painfully slow on PS 5.1 (progress bar + per-file overhead)
    [IO.Compression.ZipFile]::ExtractToDirectory($zip, $script:NodeDir)
    Remove-Item $zip
    $script:NodeBin = (Get-ChildItem $script:NodeDir -Directory | Select-Object -First 1).FullName
    $script:ExtraPath = @($script:NodeBin) + $script:ExtraPath
}

function Quote-Arg($s) { [F__BUILD__.Fs]::Quote([string]$s) }

function Child-Rpc($c, $method, $params, $timeoutSec = 60, [switch]$Notify) {
    $msg = [ordered]@{ jsonrpc = '2.0'; method = $method }
    if ($null -ne $params) { $msg.params = $params }
    if (-not $Notify) { $c.n++; $msg.id = $c.n }
    $json = $msg | ConvertTo-Json -Depth 20 -Compress
    if ($env:HELPER_DEBUG) { Write-Host "[debug] > $json" }
    $c.w.WriteLine($json); $c.w.Flush()
    if ($Notify) { return }
    $end = [DateTime]::UtcNow.AddSeconds($timeoutSec)
    while ($true) {
        if (-not $c.read) { $c.read = $c.p.StandardOutput.ReadLineAsync() }
        $left = [int]($end - [DateTime]::UtcNow).TotalMilliseconds
        $got = $false
        while ($left -gt 0) { if ($c.read.Wait([Math]::Min($left, 400))) { $got = $true; break }; Pump-Light; $left = [int]($end - [DateTime]::UtcNow).TotalMilliseconds }
        if (-not $got) {
            $why = if ($c.p.HasExited) { "exited with code $($c.p.ExitCode): " + $c.err.Result } else { 'still running, no reply' }
            throw "MCP server timed out on $method ($why)"
        }
        $line = $c.read.Result; $c.read = $null
        if ($env:HELPER_DEBUG) { Write-Host "[debug] < $line" }
        if ($null -eq $line) { [void]$c.p.WaitForExit(2000); throw ('MCP server exited: ' + $(if ($c.p.HasExited) { $c.err.Result } else { '' })) }
        try { $m = $line | ConvertFrom-Json } catch { continue }
        if ($m.id -eq $c.n -and -not $m.method) {
            if ($m.error) { throw $m.error.message }
            return $m.result
        }
    }
}

function Do-McpStart($a) {
    if ($Children.ContainsKey($a.name)) { throw "'$($a.name)' is already running" }
    if ($a.command -eq 'playwright') { $pre = Playwright-Preset $a; $a = @{ name = $a.name; command = $pre.command; args = $pre.args; env = $a.env } }
    Ensure-Node $a.command; Ensure-Uv $a.command
    $exe = Resolve-Exe $a.command   # full path incl. extension (npx.cmd, uvx.exe ...); Get-Command alone would return npx.ps1
    if (-not $exe) { throw "Command '$($a.command)' not found" }
    $psi = New-Object Diagnostics.ProcessStartInfo $exe
    $psi.Arguments = (@($a.args) | Where-Object { $null -ne $_ } | ForEach-Object { Quote-Arg $_ }) -join ' '
    $psi.RedirectStandardInput = $true; $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    if ($script:ExtraPath.Count) { $psi.EnvironmentVariables['PATH'] = ($script:ExtraPath -join ';') + ';' + $env:PATH }
    $psi.EnvironmentVariables['PYTHONUTF8'] = '1'; $psi.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'
    if ($a.env) { foreach ($q in $a.env.PSObject.Properties) { $psi.EnvironmentVariables[$q.Name] = [string]$q.Value } }
    if ($a.cwd) { $psi.WorkingDirectory = $a.cwd }
    if ($env:HELPER_DEBUG) { Write-Host "[debug] start $exe $($psi.Arguments)" }
    # .NET Framework builds the child's stdin writer from the console input encoding. If that is UTF-8 *with BOM*
    # (e.g. chcp 65001), a BOM is written at process start and corrupts the first JSON line. Use a BOM-less encoding.
    $oldIn = $null
    try { $oldIn = [Console]::InputEncoding; [Console]::InputEncoding = New-Object Text.UTF8Encoding $false } catch { }
    $c = @{ p = [Diagnostics.Process]::Start($psi); n = 0; read = $null; tools = @() }
    try { if ($oldIn) { [Console]::InputEncoding = $oldIn } } catch { }
    $c.err = $c.p.StandardError.ReadToEndAsync()   # drained in the background (also keeps the pipe from filling); shown if the server dies. ponytail: grows with a chatty server's stderr
    # default stdin encoding is the console codepage; MCP is UTF-8
    $c.w = New-Object IO.StreamWriter($c.p.StandardInput.BaseStream, (New-Object Text.UTF8Encoding $false))
    # setting the console encoding can fail without a console: if a BOM went out anyway, isolate it on its own (empty) line
    if ($c.p.StandardInput.Encoding.GetPreamble().Length -gt 0) { $c.w.WriteLine(''); $c.w.Flush() }
    try {
        [void](Child-Rpc $c 'initialize' @{ protocolVersion = '2024-11-05'; capabilities = @{}; clientInfo = @{ name = 'helpermcp'; version = '0.2' } } $(if ($env:HELPER_INIT_TIMEOUT) { [int]$env:HELPER_INIT_TIMEOUT } elseif ($a.timeout_s) { [int]$a.timeout_s } else { 240 }))
        Child-Rpc $c 'notifications/initialized' $null -Notify
        $c.tools = @((Child-Rpc $c 'tools/list' $null 60).tools)
    } catch { Stop-Tree $c.p; throw }
    $Children[$a.name] = $c
    @{ text = "$($a.name): $($c.tools.Count) tools: " + (($c.tools | ForEach-Object { $_.name }) -join ', ') }
}
function Do-McpTools($a) {
    $all = @(foreach ($n in $Children.Keys) { foreach ($t in $Children[$n].tools) { $t | Add-Member -NotePropertyName server -NotePropertyValue $n -PassThru -Force } })
    @{ text = (ConvertTo-Json -InputObject $all -Depth 30 -Compress) }
}
function Do-McpCall($a) {
    $c = $Children[$a.server]
    if (-not $c) { throw "No MCP server '$($a.server)'. Start it with mcp_start." }
    $args2 = if ($a.arguments) { $a.arguments } else { @{} }
    $r = Child-Rpc $c 'tools/call' @{ name = $a.tool; arguments = $args2 } $(if ($a.timeout_s) { [int]$a.timeout_s } else { 110 })
    @{ content = @($r.content); isError = [bool]$r.isError }
}
# uvx/npx start the real server as a grandchild: kill the whole tree, not just the wrapper
function Stop-Tree($proc) {
    try { & taskkill.exe /PID $proc.Id /T /F 2>&1 | Out-Null } catch { }
    try { if (-not $proc.HasExited) { $proc.Kill() } } catch { }
}
function Do-McpStop($a) {
    $c = $Children[$a.name]
    if ($c) { Stop-Tree $c.p; $Children.Remove($a.name) }
    @{ text = if ($c) { 'stopped' } else { 'not running' } }
}
# "Remote control" overlay: glowing screen edges that fade out + a label on top, on every monitor. Runs as its own
# process (needs a message loop), ignores the mouse, and quits when the agent's PowerShell is gone.
$OverlayScript = @'
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms, System.Drawing
Add-Type -Namespace O -Name W -MemberDefinition '[DllImport("user32.dll")] public static extern int GetWindowLong(IntPtr h, int i); [DllImport("user32.dll")] public static extern int SetWindowLong(IntPtr h, int i, int v); [DllImport("user32.dll")] public static extern bool SetProcessDPIAware(); [DllImport("user32.dll")] public static extern bool SetWindowDisplayAffinity(IntPtr h, uint a); [DllImport("user32.dll")] public static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint f);'
[void][O.W]::SetProcessDPIAware()
Add-Type -TypeDefinition @"
using System; using System.Collections.Concurrent; using System.Threading;
namespace O {
  public static class Glow {
    // alpha of every pixel is a fade of its distance to the NEAREST screen edge: no strips, nothing overlaps, no seams
    public static byte[] Make(int w, int h, int s, int r, int g, int b) {
      var px = new byte[w * h * 4]; var prof = new double[s];
      for (int d = 0; d < s; d++) { double t = (d + 0.5) / s; prof[d] = t <= 0.35 ? 0.59 + (0.18 - 0.59) * t / 0.35 : 0.18 * (1 - (t - 0.35) / 0.65); }
      for (int y = 0; y < h; y++) { int dy = Math.Min(y, h - 1 - y);
        for (int x = 0; x < w; x++) { int d = Math.Min(dy, Math.Min(x, w - 1 - x)); if (d >= s) continue;
          double a = prof[d]; int i = (y * w + x) * 4; px[i] = (byte)(b * a); px[i + 1] = (byte)(g * a); px[i + 2] = (byte)(r * a); px[i + 3] = (byte)(255 * a); } }
      return px;
    }
  }
  public static class Pump {   // commands from the agent arrive on stdin, one per line
    public static ConcurrentQueue<string> Q = new ConcurrentQueue<string>();
    public static volatile bool Eof;
    public static void Start() { var t = new Thread(() => { try { string l; while ((l = Console.In.ReadLine()) != null) Q.Enqueue(l); } catch { } Eof = true; }); t.IsBackground = true; t.Start(); }
  }
}
"@
[O.Pump]::Start()
Add-Type -Namespace O -Name C -MemberDefinition '[DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr LoadCursorFromFile(string f); [DllImport("user32.dll")] public static extern bool SetSystemCursor(IntPtr h, uint id); [DllImport("user32.dll")] public static extern bool SystemParametersInfo(uint a, uint b, IntPtr c, uint d);'
$label = $env:HM_LABEL; $lostLabel = $env:HM_LOST; $waitLabel = $env:HM_WAIT; $pausedLabel = $env:HM_PAUSED; $ppid = [int]$env:HM_PPID
$script:dpos = $null; $script:blendT = -1.0; $holdLabel = $env:HM_HOLD; $doneLabel = $env:HM_DONE; $awayLabel = $env:HM_AWAY; $script:note = ''; $script:pin = $null
$dpi = [Drawing.Graphics]::FromHwnd([IntPtr]::Zero).DpiX / 96
$script:state = 'ok'
function C($r, $g, $b, $a = 255) { [Windows.Media.Color]::FromArgb($a, $r, $g, $b) }
$BLUE = C 76 141 255; $ORANGE = C 255 138 30; $VIOLET = C 168 128 255; $GREEN = C 61 220 132; $script:okC = $BLUE
function Brush($c) { $b = New-Object Windows.Media.SolidColorBrush $c; $b.Freeze(); $b }
function Warn() { $script:state -in 'lost', 'wait', 'paused', 'hold', 'away' }   # orange states: something is not running right now
function Cur() { if (Warn) { $ORANGE } elseif ($script:state -eq 'done') { $GREEN } else { $script:okC } }

function New-Win($x, $y, $w, $h) {
    $win = New-Object Windows.Window
    $win.WindowStyle = 'None'; $win.ResizeMode = 'NoResize'; $win.AllowsTransparency = $true; $win.Background = [Windows.Media.Brushes]::Transparent
    $win.Topmost = $true; $win.ShowInTaskbar = $false; $win.ShowActivated = $false; $win.WindowStartupLocation = 'Manual'
    $win.Left = $x; $win.Top = $y; $win.Width = $w; $win.Height = $h
    $win
}
function Click-Through($win) {   # click-through, no focus, hidden from Alt+Tab
    $h = (New-Object Windows.Interop.WindowInteropHelper $win).Handle
    [void][O.W]::SetWindowLong($h, -20, ([O.W]::GetWindowLong($h, -20) -bor 0x20 -bor 0x80 -bor 0x08000000))
}
function New-Shown($x, $y, $w, $h) { $win = New-Win $x $y $w $h; $win.Show(); Click-Through $win; $win }

# ---- glow + label, one window per monitor
$mons = @()
foreach ($scr in [Windows.Forms.Screen]::AllScreens) {
    $b = $scr.Bounds
    $win = New-Win ($b.X / $dpi) ($b.Y / $dpi) ($b.Width / $dpi) ($b.Height / $dpi)
    $g = New-Object Windows.Controls.Grid
    $img = New-Object Windows.Controls.Image; $img.Stretch = 'None'; $img.HorizontalAlignment = 'Left'; $img.VerticalAlignment = 'Top'
    [void]$g.Children.Add($img)
    $pill = New-Object Windows.Controls.Border
    $pill.CornerRadius = New-Object Windows.CornerRadius 17; $pill.Padding = New-Object Windows.Thickness 18, 6, 18, 6
    $pill.Margin = New-Object Windows.Thickness 0, 12, 0, 0; $pill.HorizontalAlignment = 'Center'; $pill.VerticalAlignment = 'Top'
    $pill.Background = New-Object Windows.Media.SolidColorBrush (C 15 23 36 224); $pill.BorderThickness = New-Object Windows.Thickness 1.5
    $sp = New-Object Windows.Controls.StackPanel; $sp.Orientation = 'Horizontal'
    $dot = New-Object Windows.Shapes.Ellipse; $dot.Width = 9; $dot.Height = 9; $dot.VerticalAlignment = 'Center'
    $tb = New-Object Windows.Controls.TextBlock; $tb.Foreground = [Windows.Media.Brushes]::White; $tb.FontSize = 14; $tb.MaxWidth = 560; $tb.TextTrimming = 'CharacterEllipsis'
    $tb.FontWeight = 'SemiBold'; $tb.FontFamily = New-Object Windows.Media.FontFamily 'Segoe UI'; $tb.Margin = New-Object Windows.Thickness 9, 0, 0, 0
    $tc = New-Object Windows.Controls.TextBlock; $tc.Foreground = New-Object Windows.Media.SolidColorBrush (C 159 176 200); $tc.FontSize = 13; $tc.FontFamily = New-Object Windows.Media.FontFamily 'Segoe UI'
    [Windows.Documents.Typography]::SetNumeralAlignment($tc, 'Tabular'); $tc.Margin = New-Object Windows.Thickness 12, 1, 0, 0   # the clock does not jump with every second
    [void]$sp.Children.Add($dot); [void]$sp.Children.Add($tb); [void]$sp.Children.Add($tc); $pill.Child = $sp; [void]$g.Children.Add($pill)
    $win.Content = $g
    $pshadow = New-Object Windows.Media.Effects.DropShadowEffect; $pshadow.ShadowDepth = 0; $pshadow.BlurRadius = 26; $pshadow.Opacity = 0; $pshadow.Color = $BLUE; $pill.Effect = $pshadow
    $m = @{ win = $win; shadow = $pshadow; img = $img; pill = $pill; dot = $dot; tb = $tb; tc = $tc; w = $b.Width; h = $b.Height; cache = @{} }
    $win.Show(); Click-Through $win; $mons += $m
}
function Label-Text { switch ($script:state) { 'lost' { $lostLabel } 'wait' { $waitLabel } 'paused' { $pausedLabel } 'hold' { $holdLabel } 'done' { $doneLabel } 'away' { $awayLabel } default { if ($script:note) { $script:note } else { $label } } } }
function Clock-Text { if ($script:state -in 'ok', 'away') { $s = [int]$script:clockT.Elapsed.TotalSeconds; if ($s -ge 3600) { '{0}:{1:00}:{2:00}' -f [Math]::Floor($s / 3600), [Math]::Floor(($s % 3600) / 60), ($s % 60) } else { '{0:00}:{1:00}' -f [Math]::Floor($s / 60), ($s % 60) } } else { '' } }
$script:clockT = [Diagnostics.Stopwatch]::StartNew(); $script:lastSec = -1
$script:busy = $false; $script:capHide = $false
$script:busyOff = New-Object Windows.Threading.DispatcherTimer; $script:busyOff.Interval = [TimeSpan]::FromMilliseconds(2500); $script:busyOff.Add_Tick({ $script:busyOff.Stop(); Set-Busy $false })
function Set-Busy($b) {   # working: the label's halo breathes; waiting for a command: a plain outline
    $script:busy = $b
    foreach ($m in $mons) {
        if ($b) { $m.shadow.Color = (Cur); $an = New-Object Windows.Media.Animation.DoubleAnimation 0.3, 1.0, ([TimeSpan]::FromMilliseconds(600)); $an.AutoReverse = $true; $an.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever; $m.shadow.BeginAnimation([Windows.Media.Effects.DropShadowEffect]::OpacityProperty, $an) }
        else { $cur = $m.shadow.Opacity; $fade = New-Object Windows.Media.Animation.DoubleAnimation $cur, 0.0, ([TimeSpan]::FromMilliseconds(1400)); $fade.EasingFunction = New-Object Windows.Media.Animation.SineEase; $m.shadow.BeginAnimation([Windows.Media.Effects.DropShadowEffect]::OpacityProperty, $fade) }   # fades out softly instead of snapping
    }
}
function Apply-State {
    $c = Cur; $key = "$($c.R),$($c.G),$($c.B)"   # the glow is cached per colour
    foreach ($m in $mons) {
        if (-not $m.cache.ContainsKey($key)) {
            $px = [O.Glow]::Make($m.w, $m.h, [int](70 * $dpi), $c.R, $c.G, $c.B)
            $bs = [Windows.Media.Imaging.BitmapSource]::Create($m.w, $m.h, 96 * $dpi, 96 * $dpi, [Windows.Media.PixelFormats]::Pbgra32, $null, $px, $m.w * 4); $bs.Freeze()
            $m.cache[$key] = $bs
        }
        $m.img.Source = $m.cache[$key]
        $m.pill.BorderBrush = Brush $c; $m.dot.Fill = Brush $c
        $m.tb.Text = Label-Text; $m.tc.Text = Clock-Text; $m.tc.Visibility = $(if ($m.tc.Text) { 'Visible' } else { 'Collapsed' })
        if (Warn) {   # the orange dot pulses while the link is down or nobody has connected yet
            $an = New-Object Windows.Media.Animation.DoubleAnimation 1.0, 0.25, ([TimeSpan]::FromMilliseconds(550))
            $an.AutoReverse = $true; $an.RepeatBehavior = [Windows.Media.Animation.RepeatBehavior]::Forever
            $m.dot.BeginAnimation([Windows.UIElement]::OpacityProperty, $an)
        } else { $m.dot.BeginAnimation([Windows.UIElement]::OpacityProperty, $null); $m.dot.Opacity = 1 }
    }
}
Apply-State

# ---- the big cursor: arrow with glow, press animation, drag ring, typing dots, scroll chevrons, comet tail
$CW = 140; $HX = 44; $HY = 44
$cwin = New-Win -500 -500 $CW $CW; $cwin.Show(); Click-Through $cwin; $cwin.Hide()
$cv = New-Object Windows.Controls.Canvas; $cwin.Content = $cv
$trailDots = @(); 1..9 | ForEach-Object { $e = New-Object Windows.Shapes.Ellipse; $e.Width = 8; $e.Height = 8; $e.Visibility = 'Collapsed'; [void]$cv.Children.Add($e); $trailDots += $e }
$ring = New-Object Windows.Shapes.Ellipse; $ring.Width = 46; $ring.Height = 46; $ring.StrokeThickness = 2.4; $ring.Visibility = 'Collapsed'
[Windows.Controls.Canvas]::SetLeft($ring, $HX - 23); [Windows.Controls.Canvas]::SetTop($ring, $HY - 23); [void]$cv.Children.Add($ring)
# soft light around the (real, replaced) pointer, like Codex; it squeezes a little on a click
$halo = New-Object Windows.Shapes.Ellipse; $halo.Width = 104; $halo.Height = 104; $halo.IsHitTestVisible = $false
$haloBrush = New-Object Windows.Media.RadialGradientBrush; $haloStops = @(); foreach ($o in @(0.0, 0.5, 1.0)) { $gs = New-Object Windows.Media.GradientStop ([Windows.Media.Color]::FromArgb(0, 76, 141, 255)), $o; [void]$haloBrush.GradientStops.Add($gs); $haloStops += $gs }
$halo.Fill = $haloBrush
$haloScale = New-Object Windows.Media.ScaleTransform 1, 1; $halo.RenderTransform = $haloScale; $halo.RenderTransformOrigin = New-Object Windows.Point 0.5, 0.5
[Windows.Controls.Canvas]::SetLeft($halo, $HX - 46); [Windows.Controls.Canvas]::SetTop($halo, $HY - 44); [void]$cv.Children.Add($halo)
# the AI's arrow (the real pointer is blanked while the AI works): soft rounded, leans into the direction of movement
$arrow = New-Object Windows.Shapes.Polygon; $pts = New-Object Windows.Media.PointCollection
foreach ($q in @(@(0, 0), @(0, 23), @(5.2, 18.2), @(8.8, 26.5), @(12.3, 25), @(8.7, 16.8), @(15.6, 16.8))) { $pts.Add((New-Object Windows.Point ($q[0] * 1.4), ($q[1] * 1.4))) }
$arrow.Points = $pts; $arrow.StrokeLineJoin = 'Round'; $arrow.StrokeThickness = 1.4; $arrow.Stroke = Brush (C 76 141 255 170)
$ab = New-Object Windows.Media.LinearGradientBrush ([Windows.Media.Color]::FromArgb(255, 255, 255, 255)), ([Windows.Media.Color]::FromArgb(255, 209, 227, 255)), 90; $arrow.Fill = $ab
$arrowScale = New-Object Windows.Media.ScaleTransform 1, 1; $arrowRot = New-Object Windows.Media.RotateTransform 0
$tg = New-Object Windows.Media.TransformGroup; [void]$tg.Children.Add($arrowScale); [void]$tg.Children.Add($arrowRot); $arrow.RenderTransform = $tg; $arrow.RenderTransformOrigin = New-Object Windows.Point 0, 0
$aglow = New-Object Windows.Media.Effects.DropShadowEffect; $aglow.ShadowDepth = 2; $aglow.Direction = 270; $aglow.BlurRadius = 9; $aglow.Opacity = 0.45; $arrow.Effect = $aglow
[Windows.Controls.Canvas]::SetLeft($arrow, $HX); [Windows.Controls.Canvas]::SetTop($arrow, $HY); [void]$cv.Children.Add($arrow)
$arrowImg = New-Object Windows.Controls.Image; $arrowImg.Stretch = 'Fill'; $arrowImg.Visibility = 'Collapsed'; $arrowImg.RenderTransform = $tg; [void]$cv.Children.Add($arrowImg)
$typeDots = @(); 0..2 | ForEach-Object { $e = New-Object Windows.Shapes.Ellipse; $e.Width = 6.4; $e.Height = 6.4; $e.Visibility = 'Collapsed'
    [Windows.Controls.Canvas]::SetLeft($e, $HX + 27 + $_ * 9); [Windows.Controls.Canvas]::SetTop($e, $HY + 37); [void]$cv.Children.Add($e); $typeDots += $e }
$chev = @(); 0..2 | ForEach-Object { $l = New-Object Windows.Shapes.Polyline; $l.StrokeThickness = 3; $l.StrokeStartLineCap = 'Round'; $l.StrokeEndLineCap = 'Round'; $l.StrokeLineJoin = 'Round'
    $l.Points = New-Object Windows.Media.PointCollection; foreach ($q in @(@(0, 0), @(7, 7), @(14, 0))) { $l.Points.Add((New-Object Windows.Point $q[0], $q[1])) }
    $l.Visibility = 'Collapsed'; [void]$cv.Children.Add($l); $chev += $l }

# ---- click ripple
$RW = 220
$rwin = New-Win -500 -500 $RW $RW; $rwin.Show(); Click-Through $rwin; $rwin.Hide()
$rc = New-Object Windows.Controls.Canvas; $rwin.Content = $rc
$rings = @(); 0..1 | ForEach-Object { $e = New-Object Windows.Shapes.Ellipse; $e.Visibility = 'Collapsed'; [void]$rc.Children.Add($e); $rings += $e }
$rdot = New-Object Windows.Shapes.Ellipse; $rdot.Fill = [Windows.Media.Brushes]::White; $rdot.Visibility = 'Collapsed'; [void]$rc.Children.Add($rdot)
function Place($e, $cx, $cy, $r) { $e.Width = 2 * $r; $e.Height = 2 * $r; [Windows.Controls.Canvas]::SetLeft($e, $cx - $r); [Windows.Controls.Canvas]::SetTop($e, $cy - $r) }

# The REAL pointer is replaced for the whole session: the operator's cursor pack (CURSOR_DIR on the relay) or a soft rounded arrow. Restored when the overlay ends
# (the agent restores it too, and Windows restores it at the next sign-in whatever happens).
function Make-SoftCur($file) {
    $S = 44; $bmp = New-Object Drawing.Bitmap $S, $S, ([Drawing.Imaging.PixelFormat]::Format32bppArgb); $g = [Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'
    $pts = foreach ($q in @(@(0, 0), @(0, 23), @(5.2, 18.2), @(8.8, 26.5), @(12.3, 25), @(8.7, 16.8), @(15.6, 16.8))) { New-Object Drawing.PointF ((5 + 1.2 * $q[0]) * 1.1), ((4 + 1.2 * $q[1]) * 1.1) }
    $path = New-Object Drawing.Drawing2D.GraphicsPath; $path.AddPolygon([Drawing.PointF[]]$pts)
    $g.TranslateTransform(1.1, 2.2)
    foreach ($sh in @(@(6.6, 15), @(4.4, 23), @(2.6, 36))) { $pen = New-Object Drawing.Pen ([Drawing.Color]::FromArgb($sh[1], 5, 13, 38)), $sh[0]; $pen.LineJoin = 'Round'; $g.DrawPath($pen, $path) }
    $g.ResetTransform()
    $pw = New-Object Drawing.Pen ([Drawing.Color]::White), 2.8; $pw.LineJoin = 'Round'; $g.DrawPath($pw, $path)
    $br = New-Object Drawing.Drawing2D.LinearGradientBrush -ArgumentList @((New-Object Drawing.PointF 0, 4), (New-Object Drawing.PointF 0, 38), [Drawing.Color]::White, [Drawing.Color]::FromArgb(209, 227, 255)); $g.FillPath($br, $path)
    $po = New-Object Drawing.Pen ([Drawing.Color]::FromArgb(166, 76, 141, 255)), 1.1; $po.LineJoin = 'Round'; $g.DrawPath($po, $path); $g.Dispose()
    $bd = $bmp.LockBits((New-Object Drawing.Rectangle 0, 0, $S, $S), 'ReadOnly', 'Format32bppArgb'); $raw = New-Object byte[] ($S * $S * 4); [Runtime.InteropServices.Marshal]::Copy($bd.Scan0, $raw, 0, $raw.Length); $bmp.UnlockBits($bd)
    $ms = New-Object IO.MemoryStream; $w = New-Object IO.BinaryWriter $ms; $mask = (($S + 31) -shr 5) * 4 * $S; $size = 40 + $S * $S * 4 + $mask
    $w.Write([uint16]0); $w.Write([uint16]2); $w.Write([uint16]1); $w.Write([byte]$S); $w.Write([byte]$S); $w.Write([byte]0); $w.Write([byte]0); $w.Write([uint16]5); $w.Write([uint16]4); $w.Write([uint32]$size); $w.Write([uint32]22)
    $w.Write([uint32]40); $w.Write([int32]$S); $w.Write([int32](2 * $S)); $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]0); $w.Write([uint32]($S * $S * 4)); $w.Write([int32]0); $w.Write([int32]0); $w.Write([uint32]0); $w.Write([uint32]0)
    for ($y = $S - 1; $y -ge 0; $y--) { $w.Write($raw, $y * $S * 4, $S * 4) }
    $w.Write((New-Object byte[] $mask)); $w.Flush(); [IO.File]::WriteAllBytes($file, $ms.ToArray())
}
$CurIds = @{ pointer = 32512; beam = 32513; busy = 32514; precision = 32515; alternate = 32516; dgn1 = 32642; dgn2 = 32643; horz = 32644; vert = 32645; move = 32646; unavailable = 32648; link = 32649; working = 32650; help = 32651 }
function Read-Cur32($file) {   # 32-bit .cur -> @{ w; h; hx; hy; raw = BGRA top-down }, else $null
    try {
        $b = [IO.File]::ReadAllBytes($file); $n = [BitConverter]::ToUInt16($b, 4); $best = $null
        for ($i = 0; $i -lt $n; $i++) { $o = 6 + 16 * $i; $w = [int]$b[$o]; if ($w -eq 0) { $w = 256 }; if (-not $best -or ($w -le 48 -and $w -gt $best.w)) { $best = @{ w = $w; h = [int]$b[$o + 1]; hx = [BitConverter]::ToUInt16($b, $o + 4); hy = [BitConverter]::ToUInt16($b, $o + 6); off = [BitConverter]::ToUInt32($b, $o + 12) } } }
        $o = $best.off; if ($b[$o] -eq 0x89 -or [BitConverter]::ToUInt16($b, $o + 14) -ne 32) { return $null }
        $w = $best.w; $h = $best.h; $hs = [BitConverter]::ToUInt32($b, $o); $raw = New-Object byte[] ($w * $h * 4)
        for ($y = 0; $y -lt $h; $y++) { [Array]::Copy($b, $o + $hs + ($h - 1 - $y) * $w * 4, $raw, $y * $w * 4, $w * 4) }
        @{ w = $w; h = $h; hx = $best.hx; hy = $best.hy; raw = $raw }
    } catch { $null }
}
function Write-CurFile($file, $raw, $W, $H, $hx, $hy) {
    $ms = New-Object IO.MemoryStream; $bw = New-Object IO.BinaryWriter $ms; $mask = (($W + 31) -shr 5) * 4 * $H; $size = 40 + $W * $H * 4 + $mask
    $bw.Write([uint16]0); $bw.Write([uint16]2); $bw.Write([uint16]1); $bw.Write([byte]$W); $bw.Write([byte]$H); $bw.Write([byte]0); $bw.Write([byte]0); $bw.Write([uint16]$hx); $bw.Write([uint16]$hy); $bw.Write([uint32]$size); $bw.Write([uint32]22)
    $bw.Write([uint32]40); $bw.Write([int32]$W); $bw.Write([int32](2 * $H)); $bw.Write([uint16]1); $bw.Write([uint16]32); $bw.Write([uint32]0); $bw.Write([uint32]($W * $H * 4)); $bw.Write([int32]0); $bw.Write([int32]0); $bw.Write([uint32]0); $bw.Write([uint32]0)
    for ($y = $H - 1; $y -ge 0; $y--) { $bw.Write($raw, $y * $W * 4, $W * 4) }
    $bw.Write((New-Object byte[] $mask)); $bw.Flush(); [IO.File]::WriteAllBytes($file, $ms.ToArray())
}
function Scale-Cur($info, $k, $file) {   # a little bigger than the pack's 32 px, smooth
    $W = [int][Math]::Round($info.w * $k); $H = [int][Math]::Round($info.h * $k)
    $src = New-Object Drawing.Bitmap $info.w, $info.h, ([Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $bd = $src.LockBits((New-Object Drawing.Rectangle 0, 0, $info.w, $info.h), 'WriteOnly', 'Format32bppArgb'); [Runtime.InteropServices.Marshal]::Copy($info.raw, 0, $bd.Scan0, $info.raw.Length); $src.UnlockBits($bd)
    $dst = New-Object Drawing.Bitmap $W, $H, ([Drawing.Imaging.PixelFormat]::Format32bppArgb); $g = [Drawing.Graphics]::FromImage($dst); $g.InterpolationMode = 'HighQualityBicubic'; $g.PixelOffsetMode = 'HighQuality'; $g.CompositingMode = 'SourceCopy'
    $g.DrawImage($src, 0, 0, $W, $H); $g.Dispose()
    $bd = $dst.LockBits((New-Object Drawing.Rectangle 0, 0, $W, $H), 'ReadOnly', 'Format32bppArgb'); $raw = New-Object byte[] ($W * $H * 4); [Runtime.InteropServices.Marshal]::Copy($bd.Scan0, $raw, 0, $raw.Length); $dst.UnlockBits($bd)
    Write-CurFile $file $raw $W $H ([int][Math]::Round($info.hx * $k)) ([int][Math]::Round($info.hy * $k))
}
function Make-BlankCur($file) {
    $S = 32; $mask = (($S + 31) -shr 5) * 4 * $S; $size = 40 + $S * $S * 4 + $mask; $ms = New-Object IO.MemoryStream; $w = New-Object IO.BinaryWriter $ms
    $w.Write([uint16]0); $w.Write([uint16]2); $w.Write([uint16]1); $w.Write([byte]$S); $w.Write([byte]$S); $w.Write([byte]0); $w.Write([byte]0); $w.Write([uint16]0); $w.Write([uint16]0); $w.Write([uint32]$size); $w.Write([uint32]22)
    $w.Write([uint32]40); $w.Write([int32]$S); $w.Write([int32](2 * $S)); $w.Write([uint16]1); $w.Write([uint16]32); $w.Write([uint32]0); $w.Write([uint32]($S * $S * 4)); $w.Write([int32]0); $w.Write([int32]0); $w.Write([uint32]0); $w.Write([uint32]0)
    $w.Write((New-Object byte[] ($S * $S * 4))); $w.Write([byte[]](,[byte]255 * $mask)); $w.Flush(); [IO.File]::WriteAllBytes($file, $ms.ToArray())
}
$script:CurFiles = @{}; $script:BlankFile = $null; $script:Blanked = $false
function Set-Pointers($blank) {   # blank = hide the real pointer (the AI's own arrow is drawn instead), else the session cursors
    if ($script:Blanked -eq $blank -or -not $script:CurFiles.Count) { return }
    $script:Blanked = $blank
    if ($blank) { foreach ($id in @($CurIds.Values)) { $h = [O.C]::LoadCursorFromFile($script:BlankFile); if ($h -ne [IntPtr]::Zero) { [void][O.C]::SetSystemCursor($h, [uint32]$id) } } }
    else { Restore-Cursors; foreach ($k in @($script:CurFiles.Keys)) { $h = [O.C]::LoadCursorFromFile($script:CurFiles[$k]); if ($h -ne [IntPtr]::Zero) { [void][O.C]::SetSystemCursor($h, [uint32]$CurIds[$k]) } } }
}
function Restore-Cursors { [void][O.C]::SystemParametersInfo(0x57, 0, [IntPtr]::Zero, 0) }
function Apply-Cursors {
    try {
        $dir = Join-Path $env:TEMP ('helpermcp-cursors-' + [guid]::NewGuid().ToString('N').Substring(0, 8)); [void](New-Item $dir -ItemType Directory -Force)
        $t0 = [Diagnostics.Stopwatch]::StartNew(); $got = @{}
        if ($env:HM_RELAY) {
            foreach ($k in @('pointer') + @($CurIds.Keys | Where-Object { $_ -ne 'pointer' })) {
                if ($t0.Elapsed.TotalSeconds -gt 20) { break }
                $ext = if ($k -eq 'busy' -or $k -eq 'working') { 'ani' } else { 'cur' }
                try { $rq = [Net.WebRequest]::Create("$($env:HM_RELAY)/cursor/$k.$ext"); $rq.Timeout = 3000; $rs = $rq.GetResponse(); $f = Join-Path $dir "$k.$ext"; $fs = [IO.File]::Create($f); $rs.GetResponseStream().CopyTo($fs); $fs.Close(); $rs.Close(); $got[$k] = $f } catch { }
            }
        }
        if (-not $got.ContainsKey('pointer')) { $f = Join-Path $dir 'pointer.cur'; Make-SoftCur $f; $got['pointer'] = $f }
        else {
            $info = Read-Cur32 $got['pointer']
            if ($info) {
                $pm = New-Object byte[] $info.raw.Length   # premultiplied copy for WPF
                for ($i = 0; $i -lt $info.raw.Length; $i += 4) { $al = $info.raw[$i + 3]; $pm[$i] = [byte]($info.raw[$i] * $al / 255); $pm[$i + 1] = [byte]($info.raw[$i + 1] * $al / 255); $pm[$i + 2] = [byte]($info.raw[$i + 2] * $al / 255); $pm[$i + 3] = $al }
                $bs = [Windows.Media.Imaging.BitmapSource]::Create($info.w, $info.h, 96, 96, [Windows.Media.PixelFormats]::Pbgra32, $null, $pm, $info.w * 4); $bs.Freeze()
                $K = 1.45; $arrowImg.Source = $bs; $arrowImg.Width = $info.w * $K; $arrowImg.Height = $info.h * $K
                [Windows.Controls.Canvas]::SetLeft($arrowImg, $HX - $info.hx * $K); [Windows.Controls.Canvas]::SetTop($arrowImg, $HY - $info.hy * $K)
                $arrowImg.RenderTransformOrigin = New-Object Windows.Point ($info.hx / $info.w), ($info.hy / $info.h); $arrow.Visibility = 'Collapsed'; $arrowImg.Visibility = 'Visible'
                $f2 = Join-Path $dir 'pointer-big.cur'; Scale-Cur $info 1.35 $f2; $got['pointer'] = $f2
            }
        }
        foreach ($k in @($got.Keys)) { $h = [O.C]::LoadCursorFromFile($got[$k]); if ($h -ne [IntPtr]::Zero) { [void][O.C]::SetSystemCursor($h, [uint32]$CurIds[$k]) } }
        $script:CurFiles = $got; $script:BlankFile = Join-Path $dir 'blank.cur'; Make-BlankCur $script:BlankFile; $script:CurDir = $dir
    } catch { [Console]::Error.WriteLine('cursors: ' + $_); Restore-Cursors }
}
$clock = [Diagnostics.Stopwatch]::StartNew()
$script:lastActive = -99.0; $script:opacity = 0.0; $script:pressedT = -99.0; $script:dragging = $false
$script:scrollDir = 0; $script:scrollT = -99.0; $script:typingT = -99.0; $script:rip = $null; $script:cursorShown = $false; $script:ripShown = $false
$trail = New-Object System.Collections.ArrayList
$script:lastPtr = $null; $script:lean = 0.0; $script:vx = 0.0; $script:vy = 0.0; $script:rotTgt = 0.0; $script:movingT = -99.0; $script:typeAnim = $null

function Type-Offset($now) {   # where the arrow stands while text is typed: it follows the caret (about 7.5 px per character, 20 px per line) just below the text
    $a = $script:typeAnim; if (-not $a -or -not $a.lines.Count) { return @(0, 0) }
    $el = $now - $a.t0; if ($el -gt $a.dur + 1.2) { return @(0, 0) }
    $tot = ($a.lines | Measure-Object -Sum).Sum + $a.lines.Count - 1; $pos = [Math]::Min($el / [Math]::Max($a.dur, 0.05), 1.0) * $tot; $row = 0
    for ($i = 0; $i -lt $a.lines.Count - 1; $i++) { if ($pos -le $a.lines[$i]) { break }; $pos -= $a.lines[$i] + 1; $row++ }
    return @(([Math]::Min($pos, 70) * 7.5), (12 + 20 * $row))
}
function On-Line($line) {
    $f = $line.Trim() -split '\s+'; $now = $clock.Elapsed.TotalSeconds
    if (-not $f -or -not $f[0]) { return }
    if ($f[0] -eq 'state' -and $f.Count -gt 1) { if ($script:state -ne $f[1]) { if ($f[1] -eq 'ok' -and $script:state -in 'done', 'wait') { $script:clockT.Restart() }; $script:state = $f[1]; Apply-State }; return }
    if ($f[0] -eq 'color' -and $f.Count -ge 4) { $script:okC = C ([int]$f[1]) ([int]$f[2]) ([int]$f[3]); Apply-State; foreach ($m in $mons) { if ($script:busy) { $m.shadow.Color = (Cur) } }; return }
    if ($f[0] -eq 'note') { $script:note = $line.Trim().Substring(4).Trim(); Apply-State; return }
    if ($f[0] -eq 'pin' -and $f.Count -ge 3) { $script:pin = @{ x = [int]$f[1]; y = [int]$f[2]; t = $now }; $script:lastActive = $now; return }
    if ($f[0] -eq 'cap') { $script:capHide = $true; foreach ($m in $mons) { $m.win.Opacity = 0 }; $cwin.Opacity = 0; $rwin.Opacity = 0; return }
    if ($f[0] -eq 'uncap') { $script:capHide = $false; foreach ($m in $mons) { $m.win.Opacity = 1 }; $rwin.Opacity = 1; return }
    if ($f[0] -eq 'busy') { $script:busyOff.Stop(); Set-Busy $true; return }
    if ($f[0] -eq 'idle') { $script:busyOff.Stop(); $script:busyOff.Start(); return }   # the halo stays through the gap between two calls of the AI
    $script:lastActive = $now
    switch ($f[0]) {
        'click' { $script:pressedT = $now; $c = if ($f[3] -eq 'right') { $VIOLET } else { Cur }; $script:rip = @{ x = [double]$f[1]; y = [double]$f[2]; t = $now; c = $c } }
        'down'  { $script:dragging = $true; $script:pressedT = $now }
        'up'    { $script:dragging = $false; if ($f.Count -ge 3) { $script:rip = @{ x = [double]$f[1]; y = [double]$f[2]; t = $now; c = (Cur) } } }
        'scroll' { $script:scrollDir = if ([double]$f[1] -gt 0) { 1 } else { -1 }; $script:scrollT = $now }
        'typing' { $script:typingT = $now }
        'type' { if ($f.Count -ge 3) { $script:typeAnim = @{ t0 = $now; dur = [double]::Parse($f[1], [Globalization.CultureInfo]::InvariantCulture); lines = @($f[2].Split(',') | Where-Object { $_ } | ForEach-Object { [int]$_ }) } } }
    }
}

$timer = New-Object Windows.Threading.DispatcherTimer
$cwinH = (New-Object Windows.Interop.WindowInteropHelper $cwin).Handle
$timer.Interval = [TimeSpan]::FromMilliseconds(8)
$timer.Add_Tick({
    $line = $null
    while ([O.Pump]::Q.TryDequeue([ref]$line)) { On-Line $line }
    if ([O.Pump]::Eof) { [Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown(); return }
    $sec = [int]$script:clockT.Elapsed.TotalSeconds
    if ($sec -ne $script:lastSec) { $script:lastSec = $sec; $t = Clock-Text; foreach ($m in $mons) { $m.tc.Text = $t } }   # the session clock in the label
    $now = $clock.Elapsed.TotalSeconds; $p = [Windows.Forms.Cursor]::Position; $c = Cur
    if ($trail.Count -eq 0 -or $trail[$trail.Count - 1].x -ne $p.X -or $trail[$trail.Count - 1].y -ne $p.Y) { [void]$trail.Add(@{ t = $now; x = $p.X; y = $p.Y }); if ($trail.Count -gt 14) { $trail.RemoveAt(0) } }
    $active = (($now - $script:lastActive) -lt 8.0) -or $script:dragging
    $tgt = if ($active) { 1.0 } else { 0.0 }
    if ($script:lastPtr) {   # the tip turns into the direction of movement (the arrow points up-left at rest), and settles back when the pointer stops
        $script:vx = $script:vx * 0.6 + ($p.X - $script:lastPtr.X) * 0.4; $script:vy = $script:vy * 0.6 + ($p.Y - $script:lastPtr.Y) * 0.4
        if ([Math]::Sqrt($script:vx * $script:vx + $script:vy * $script:vy) -gt 1.6) { $script:rotTgt = [Math]::Atan2($script:vy, $script:vx) * 180 / [Math]::PI + 135; $script:movingT = $now }
        elseif ($now - $script:movingT -gt 0.45) { $script:rotTgt = 0.0 }
        $d = (($script:rotTgt - $script:lean + 540) % 360) - 180; $script:lean += $d * 0.2
    }
    $script:lastPtr = $p; $arrowRot.Angle = $script:lean
    Set-Pointers $active
    $script:opacity += ($tgt - $script:opacity) * 0.22
    if ($script:opacity -lt 0.03 -and -not $active) { if ($script:cursorShown) { $cwin.Hide(); $script:cursorShown = $false } }
    else {
        if (-not $script:cursorShown) { $cwin.Show(); $script:cursorShown = $true }
        $pinned = $script:pin -and ($now - $script:pin.t) -lt 1.5
        $q = if ($pinned) { @($script:pin.x, $script:pin.y) } else { @($p.X, $p.Y) }   # while typing: at the text caret
        if ($pinned) { $script:blendT = $now + 0.6 }
        if (-not $script:dpos) { $script:dpos = @([double]$q[0], [double]$q[1]) }
        $kk = if ($pinned -or $now -lt $script:blendT) { 0.14 } else { 1.0 }   # glides from letter to letter instead of jumping
        $script:dpos[0] += ($q[0] - $script:dpos[0]) * $kk; $script:dpos[1] += ($q[1] - $script:dpos[1]) * $kk
        [void][O.W]::SetWindowPos($cwinH, [IntPtr]::Zero, [int]($script:dpos[0] - $HX * $dpi), [int]($script:dpos[1] - $HY * $dpi), 0, 0, 0x15);   # a direct window move: much smoother than setting Left/Top through WPF
         $cwin.Opacity = $(if ($script:capHide) { 0 } else { [Math]::Min(1.0, $script:opacity) })
        $haloStops[0].Color = [Windows.Media.Color]::FromArgb(128, $c.R, $c.G, $c.B); $haloStops[1].Color = [Windows.Media.Color]::FromArgb(41, $c.R, $c.G, $c.B); $haloStops[2].Color = [Windows.Media.Color]::FromArgb(0, $c.R, $c.G, $c.B); $br = Brush $c
        $pa = $now - $script:pressedT
        $s = if ($script:dragging) { 0.9 } elseif ($pa -ge 0 -and $pa -lt 0.2) { 1 - 0.16 * [Math]::Sin([Math]::PI * $pa / 0.2) } else { 1.0 }
        $arrowScale.ScaleX = $s; $arrowScale.ScaleY = $s; $haloScale.ScaleX = $s; $haloScale.ScaleY = $s
        if ($script:dragging) { $ring.Visibility = 'Visible'; $ring.Stroke = $br; $ring.Fill = Brush (C $c.R $c.G $c.B 46); $rr = 23 + 3 * [Math]::Sin($now * 8); Place $ring $HX $HY $rr } else { $ring.Visibility = 'Collapsed' }
        for ($i = 0; $i -lt $trailDots.Count; $i++) {   # comet tail
            $e = $trailDots[$i]; $k = $trail.Count - 2 - $i
            if ($k -ge 0 -and ($now - $trail[$k].t) -lt 0.3) {
                $age = ($now - $trail[$k].t) / 0.3; $e.Visibility = 'Visible'; $e.Fill = Brush (C $c.R $c.G $c.B ([int](82 * (1 - $age))))
                $e.Width = 12 * (1 - $age) + 2; $e.Height = $e.Width
                [Windows.Controls.Canvas]::SetLeft($e, $HX + $trail[$k].x - $p.X + 3 - $e.Width / 2); [Windows.Controls.Canvas]::SetTop($e, $HY + $trail[$k].y - $p.Y + 5 - $e.Width / 2)
            } else { $e.Visibility = 'Collapsed' }
        }
        $ta = $now - $script:typingT
        for ($i = 0; $i -lt 3; $i++) { if ($ta -ge 0 -and $ta -lt 1.6) { $typeDots[$i].Visibility = 'Visible'; $typeDots[$i].Fill = Brush (C $c.R $c.G $c.B ([int](255 * (0.35 + 0.65 * [Math]::Max(0, [Math]::Sin($ta * 9 - $i * 0.9)))))) } else { $typeDots[$i].Visibility = 'Collapsed' } }
        $sa = $now - $script:scrollT
        for ($i = 0; $i -lt 3; $i++) {
            if ($script:scrollDir -ne 0 -and $sa -ge 0 -and $sa -lt 0.7) {
                $q = (($sa / 0.7) + $i / 3.0) % 1.0; $yy = $HY + 26 + $script:scrollDir * (6 + 26 * $q) + $(if ($script:scrollDir -lt 0) { -26 } else { 0 })
                $chev[$i].Visibility = 'Visible'; $chev[$i].Stroke = Brush (C $c.R $c.G $c.B ([int](230 * (1 - $q))))
                $chev[$i].RenderTransform = New-Object Windows.Media.ScaleTransform 1, $script:scrollDir
                [Windows.Controls.Canvas]::SetLeft($chev[$i], $HX + 34); [Windows.Controls.Canvas]::SetTop($chev[$i], $yy - 3.5 * $script:scrollDir - $(if ($script:scrollDir -lt 0) { 0 } else { 0 }))
            } else { $chev[$i].Visibility = 'Collapsed' }
        }
    }
    if ($script:rip -and ($now - $script:rip.t) -gt 0.9) { $script:rip = $null }
    if ($script:rip) {
        $r = $script:rip; if (-not $script:ripShown) { $rwin.Show(); $script:ripShown = $true }
        $rwin.Left = $r.x / $dpi - $RW / 2; $rwin.Top = $r.y / $dpi - $RW / 2; $rb = Brush $r.c
        $idx = 0
        foreach ($d in @(@(0.0, 8), @(0.16, 4))) {
            $pp = ($now - $r.t - $d[0]) / 0.6; $e = $rings[$idx]; $idx++
            if ($pp -ge 0 -and $pp -le 1) {
                $e.Visibility = 'Visible'; Place $e ($RW / 2) ($RW / 2) ($d[1] + 72 * (1 - [Math]::Pow(1 - $pp, 3)))
                $e.Stroke = Brush (C $r.c.R $r.c.G $r.c.B ([int](230 * [Math]::Pow(1 - $pp, 1.3)))); $e.StrokeThickness = 3.4 * (1 - $pp) + 1; $e.Fill = Brush (C $r.c.R $r.c.G $r.c.B ([int](30 * (1 - $pp))))
            } else { $e.Visibility = 'Collapsed' }
        }
        $p0 = ($now - $r.t) / 0.3
        if ($p0 -ge 0 -and $p0 -le 1) { $rdot.Visibility = 'Visible'; Place $rdot ($RW / 2) ($RW / 2) (9 * (1 - $p0) + 2); $rdot.Opacity = 1 - $p0 } else { $rdot.Visibility = 'Collapsed' }
    } elseif ($script:ripShown) { $rwin.Hide(); $script:ripShown = $false }
})
$timer.Start()
$once = New-Object Windows.Threading.DispatcherTimer; $once.Interval = [TimeSpan]::FromMilliseconds(400)
$once.Add_Tick({ $once.Stop(); Apply-Cursors })   # after the glow is on screen (downloading the pack can take a moment)
$once.Start()
$wd = New-Object Windows.Threading.DispatcherTimer
$wd.Interval = [TimeSpan]::FromSeconds(1.5)
$wd.Add_Tick({
    if (-not (Get-Process -Id $ppid -ErrorAction SilentlyContinue)) { [Windows.Threading.Dispatcher]::CurrentDispatcher.InvokeShutdown() }   # agent gone: remove the overlay too
    else { foreach ($m in $mons) { $m.win.Topmost = $false; $m.win.Topmost = $true } }   # stay above other topmost windows
})
$wd.Start()
[Windows.Threading.Dispatcher]::Run()
Restore-Cursors
if ($script:CurDir) { Remove-Item $script:CurDir -Recurse -Force -ErrorAction SilentlyContinue }
'@
function Start-Overlay {
    if ($env:HELPER_NO_OVERLAY) { return }
    try {
        $psi = New-Object Diagnostics.ProcessStartInfo 'powershell.exe'
        # the script is too long for -EncodedCommand (the command line limit is ~32k chars): run it from a temp file (UTF-8 with BOM for PS 5.1)
        $file = Join-Path $env:TEMP ('helpermcp-overlay-' + [guid]::NewGuid().ToString('N').Substring(0, 8) + '.ps1')
        [IO.File]::WriteAllText($file, $OverlayScript, (New-Object Text.UTF8Encoding $true)); $script:TmpDirs += $file
        $psi.Arguments = '-NoProfile -STA -WindowStyle Hidden -ExecutionPolicy Bypass -File "' + $file + '"'
        $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true; $psi.RedirectStandardInput = $true
        $psi.EnvironmentVariables['HM_RELAY'] = $RELAY; $psi.EnvironmentVariables['HM_LABEL'] = (T 'Удалённое управление' 'Remote control'); $psi.EnvironmentVariables['HM_PPID'] = [string]$PID
        $psi.EnvironmentVariables['HM_LOST'] = (T 'Связь потеряна, переподключение…' 'Connection lost, reconnecting…'); $psi.EnvironmentVariables['HM_WAIT'] = (T 'Ожидание помощника…' 'Waiting for the helper…'); $psi.EnvironmentVariables['HM_PAUSED'] = (T 'Пауза' 'Paused')
        $psi.EnvironmentVariables['HM_HOLD'] = (T 'Помощник на паузе, вернётся' 'The helper is on hold, back soon'); $psi.EnvironmentVariables['HM_DONE'] = (T 'Готово: помощник закончил' 'Done: the helper has finished'); $psi.EnvironmentVariables['HM_AWAY'] = (T 'Помощник давно ничего не делает' 'The helper has been quiet for a while')
        $script:OverlayProc = [Diagnostics.Process]::Start($psi)
        $script:OverlayIn = $script:OverlayProc.StandardInput; $script:OverlayIn.AutoFlush = $true
    } catch { }   # a missing overlay must never block the help session
}

function Cleanup-Children {
    foreach ($c in $Children.Values) { Stop-Tree $c.p }
    if ($script:OverlayProc) { try { $script:OverlayIn.Close(); if (-not $script:OverlayProc.WaitForExit(3000)) { $script:OverlayProc.Kill() } } catch { try { $script:OverlayProc.Kill() } catch { } } }
    try { [void][H.U__BUILD__]::SystemParametersInfo(0x57, 0, [IntPtr]::Zero, 0) } catch { }   # system cursors back, whatever happened to the overlay
    try { [F__BUILD__.Live]::Stop() } catch { }   # iex runs in the user's window: the filming thread must not outlive the session
    foreach ($d in @($script:NodeDir) + $script:TmpDirs) { if ($d) { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue } }
}

# Light requests (screenshots, sysinfo, file reads) are answered even while a long command runs: the live viewer and the AI's
# screenshots never freeze behind a 5-minute install or render. Heavy ones wait their turn.
$LightTools = 'screenshot', 'watch', 'sysinfo', 'list_dir', 'read_file', 'mcp_tools', 'tree', 'stream'
$script:Deferred = New-Object System.Collections.ArrayList
$script:Token = $null; $script:Mode = 'auto'; $script:Code = $null; $script:LastPump = [DateTime]::MinValue

# ---- the friend's console: a pinned header with the session code (copied to the clipboard), Esc ends the session at any moment, a soft chime and a flashing window
# when a question is waiting, ONE key answers it (Y yes, A always for that kind of action until the session ends, N no), small steps are asked together,
# and after the answer the window focus and the pointer are put back where the AI left them (otherwise a click that was allowed is followed by typing into the wrong window).
$AskGroup = @{ ui_click = 'input'; ui_set = 'input'; click = 'input'; move = 'input'; drag = 'input'; scroll = 'input'; type_text = 'input'; press_key = 'input'; actions = 'input'; run = 'commands'; start_process = 'commands'; fsop = 'files'; util = 'commands'
    write_file = 'files'; edit_file = 'files'; push_file = 'files'; fetch_file = 'files'; mcp_start = 'mcp'; mcp_call = 'mcp' }
$script:Allowed = @{}; $script:EndRequested = $false; $script:AiAt = $null; $script:AiPos = $null; $script:AiFg = [IntPtr]::Zero; $script:VT = $false; $script:Snd = @{}
$Quiet = @{ ui_tree = @('читаю элементы окна', 'reading the window controls'); watch = @('смотрю, что происходит на экране', 'watching the screen'); trace = @('читаю текст на экране', 'reading text on the screen'); agent_log = @('читаю журнал', 'reading the log'); screenshot = @('смотрю на экран', 'looking at the screen'); sysinfo = @('смотрю сведения о системе', 'reading system info'); list_dir = @('смотрю папку', 'listing a folder')
    read_file = @('читаю файл', 'reading a file'); mcp_tools = @('смотрю MCP', 'listing MCP tools'); mcp_stop = @('останавливаю MCP', 'stopping MCP')
    tree = @('смотрю папки', 'looking through folders'); find = @('ищу файлы', 'searching files'); system = @('смотрю состояние системы', 'reading the system state'); sysdata = @('читаю состояние системы', 'reading the system state'); fsop = @('работаю с файлами', 'working with files') }
function Group-Label($g) { switch ($g) { 'input' { T 'мышь и клавиатура' 'mouse & keyboard' } 'commands' { T 'команды' 'commands' } 'files' { T 'файлы' 'files' } default { 'MCP' } } }
function Cut($t, $n) { $t = ([string]$t) -replace "[\r\n]+", ' '; if ($t.Length -gt $n) { $t.Substring(0, $n) + '…' } else { $t } }
function Step-Text($st) {
    $x = $st.x; $y = $st.y
    switch ($st.do) {
        'move' { T "подвинуть мышь к ($x, $y)" "move the mouse to ($x, $y)" }
        'click' { if ($st.double) { T "двойной клик ($x, $y)" "double-click ($x, $y)" } elseif ($st.button -eq 'right') { T "правый клик ($x, $y)" "right-click ($x, $y)" } elseif ($st.button -eq 'middle') { T "средний клик ($x, $y)" "middle-click ($x, $y)" } else { T "нажать ($x, $y)" "click ($x, $y)" } }
        'drag' { T "перетащить ($x, $y) -> ($($st.x2), $($st.y2))" "drag ($x, $y) -> ($($st.x2), $($st.y2))" }
        'scroll' { $am = if ($st.amount) { $st.amount } else { 3 }; T "прокрутить ($am)" "scroll ($am)" }
        'type' { T ('ввести "' + (Cut $st.text 60) + '"') ('type "' + (Cut $st.text 60) + '"') }
        'key' { T "нажать клавиши $($st.keys)" "press $($st.keys)" }
        'wait' { $ms = if ($st.ms) { $st.ms } else { 500 }; T "подождать $ms мс" "wait $ms ms" }
        default { [string]$st.do }
    }
}
function Steps-Of($name, $a) {   # the steps of a tool call; a move right before a click on the same spot shows as one step
    $raw = if ($name -eq 'actions') { @($a.steps) } else { $m = @{ type_text = 'type'; press_key = 'key' }; $d = if ($m.ContainsKey($name)) { $m[$name] } else { $name }; $o = New-Object psobject -Property @{ do = $d }; foreach ($p in $a.PSObject.Properties) { Add-Member -InputObject $o -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force }; Add-Member -InputObject $o -NotePropertyName do -NotePropertyValue $d -Force; @($o) }
    $out = New-Object System.Collections.ArrayList
    foreach ($st in $raw) {
        if ($out.Count -and $out[$out.Count - 1].do -eq 'move' -and $st.do -eq 'click' -and $out[$out.Count - 1].x -eq $st.x -and $out[$out.Count - 1].y -eq $st.y) { $out.RemoveAt($out.Count - 1) }
        [void]$out.Add($st)
    }
    $out
}
function Describe-Action($name, $a) {   # -> array of short sentences
    if ($name -eq 'ui_click' -or $name -eq 'ui_set') { $who = if ($a.name) { [string]$a.name } else { "#$($a.id)" }; return @($(if ($name -eq 'ui_click') { (T 'нажать: ' 'press: ') + (Cut $who 60) } else { (T 'ввести в поле ' 'fill in ') + (Cut $who 40) + ': ' + (Cut ([string]$a.value) 40) })) }
    if ($AskGroup[$name] -eq 'input') { return @(Steps-Of $name $a | ForEach-Object { Step-Text $_ }) }
    $pre = switch ($name) { 'run' { T 'команда: ' 'command: ' } 'start_process' { T 'запустить: ' 'start: ' } 'write_file' { T 'записать файл: ' 'write file: ' } 'fetch_file' { T 'скопировать файл: ' 'copy file: ' } 'edit_file' { T 'изменить файл: ' 'edit file: ' } 'push_file' { T 'получить файл: ' 'receive file: ' } 'fsop' { (T 'файлы: ' 'files: ') + $a.op + ' ' } 'util' { (T 'утилита: ' 'utility: ') + $a.op + ' ' } 'mcp_start' { T 'запустить MCP: ' 'start MCP: ' } 'mcp_call' { T 'вызвать MCP: ' 'call MCP: ' } default { "$name " } }
    $tail = if ($a.command) { $a.command } elseif ($a.path) { $a.path } elseif ($a.name) { $a.name } elseif ($a.url) { $a.url } elseif ($name -eq 'util') { '' } else { ($a | ConvertTo-Json -Compress) }
    @($pre + (Cut $tail 90))
}
function Say-Step($name, $a) {
    if ($Quiet.ContainsKey($name)) {
        if ($script:LastQuiet -eq $name) { return }   # "looking at the screen" once, not after every picture
        $script:LastQuiet = $name; Write-Host ('  . ' + (T $Quiet[$name][0] $Quiet[$name][1])) -ForegroundColor DarkGray; return
    }
    $script:LastQuiet = $null
    $d = @(Describe-Action $name $a)
    if ($d.Count -eq 1) { Write-Host '  -> ' -ForegroundColor Cyan -NoNewline; Write-Host $d[0] }
    else { Write-Host ('  -> ' + (T 'действия:' 'actions:')) -ForegroundColor Cyan; $i = 0; foreach ($x in $d) { $i++; Write-Host "       $i. $x" } }
}
function Play-Sound($kind) {
    try {
        if (-not $script:Snd.ContainsKey($kind)) {
            $notes = if ($kind -eq 'ask') { @(@(784.0, 0.0, 0.55), @(1046.5, 0.16, 0.7)) } else { @(@(523.25, 0.0, 0.5), @(659.25, 0.12, 0.5), @(783.99, 0.24, 0.7)) }
            $w = [K__BUILD__.Chime]::Make([double[]]($notes | ForEach-Object { $_[0] }), [double[]]($notes | ForEach-Object { $_[1] }), [double[]]($notes | ForEach-Object { $_[2] }), $(if ($kind -eq 'ask') { 0.5 } else { 0.4 }))
            $script:Snd[$kind] = New-Object Media.SoundPlayer (New-Object IO.MemoryStream (, $w))
        }
        $script:Snd[$kind].Play()
    } catch { }
}
function Enable-VT { try { $h = [H.U__BUILD__]::GetStdHandle(-11); $m = 0; if ([H.U__BUILD__]::GetConsoleMode($h, [ref]$m) -and [H.U__BUILD__]::SetConsoleMode($h, $m -bor 4)) { $script:VT = $true } } catch { } }
$script:OperatorSeen = $false; $script:HdrDrawn = $false
# ---- keeping the session: local state, autostart, a log, network diagnosis and one repair attempt
$StateDir = if ($env:HELPER_STATE_DIR) { $env:HELPER_STATE_DIR } else { Join-Path $env:APPDATA 'HelperMCP' }
$SessionFile = Join-Path $StateDir 'session.json'; $LogFile = Join-Path $StateDir 'agent.log'; $RunKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
$script:Persist = $false; $script:FinalEnd = $false
function Write-AgentLog($m) {
    try {
        [void](New-Item $StateDir -ItemType Directory -Force)
        if ((Test-Path $LogFile) -and (Get-Item $LogFile).Length -gt 1MB) { Move-Item $LogFile "$LogFile.1" -Force }
        Add-Content -Path $LogFile -Value ((Get-Date -Format 'yyyy-MM-dd HH:mm:ss ') + (([string]$m) -replace "`n", "`n    ")) -Encoding UTF8
    } catch { }
}
function Get-BootTime { try { [int][DateTimeOffset]::new((Get-CimInstance Win32_OperatingSystem).LastBootUpTime).ToUnixTimeSeconds() } catch { 0 } }
function Get-DeviceId {   # a permanent per-install identity (like an AnyDesk/RustDesk ID): the relay then hands back the same code every time, not a new random one
    $f = Join-Path $StateDir 'device.json'
    try { $d = Get-Content $f -Raw -Encoding UTF8 -ErrorAction Stop | ConvertFrom-Json; if ($d.id) { return $d.id } } catch { }
    $id = ([guid]::NewGuid().ToString('N') + [guid]::NewGuid().ToString('N'))
    try { [void](New-Item $StateDir -ItemType Directory -Force); @{ id = $id } | ConvertTo-Json | Set-Content $f -Encoding UTF8 } catch { }
    return $id
}
function Norm-Mode($m) {   # confirm: ask before every action. auto: no questions (the default). unattended: like auto, plus Esc only pauses (the admin panel ends it); old agents said 'ask'/'full'
    switch ($m) { 'confirm' { 'confirm' } 'auto' { 'auto' } 'unattended' { 'unattended' } 'ask' { 'confirm' } 'full' { 'auto' } default { $null } }
}
function Save-Session($code, $token, $mode) {   # the token is encrypted for this Windows user (DPAPI): the file is useless on another account or PC
    try {
        [void](New-Item $StateDir -ItemType Directory -Force)
        $enc = ConvertFrom-SecureString (ConvertTo-SecureString $token -AsPlainText -Force)
        @{ relay = $RELAY; code = $code; token = $enc; mode = $mode; boot = (Get-BootTime); saved = [int][DateTimeOffset]::UtcNow.ToUnixTimeSeconds() } | ConvertTo-Json | Set-Content $SessionFile -Encoding UTF8
        if ($env:HELPER_TOKEN_FILE) { Set-Content $env:HELPER_TOKEN_FILE $token -Encoding UTF8 -NoNewline }   # tests only: the plaintext token, so the harness need not re-decrypt DPAPI
    } catch { Write-AgentLog "cannot save the session: $_" }
}
function Load-Session {
    try {
        $d = Get-Content $SessionFile -Raw -Encoding UTF8 | ConvertFrom-Json
        if ($d.relay -ne $RELAY -or -not $d.code -or -not $d.token) { return $null }
        $tok = [Runtime.InteropServices.Marshal]::PtrToStringAuto([Runtime.InteropServices.Marshal]::SecureStringToBSTR((ConvertTo-SecureString $d.token)))
        @{ code = $d.code; token = $tok; mode = $d.mode; boot = [int]$d.boot }
    } catch { $null }
}
function Install-Autostart {   # after a reboot the helper starts again by itself, in a visible window, and resumes the same session
    if ($env:HELPER_NO_AUTOSTART) { return }
    try {
        [void](New-Item $StateDir -ItemType Directory -Force)
        $f = Join-Path $StateDir 'agent.ps1'
        [IO.File]::WriteAllText($f, (Invoke-WebRequest "$RELAY/h" -UseBasicParsing -TimeoutSec 20).Content, (New-Object Text.UTF8Encoding $true))   # the one-liner runs from memory: keep a copy
        Set-ItemProperty -Path $RunKey -Name 'HelperMCP' -Value ('powershell.exe -NoProfile -ExecutionPolicy Bypass -File "' + $f + '"')
        try { Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Explorer\StartupApproved\Run' -Name 'HelperMCP' -ErrorAction SilentlyContinue } catch { }   # Task Manager's "Startup apps" switch would otherwise keep it off after a reboot
        Write-AgentLog 'autostart installed'
    } catch { Write-AgentLog "autostart failed: $_" }
}
function Forget-Session {
    foreach ($f in $SessionFile, (Join-Path $StateDir 'agent.ps1')) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
    try { Remove-ItemProperty -Path $RunKey -Name 'HelperMCP' -ErrorAction SilentlyContinue } catch { }
    Write-AgentLog 'session ended by the user: saved session and autostart removed'
}
function Test-Ping($h) { try { (New-Object Net.NetworkInformation.Ping).Send($h, 1200).Status -eq 'Success' } catch { $false } }
$NetToolsRx = '^(winws|zapret|goodbyedpi|clash|mihomo|verge|v2ray|xray|sing-box|nekoray|nekobox|v2rayn|hiddify|openvpn|wireguard|wg|tailscale|zerotier|hamachi|nordvpn|expressvpn|protonvpn|warp-svc|cloudflared|amnezia|outline|shadowsocks|windscribe|surfshark|forticlient|vpnui|pangps|fiddler|charles|mitmproxy|wireshark|dumpcap|privoxy|proxifier|netmod|psiphon|lantern)'
function Diagnose-Net {   # what exactly is wrong right now: adapters, route, gateway, internet, DNS, the relay itself
    $u = [Uri]$RELAY; $d = [ordered]@{}
    try { $ad = @(Get-NetAdapter -ErrorAction Stop | Select-Object Name, Status, InterfaceDescription, LinkSpeed); $d.adapters = ($ad | ForEach-Object { "$($_.Name) [$($_.Status)] $($_.InterfaceDescription) $($_.LinkSpeed)" }) -join '; ' } catch { $ad = @(); $d.adapters = "unavailable: $_" }
    $up = @($ad | Where-Object { $_.Status -eq 'Up' }); $d.links_up = @($up | ForEach-Object { $_.Name })
    $d.vpn = @($up | Where-Object { $_.InterfaceDescription -match 'TAP|TUN|WireGuard|Wintun|VPN|Meta|Tailscale|ZeroTier|Hamachi|Cisco|Fortinet|NordLynx|Clash' } | ForEach-Object { $_.Name })
    try { $d.gateway = (Get-NetRoute -DestinationPrefix '0.0.0.0/0' -ErrorAction Stop | Sort-Object RouteMetric | Select-Object -First 1).NextHop } catch { $d.gateway = $null }
    if ($d.gateway -and $d.gateway -ne '0.0.0.0') { $d.ping_gateway = Test-Ping $d.gateway } else { $d.ping_gateway = $null }
    $d.ping_internet = Test-Ping '1.1.1.1'
    try { [void][Net.Dns]::GetHostAddresses($u.Host); $d.dns_ok = $true } catch { $d.dns_ok = $false; $d.dns_error = "$($_.Exception.InnerException.Message)" }
    try { $c = New-Object Net.Sockets.TcpClient; $iar = $c.BeginConnect($u.Host, $u.Port, $null, $null); $d.relay_tcp = ($iar.AsyncWaitHandle.WaitOne(3000) -and $c.Connected); $c.Close() } catch { $d.relay_tcp = $false; $d.relay_error = "$($_.Exception.Message)" }
    try { $d.route = [F__BUILD__.Route]::Status(); $d.tools = @(Get-Process -ErrorAction SilentlyContinue | Where-Object { $_.ProcessName -match $NetToolsRx } | ForEach-Object { $_.ProcessName } | Sort-Object -Unique) -join ',' } catch { }
    $d.class = if (-not $d.links_up.Count) { 'no_link' } elseif ($d.gateway -and $d.ping_gateway -eq $false) { 'lan_down' } elseif (-not $d.ping_internet) { 'isp_down' } elseif (-not $d.dns_ok) { 'dns' } elseif (-not $d.relay_tcp) { if ($d.vpn.Count) { 'relay_unreachable_vpn' } else { 'relay_unreachable' } } else { 'http_or_tls' }
    $d
}
function Heal-Net($d) {   # one attempt per outage, by cause; a VPN is never touched
    $acts = @(); $cls = [string]$d.class
    if ($cls -eq 'dns') { ipconfig /flushdns | Out-Null; $acts += 'ipconfig /flushdns' }
    elseif ($cls -in 'no_link', 'lan_down', 'isp_down') {
        ipconfig /flushdns | Out-Null; $acts += 'ipconfig /flushdns'
        $isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
        if ($isAdmin) {
            try { foreach ($a in @(Get-NetAdapter -Physical -ErrorAction Stop | Where-Object { $_.Status -ne 'Disabled' -and $_.InterfaceDescription -notmatch 'Bluetooth' })) { Restart-NetAdapter -Name $a.Name -Confirm:$false -ErrorAction Stop; $acts += "Restart-NetAdapter '$($a.Name)'" } } catch { $acts += "adapter restart failed: $($_.Exception.Message)" }
        } else { $acts += 'restarting an adapter needs administrator rights: not done' }
    }
    elseif ($cls -like '*_vpn') { $acts += "a VPN adapter is up ($(@($d.vpn) -join ',')): not touched; the relay is unreachable through it" }
    else { $acts += "nothing to repair automatically for: $cls" }
    $acts
}
$script:Out = @{ t0 = $null; diag = $null; acts = @(); healed = $false }
function Outage-Tick {   # after every failed poll: diagnose after ~4 s, repair once after ~10 s
    $now = [DateTime]::UtcNow
    if (-not $script:Out.t0) { $script:Out.t0 = $now; Write-AgentLog 'connection to the relay lost' }
    $el = ($now - $script:Out.t0).TotalSeconds
    if ($el -ge 4 -and -not $script:Out.diag) {
        $script:Out.diag = Diagnose-Net; $d = $script:Out.diag
        Write-AgentLog ("diagnosis: class=$($d.class) gateway=$($d.gateway) ping_gw=$($d.ping_gateway) ping_inet=$($d.ping_internet) dns=$($d.dns_ok) relay_tcp=$($d.relay_tcp) vpn=$(@($d.vpn) -join ',') route=$($d.route) tools=$($d.tools)`n$($d.adapters)")
    }
    if ($el -ge 10 -and $script:Out.diag -and -not $script:Out.healed) { $script:Out.healed = $true; $script:Out.acts = @(Heal-Net $script:Out.diag); Write-AgentLog ('repair attempt: ' + ($script:Out.acts -join ' | ')) }
}
$script:RouteQ = New-Object Collections.ArrayList; $script:RouteKey = ''
function Route-Events {   # route switches seen by the watchdog: into the local log at once, to the relay as soon as it is reachable
    try {
        foreach ($e in [F__BUILD__.Route]::Drain()) { $t, $m = $e -split '\|', 2; Write-AgentLog "route: $m"; [void]$script:RouteQ.Add(@($t, $m)); if ($t -eq 'route') { Write-Orange ('  ' + [char]0x21C4 + ' ' + $m) } }
        $k = [F__BUILD__.Route]::Key(); if ($k -and $k -ne $script:RouteKey) { $script:RouteKey = $k; try { [void](New-Item $StateDir -ItemType Directory -Force); Set-Content -Path (Join-Path $StateDir 'route.txt') -Value $k -Encoding ASCII } catch { } }
        if ($script:Net -eq 'ok' -and $script:Token) { while ($script:RouteQ.Count) { $q = $script:RouteQ[0]; try { [void](Api '/a/event' @{ type = $q[0]; msg = $q[1] } $script:Token 6) } catch { break }; $script:RouteQ.RemoveAt(0) } }
    } catch { }
}
function Outage-Over {
    if (-not $script:Out.t0) { return }
    $el = [int]([DateTime]::UtcNow - $script:Out.t0).TotalSeconds; $d = $script:Out.diag
    if ($el -ge 3) {
        Write-AgentLog "connection restored after $el s"
        try { [void](Api '/a/event' @{ type = 'outage'; duration_s = $el; class = $(if ($d) { $d.class } else { 'short' }); actions = @($script:Out.acts); diagnosis = $(if ($d) { ($d | ConvertTo-Json -Compress -Depth 3) } else { '' }) } $script:Token 8) } catch { Write-AgentLog "could not send the outage report: $_" }
    }
    $script:Out = @{ t0 = $null; diag = $null; acts = @(); healed = $false }
}
function Do-AgentLog($a) {
    $n = if ($a.lines) { [int]$a.lines } else { 80 }
    $t = if (Test-Path $LogFile) { (Get-Content $LogFile -Tail $n -Encoding UTF8) -join "`n" } else { '' }
    @{ text = $(if ($t) { $t } else { '(the log is empty)' }) }
}
function Orange($text) { if ($script:VT) { "$([char]27)[38;5;208m$text$([char]27)[0m" } else { $text } }
function Write-Orange($text) { if ($script:VT) { [Console]::WriteLine((Orange $text)) } else { Write-Host $text -ForegroundColor DarkYellow } }
function Status-Text {
    $st = if ($script:Net -eq 'lost') { 'lost' } elseif ([K__BUILD__.Keys]::Paused) { 'paused' } elseif ($script:OperatorSeen) { $script:Phase } else { 'wait' }
    switch ($st) {
        'hold' { @('wait', ('|| ' + (T 'Помощник на паузе и вернётся' 'The helper is on hold and will be back'))) }
        'done' { @('ok', ([char]0x2714 + ' ' + (T 'Помощник закончил работу' 'The helper finished the work'))) }
        'away' { @('wait', ([char]0x25CC + ' ' + (T 'Помощник давно ничего не делает' 'The helper has been quiet for a while'))) }
        'paused' { @('wait', ("||" + ' ' + (T 'Пауза: помощник ждёт. Esc — меню' 'Paused: the helper is waiting. Esc = menu'))) }
        'ok' { @('ok', ([char]0x25CF + ' ' + (T 'Помощник подключён' 'Helper connected'))) }
        'lost' { @('lost', ([char]0x25CC + ' ' + (T 'Связь потеряна, переподключение…' 'Connection lost, reconnecting…'))) }
        default { @('wait', ([char]0x25CC + ' ' + (T 'Ожидание помощника… он подключается по коду' 'Waiting for the helper to connect with the code…'))) }
    }
}
function Show-Status {   # redraw only the status row (row 5) of the pinned header
    try { [K__BUILD__.Keys]::OpSeen = $script:OperatorSeen; if (-not [K__BUILD__.Keys]::Paused) { $xx = Status-Text; [K__BUILD__.Keys]::StRestore = $xx[1]; [K__BUILD__.Keys]::StRestoreOk = ($xx[0] -eq 'ok') } } catch { }
    if (-not $script:VT -or -not $script:HdrDrawn) { return }
    try { $e = [char]27; $x = Status-Text; $col = if ($x[0] -eq 'ok') { "$e[1;32m" } else { "$e[1;38;5;208m" }; [Console]::Write("${e}7$e[5;1H$e[2K" + [K__BUILD__.Keys]::Row($x[1], $(if ($x[0] -eq 'ok') { '1;32' } else { '1;38;5;208' })) + "${e}8") } catch { }
}
function Draw-Header($code, $copied) {
    $e = [char]27; $k = [K__BUILD__.Keys]
    try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
    try { if ($script:VT) { [Console]::Write("$e[2J$e[H") } else { Clear-Host } } catch { }
    $k::VT = $script:VT
    $x = Status-Text; $relayHost = try { ([Uri]$RELAY).Host } catch { $RELAY }
    $lines = @(
        $k::Top('Remote Help'),
        $k::CodeRow('Session code', $code, $(if ($copied) { ([string][char]0x2713) + ' copied to the clipboard' } else { '' })),
        $k::Row('Tell this code to the person who is helping you.', '33'),
        $k::Row(('Mode: ' + $(switch ($script:Mode) { 'unattended' { 'unattended access' } 'auto' { 'auto, no questions' } default { 'ask before every action' } }) + '   |   Server: ' + $relayHost), '2;33'),
        $k::Row($x[1], $(if ($x[0] -eq 'ok') { '1;32' } else { '1;38;5;208' })),
        $k::Row($(if ($script:Mode -eq 'unattended') { 'Press Esc at any time to pause. Only the administrator ends this session.' } else { 'Press Esc at any time to pause or end the session.' }), '33'),
        $k::Bottom())
    foreach ($l in $lines) { if ($script:VT) { [Console]::WriteLine($l) } else { Write-Host $l -ForegroundColor Yellow } }
    $script:HdrDrawn = $true
    if ($script:VT) { try { $h = [Console]::WindowHeight; [Console]::Write("$e[8;${h}r$e[8;1H") } catch { } }   # the header stays on top, the log scrolls below it
}
function Flash-Console {
    try { $f = New-Object 'H.U__BUILD__+FLASHWINFO'; $f.cbSize = [Runtime.InteropServices.Marshal]::SizeOf($f); $f.hwnd = [H.U__BUILD__]::GetAncestor([H.U__BUILD__]::GetConsoleWindow(), 3); $f.dwFlags = 15; $f.uCount = 8; [void][H.U__BUILD__]::FlashWindowEx([ref]$f) } catch { }
}
function Restore-Focus($h) {
    if ($h -eq [IntPtr]::Zero -or -not [H.U__BUILD__]::IsWindow($h) -or [H.U__BUILD__]::GetForegroundWindow() -eq $h) { return }
    [H.U__BUILD__]::keybd_event(0x12, 0, 0, [UIntPtr]::Zero); [H.U__BUILD__]::keybd_event(0x12, 0, 2, [UIntPtr]::Zero)   # an Alt tap lets SetForegroundWindow through the foreground lock
    [void][H.U__BUILD__]::SetForegroundWindow($h); Start-Sleep -Milliseconds 200
}
function Is-Console($h) { $c = [H.U__BUILD__]::GetConsoleWindow(); $h -eq $c -or $h -eq [H.U__BUILD__]::GetAncestor($c, 3) }
function Focus-Before-Question {   # the window to give the focus back to: the foreground one, or the last one that was not this console
    $fg = [H.U__BUILD__]::GetForegroundWindow()
    if ((Is-Console $fg) -and $script:AiFg -ne [IntPtr]::Zero) { return $script:AiFg }
    $fg
}
function Check-Esc { if ([K__BUILD__.Keys]::Esc) { $script:EndRequested = $true; throw 'The user ended the session (pressed Esc). Stop all work on this PC now and tell the operator; do not retry.' } }
function Ask-Permission($name, $a) {
    $g = $AskGroup[$name]; if ($script:Allowed[$g]) { return }
    $fg = Focus-Before-Question; $d = @(Describe-Action $name $a)
    Play-Sound 'ask'; Flash-Console; $title = $null; try { $title = $Host.UI.RawUI.WindowTitle; $Host.UI.RawUI.WindowTitle = '>> ' + (T 'ТРЕБУЕТСЯ ПОДТВЕРЖДЕНИЕ' 'CONFIRMATION NEEDED') } catch { }
    [ConsoleKey]$k = [ConsoleKey]::NoName; while ([K__BUILD__.Keys]::Q.TryDequeue([ref]$k)) { }   # keys typed before the question must not answer it
    Write-Host ''
    if ($d.Count -eq 1) { Write-Host ('  >> ' + (T 'Разрешить: ' 'Allow: ') + $d[0] + '  ') -ForegroundColor Black -BackgroundColor Yellow }
    else { Write-Host ('  >> ' + (T 'Разрешить действия:' 'Allow these actions:') + '  ') -ForegroundColor Black -BackgroundColor Yellow; $i = 0; foreach ($x in $d) { $i++; Write-Host "       $i. $x" -ForegroundColor Yellow } }
    Write-Host ('     [Y] ' + (T 'да' 'yes') + '    [A] ' + (T 'всегда' 'always') + '    [N] ' + (T 'нет' 'no') + '    [Esc] ' + (T 'завершить сеанс' 'end the session')) -ForegroundColor Yellow
    Write-Host ('     A = ' + (T 'не спрашивать про' 'stop asking about') + ' ' + (Group-Label $g) + ' ' + (T 'до конца сеанса' 'until the session ends')) -ForegroundColor DarkYellow
    $answer = $null
    while (-not $answer) {
        Check-Esc
        if ([K__BUILD__.Keys]::Q.TryDequeue([ref]$k)) { switch ($k) { 'Y' { $answer = 'y' } 'Enter' { $answer = 'y' } 'A' { $answer = 'a' } 'N' { $answer = 'n' } } } else { Start-Sleep -Milliseconds 40 }
    }
    if ($title) { try { $Host.UI.RawUI.WindowTitle = $title } catch { } }
    if ($answer -eq 'n') { Write-Host ('     ' + (T 'отклонено' 'denied')) -ForegroundColor DarkYellow; throw 'The user denied this action. Do not repeat it; ask the operator what to do instead.' }
    if ($answer -eq 'a') { $script:Allowed[$g] = $true; Write-Host ('     ' + [char]0x221A + ' ' + (T "дальше без вопросов: $(Group-Label $g)" "no more questions for: $(Group-Label $g)")) -ForegroundColor Green }
    else { Write-Host ('     ' + [char]0x221A + ' ' + (T 'разрешено' 'allowed')) -ForegroundColor Green }
    Restore-Focus $fg
}
$GuiTools = 'ui_click', 'ui_set', 'click', 'move', 'drag', 'scroll', 'type_text', 'press_key', 'actions'
function Resume-State($name, $a) {   # put the window focus and the pointer back where the previous AI action left them
    if ($GuiTools -notcontains $name -or -not $script:AiAt -or ([DateTime]::UtcNow - $script:AiAt).TotalSeconds -gt 90) { return }
    $first = (Steps-Of $name $a | Select-Object -First 1).do
    if ($script:AiFg -ne [IntPtr]::Zero -and [H.U__BUILD__]::GetForegroundWindow() -ne $script:AiFg) { Restore-Focus $script:AiFg }
    if ($first -in 'type', 'key', 'scroll') {
        $p = [Windows.Forms.Cursor]::Position
        if ([Math]::Abs($p.X - $script:AiPos.X) + [Math]::Abs($p.Y - $script:AiPos.Y) -gt 6) { Overlay-Send 'active'; Glide $script:AiPos.X $script:AiPos.Y 0.3 }
    }
}
function Mark-State($name) {
    if ($GuiTools -notcontains $name) { return }
    Start-Sleep -Milliseconds 80; $fg = [H.U__BUILD__]::GetForegroundWindow()
    $script:AiAt = [DateTime]::UtcNow; $script:AiPos = [Windows.Forms.Cursor]::Position; $script:AiFg = if (Is-Console $fg) { [IntPtr]::Zero } else { $fg }
}
function Do-Actions($a) {   # a short list of small GUI steps, confirmed once
    $done = @(); $i = 0
    foreach ($st in @($a.steps | Select-Object -First 20)) {
        $i++
        try {
            switch ($st.do) {
                'move' { [void](Do-Move $st) }
                'click' { [void](Do-Click $st) }
                'drag' { [void](Do-Drag $st) }
                'scroll' { [void](Do-Scroll $st) }
                'type' { [void](Do-TypeText @{ text = $st.text }) }
                'key' { [void](Do-PressKey @{ keys = $st.keys }) }
                'wait' { Start-Sleep -Milliseconds ([Math]::Min(5000, [int]$st.ms)) }
                default { throw "unknown step '$($st.do)'" }
            }
        } catch { throw "step $i ($($st.do)) failed: $($_.Exception.Message). Steps before it were done: $(if ($done) { $done -join ', ' } else { 'none' })." }
        $done += "${i}:$($st.do)"
    }
    @{ text = "ok, $($done.Count) step(s) done" }
}
function Process-Command($cmd) {
    $name = $cmd.tool; $a = $cmd.args
    $viewFrame = $name -eq 'screenshot' -and $a.view   # the operator's live viewer: no console line, no state change
    $meta = $name -in 'look', 'hold', 'task_done', 'stream', 'set_mode'
    if (-not $viewFrame -and -not $meta) {
        $script:LastOp = [DateTime]::UtcNow
        if (-not $script:OperatorSeen -or $script:Phase -ne 'ok') {
            $first = -not $script:OperatorSeen; $wasDone = $script:Phase -eq 'done'
            $script:OperatorSeen = $true; $script:Phase = 'ok'; Overlay-Send 'state ok'; Show-Status
            if ($first) { Write-Host ('  ' + [char]0x25CF + ' ' + (T 'Помощник подключён' 'Helper connected')) -ForegroundColor Green }
            if ($wasDone -and $script:Persist) { Install-Autostart }   # work resumed after task_done: re-arm the safety net
        }
    }
    if (-not $viewFrame -and -not $meta) { Say-Step $name $a }
    $res = @{ id = $cmd.id }
    $quietCall = $Quiet.ContainsKey($name) -or $meta -or $viewFrame; if (-not $quietCall) { Overlay-Send 'busy' }
    try {
        Check-Esc
        if ([K__BUILD__.Keys]::Paused -and -not $Quiet.ContainsKey($name) -and -not $meta) { throw 'PAUSED by the user (Esc menu). The session is kept. Do not retry now: use wait_online, then continue.' }
        if ($script:Mode -eq 'confirm' -and $AskTools -contains $name -and -not ($name -eq 'util' -and $ReadOnlyUtil -contains $a.op) -and -not ($name -eq 'fsop' -and $a.op -in 'preview', 'stat')) { Ask-Permission $name $a }
        Resume-State $name $a
        $fn = @{ screenshot = 'Do-Screenshot'; click = 'Do-Click'; move = 'Do-Move'; drag = 'Do-Drag'; scroll = 'Do-Scroll'; type_text = 'Do-TypeText'; press_key = 'Do-PressKey'
            run = 'Do-Run'; read_file = 'Do-ReadFile'; write_file = 'Do-WriteFile'; list_dir = 'Do-ListDir'; sysinfo = 'Do-SysInfo'
            actions = 'Do-Actions'; focus_window = 'Do-FocusWindow'; ui_tree = 'Do-UiTree'; ui_click = 'Do-UiClick'; ui_set = 'Do-UiSet'; trace = 'Do-Trace'; watch = 'Do-Watch'; look = 'Do-Look'; hold = 'Do-Hold'; task_done = 'Do-TaskDone'; set_mode = 'Do-SetMode'; agent_log = 'Do-AgentLog'; fetch_file = 'Do-FetchFile'; tree = 'Do-Tree'; find = 'Do-Find'; edit_file = 'Do-EditFile'; push_file = 'Do-PushFile'; system = 'Do-System'; sysdata = 'Do-SysData'; fsop = 'Do-FsOp'; util = 'Do-Util'; stream = 'Do-Stream'; start_process = 'Do-StartProcess'; mcp_start = 'Do-McpStart'; mcp_tools = 'Do-McpTools'; mcp_call = 'Do-McpCall'; mcp_stop = 'Do-McpStop' }[$name]
        if (-not $fn) { throw "Unknown tool $name" }
        $res.ok = $true; $res.data = & $fn $a
        Mark-State $name
    } catch { $ex = $_.Exception; while ($ex -is [Management.Automation.MethodInvocationException] -and $ex.InnerException) { $ex = $ex.InnerException }; $res.ok = $false; $res.error = $ex.Message }   # a C# helper's own message, not "Exception calling ..."
    if (-not $quietCall) { Overlay-Send 'idle' }
    if (-not $quietCall) { if ($res.ok) { Write-Host ('     ' + [char]0x221A + ' ' + (T 'готово' 'done')) -ForegroundColor Green } else { Write-Host ('     x ' + (Cut $res.error 120)) -ForegroundColor Red } }
    for ($attempt = 0; $attempt -lt 5; $attempt++) {   # a lost result would leave the operator waiting for a call that already finished
        try { Post-Result $res $script:Token; break }
        catch { $sc = 0; try { $sc = [int]$_.Exception.Response.StatusCode } catch { }; if ($sc -eq 401 -or $sc -eq 410) { break }; Start-Sleep (1 + $attempt) }
    }
}

# Called from the wait loops of long operations: take a look at the relay without blocking, serve light requests right away.
function Pump-Light {
    Check-Esc
    if (-not $script:Token -or ([DateTime]::UtcNow - $script:LastPump).TotalMilliseconds -lt 400) { return }
    $script:LastPump = [DateTime]::UtcNow
    try { $r = Api '/a/poll?w=0' $null $script:Token 10 } catch { return }
    if ($r.StatusCode -ne 200 -or -not $r.Content) { return }
    $cmd = $r.Content | ConvertFrom-Json
    if ($cmd.tool -eq 'bye') { [void]$script:Deferred.Add($cmd); return }
    if ($LightTools -contains $cmd.tool) { Process-Command $cmd } else { [void]$script:Deferred.Add($cmd) }
}

# Tell the overlay about connection state and effects (click ripple, drag, scroll ...). Never throws.
function Overlay-Send($line) { try { if ($script:OverlayIn) { $script:OverlayIn.WriteLine($line) } } catch { } }

$script:Net = 'ok'
function Net-State($st) {
    if ($script:Net -eq $st) { return }
    $script:Net = $st
    if ($st -eq 'lost') { Write-Orange ('  ' + [char]0x25CC + ' ' + (T 'Связь потеряна, переподключение…' 'Connection lost, reconnecting…')) } else { Write-Host ('  ' + [char]0x25CF + ' ' + (T 'Связь восстановлена' 'Connection restored')) -ForegroundColor Green }
    Overlay-Send ("state " + $(if ($st -eq 'lost') { 'lost' } elseif ($script:OperatorSeen) { $script:Phase } else { 'wait' }))   # the overlay turns orange while the link is down or nobody has connected yet
    Show-Status
}

function Register-Agent($mode, $resume, $resumeToken, $note) {
    $body = @{ os = (Get-CimInstance Win32_OperatingSystem).Caption; host = $env:COMPUTERNAME; user = $env:USERNAME; mode = $mode; persist = $script:Persist; note = [string]$note; device_id = (Get-DeviceId) }
    if ($resumeToken) { $body.resume_token = $resumeToken }   # proof that it is the same PC: the server then keeps everything it has
    if ($resume) { $body.resume = $resume }   # the server may have forgotten us (restart, long outage): ask for the same code back
    (Api '/a/register' $body $null 20).Content | ConvertFrom-Json
}

function Start-Helper {
    $saved = if ($env:HELPER_NEW) { $null } else { Load-Session }
    $mode = Norm-Mode $env:HELPER_MODE
    if ($saved -and (Norm-Mode $saved.mode)) { $mode = Norm-Mode $saved.mode }   # after a reboot or a restart nothing is asked again: it reconnects at once
    elseif (-not $mode) {
        $ans = Read-Host (T 'Режим: [1] спрашивать про каждое действие (рекомендуется)  [2] авто, без вопросов  [3] постоянный доступ (Esc только ставит на паузу, завершить может только админ)' 'Mode: [1] ask before every action (recommended)  [2] auto, no questions  [3] unattended (Esc only pauses, only the admin ends it)')
        $mode = switch ($ans.Trim()) { '2' { 'auto' } '3' { 'unattended' } default { 'confirm' } }
    }
    $script:Mode = $mode; [K__BUILD__.Keys]::Unattended = ($mode -eq 'unattended')
    try { [F__BUILD__.Route]::Init($RELAY, $(try { (Get-Content (Join-Path $StateDir 'route.txt') -ErrorAction Stop | Select-Object -First 1) } catch { '' }), (Join-Path $StateDir 'route.block')); [Net.WebRequest]::DefaultWebProxy = [F__BUILD__.Route]::Proxy } catch { Write-AgentLog "route layer: $_" }   # the link to the relay survives a VPN, zapret or a dead default route
    if ($saved) { $script:Mode = $mode = (Norm-Mode $saved.mode); [K__BUILD__.Keys]::Unattended = ($mode -eq 'unattended'); $script:Persist = $true }
    elseif ($env:HELPER_PERSIST -in '0', '1') { $script:Persist = ($env:HELPER_PERSIST -eq '1') }   # tests / an explicit opt-out only: otherwise the session is always kept (internet loss, reboots), like the mode question used to default
    else { $script:Persist = $true }
    $note = ''
    if ($saved) { Write-Host ('  ' + (T 'Продолжаю прошлый сеанс ' 'Resuming the previous session ') + $saved.code) -ForegroundColor Yellow; $note = if ([Math]::Abs($saved.boot - (Get-BootTime)) -gt 90) { 'after a reboot' } else { 'restarted' }; Write-AgentLog "resuming session $($saved.code) ($note)" }
    $wait = 1.0
    while ($true) {   # the server can be unreachable right at the start (no internet yet, VPN still connecting): keep trying
        try { $r = $(if ($saved) { Register-Agent $mode $saved.code $saved.token $note } else { Register-Agent $mode $null $null '' }); break }
        catch { Enable-VT; Write-Orange ('  ' + [char]0x25CC + ' ' + (T 'Подключаюсь к серверу…' 'Connecting to the server…')); Start-Sleep -Milliseconds ([int]([Math]::Min($wait, 10.0) * 1000)); $wait *= 1.7 }
    }
    $token = $r.token; $script:Token = $token; $code = $script:Code = $r.code
    if ($script:Persist) { Save-Session $code $token $mode; if (-not $saved) { Install-Autostart } elseif (-not $env:HELPER_NO_AUTOSTART) { try { $af = Join-Path $StateDir 'agent.ps1'; if (-not (Test-Path $af) -or ((Get-Date) - (Get-Item $af).LastWriteTime).TotalHours -gt 24) { Install-Autostart } } catch { } } }
    Write-AgentLog "session $code $(if ($r.resumed) { 'resumed' } else { 'started' }) persist=$($script:Persist) relay=$RELAY"
    $copied = $false; try { Set-Clipboard -Value $code; $copied = $true } catch { try { $code | clip; $copied = $true } catch { } }
    Enable-VT; Draw-Header $code $copied
    [K__BUILD__.Keys]::Relay = $RELAY; [K__BUILD__.Keys]::Token = $script:Token; $script:KeysOn = $false; try { [K__BUILD__.Keys]::Start(); $script:KeysOn = $true } catch { }
    Play-Sound 'ok'
    Start-Overlay
    Overlay-Send 'state wait'
    $k = [K__BUILD__.Keys]; $k::VT = $script:VT; $k::Overlay = $script:OverlayIn
    $k::MenuRun = (T 'Меню:  [P] пауза    [X] завершить сеанс    [Esc] назад' 'Menu:  [P] pause    [X] end the session    [Esc] back'); $k::MenuPaused = (T 'Пауза.  [R] продолжить    [X] завершить сеанс    [Esc] назад' 'Paused.  [R] continue    [X] end the session    [Esc] back')
    $k::ConfirmEnd = (T 'Завершить сеанс полностью? Код перестанет работать, понадобится новый.   [Y] да   [N] нет' 'End the session completely? The code stops working and a new one is needed.   [Y] yes   [N] no')
    $k::StPaused = (T 'Пауза: помощник ждёт. Esc — меню' 'Paused: the helper is waiting. Esc = menu'); $k::Continuing = (T 'продолжаем' 'continuing')
    $k::StRestore = ([char]0x25CC + ' ' + (T 'Ожидание помощника… он подключается по коду' 'Waiting for the helper to connect with the code…')); $k::StRestoreOk = $false
    if ($r.resumed -and $saved) { $script:OperatorSeen = $true; Overlay-Send 'state ok'; Show-Status }
    $fails = 0; $delay = 1.0
    try {
        while ($true) {
            if ([K__BUILD__.Keys]::Esc) { Write-Host ('  ' + (T 'сеанс завершён (Esc)' 'session ended (Esc)')) -ForegroundColor Yellow; return }
            if ($script:Deferred.Count) { $cmd = $script:Deferred[0]; $script:Deferred.RemoveAt(0) }
            else {
                $failed = $false; $resp = $null
                try { $resp = Api '/a/poll' $null $script:Token 22 }   # the relay answers within 15 s; anything longer is a dead connection
                catch {
                    if ([K__BUILD__.Keys]::Esc) { $script:EndRequested = $true; Write-Host ('  ' + (T 'сеанс завершён (Esc)' 'session ended (Esc)')) -ForegroundColor Yellow; return }
                    $sc = 0; try { $sc = [int]$_.Exception.Response.StatusCode } catch { }
                    if ($sc -eq 410) { Write-Host (T 'сессия закрыта (помощник завершил её)' 'session closed (ended by the helper)'); $script:FinalEnd = $true; return }
                    if ($sc -eq 401) {   # unknown to the server: it was reset or we were away too long -> register again, same code if possible
                        try {
                            $r = Register-Agent $mode $code $script:Token 'relay lost its state'; $script:Token = $r.token; $code = $script:Code = $r.code; [K__BUILD__.Keys]::Token = $script:Token; if ($script:Persist) { Save-Session $code $script:Token $mode }; Write-AgentLog 'registered again after the relay lost its state'
                            [K__BUILD__.Keys]::Token = $script:Token; Write-Host "[helper] registered again, session code: $code"
                            $fails = 0; $delay = 1.0; Net-State 'ok'; continue
                        } catch { $sc2 = 0; try { $sc2 = [int]$_.Exception.Response.StatusCode } catch { }; if ($sc2 -eq 410) { Write-Host (T 'сессия закрыта' 'session closed'); $script:FinalEnd = $true; return } }
                    }
                    $failed = $true; try { [F__BUILD__.Route]::Failed() } catch { }
                }
                if ($failed) {   # no internet, DNS, VPN switch, TLS, timeouts ... keep trying with backoff
                    $fails++
                    if ($fails -ge 2) { Net-State 'lost' }
                    Outage-Tick
                    try { [Net.ServicePointManager]::FindServicePoint([Uri]$RELAY).CloseConnectionGroup('') | Out-Null } catch { }   # drop connections that died with the old route
                    Route-Events
                    Start-Sleep -Milliseconds $(if ($fails -le 3) { 400 } else { [int]([Math]::Min($delay, 10.0) * 1000 * (0.8 + 0.4 * (Get-Random -Maximum 1.0))) })   # a route switch heals in a second or two: look again soon
                    if ($fails -gt 3) { $delay = $delay * 1.7 }; continue
                }
                if ($fails) { Outage-Over }
                $fails = 0; $delay = 1.0; Net-State 'ok'; try { [F__BUILD__.Route]::Ok() } catch { }; Route-Events
                if ($script:OperatorSeen -and $script:Phase -eq 'ok' -and ([DateTime]::UtcNow - $script:LastOp).TotalMinutes -ge 5) { $script:Phase = 'away'; Overlay-Send 'state away'; Show-Status }
                if ($resp.StatusCode -ne 200 -or -not $resp.Content) { continue }
                $cmd = $resp.Content | ConvertFrom-Json
            }
            if ($cmd.tool -eq 'bye') { Write-Host 'session closed'; $script:FinalEnd = $true; return }
            Process-Command $cmd
            if ($script:EndRequested -or [K__BUILD__.Keys]::Esc) { Write-Host ('  ' + (T 'сеанс завершён (Esc)' 'session ended (Esc)')) -ForegroundColor Yellow; return }
        }
    } finally {
        Cleanup-Children
        $final = [K__BUILD__.Keys]::Final -or $script:FinalEnd -or -not $script:Persist   # a closed window or a reboot keeps a saved session; only the user's confirmed end (or the operator's) ends it
        try { [void](Api '/a/bye' @{ final = $final } $script:Token 5) } catch { }
        Write-AgentLog $(if ($final) { 'stopped (session ended)' } else { 'stopped (session kept)' })
        if ($final) { Forget-Session }
        try { if ((Get-Clipboard -Raw).Trim() -eq $code) { Set-Clipboard -Value ' ' } } catch { }   # the session code does not stay in the clipboard
        if ($script:VT) { try { $e = [char]27; [Console]::Write("$e[r$e[$([Console]::WindowHeight);1H`n") } catch { } }   # the header's scroll region off, the prompt back at the bottom
    }
}
Start-Helper
$ErrorActionPreference = $prevEAP
