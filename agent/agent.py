#!/usr/bin/env python3
"""HelperMCP agent for Linux. Python 3 stdlib only (GTK via python3-gi is used if present, for the overlay).
Run: python3 <(curl -fsSL RELAY/p)"""
import base64, ctypes, ctypes.util, getpass, json, locale, os, platform, queue, shutil, signal, socket
import subprocess, sys, tarfile, tempfile, threading, time
import urllib.request, urllib.error

RELAY = os.environ.get("HELPER_RELAY") or "__RELAY__"
RU = (locale.getlocale()[0] or os.environ.get("LANG", "")).lower().startswith("ru")
T = {
    "banner": ("УДАЛЁННАЯ ПОМОЩЬ. Код сессии:", "REMOTE HELP. Session code:"),
    "tell": ("Назови этот код тому, кто тебе помогает. Закрой окно или Ctrl+C - доступ пропадёт.",
             "Give this code to your helper. Close this window or press Ctrl+C to stop."),
    "mode": ("Режим: [1] спрашивать про каждое действие (рекомендуется)  [2] полный доступ: ",
             "Mode: [1] ask before every action (recommended)  [2] full access: "),
    "allow": ("Разрешить? [y/N] ", "Allow? [y/N] "),
    "overlay": ("Удалённое управление", "Remote control"),
}
t = lambda k: T[k][0 if RU else 1]
ASK_TOOLS = {"run", "write_file", "click", "type_text", "press_key", "scroll", "mcp_start", "mcp_call"}
MAX_OUT = 100_000
NODE_VERSION, NODE_MIN = "v22.11.0", 20   # Playwright & co. need Node >= 20
NODE_DIR = NODE_BIN = None                # temp dir of the portable Node, if we had to download one
CHILDREN = {}                             # name -> Child (other MCP servers running on this PC)
TMP = []                                  # temp files/dirs removed on exit
SCALE = 1.0                               # screenshot px -> real px
GUI = {"type": None}                      # filled by find_gui()
OVERLAY_PROC = None


# ---- graphical session --------------------------------------------------------------------
def find_gui():
    """The agent often runs from SSH/tty: borrow DISPLAY & co. from the user's desktop session."""
    keys = ("DISPLAY", "XAUTHORITY", "WAYLAND_DISPLAY", "XDG_RUNTIME_DIR", "DBUS_SESSION_BUS_ADDRESS", "XDG_SESSION_TYPE")
    if not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")) and sys.platform.startswith("linux"):
        uid = os.getuid()
        for name in ("gnome-shell", "plasmashell", "kwin_x11", "kwin_wayland", "xfce4-session", "cinnamon", "mate-session",
                     "Xorg", "Xwayland", "sway", "mutter", "gnome-session-binary"):
            p = subprocess.run(["pgrep", "-u", str(uid), "-x", name], capture_output=True, text=True)
            for pid in p.stdout.split():
                try:
                    env = dict(kv.split("=", 1) for kv in open(f"/proc/{pid}/environ").read().split("\0") if "=" in kv)
                except OSError:
                    continue
                if env.get("DISPLAY") or env.get("WAYLAND_DISPLAY"):
                    os.environ.update({k: env[k] for k in keys if k in env})
                    break
            if os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY"):
                break
    wl = os.environ.get("XDG_SESSION_TYPE") == "wayland" or (os.environ.get("WAYLAND_DISPLAY") and not os.environ.get("DISPLAY"))
    GUI["type"] = None if not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY")) else ("wayland" if wl else "x11")
    return GUI["type"]


def need_x11():
    if GUI["type"] == "x11": return
    if GUI["type"] == "wayland":
        raise RuntimeError("This is a Wayland session: mouse/keyboard control is not possible. "
                           "Ask the user to log in with 'Ubuntu on Xorg' (gear icon on the login screen). "
                           "Commands, files, screenshots and browsers still work.")
    raise RuntimeError("No graphical session found (nobody is logged in to a desktop).")


