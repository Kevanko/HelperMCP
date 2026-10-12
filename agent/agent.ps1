# HelperMCP agent for Windows 10/11 (PowerShell 5.1+). Runs in memory, installs nothing.
#   [Net.ServicePointManager]::SecurityProtocol=3072; irm RELAY/h | iex
$prevEAP = $ErrorActionPreference; $ErrorActionPreference = 'Stop'  # restored at the end: iex runs in the user's session
# Windows PowerShell 5.1 started from PowerShell 7 inherits a module path pointing at 7's modules and then fails to load even
# built-in ones (ConvertTo-SecureString, ...): use 5.1's own module folders.
if ($PSVersionTable.PSVersion.Major -le 5 -and "$env:PSModulePath" -match 'PowerShell[\\/]7') { $env:PSModulePath = @((Join-Path ([Environment]::GetFolderPath('MyDocuments')) 'WindowsPowerShell\Modules'), (Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'), (Join-Path $PSHOME 'Modules')) -join ';' }
$RELAY = if ($env:HELPER_RELAY) { $env:HELPER_RELAY } else { '__RELAY__' }
$ru = (Get-Culture).TwoLetterISOLanguageName -eq 'ru'
function T($r, $e) { if ($ru) { $r } else { $e } }
$AskTools = 'run', 'start_process', 'fetch_file', 'write_file', 'click', 'move', 'drag', 'type_text', 'press_key', 'scroll', 'actions', 'mcp_start', 'mcp_call'
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

Add-Type -TypeDefinition @"
using System; using System.Collections.Concurrent; using System.Threading; using System.IO; using System.Net;
namespace K__BUILD__ {
  public static class Keys {   // one reader for the keyboard: Esc opens a menu (pause / continue / end), the other keys answer the questions
    public static ConcurrentQueue<ConsoleKey> Q = new ConcurrentQueue<ConsoleKey>();
    public static volatile bool Esc, Paused, Final, OpSeen, VT, StRestoreOk;      // Esc = the user confirmed the end
    public static string Relay, Token, MenuRun, MenuPaused, ConfirmEnd, StPaused, StRestore, Continuing;
    public static System.IO.StreamWriter Overlay;
    static string C(string code, string s) { return VT ? "\u001b[" + code + "m" + s + "\u001b[0m" : s; }
    static void Say(string s) { try { Console.WriteLine(s); } catch { } }
    static void Ov(string line) { try { var o = Overlay; if (o != null) lock (o) o.WriteLine(line); } catch { } }
    static void Status(string text, bool ok) { if (!VT) return; try { Console.Write("\u001b7\u001b[5;1H\u001b[2K  \u001b[33m\u2502 \u001b[" + (ok ? "1;32m" : "1;38;5;208m") + text + "\u001b[0m\u001b8"); } catch { } }
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
      var t = new Thread(() => { try { while (true) { var k = Console.ReadKey(true); if (k.Key == ConsoleKey.Escape) Menu(); else Q.Enqueue(k.Key); } } catch { } });
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
function Do-TaskDone($a) { $script:Phase = 'done'; Overlay-Send 'state done'; Write-Host ('  ' + [char]0x2714 + ' ' + (T 'Помощник закончил работу' 'The helper finished the work')) -ForegroundColor Green; Show-Status; @{ text = 'ok' } }
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
    $cmd = '[Console]::OutputEncoding=[Text.Encoding]::UTF8; $ProgressPreference="SilentlyContinue"; ' + $a.command
    $psi = New-Object Diagnostics.ProcessStartInfo 'powershell.exe'
    $psi.Arguments = '-NoProfile -NonInteractive -EncodedCommand ' + [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($cmd))
    $psi.RedirectStandardOutput = $true; $psi.RedirectStandardError = $true; $psi.RedirectStandardInput = $true
    $psi.UseShellExecute = $false; $psi.CreateNoWindow = $true
    $psi.StandardOutputEncoding = [Text.Encoding]::UTF8; $psi.StandardErrorEncoding = [Text.Encoding]::UTF8
    if ($script:ExtraPath.Count) { $psi.EnvironmentVariables['PATH'] = ($script:ExtraPath -join ';') + ';' + $env:PATH }
    $psi.EnvironmentVariables['PYTHONUTF8'] = '1'; $psi.EnvironmentVariables['PYTHONIOENCODING'] = 'utf-8'   # Python tools crash on non-ASCII output otherwise
    if ($a.cwd) { $psi.WorkingDirectory = $a.cwd }
    $p = [Diagnostics.Process]::Start($psi)
    $p.StandardInput.Close()
    $o = $p.StandardOutput.ReadToEndAsync(); $e = $p.StandardError.ReadToEndAsync()
    $deadline = [DateTime]::UtcNow.AddSeconds($secs)
    while (-not $p.WaitForExit(400)) {
        if ([DateTime]::UtcNow -gt $deadline) { Stop-Tree $p; return @{ text = "[timeout after ${secs}s]" } }
        Pump-Light
    }
    [void]$p.WaitForExit()
    @{ text = Clip ("[exit $($p.ExitCode)]`n" + $o.Result + $e.Result) }
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
    $max = if ($a.max_bytes) { [int]$a.max_bytes } else { 200000 }
    $fs = [IO.File]::Open($a.path, 'Open', 'Read', 'ReadWrite')
    try { $buf = New-Object byte[] ([Math]::Min($max, $fs.Length)); [void]$fs.Read($buf, 0, $buf.Length) } finally { $fs.Dispose() }
    @{ text = [Text.Encoding]::UTF8.GetString($buf) }
}
# Upload a file to the relay and return a download link for the operator.
function Do-FetchFile($a) {
    $f = (Resolve-Path -LiteralPath $a.path).Path
    $pp = $ProgressPreference; $ProgressPreference = 'SilentlyContinue'
    try {
        $resp = Invoke-WebRequest -Uri ("$RELAY/a/file?name=" + [Uri]::EscapeDataString((Split-Path $f -Leaf))) -Method Post -InFile $f `
            -Headers @{ Authorization = "Bearer $script:Token" } -ContentType 'application/octet-stream' -TimeoutSec 3600 -UseBasicParsing
    } finally { $ProgressPreference = $pp }
    $d = $resp.Content | ConvertFrom-Json
    @{ text = "$($d.url)  ($($d.size) bytes, link valid 24 h)" }
}
function Do-WriteFile($a) {
    [IO.File]::WriteAllText($a.path, $a.content, (New-Object Text.UTF8Encoding $false))
    @{ text = 'written' }
}
function Do-ListDir($a) {
    $rows = Get-ChildItem -LiteralPath $a.path -Force -ErrorAction SilentlyContinue | Select-Object -First 500 | ForEach-Object {
        '{0} {1,12} {2:yyyy-MM-dd HH:mm:ss} {3}' -f $(if ($_.PSIsContainer) { 'd' } else { '-' }), $(if ($_.PSIsContainer) { 0 } else { $_.Length }), $_.LastWriteTime, $_.Name
    }
    @{ text = ($rows -join "`n") }
}
function Do-SysInfo($a) {
    $os = Get-CimInstance Win32_OperatingSystem
    $admin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole('Administrator')
    @{ text = (@{
        os = "$($os.Caption) build $($os.BuildNumber)"; host = $env:COMPUTERNAME; user = $env:USERNAME; admin = $admin
        powershell = $PSVersionTable.PSVersion.ToString(); cpu = (Get-CimInstance Win32_Processor | Select-Object -First 1).Name
        ram_gb = [Math]::Round($os.TotalVisibleMemorySize / 1MB, 1); free_ram_gb = [Math]::Round($os.FreePhysicalMemory / 1MB, 1)
        monitors = @([Windows.Forms.Screen]::AllScreens | ForEach-Object -Begin { $i = 0 } -Process { "{0}: {1}x{2} at {3},{4}{5}" -f $i++, $_.Bounds.Width, $_.Bounds.Height, $_.Bounds.X, $_.Bounds.Y, $(if ($_.Primary) { " (primary)" } else { "" }) }); boot = $os.LastBootUpTime.ToString('s'); lang = (Get-Culture).Name; node = (& { try { (& node -v 2>$null) } catch { $null } }); uv = (& { try { (& uv --version 2>$null) } catch { $null } })
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

function Quote-Arg($s) { if ($s -match '[\s"]') { '"' + ($s -replace '"', '\"') + '"' } else { $s } }

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
    foreach ($d in @($script:NodeDir) + $script:TmpDirs) { if ($d) { Remove-Item $d -Recurse -Force -ErrorAction SilentlyContinue } }
}

# Light requests (screenshots, sysinfo, file reads) are answered even while a long command runs: the live viewer and the AI's
# screenshots never freeze behind a 5-minute install or render. Heavy ones wait their turn.
$LightTools = 'screenshot', 'watch', 'sysinfo', 'list_dir', 'read_file', 'mcp_tools'
$script:Deferred = New-Object System.Collections.ArrayList
$script:Token = $null; $script:Mode = 'full'; $script:LastPump = [DateTime]::MinValue

# ---- the friend's console: a pinned header with the session code (copied to the clipboard), Esc ends the session at any moment, a soft chime and a flashing window
# when a question is waiting, ONE key answers it (Y yes, A always for that kind of action until the session ends, N no), small steps are asked together,
# and after the answer the window focus and the pointer are put back where the AI left them (otherwise a click that was allowed is followed by typing into the wrong window).
$AskGroup = @{ click = 'input'; move = 'input'; drag = 'input'; scroll = 'input'; type_text = 'input'; press_key = 'input'; actions = 'input'; run = 'commands'; start_process = 'commands'
    write_file = 'files'; fetch_file = 'files'; mcp_start = 'mcp'; mcp_call = 'mcp' }
$script:Allowed = @{}; $script:EndRequested = $false; $script:AiAt = $null; $script:AiPos = $null; $script:AiFg = [IntPtr]::Zero; $script:VT = $false; $script:Snd = @{}
$Quiet = @{ watch = @('смотрю, что происходит на экране', 'watching the screen'); trace = @('читаю текст на экране', 'reading text on the screen'); agent_log = @('читаю журнал', 'reading the log'); screenshot = @('смотрю на экран', 'looking at the screen'); sysinfo = @('смотрю сведения о системе', 'reading system info'); list_dir = @('смотрю папку', 'listing a folder')
    read_file = @('читаю файл', 'reading a file'); mcp_tools = @('смотрю MCP', 'listing MCP tools'); mcp_stop = @('останавливаю MCP', 'stopping MCP') }
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
    if ($AskGroup[$name] -eq 'input') { return @(Steps-Of $name $a | ForEach-Object { Step-Text $_ }) }
    $pre = switch ($name) { 'run' { T 'команда: ' 'command: ' } 'start_process' { T 'запустить: ' 'start: ' } 'write_file' { T 'записать файл: ' 'write file: ' } 'fetch_file' { T 'скопировать файл: ' 'copy file: ' } 'mcp_start' { T 'запустить MCP: ' 'start MCP: ' } 'mcp_call' { T 'вызвать MCP: ' 'call MCP: ' } default { "$name " } }
    $tail = if ($a.command) { $a.command } elseif ($a.path) { $a.path } elseif ($a.name) { $a.name } else { ($a | ConvertTo-Json -Compress) }
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
        Write-AgentLog 'autostart installed'
    } catch { Write-AgentLog "autostart failed: $_" }
}
function Forget-Session {
    foreach ($f in $SessionFile, (Join-Path $StateDir 'agent.ps1')) { Remove-Item $f -Force -ErrorAction SilentlyContinue }
    try { Remove-ItemProperty -Path $RunKey -Name 'HelperMCP' -ErrorAction SilentlyContinue } catch { }
    Write-AgentLog 'session ended by the user: saved session and autostart removed'
}
function Test-Ping($h) { try { (New-Object Net.NetworkInformation.Ping).Send($h, 1200).Status -eq 'Success' } catch { $false } }
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
        Write-AgentLog ("diagnosis: class=$($d.class) gateway=$($d.gateway) ping_gw=$($d.ping_gateway) ping_inet=$($d.ping_internet) dns=$($d.dns_ok) relay_tcp=$($d.relay_tcp) vpn=$(@($d.vpn) -join ',')`n$($d.adapters)")
    }
    if ($el -ge 10 -and $script:Out.diag -and -not $script:Out.healed) { $script:Out.healed = $true; $script:Out.acts = @(Heal-Net $script:Out.diag); Write-AgentLog ('repair attempt: ' + ($script:Out.acts -join ' | ')) }
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
    try { $e = [char]27; $x = Status-Text; $col = if ($x[0] -eq 'ok') { "$e[1;32m" } else { "$e[1;38;5;208m" }; [Console]::Write("${e}7$e[5;1H$e[2K  $e[33m$([char]0x2502) $col$($x[1])$e[0m${e}8") } catch { }
}
function Draw-Header($code, $copied) {
    $e = [char]27; $bar = [string]([char]0x2500) * 56
    try { [Console]::OutputEncoding = [Text.Encoding]::UTF8 } catch { }
    try { if ($script:VT) { [Console]::Write("$e[2J$e[H") } else { Clear-Host } } catch { }
    Write-Host ('  ' + [char]0x250C + ' ' + (T 'УДАЛЁННАЯ ПОМОЩЬ' 'REMOTE HELP') + ' ' + $bar) -ForegroundColor Yellow
    Write-Host ('  ' + [char]0x2502 + ' ' + (T 'Код сессии:' 'Session code:') + '  ') -ForegroundColor Yellow -NoNewline; Write-Host " $code " -ForegroundColor Black -BackgroundColor Yellow -NoNewline
    if ($copied) { Write-Host ('   ' + [char]0x221A + ' ' + (T 'скопирован в буфер обмена' 'copied to the clipboard')) -ForegroundColor Green } else { Write-Host '' }
    Write-Host ('  ' + [char]0x2502 + ' ' + (T 'Скажи этот код тому, кто помогает.' 'Tell this code to the person who helps you.')) -ForegroundColor DarkYellow
    Write-Host ('  ' + [char]0x2502 + ' ' + (T 'Esc - завершить сеанс в любой момент' 'Esc - end the session at any time')) -ForegroundColor DarkYellow
    $x = Status-Text; Write-Host ('  ' + [char]0x2502 + ' ') -ForegroundColor Yellow -NoNewline
    if ($script:VT) { $col = if ($x[0] -eq 'ok') { "$e[1;32m" } else { "$e[1;38;5;208m" }; [Console]::WriteLine("$col$($x[1])$e[0m") } else { Write-Host $x[1] -ForegroundColor $(if ($x[0] -eq 'ok') { 'Green' } else { 'DarkYellow' }) }
    Write-Host ('  ' + [char]0x2514 + $bar + [string]([char]0x2500) * 18) -ForegroundColor Yellow
    $script:HdrDrawn = $true
    if ($script:VT) { try { $h = [Console]::WindowHeight; [Console]::Write("$e[7;${h}r$e[7;1H") } catch { } }   # the header stays on top, the log scrolls below it
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
$GuiTools = 'click', 'move', 'drag', 'scroll', 'type_text', 'press_key', 'actions'
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
    $meta = $name -in 'look', 'hold', 'task_done'
    if (-not $viewFrame -and -not $meta) {
        $script:LastOp = [DateTime]::UtcNow
        if (-not $script:OperatorSeen -or $script:Phase -ne 'ok') {
            $first = -not $script:OperatorSeen; $script:OperatorSeen = $true; $script:Phase = 'ok'; Overlay-Send 'state ok'; Show-Status
            if ($first) { Write-Host ('  ' + [char]0x25CF + ' ' + (T 'Помощник подключён' 'Helper connected')) -ForegroundColor Green }
        }
    }
    if (-not $viewFrame -and -not $meta) { Say-Step $name $a }
    $res = @{ id = $cmd.id }
    $quietCall = $Quiet.ContainsKey($name) -or $meta -or $viewFrame; if (-not $quietCall) { Overlay-Send 'busy' }
    try {
        Check-Esc
        if ([K__BUILD__.Keys]::Paused -and -not $Quiet.ContainsKey($name)) { throw 'PAUSED by the user (Esc menu). The session is kept. Do not retry now: use wait_online, then continue.' }
        if ($script:Mode -eq 'ask' -and $AskTools -contains $name) { Ask-Permission $name $a }
        Resume-State $name $a
        $fn = @{ screenshot = 'Do-Screenshot'; click = 'Do-Click'; move = 'Do-Move'; drag = 'Do-Drag'; scroll = 'Do-Scroll'; type_text = 'Do-TypeText'; press_key = 'Do-PressKey'
            run = 'Do-Run'; read_file = 'Do-ReadFile'; write_file = 'Do-WriteFile'; list_dir = 'Do-ListDir'; sysinfo = 'Do-SysInfo'
            actions = 'Do-Actions'; focus_window = 'Do-FocusWindow'; trace = 'Do-Trace'; watch = 'Do-Watch'; look = 'Do-Look'; hold = 'Do-Hold'; task_done = 'Do-TaskDone'; agent_log = 'Do-AgentLog'; fetch_file = 'Do-FetchFile'; start_process = 'Do-StartProcess'; mcp_start = 'Do-McpStart'; mcp_tools = 'Do-McpTools'; mcp_call = 'Do-McpCall'; mcp_stop = 'Do-McpStop' }[$name]
        if (-not $fn) { throw "Unknown tool $name" }
        $res.ok = $true; $res.data = & $fn $a
        Mark-State $name
    } catch { $res.ok = $false; $res.error = $_.Exception.Message }
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
    $body = @{ os = (Get-CimInstance Win32_OperatingSystem).Caption; host = $env:COMPUTERNAME; user = $env:USERNAME; mode = $mode; persist = $script:Persist; note = [string]$note }
    if ($resumeToken) { $body.resume_token = $resumeToken }   # proof that it is the same PC: the server then keeps everything it has
    if ($resume) { $body.resume = $resume }   # the server may have forgotten us (restart, long outage): ask for the same code back
    (Api '/a/register' $body $null 20).Content | ConvertFrom-Json
}

function Start-Helper {
    $mode = $env:HELPER_MODE
    if ($mode -ne 'ask' -and $mode -ne 'full') {
        $ans = Read-Host (T 'Режим: [1] спрашивать про каждое действие (рекомендуется)  [2] полный доступ' 'Mode: [1] ask before every action (recommended)  [2] full access')
        $mode = if ($ans.Trim() -eq '2') { 'full' } else { 'ask' }
    }
    $script:Mode = $mode
    $saved = if ($env:HELPER_NEW) { $null } else { Load-Session }
    if ($saved) { $script:Mode = $mode = $saved.mode; $script:Persist = $true }
    elseif ($env:HELPER_PERSIST -in '0', '1') { $script:Persist = ($env:HELPER_PERSIST -eq '1') }
    elseif (-not [Console]::IsInputRedirected) { $script:Persist = ((Read-Host (T 'Сохранять сеанс при потере интернета и после перезагрузки (код не изменится)? [Д/н]' 'Keep this session through internet loss and reboots (the code stays the same)? [Y/n]')).Trim().ToLower() -notin 'n', 'no', 'н', 'нет') }
    $note = ''
    if ($saved) { Write-Host ('  ' + (T 'Продолжаю прошлый сеанс ' 'Resuming the previous session ') + $saved.code) -ForegroundColor Yellow; $note = if ([Math]::Abs($saved.boot - (Get-BootTime)) -gt 90) { 'after a reboot' } else { 'restarted' }; Write-AgentLog "resuming session $($saved.code) ($note)" }
    $wait = 1.0
    while ($true) {   # the server can be unreachable right at the start (no internet yet, VPN still connecting): keep trying
        try { $r = $(if ($saved) { Register-Agent $mode $saved.code $saved.token $note } else { Register-Agent $mode $null $null '' }); break }
        catch { Enable-VT; Write-Orange ('  ' + [char]0x25CC + ' ' + (T 'Подключаюсь к серверу…' 'Connecting to the server…')); Start-Sleep -Milliseconds ([int]([Math]::Min($wait, 10.0) * 1000)); $wait *= 1.7 }
    }
    $token = $r.token; $script:Token = $token; $code = $r.code
    if ($script:Persist) { Save-Session $code $token $mode; if (-not $saved) { Install-Autostart } }
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
                            $r = Register-Agent $mode $code $script:Token 'relay lost its state'; $script:Token = $r.token; $code = $r.code; [K__BUILD__.Keys]::Token = $script:Token; if ($script:Persist) { Save-Session $code $script:Token $mode }; Write-AgentLog 'registered again after the relay lost its state'
                            [K__BUILD__.Keys]::Token = $script:Token; Write-Host "[helper] registered again, session code: $code"
                            $fails = 0; $delay = 1.0; Net-State 'ok'; continue
                        } catch { $sc2 = 0; try { $sc2 = [int]$_.Exception.Response.StatusCode } catch { }; if ($sc2 -eq 410) { Write-Host (T 'сессия закрыта' 'session closed'); $script:FinalEnd = $true; return } }
                    }
                    $failed = $true
                }
                if ($failed) {   # no internet, DNS, VPN switch, TLS, timeouts ... keep trying with backoff
                    $fails++
                    if ($fails -ge 2) { Net-State 'lost' }
                    Outage-Tick
                    try { [Net.ServicePointManager]::FindServicePoint([Uri]$RELAY).CloseConnectionGroup('') | Out-Null } catch { }   # drop connections that died with the old route
                    Start-Sleep -Milliseconds ([int]([Math]::Min($delay, 10.0) * 1000 * (0.8 + 0.4 * (Get-Random -Maximum 1.0))))
                    $delay = $delay * 1.7; continue
                }
                if ($fails) { Outage-Over }
                $fails = 0; $delay = 1.0; Net-State 'ok'
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