_X = {}
def xlib():
    if _X: return _X
    need_x11()
    x11 = ctypes.CDLL(ctypes.util.find_library("X11") or "libX11.so.6")
    xt = ctypes.CDLL(ctypes.util.find_library("Xtst") or "libXtst.so.6")
    V, UL, I, UI = ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_uint
    x11.XOpenDisplay.restype, x11.XOpenDisplay.argtypes = V, [ctypes.c_char_p]
    x11.XStringToKeysym.restype, x11.XStringToKeysym.argtypes = UL, [ctypes.c_char_p]
    x11.XKeysymToKeycode.restype, x11.XKeysymToKeycode.argtypes = ctypes.c_ubyte, [V, UL]
    x11.XGetKeyboardMapping.restype, x11.XGetKeyboardMapping.argtypes = ctypes.POINTER(UL), [V, ctypes.c_ubyte, I, ctypes.POINTER(I)]
    x11.XChangeKeyboardMapping.argtypes = [V, I, I, ctypes.POINTER(UL), I]
    x11.XDisplayKeycodes.argtypes = [V, ctypes.POINTER(I), ctypes.POINTER(I)]
    x11.XFree.argtypes, x11.XSync.argtypes, x11.XFlush.argtypes = [V], [V, I], [V]
    xt.XTestFakeKeyEvent.argtypes = [V, UI, I, UL]
    xt.XTestFakeButtonEvent.argtypes = [V, UI, I, UL]
    xt.XTestFakeMotionEvent.argtypes = [V, I, I, I, UL]
    d = x11.XOpenDisplay(None)
    if not d: raise RuntimeError(f"Cannot open X display {os.environ.get('DISPLAY')} (XAUTHORITY={os.environ.get('XAUTHORITY')})")
    _X.update(x=x11, t=xt, d=d)
    return _X


def sync(X): X["x"].XSync(X["d"], 0)


# ---- screenshots ------------------------------------------------------------------------------
def capture_file(d):
    out_png, out_jpg = os.path.join(d, "s.png"), os.path.join(d, "s.jpg")
    if GUI["type"] == "wayland":
        tries = [("grim", ["grim", out_png], out_png), ("gnome-screenshot", ["gnome-screenshot", "-f", out_png], out_png),
                 ("spectacle", ["spectacle", "-b", "-n", "-o", out_png], out_png)]
    else:
        tries = [("scrot", ["scrot", "-o", "-q", "80", out_jpg], out_jpg), ("maim", ["maim", out_png], out_png),
                 ("import", ["import", "-window", "root", out_png], out_png),
                 ("gnome-screenshot", ["gnome-screenshot", "-f", out_png], out_png)]
    for prog, cmd, out in tries:
        if shutil.which(prog):
            subprocess.run(cmd, capture_output=True, timeout=20)
            if os.path.exists(out) and os.path.getsize(out) > 0: return out
    # last resort without any tool: GDK (X11 only)
    if GUI["type"] == "x11":
        try:
            import gi; gi.require_version("Gdk", "3.0"); from gi.repository import Gdk
            w = Gdk.get_default_root_window(); pb = Gdk.pixbuf_get_from_window(w, 0, 0, w.get_width(), w.get_height())
            pb.savev(out_png, "png", [], []); return out_png
        except Exception: pass
    raise RuntimeError("No screenshot tool. Ask the user to run: sudo apt install scrot" if GUI["type"] != "wayland"
                       else "No Wayland screenshot tool. Ask the user to run: sudo apt install gnome-screenshot")


def screenshot(_):
    global SCALE
    if not GUI["type"]: raise RuntimeError("No graphical session found (nobody is logged in to a desktop).")
    d = tempfile.mkdtemp()
    try:
        path = capture_file(d)
        try:  # downscale to <=1920 px wide (cheaper for the AI), remember the factor for click coordinates
            import gi; gi.require_version("GdkPixbuf", "2.0"); from gi.repository import GdkPixbuf
            pb = GdkPixbuf.Pixbuf.new_from_file(path); w = pb.get_width()
            SCALE = max(1.0, w / 1920)
            if SCALE > 1: pb = pb.scale_simple(1920, int(pb.get_height() / SCALE), GdkPixbuf.InterpType.BILINEAR)
            _, buf = pb.save_to_bufferv("jpeg", ["quality"], ["70"])
            return {"image": base64.b64encode(buf).decode(), "mime": "image/jpeg"}
        except Exception:
            SCALE = 1.0
            with open(path, "rb") as f:
                return {"image": base64.b64encode(f.read()).decode(), "mime": "image/jpeg" if path.endswith("jpg") else "image/png"}
    finally:
        shutil.rmtree(d, ignore_errors=True)


# ---- mouse & keyboard (X11 XTest through ctypes: no xdotool needed) ---------------------------------
def click(a):
    X = xlib(); x, y = int(a["x"] * SCALE), int(a["y"] * SCALE)
    X["t"].XTestFakeMotionEvent(X["d"], -1, x, y, 0); sync(X); time.sleep(0.05)
    b = {"left": 1, "middle": 2, "right": 3}[a.get("button", "left")]
    for _ in range(2 if a.get("double") else 1):
        X["t"].XTestFakeButtonEvent(X["d"], b, 1, 0); X["t"].XTestFakeButtonEvent(X["d"], b, 0, 0); sync(X); time.sleep(0.06)
    return {"text": "ok"}


def scroll(a):
    X = xlib()
    if "x" in a and "y" in a: X["t"].XTestFakeMotionEvent(X["d"], -1, int(a["x"] * SCALE), int(a["y"] * SCALE), 0)
    n = int(a.get("amount", 3)); b = 5 if n > 0 else 4   # positive = down
    for _ in range(abs(n)):
        X["t"].XTestFakeButtonEvent(X["d"], b, 1, 0); X["t"].XTestFakeButtonEvent(X["d"], b, 0, 0)
    sync(X); return {"text": "ok"}


MODS = {"ctrl": "Control_L", "control": "Control_L", "alt": "Alt_L", "shift": "Shift_L", "win": "Super_L", "windows": "Super_L",
        "super": "Super_L", "meta": "Super_L"}
KEYS = {"enter": "Return", "return": "Return", "esc": "Escape", "escape": "Escape", "backspace": "BackSpace", "del": "Delete",
        "delete": "Delete", "pageup": "Prior", "pagedown": "Next", "space": "space", "tab": "Tab", "home": "Home", "end": "End",
        "left": "Left", "right": "Right", "up": "Up", "down": "Down", "insert": "Insert"}


def keysym(name):
    X = xlib(); n = MODS.get(name.lower()) or KEYS.get(name.lower()) or name
    for cand in (n, n.capitalize(), n.upper(), n.lower()):
        ks = X["x"].XStringToKeysym(cand.encode())
        if ks: return ks
    raise RuntimeError(f"Unknown key '{name}'")


def press_key(a):
    X = xlib(); codes = []
    for k in a["keys"].split("+"):
        kc = X["x"].XKeysymToKeycode(X["d"], keysym(k.strip()))
        if not kc: raise RuntimeError(f"Key '{k}' is not on this keyboard layout")
        codes.append(kc)
    for kc in codes: X["t"].XTestFakeKeyEvent(X["d"], kc, 1, 0)
    for kc in reversed(codes): X["t"].XTestFakeKeyEvent(X["d"], kc, 0, 0)
    sync(X); return {"text": "ok"}


def type_text(a):
    """Type any Unicode: park each character's keysym on a spare keycode, press it, restore the keymap (what xdotool does)."""
    X = xlib(); x11, d = X["x"], X["d"]
    lo, hi, per = ctypes.c_int(), ctypes.c_int(), ctypes.c_int()
    x11.XDisplayKeycodes(d, ctypes.byref(lo), ctypes.byref(hi))
    m = x11.XGetKeyboardMapping(d, lo.value, hi.value - lo.value + 1, ctypes.byref(per))
    spare = hi.value
    for i in range(hi.value - lo.value, -1, -1):
        if all(m[i * per.value + j] == 0 for j in range(per.value)): spare = lo.value + i; break
    x11.XFree(m)
    arr = (ctypes.c_ulong * per.value)
    try:
        for ch in a["text"]:
            ks = {"\n": 0xFF0D, "\t": 0xFF09}.get(ch, ord(ch) if ord(ch) < 0x100 else 0x01000000 + ord(ch))
            x11.XChangeKeyboardMapping(d, spare, per.value, arr(*([ks] * per.value)), 1); sync(X); time.sleep(0.012)
            X["t"].XTestFakeKeyEvent(d, spare, 1, 0); X["t"].XTestFakeKeyEvent(d, spare, 0, 0); sync(X); time.sleep(0.012)
    finally:
        x11.XChangeKeyboardMapping(d, spare, per.value, arr(*([0] * per.value)), 1); sync(X)
    return {"text": "ok"}


# ---- shell & files ------------------------------------------------------------------------------
def sh(cmd, timeout=60):
    p = subprocess.run(cmd, shell=isinstance(cmd, str), capture_output=True, text=True, timeout=timeout, errors="replace")
    return p.returncode, (p.stdout + p.stderr)


def clip(s):
    return s if len(s) <= MAX_OUT else s[:MAX_OUT] + f"\n...[truncated {len(s) - MAX_OUT} chars]"


def run(a):
    try:
        code, out = sh(["bash", "-c", a["command"]], a.get("timeout_s", 60))
    except subprocess.TimeoutExpired as e:
        return {"text": f"[timeout after {a.get('timeout_s', 60)}s]\n" + clip(str(e.stdout or ""))}
    return {"text": f"[exit {code}]\n" + clip(out)}


def read_file(a):
    with open(os.path.expanduser(a["path"]), "rb") as f:
        return {"text": f.read(a.get("max_bytes", 200_000)).decode("utf-8", "replace")}


def write_file(a):
    with open(os.path.expanduser(a["path"]), "w", encoding="utf-8") as f:
        f.write(a["content"])
    return {"text": "written"}


def list_dir(a):
    rows = []
    for e in sorted(os.scandir(os.path.expanduser(a["path"])), key=lambda e: e.name)[:500]:
        try:
            st = e.stat(follow_symlinks=False)
            rows.append(f"{'d' if e.is_dir() else '-'} {st.st_size:>12} {time.strftime('%F %T', time.localtime(st.st_mtime))} {e.name}")
        except OSError:
            rows.append(f"? {e.name}")
    return {"text": "\n".join(rows)}


def sysinfo(_):
    return {"text": json.dumps({
        "os": platform.platform(), "host": socket.gethostname(), "user": getpass.getuser(),
        "python": platform.python_version(), "cpus": os.cpu_count(), "root": os.geteuid() == 0,
        "display": os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY"), "session": GUI["type"],
        "node": sh("node -v 2>/dev/null")[1].strip() or None,
        "uptime": sh("uptime -p")[1].strip(), "mem": sh("free -h | sed -n 2p")[1].strip(), "disk": sh("df -h / | tail -1")[1].strip(),
    }, indent=2, ensure_ascii=False)}


# ---- other MCP servers on this PC -----------------------------------------------------------------
def node_major():
    try: return int(sh(["node", "-v"], 10)[1].strip().lstrip("v").split(".")[0])
    except Exception: return 0


def ensure_node(command):
    """npx/node/npm missing or older than 20? Download a portable Node into a temp dir (removed on exit)."""
    global NODE_DIR, NODE_BIN
    if os.path.basename(command) not in ("npx", "node", "npm") or NODE_BIN or node_major() >= NODE_MIN:
        return
    arch = {"x86_64": "x64", "amd64": "x64", "aarch64": "arm64", "arm64": "arm64"}.get(platform.machine().lower())
    osn = {"Linux": "linux", "Darwin": "darwin"}.get(platform.system())
    if not (arch and osn): raise RuntimeError("Node.js >= 20 is missing and no portable build exists for this system")
    base = f"node-{NODE_VERSION}-{osn}-{arch}"
    NODE_DIR = tempfile.mkdtemp(prefix="helpermcp-node-"); TMP.append(NODE_DIR)
    print("[helper] downloading portable Node.js ...", flush=True)
    pkg = os.path.join(NODE_DIR, "n.tar.xz")
    urllib.request.urlretrieve(f"https://nodejs.org/dist/{NODE_VERSION}/{base}.tar.xz", pkg)
    with tarfile.open(pkg) as tf: tf.extractall(NODE_DIR)
    os.remove(pkg)
    NODE_BIN = os.path.join(NODE_DIR, base, "bin")


def playwright_preset(a):
    """command="playwright": a real, visible browser with sound, like a normal Playwright MCP on a desktop."""
    exe = next((p for n in ("google-chrome", "google-chrome-stable", "chromium", "chromium-browser", "microsoft-edge", "brave-browser")
                for p in [shutil.which(n)] if p), None)
    opts = {"headless": False, "chromiumSandbox": True, "ignoreDefaultArgs": ["--mute-audio", "--disable-blink-features=AutomationControlled"], "args": ["--autoplay-policy=no-user-gesture-required"]}
    if exe: opts["executablePath"] = exe
    d = tempfile.mkdtemp(prefix="helpermcp-pw-"); TMP.append(d)
    cfg = os.path.join(d, "config.json")
    with open(cfg, "w") as f: json.dump({"browser": {"browserName": "chromium", "launchOptions": opts}}, f)
    return "npx", ["-y", "@playwright/mcp@latest", "--config", cfg] + list(a.get("args") or [])


class Child:
    """One stdio MCP server running on this PC."""
    def __init__(self, command, args, env):
        e = dict(os.environ, **(env or {}))
        if NODE_BIN:
            e["PATH"] = NODE_BIN + os.pathsep + e.get("PATH", "")
            if command in ("npx", "node", "npm"): command = os.path.join(NODE_BIN, command)
        self.p = subprocess.Popen([command] + list(args or []), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, env=e, text=True, encoding="utf-8", bufsize=1)
        self.q, self.n, self.tools, self.err = queue.Queue(), 0, [], []
        threading.Thread(target=self._read, daemon=True).start()
        threading.Thread(target=lambda: [self.err.append(l) for l in self.p.stderr], daemon=True).start()

    def why(self):  # last stderr lines, for error messages
        return "".join(self.err[-8:]).strip()[:1500]

    def _read(self):
        for line in self.p.stdout: self.q.put(line)
        self.q.put(None)

    def rpc(self, method, params=None, timeout=60, notify=False):
        msg = {"jsonrpc": "2.0", "method": method}
        if params is not None: msg["params"] = params
        if not notify:
            self.n += 1; msg["id"] = self.n
        self.p.stdin.write(json.dumps(msg) + "\n"); self.p.stdin.flush()
        if notify: return None
        end = time.time() + timeout
        while True:
            try: line = self.q.get(timeout=max(0.1, end - time.time()))
            except queue.Empty: raise RuntimeError(f"MCP server timed out on {method}. {self.why()}")
            if line is None: raise RuntimeError(f"MCP server exited. {self.why()}")
            try: m = json.loads(line)
            except ValueError: continue
            if m.get("id") == self.n and "method" not in m:
                if "error" in m: raise RuntimeError(m["error"].get("message", str(m["error"])))
                return m["result"]


def mcp_start(a):
    name, command, args = a["name"], a["command"], a.get("args")
    if name in CHILDREN: raise RuntimeError(f"'{name}' is already running")
    if command == "playwright": command, args = playwright_preset(a)
    ensure_node(command)
    c = Child(command, args, a.get("env"))
    try:
        c.rpc("initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                             "clientInfo": {"name": "helpermcp", "version": "0.3"}}, timeout=240)
        c.rpc("notifications/initialized", notify=True)
        c.tools = c.rpc("tools/list", timeout=60)["tools"]
    except Exception:
        c.p.kill(); raise
    CHILDREN[name] = c
    return {"text": f"{name}: {len(c.tools)} tools: " + ", ".join(t["name"] for t in c.tools)}


def mcp_tools(_):
    return {"text": json.dumps([{"server": n, **t} for n, c in CHILDREN.items() for t in c.tools])}


def mcp_call(a):
    c = CHILDREN.get(a["server"])
    if not c: raise RuntimeError(f"No MCP server '{a['server']}'. Start it with mcp_start.")
    r = c.rpc("tools/call", {"name": a["tool"], "arguments": a.get("arguments") or {}}, timeout=110)
    return {"content": r.get("content", []), "isError": r.get("isError", False)}


def mcp_stop(a):
    c = CHILDREN.pop(a["name"], None)
    if c: c.p.kill()
    return {"text": "stopped" if c else "not running"}


# ---- "remote control" overlay: glowing screen edges + a label on top (like Codex) ----------------------
OVERLAY = r'''
import os, sys, math
import gi, cairo
gi.require_version("Gtk", "3.0"); gi.require_version("Gdk", "3.0")
from gi.repository import Gtk, Gdk, GLib
label, ppid = sys.argv[1], int(sys.argv[2])
R, G, B = 0x4C / 255, 0x8D / 255, 0xFF / 255
wins = []
def make(mon):                       # one overlay window per monitor: every screen the helper can see is marked
    g = mon.get_geometry(); W, H = g.width, g.height
    w = Gtk.Window(type=Gtk.WindowType.POPUP)
    w.set_app_paintable(True)
    vis = w.get_screen().get_rgba_visual()
    if vis: w.set_visual(vis)
    w.set_default_size(W, H); w.move(g.x, g.y); w.set_keep_above(True); w.set_accept_focus(False)
    def draw(_, cr):
        cr.set_operator(cairo.OPERATOR_SOURCE); cr.set_source_rgba(0, 0, 0, 0); cr.paint(); cr.set_operator(cairo.OPERATOR_OVER)
        s = 70
        for (x0, y0, x1, y1, rx, ry, rw, rh) in ((0, 0, s, 0, 0, 0, s, H), (W, 0, W - s, 0, W - s, 0, s, H),
                                                (0, 0, 0, s, 0, 0, W, s), (0, H, 0, H - s, 0, H - s, W, s)):
            gr = cairo.LinearGradient(x0, y0, x1, y1)
            gr.add_color_stop_rgba(0, R, G, B, 0.55); gr.add_color_stop_rgba(0.35, R, G, B, 0.18); gr.add_color_stop_rgba(1, R, G, B, 0)
            cr.set_source(gr); cr.rectangle(rx, ry, rw, rh); cr.fill()
        cr.select_font_face("Sans", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_BOLD); cr.set_font_size(15)
        tw = cr.text_extents(label).x_advance; pw, ph = tw + 54, 34; px, py, r = (W - pw) / 2, 12, 17
        cr.new_sub_path(); cr.arc(px + pw - r, py + r, r, -math.pi / 2, math.pi / 2); cr.arc(px + r, py + r, r, math.pi / 2, 3 * math.pi / 2); cr.close_path()
        cr.set_source_rgba(0.06, 0.09, 0.14, 0.88); cr.fill_preserve(); cr.set_source_rgba(R, G, B, 0.9); cr.set_line_width(1.5); cr.stroke()
        cr.arc(px + 20, py + ph / 2, 5, 0, 2 * math.pi); cr.set_source_rgba(R, G, B, 1); cr.fill()
        cr.set_source_rgba(1, 1, 1, 1); cr.move_to(px + 34, py + ph / 2 + 5); cr.show_text(label)
    w.connect("draw", draw); w.show_all()
    w.get_window().input_shape_combine_region(cairo.Region(), 0, 0)   # clicks go straight through
    wins.append(w)
dsp = Gdk.Display.get_default()
for i in range(dsp.get_n_monitors()): make(dsp.get_monitor(i))
def tick():
    try: os.kill(ppid, 0)            # agent gone (window closed, crash): remove the overlay too
    except OSError: Gtk.main_quit(); return False
    for w in wins: w.get_window().raise_()
    return True
GLib.timeout_add(1500, tick)
Gtk.main()
'''


def overlay_start():
    global OVERLAY_PROC
    if os.environ.get("HELPER_NO_OVERLAY") or not GUI["type"]: return
    try:
        OVERLAY_PROC = subprocess.Popen([sys.executable, "-c", OVERLAY, t("overlay"), str(os.getpid())],
                                        stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception: pass


def cleanup():
    for c in CHILDREN.values():
        try: c.p.kill()
        except Exception: pass
    if OVERLAY_PROC:
        try: OVERLAY_PROC.kill()
        except Exception: pass
    for p in TMP: shutil.rmtree(p, ignore_errors=True)


# ---- relay protocol -----------------------------------------------------------------------------------
def api(path, data=None, token=None, timeout=40):
    req = urllib.request.Request(RELAY + path, method="POST" if data is not None else "GET")
    if token: req.add_header("Authorization", "Bearer " + token)
    if data is not None:
        req.add_header("Content-Type", "application/json"); data = json.dumps(data).encode()
    with urllib.request.urlopen(req, data, timeout=timeout) as r:
        raw = r.read()
        return (r.status, json.loads(raw) if raw else None)


TOOLS = dict(screenshot=screenshot, press_key=press_key, click=click, scroll=scroll, type_text=type_text, run=run,
             read_file=read_file, write_file=write_file, list_dir=list_dir, sysinfo=sysinfo,
             mcp_start=mcp_start, mcp_tools=mcp_tools, mcp_call=mcp_call, mcp_stop=mcp_stop)


def main():
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0)); signal.signal(signal.SIGHUP, lambda *_: sys.exit(0))  # run cleanup()
    find_gui()
    mode = os.environ.get("HELPER_MODE")
    if mode not in ("ask", "full"):
        mode = "full" if input(t("mode")).strip() == "2" else "ask"
    _, reg = api("/a/register", {"os": platform.platform(), "host": socket.gethostname(), "user": getpass.getuser(), "mode": mode})
    token = reg["token"]
    print(f"\n  {t('banner')}  {reg['code']}\n  {t('tell')}\n", flush=True)
    overlay_start()
    try:
        while True:
            try:
                status, cmd = api("/a/poll", token=token, timeout=40)
            except urllib.error.HTTPError as e:
                if e.code in (401, 410): print("session closed"); return
                time.sleep(3); continue
            except (urllib.error.URLError, OSError, TimeoutError):
                time.sleep(3); continue
            if status != 200 or not cmd: continue
            name, args = cmd["tool"], cmd["args"]
            if name == "bye": print("session closed"); return
            print(f"[helper] {name} {json.dumps(args, ensure_ascii=False)[:200]}", flush=True)
            res = {"id": cmd["id"]}
            try:
                if mode == "ask" and name in ASK_TOOLS and input(t("allow")).strip().lower() not in ("y", "yes", "д", "да"):
                    raise RuntimeError("User denied this action.")
                res.update(ok=True, data=TOOLS[name](args))
            except Exception as e:  # report every failure to the operator
                res.update(ok=False, error=f"{type(e).__name__}: {e}")
            try: api("/a/result", res, token)
            except Exception: pass
    except KeyboardInterrupt:
        pass
    finally:
        cleanup()
        try: api("/a/bye", {}, token, timeout=5)
        except Exception: pass


if __name__ == "__main__":
    main()
