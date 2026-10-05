#!/usr/bin/env python3
"""HelperMCP agent for Linux. Python 3 stdlib only (GTK via python3-gi is used if present, for the overlay).
Run: python3 <(curl -fsSL RELAY/p)"""
import base64, ctypes, ctypes.util, getpass, gzip, hashlib, json, math, random, locale, os, platform, queue, shutil, signal, socket
import subprocess, sys, tarfile, tempfile, threading, time
import urllib.parse, urllib.request, urllib.error
from concurrent.futures import ThreadPoolExecutor

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
    "lost": ("Связь потеряна, переподключение…", "Connection lost, reconnecting…"),
}
t = lambda k: T[k][0 if RU else 1]
ASK_TOOLS = {"run", "start_process", "fetch_file", "write_file", "click", "move", "drag", "type_text", "press_key", "scroll", "mcp_start", "mcp_call"}
MAX_OUT = 100_000
NODE_VERSION, NODE_MIN = "v22.11.0", 20   # Playwright & co. need Node >= 20
NODE_DIR = NODE_BIN = None                # temp dir of the portable Node, if we had to download one
EXTRA_PATH = []                           # dirs of portable runtimes (node, uv) put in front of PATH for everything we start
STARTED = []                              # processes launched with start_process (listed by sysinfo, left running on exit)
CHILDREN = {}                             # name -> Child (other MCP servers running on this PC)
TMP = []                                  # temp files/dirs removed on exit
SCALE = 1.0                               # screenshot px -> real px
ORIGIN = (0, 0)                           # real px of the screenshot's top-left corner (non-zero for a single monitor)
GUI = {"type": None}                      # filled by find_gui()
OVERLAY_PROC = None
TOKEN = None                              # this agent's relay token (set in main)


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
    x11.XDefaultRootWindow.restype, x11.XDefaultRootWindow.argtypes = UL, [V]
    x11.XQueryPointer.argtypes = [V, UL, ctypes.POINTER(UL), ctypes.POINTER(UL)] + [ctypes.POINTER(I)] * 4 + [ctypes.POINTER(UI)]
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


def monitors():
    """[(x, y, w, h)] of every screen, via GDK; empty if unknown."""
    try:
        import gi; gi.require_version("Gdk", "3.0"); from gi.repository import Gdk
        d = Gdk.Display.get_default()
        return [(g.x, g.y, g.width, g.height) for g in (d.get_monitor(i).get_geometry() for i in range(d.get_n_monitors()))]
    except Exception:
        return []


def screenshot(a):
    global SCALE, ORIGIN
    a = a or {}
    if not GUI["type"]: raise RuntimeError("No graphical session found (nobody is logged in to a desktop).")
    mons, want, view = monitors(), a.get("monitor"), bool(a.get("view"))   # view: the live viewer's frame, must not change click coordinates
    cap, qual = int(a.get("max_width") or (1280 if view else 1920)), int(a.get("quality") or (65 if view else 70))
    if want is not None and not (0 <= int(want) < len(mons)): raise RuntimeError(f"No monitor {want}. Monitors: {mons}")
    d = tempfile.mkdtemp()
    try:
        path = capture_file(d)
        try:  # crop to one monitor if asked, downscale, remember offset+factor for click coordinates
            import gi; gi.require_version("GdkPixbuf", "2.0"); from gi.repository import GdkPixbuf
            pb = GdkPixbuf.Pixbuf.new_from_file(path); org = (0, 0)
            if want is not None:
                x, y, w, h = mons[int(want)]; pb = pb.new_subpixbuf(x, y, w, h); org = (x, y)
            w = pb.get_width(); sc = max(1.0, w / cap)
            if sc > 1: pb = pb.scale_simple(cap, int(pb.get_height() / sc), GdkPixbuf.InterpType.BILINEAR)
            if not view: SCALE, ORIGIN = sc, org
            _, buf = pb.save_to_bufferv("jpeg", ["quality"], [str(qual)]); mime = "image/jpeg"
        except Exception:
            if not view: SCALE, ORIGIN = 1.0, (0, 0)
            with open(path, "rb") as f: buf = f.read()
            mime = "image/jpeg" if path.endswith("jpg") else "image/png"
        h = hashlib.md5(buf).hexdigest()
        if a.get("prev") and a["prev"] == h: return {"same": True, "h": h}   # nothing changed: send nothing
        return {"jpeg": bytes(buf), "mime": mime, "h": h}
    finally:
        shutil.rmtree(d, ignore_errors=True)


# ---- mouse & keyboard (X11 XTest through ctypes: no xdotool needed) ---------------------------------
def pointer_pos():
    X = xlib(); x11 = X["x"]
    r, c = ctypes.c_ulong(), ctypes.c_ulong(); rx, ry, wx, wy, mk = ctypes.c_int(), ctypes.c_int(), ctypes.c_int(), ctypes.c_int(), ctypes.c_uint()
    x11.XQueryPointer(X["d"], x11.XDefaultRootWindow(X["d"]), ctypes.byref(r), ctypes.byref(c), ctypes.byref(rx), ctypes.byref(ry), ctypes.byref(wx), ctypes.byref(wy), ctypes.byref(mk))
    return rx.value, ry.value


def glide(x, y, dur=None):
    """Move the real pointer like a hand would: eased, about 60 steps/s, speed depends on the distance (the overlay cursor follows it)."""
    X = xlib(); cx, cy = pointer_pos(); dist = math.hypot(x - cx, y - cy)
    if dist < 2: return
    dur = dur or min(0.7, 0.14 + dist * 0.00034)
    n = max(4, int(dur / 0.016))
    for i in range(1, n + 1):
        p = i / n; k = 4 * p ** 3 if p < 0.5 else 1 - (-2 * p + 2) ** 3 / 2     # ease in-out cubic
        X["t"].XTestFakeMotionEvent(X["d"], -1, int(round(cx + (x - cx) * k)), int(round(cy + (y - cy) * k)), 0); sync(X); time.sleep(dur / n)


def _target(a, kx="x", ky="y"):
    return int(a[kx] * SCALE) + ORIGIN[0], int(a[ky] * SCALE) + ORIGIN[1]


def move(a):
    xlib(); overlay_send("active"); x, y = _target(a); glide(x, y); return {"text": "ok"}


def click(a):
    X = xlib(); x, y = _target(a); btn = a.get("button", "left"); b = {"left": 1, "middle": 2, "right": 3}[btn]
    overlay_send("active"); glide(x, y); time.sleep(0.05)
    for i in range(2 if a.get("double") else 1):
        if i == 0: overlay_send("pre"); time.sleep(0.08)
        overlay_send(f"click {x} {y} {btn}")
        X["t"].XTestFakeButtonEvent(X["d"], b, 1, 0); sync(X); time.sleep(0.08)
        X["t"].XTestFakeButtonEvent(X["d"], b, 0, 0); sync(X); time.sleep(0.1)
    return {"text": "ok"}


def drag(a):
    """Press at (x,y), glide to (x2,y2) with the button held, release (moving windows, selecting, sliders ...)."""
    X = xlib(); x1, y1 = _target(a); x2, y2 = _target(a, "x2", "y2"); b = {"left": 1, "middle": 2, "right": 3}[a.get("button", "left")]
    overlay_send("active"); glide(x1, y1); time.sleep(0.06); overlay_send("pre"); time.sleep(0.08)
    X["t"].XTestFakeButtonEvent(X["d"], b, 1, 0); sync(X); overlay_send(f"down {x1} {y1}"); time.sleep(0.12)
    glide(x2, y2, min(1.4, 0.3 + math.hypot(x2 - x1, y2 - y1) * 0.0007)); time.sleep(0.1)
    X["t"].XTestFakeButtonEvent(X["d"], b, 0, 0); sync(X); overlay_send(f"up {x2} {y2}")
    return {"text": "ok"}


def scroll(a):
    X = xlib(); overlay_send("active")
    if "x" in a and "y" in a: x, y = _target(a); glide(x, y)
    n = int(a.get("amount", 3)); b = 5 if n > 0 else 4   # positive = down
    overlay_send(f"scroll {n}")
    for _ in range(abs(n)):
        X["t"].XTestFakeButtonEvent(X["d"], b, 1, 0); X["t"].XTestFakeButtonEvent(X["d"], b, 0, 0); sync(X); time.sleep(0.04)
    return {"text": "ok"}


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
    overlay_send("typing"); sync(X); return {"text": "ok"}


def type_text(a):
    """Type any Unicode: park each character's keysym on a spare keycode, press it, restore the keymap (what xdotool does)."""
    X = xlib(); x11, d = X["x"], X["d"]; overlay_send("typing")
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


def with_path(env=None):
    e = dict(os.environ, PYTHONUTF8="1", **(env or {}))
    if EXTRA_PATH: e["PATH"] = os.pathsep.join(EXTRA_PATH + [e.get("PATH", "")])
    return e


def ensure_for(text, args=None):
    """A command mentions uv/uvx/npx/npm/node that is not installed? Fetch the portable one first (as if it had always been there)."""
    import re
    words = set(re.findall(r"(?:^|[\s;&|(])(uvx|uv|npx|npm|node)(?=[\s;&|)]|$)", text or ""))
    for w in sorted(words):
        try: ensure_node(w); ensure_uv(w)
        except Exception as e: print(f"[helper] could not prepare {w}: {e}", flush=True)


def run(a):
    ensure_for(a["command"])
    try:
        p = subprocess.run(["bash", "-c", a["command"]], capture_output=True, text=True, timeout=a.get("timeout_s", 60), errors="replace", env=with_path(), cwd=a.get("cwd"))
        code, out = p.returncode, p.stdout + p.stderr
    except subprocess.TimeoutExpired as e:
        return {"text": f"[timeout after {a.get('timeout_s', 60)}s]\n" + clip(str(e.stdout or ""))}
    return {"text": f"[exit {code}]\n" + clip(out)}


def start_process(a):
    """Launch a program detached (GUI apps like Blender/Unity, servers) and return at once; it keeps running after this call."""
    ensure_for(os.path.basename(a["command"]))
    cmd = shutil.which(a["command"], path=with_path()["PATH"]) or a["command"]
    log = os.path.join(tempfile.gettempdir(), f"helpermcp-start-{os.getpid()}-{len(STARTED)}.log")
    with open(log, "wb") as lf:
        p = subprocess.Popen([cmd] + list(a.get("args") or []), cwd=a.get("cwd"), env=with_path(a.get("env")), stdin=subprocess.DEVNULL,
                             stdout=lf, stderr=subprocess.STDOUT, start_new_session=True)
    STARTED.append(p)
    try: p.wait(timeout=min(float(a.get("wait_s", 2)), 30))   # returns early if it crashes right away
    except subprocess.TimeoutExpired: pass
    rc = p.poll()
    tail = open(log, "r", errors="replace").read()[-1500:]
    if rc is not None: return {"text": f"[exited with code {rc} right away]\n{tail}"}
    return {"text": f"[started pid {p.pid}, still running]\n{tail}"}


def fetch_file(a):
    """Upload a file to the relay and return a download link for the operator."""
    path = os.path.expanduser(a["path"]); size = os.path.getsize(path)
    req = urllib.request.Request(RELAY + "/a/file?name=" + urllib.parse.quote(os.path.basename(path)), method="POST")
    req.add_header("Authorization", "Bearer " + TOKEN); req.add_header("Content-Length", str(size)); req.add_header("Content-Type", "application/octet-stream")
    with open(path, "rb") as f, urllib.request.urlopen(req, f, timeout=3600) as resp:
        d = json.loads(resp.read())
    return {"text": f"{d['url']}  ({d['size']} bytes, link valid 24 h)"}


def read_file(a):
    path = os.path.expanduser(a["path"])
    if path.lower().endswith((".png", ".jpg", ".jpeg", ".gif", ".bmp", ".webp", ".tif", ".tiff")):   # an image: return it as an image, scaled down
        cap = int(a.get("max_width") or 1600)
        try:
            import gi; gi.require_version("GdkPixbuf", "2.0"); from gi.repository import GdkPixbuf
            pb = GdkPixbuf.Pixbuf.new_from_file(path); w0, h0 = pb.get_width(), pb.get_height()
            if w0 > cap: pb = pb.scale_simple(cap, int(h0 * cap / w0), GdkPixbuf.InterpType.BILINEAR)
            _, buf = pb.save_to_bufferv("jpeg", ["quality"], [str(int(a.get("quality") or 80))])
            return {"jpeg": bytes(buf), "mime": "image/jpeg", "text": f"{w0}x{h0} image"}
        except Exception:
            with open(path, "rb") as f: return {"jpeg": f.read(), "mime": "image/png" if path.lower().endswith(".png") else "image/jpeg"}
    with open(path, "rb") as f:
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
        "monitors": [f"{i}: {w}x{h} at {x},{y}" for i, (x, y, w, h) in enumerate(monitors())],
        "node": sh("node -v 2>/dev/null")[1].strip() or None, "uv": sh("uv --version 2>/dev/null")[1].strip() or None,
        "started": [{"pid": p.pid, "running": p.poll() is None} for p in STARTED],
        "uptime": sh("uptime -p")[1].strip(), "mem": sh("free -h | sed -n 2p")[1].strip(), "disk": sh("df -h / | tail -1")[1].strip(),
    }, indent=2, ensure_ascii=False)}


# ---- other MCP servers on this PC -----------------------------------------------------------------
def node_major():
    try: return int(sh(["node", "-v"], 10)[1].strip().lstrip("v").split(".")[0])
    except Exception: return 0


def _download(url, dest):
    urllib.request.urlretrieve(url, dest)


def ensure_node(command):
    """npx/node/npm missing or older than 20? Download a portable Node into a temp dir (removed on exit)."""
    global NODE_DIR, NODE_BIN
    base = os.path.basename(command)
    if base not in ("npx", "node", "npm") or NODE_BIN or (base == "node" and shutil.which("node")) or node_major() >= NODE_MIN:
        return   # a plain `node script.js` runs on whatever Node is installed; npx/npm packages usually need >= 20
    arch = {"x86_64": "x64", "amd64": "x64", "aarch64": "arm64", "arm64": "arm64"}.get(platform.machine().lower())
    osn = {"Linux": "linux", "Darwin": "darwin"}.get(platform.system())
    if not (arch and osn): raise RuntimeError("Node.js >= 20 is missing and no portable build exists for this system")
    base = f"node-{NODE_VERSION}-{osn}-{arch}"
    NODE_DIR = tempfile.mkdtemp(prefix="helpermcp-node-"); TMP.append(NODE_DIR)
    print("[helper] downloading portable Node.js ...", flush=True)
    pkg = os.path.join(NODE_DIR, "n.tar.xz")
    _download(f"https://nodejs.org/dist/{NODE_VERSION}/{base}.tar.xz", pkg)
    with tarfile.open(pkg) as tf: tf.extractall(NODE_DIR)
    os.remove(pkg)
    NODE_BIN = os.path.join(NODE_DIR, base, "bin"); EXTRA_PATH.insert(0, NODE_BIN)


def ensure_uv(command):
    """uv/uvx (how most Python MCP servers are started) missing? Download the portable uv into a temp dir."""
    if os.path.basename(command) not in ("uv", "uvx") or shutil.which(command, path=with_path()["PATH"]): return
    arch = {"x86_64": "x86_64", "amd64": "x86_64", "aarch64": "aarch64", "arm64": "aarch64"}.get(platform.machine().lower())
    tgt = {("Linux", "x86_64"): "x86_64-unknown-linux-gnu", ("Linux", "aarch64"): "aarch64-unknown-linux-gnu",
           ("Darwin", "x86_64"): "x86_64-apple-darwin", ("Darwin", "aarch64"): "aarch64-apple-darwin"}.get((platform.system(), arch))
    if not tgt: raise RuntimeError("uv is missing and no portable build exists for this system")
    d = tempfile.mkdtemp(prefix="helpermcp-uv-"); TMP.append(d)
    print("[helper] downloading portable uv ...", flush=True)
    pkg = os.path.join(d, "uv.tar.gz")
    _download(f"https://github.com/astral-sh/uv/releases/latest/download/uv-{tgt}.tar.gz", pkg)
    with tarfile.open(pkg) as tf: tf.extractall(d)
    os.remove(pkg)
    EXTRA_PATH.insert(0, os.path.join(d, f"uv-{tgt}"))


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
    def __init__(self, command, args, env, cwd=None):
        e = with_path(env)
        command = shutil.which(command, path=e["PATH"]) or command
        self.p = subprocess.Popen([command] + list(args or []), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.PIPE, env=e, text=True, encoding="utf-8", bufsize=1, cwd=cwd, start_new_session=True)
        self.q, self.n, self.tools, self.err, self.lock = queue.Queue(), 0, [], [], threading.Lock()
        threading.Thread(target=self._read, daemon=True).start()
        threading.Thread(target=lambda: [self.err.append(l) for l in self.p.stderr], daemon=True).start()

    def kill(self):  # the whole process group: uvx/npx start the real server as a grandchild
        try: os.killpg(self.p.pid, signal.SIGKILL)
        except Exception:
            try: self.p.kill()
            except Exception: pass

    def why(self):  # last stderr lines, for error messages
        return "".join(self.err[-8:]).strip()[:1500]

    def _read(self):
        for line in self.p.stdout: self.q.put(line)
        self.q.put(None)

    def rpc(self, method, params=None, timeout=60, notify=False):
        with self.lock: return self._rpc(method, params, timeout, notify)   # one request at a time per server

    def _rpc(self, method, params, timeout, notify):
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
    ensure_node(command); ensure_uv(command)
    c = Child(command, args, a.get("env"), a.get("cwd"))
    try:
        c.rpc("initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                             "clientInfo": {"name": "helpermcp", "version": "0.4"}}, timeout=a.get("timeout_s", 240))
        c.rpc("notifications/initialized", notify=True)
        c.tools = c.rpc("tools/list", timeout=60)["tools"]
    except Exception:
        c.kill(); raise
    CHILDREN[name] = c
    return {"text": f"{name}: {len(c.tools)} tools: " + ", ".join(t["name"] for t in c.tools)}


def mcp_tools(_):
    return {"text": json.dumps([{"server": n, **t} for n, c in CHILDREN.items() for t in c.tools])}


def mcp_call(a):
    c = CHILDREN.get(a["server"])
    if not c: raise RuntimeError(f"No MCP server '{a['server']}'. Start it with mcp_start.")
    r = c.rpc("tools/call", {"name": a["tool"], "arguments": a.get("arguments") or {}}, timeout=a.get("timeout_s", 110))
    return {"content": r.get("content", []), "isError": r.get("isError", False)}


def mcp_stop(a):
    c = CHILDREN.pop(a["name"], None)
    if c: c.kill()
    return {"text": "stopped" if c else "not running"}


# ---- "remote control" overlay: glowing screen edges + a label on top (like Codex) ----------------------
OVERLAY = r'''import os, sys, math, time
from array import array
from collections import deque
import gi, cairo
gi.require_version("Gtk", "3.0"); gi.require_version("Gdk", "3.0")
from gi.repository import Gtk, Gdk, GLib

label, ppid, lost_label = sys.argv[1], int(sys.argv[2]), (sys.argv[3] if len(sys.argv) > 3 else "Connection lost")
BLUE, ORANGE, VIOLET = (0x4C / 255, 0x8D / 255, 0xFF / 255), (1.0, 0x8A / 255, 0x1E / 255), (0.66, 0.5, 1.0)
disp = Gdk.Display.get_default()
scr = disp.get_default_screen()
if not scr.is_composited() or scr.get_rgba_visual() is None:
    sys.exit(0)                      # without compositing transparent windows would be opaque black boxes: show nothing
state = "ok"                         # ok | lost  (connection to the relay)
S_DEPTH = 70                         # glow depth in px

def col(): return ORANGE if state == "lost" else BLUE

def new_window(w, h, x, y):
    # A managed NOTIFICATION window, not an override-redirect POPUP: GNOME Shell does not let clicks through an
    # override-redirect overlay to its own panel / tray, whatever the X input shape says; it does for this window type.
    win = Gtk.Window(type=Gtk.WindowType.TOPLEVEL)
    win.set_decorated(False); win.set_type_hint(Gdk.WindowTypeHint.NOTIFICATION)
    win.set_skip_taskbar_hint(True); win.set_skip_pager_hint(True); win.stick()
    win.set_app_paintable(True); win.set_visual(scr.get_rgba_visual())
    win.set_default_size(w, h); win.move(x, y); win.set_keep_above(True); win.set_accept_focus(False)
    return win

def new_popup(w, h, x, y):
    win = Gtk.Window(type=Gtk.WindowType.POPUP); win.set_app_paintable(True); win.set_visual(scr.get_rgba_visual())
    win.set_default_size(w, h); win.move(x, y); win.set_keep_above(True); win.set_accept_focus(False)
    return win

def click_through(win): win.get_window().input_shape_combine_region(cairo.Region(), 0, 0)

# ---- glow: alpha of every pixel is a fade of its distance to the NEAREST screen edge (no strips: nothing overlaps, no seams)
def build_glow(W, H, rgb):
    R, G, B = rgb
    def fade(d):
        t = (d + 0.5) / S_DEPTH
        return 0.59 + (0.18 - 0.59) * t / 0.35 if t <= 0.35 else 0.18 * (1 - (t - 0.35) / 0.65)
    prof = [(int(255 * fade(d)) << 24) | (int(R * 255 * fade(d)) << 16) | (int(G * 255 * fade(d)) << 8) | int(B * 255 * fade(d)) for d in range(S_DEPTH)]
    px = array("I", bytes(4 * W * H))
    for y in range(H):
        dy = min(y, H - 1 - y)
        if dy < S_DEPTH:
            left = [prof[min(dy, x)] for x in range(S_DEPTH)]
            px[y * W: y * W + S_DEPTH] = array("I", left)
            px[y * W + S_DEPTH: (y + 1) * W - S_DEPTH] = array("I", [prof[dy]]) * (W - 2 * S_DEPTH)
            px[(y + 1) * W - S_DEPTH: (y + 1) * W] = array("I", left[::-1])
        else:
            px[y * W: y * W + S_DEPTH] = array("I", prof)
            px[(y + 1) * W - S_DEPTH: (y + 1) * W] = array("I", prof[::-1])
    return cairo.ImageSurface.create_for_data(px, cairo.FORMAT_ARGB32, W, H, W * 4), px

glows, pills, strips = [], [], []
tmp = cairo.Context(cairo.ImageSurface(cairo.FORMAT_ARGB32, 10, 10))
tmp.select_font_face("Sans", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_BOLD); tmp.set_font_size(15)
T0 = time.monotonic()
PILL_W = int(max(tmp.text_extents(label + "   00:00:00").x_advance, tmp.text_extents(lost_label).x_advance)) + 58

def make_monitor(mon):
    g = mon.get_geometry()
    W, H = g.width - 1, g.height - 1   # NOT exactly screen-sized: mutter would treat a full-screen window as opaque, stop compositing it and show black
    w = new_window(W, H, g.x, g.y)
    cache = {}
    def surf():
        if state not in cache: cache[state] = build_glow(W, H, col())
        return cache[state][0]
    def draw(_, cr):
        cr.set_operator(cairo.OPERATOR_SOURCE); cr.set_source_surface(surf(), 0, 0); cr.paint()
    w.connect("draw", draw); w.show_all(); click_through(w); glows.append(w)
    # GNOME Shell draws its panel / dock above every normal window, so the glow would vanish under it. Where the panel takes space
    # (work area smaller than the monitor) an override-redirect strip repeats the same glow right over the panel, so the light runs
    # along the whole monitor. Shell does not let clicks through such a window, so the strip hides while the pointer is on it
    # (see tick): the panel stays clickable, the glow only blinks out where the mouse actually is.
    wa = mon.get_workarea(); sides = []
    top, bot, lef, rig = wa.y - g.y, g.y + g.height - (wa.y + wa.height), wa.x - g.x, g.x + g.width - (wa.x + wa.width)
    if top > 0: sides.append((0, 0, W, min(S_DEPTH, top + 2)))
    if bot > 1: sides.append((0, H - min(S_DEPTH, bot + 1), W, min(S_DEPTH, bot + 1)))
    if lef > 0: sides.append((0, 0, min(S_DEPTH, lef + 2), H))
    if rig > 1: sides.append((W - min(S_DEPTH, rig + 1), 0, min(S_DEPTH, rig + 1), H))
    for (sx, sy, sw, sh) in sides:
        sw_ = Gtk.Window(type=Gtk.WindowType.POPUP); sw_.set_app_paintable(True); sw_.set_visual(scr.get_rgba_visual())
        sw_.set_default_size(sw, sh); sw_.move(g.x + sx, g.y + sy); sw_.set_keep_above(True); sw_.set_accept_focus(False)
        def sdraw(_, cr, sx=sx, sy=sy):
            cr.set_operator(cairo.OPERATOR_SOURCE); cr.set_source_surface(surf(), -sx, -sy); cr.paint()
        sw_.connect("draw", sdraw); sw_.show_all(); click_through(sw_); glows.append(sw_)
        strips.append([sw_, (g.x + sx - 6, g.y + sy - 6, sw + 12, sh + 12), True])
    # the label is its own small window: it pulses without repainting the full-screen glow
    pw = new_window(PILL_W, 36, g.x + (g.width - PILL_W) // 2, g.y + 12)
    def pdraw(_, cr):
        cr.set_operator(cairo.OPERATOR_SOURCE); cr.set_source_rgba(0, 0, 0, 0); cr.paint(); cr.set_operator(cairo.OPERATOR_OVER)
        r_, g_, b_ = col(); lost = state == "lost"; text = lost_label if lost else label + "   %02d:%02d:%02d" % ((int(time.monotonic() - T0) // 3600,) + divmod(int(time.monotonic() - T0) % 3600, 60))
        pulse = 0.55 + 0.45 * (0.5 + 0.5 * math.sin(time.monotonic() * 5)) if lost else 1.0
        cr.select_font_face("Sans", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_BOLD); cr.set_font_size(15)
        ext = cr.text_extents(text); ph, rr, pad = 34, 17, 18
        w_ = pad + 10 + 9 + ext.x_advance + pad; x0, y0 = (PILL_W - w_) / 2, 1          # the pill hugs its content and sits in the middle of the window
        cr.new_sub_path(); cr.arc(x0 + w_ - rr, y0 + rr, rr, -math.pi / 2, math.pi / 2); cr.arc(x0 + rr, y0 + rr, rr, math.pi / 2, 3 * math.pi / 2); cr.close_path()
        cr.set_source_rgba(0.06, 0.09, 0.14, 0.9); cr.fill_preserve(); cr.set_source_rgba(r_, g_, b_, 0.95); cr.set_line_width(1.5); cr.stroke()
        cr.arc(x0 + pad + 5, y0 + ph / 2, 5, 0, 2 * math.pi); cr.set_source_rgba(r_, g_, b_, pulse); cr.fill()
        fe = cr.font_extents()
        cr.set_source_rgba(1, 1, 1, 1); cr.move_to(x0 + pad + 19, y0 + ph / 2 + (fe[0] - fe[1]) / 2 - 0.5); cr.show_text(text)
    pw.connect("draw", pdraw); pw.show_all(); click_through(pw); pills.append(pw)

for i in range(disp.get_n_monitors()): make_monitor(disp.get_monitor(i))

# ---- the big cursor, click ripples, drag / scroll / typing indicators
CW = 140; HX = HY = 44               # cursor window size and where the arrow tip sits in it
cursor = new_popup(CW, CW, -500, -500)
RW = 220
ripple = new_window(RW, RW, -500, -500)
last_active = 0.0; opacity = 0.0; pre_until = 0.0; lean = 0.0; lastp = None
pressed_t = -9.0; dragging = False; scroll_dir = 0; scroll_t = -9.0; typing_t = -9.0
rip = None                            # (x, y, t0, rgb)
trail = deque(maxlen=14)
shown = {"cursor": False, "ripple": False}

def pointer():
    _, x, y = disp.get_default_seat().get_pointer().get_position()
    return x, y

# ---- the REAL pointer is replaced for the whole session (every app, the panel too): the operator's cursor pack (CURSOR_DIR on the relay) or a soft rounded arrow
ARROW = [(0, 0), (0, 23), (5.2, 18.2), (8.8, 26.5), (12.3, 25), (8.7, 16.8), (15.6, 16.8)]
SYS = False
def soft_arrow(size=44):
    """(w, h, hotx, hoty, premultiplied ARGB bytes) of a soft rounded arrow with a light shadow"""
    sf = cairo.ImageSurface(cairo.FORMAT_ARGB32, size, size); c = cairo.Context(sf); k = size / 40.0
    c.scale(k, k); c.translate(5, 4); c.scale(1.2, 1.2)
    c.move_to(*ARROW[0])
    for q in ARROW[1:]: c.line_to(*q)
    c.close_path(); c.set_line_join(cairo.LINE_JOIN_ROUND); path = c.copy_path()
    c.save(); c.translate(1, 2)
    for lw, a in ((6, 0.06), (4, 0.09), (2.4, 0.14)): c.new_path(); c.append_path(path); c.set_source_rgba(0.02, 0.05, 0.15, a); c.set_line_width(lw); c.stroke()
    c.restore()
    c.new_path(); c.append_path(path); c.set_source_rgb(1, 1, 1); c.set_line_width(2.4); c.stroke_preserve()
    g = cairo.LinearGradient(0, 0, 0, 27); g.add_color_stop_rgb(0, 1, 1, 1); g.add_color_stop_rgb(1, 0.82, 0.89, 1)
    c.set_source(g); c.fill_preserve(); c.set_source_rgba(0.3, 0.55, 1, 0.65); c.set_line_width(0.9); c.stroke()
    return size, size, int(5 * k), int(4 * k), bytes(sf.get_data())

def parse_cur(data):
    """largest image of a Windows .cur (32-bit BMP or PNG) -> (w, h, hotx, hoty, premultiplied ARGB bytes)"""
    import struct
    n = struct.unpack_from("<H", data, 4)[0]; best = None
    for i in range(n):
        w, h, _, _, hx, hy, sz, off = struct.unpack_from("<BBBBHHII", data, 6 + 16 * i)
        w, h = w or 256, h or 256
        if not best or (w <= 48 < best[0]) or (best[0] <= 48 and best[0] < w <= 48): best = (w, h, hx, hy, sz, off)
    w, h, hx, hy, sz, off = best; img = data[off:off + sz]; out = bytearray(w * h * 4)
    if img[:4] == b"\x89PNG":
        from gi.repository import GdkPixbuf
        ld = GdkPixbuf.PixbufLoader(); ld.write(img); ld.close(); pb = ld.get_pixbuf().add_alpha(False, 0, 0, 0)
        w, h, rs = pb.get_width(), pb.get_height(), pb.get_rowstride(); px = pb.get_pixels(); out = bytearray(w * h * 4)
        for y in range(h):
            for x in range(w):
                r, g, b, a = px[y * rs + x * 4: y * rs + x * 4 + 4]; o = (y * w + x) * 4
                out[o:o + 4] = bytes((b * a // 255, g * a // 255, r * a // 255, a))
        return w, h, hx, hy, bytes(out)
    hs, bw, bh, _, bpp, _c, _s, _x1, _y1, ncol = struct.unpack_from("<IiiHHIIiiI", img, 0)
    w, h = bw, abs(bh) // 2
    if bpp <= 8: ncol = ncol or (1 << bpp); pal = [img[hs + 4 * i: hs + 4 * i + 3] for i in range(ncol)]; hs += 4 * ncol
    rowb = ((w * bpp + 31) // 32) * 4; maskrow = ((w + 31) // 32) * 4; mask0 = hs + rowb * h; out = bytearray(w * h * 4)
    for y in range(h):
        row = hs + (h - 1 - y) * rowb
        for x in range(w):
            if bpp == 32: b, g, r, a = img[row + 4 * x: row + 4 * x + 4]
            else:
                if bpp == 24: b, g, r = img[row + 3 * x: row + 3 * x + 3]
                else:
                    bit = x * bpp; idx = (img[row + bit // 8] >> (8 - bpp - bit % 8)) & ((1 << bpp) - 1); b, g, r = pal[idx]
                a = 0 if (img[mask0 + (h - 1 - y) * maskrow + x // 8] >> (7 - x % 8)) & 1 else 255
            o = (y * w + x) * 4; out[o:o + 4] = bytes((b * a // 255, g * a // 255, r * a // 255, a))
    return w, h, hx, hy, bytes(out)

# The session theme: an Xcursor theme is written to ~/.icons and selected through gsettings, so every app (and the panel) shows
# it, and it is put back when the overlay ends (or at the next start if the PC was killed in between). XFixesChangeCursorByName was tried first:
# it replaces server-side cursors for good and cannot be undone.
import json, subprocess as sp, shutil, signal
THEME = "helpermcp-remote"; THEME_DIR = os.path.expanduser("~/.icons/" + THEME); RESTORE = os.path.expanduser("~/.cache/helpermcp-cursor.json")
GS = ["gsettings", "get", "org.gnome.desktop.interface", "cursor-theme"]
def gs(*a):
    r = sp.run(["gsettings"] + list(a), capture_output=True, text=True, timeout=8); return r.stdout.strip().strip("'")
def restore_theme():
    try:
        old = json.load(open(RESTORE))["old"]
        gs("set", "org.gnome.desktop.interface", "cursor-theme", old); os.remove(RESTORE)
    except Exception: pass
    shutil.rmtree(THEME_DIR, ignore_errors=True)

def xcursor_bytes(img):
    import struct
    w, h, hx, hy, data = img
    chunk = struct.pack("<IIIIIIIII", 36, 0xfffd0002, w, 1, w, h, hx, hy, 0) + data
    return b"Xcur" + struct.pack("<III", 16, 0x10000, 1) + struct.pack("<III", 0xfffd0002, w, 28) + chunk

NAMES = {"pointer": ["left_ptr", "default", "arrow", "top_left_arrow"], "link": ["hand2", "hand1", "pointer", "pointing_hand"], "beam": ["xterm", "text", "ibeam"],
         "help": ["question_arrow", "help"], "precision": ["crosshair", "cross"], "unavailable": ["not-allowed", "crossed_circle", "forbidden"],
         "vert": ["sb_v_double_arrow", "ns-resize", "size_ver"], "horz": ["sb_h_double_arrow", "ew-resize", "size_hor"], "move": ["fleur", "move"],
         "dgn1": ["nwse-resize", "size_fdiag"], "dgn2": ["nesw-resize", "size_bdiag"]}

def apply_theme():
    """pack from the relay (optional) or the soft arrow, as the cursor theme for the whole session; returns True when it is active"""
    try:
        restore_theme()                                   # leftovers of a killed run
        got = {}; relay = os.environ.get("HM_RELAY", ""); t0 = time.monotonic()
        if relay:
            import urllib.request
            for key in NAMES:
                if time.monotonic() - t0 > 6: break
                try:
                    with urllib.request.urlopen(relay + "/cursor/%s.cur" % key, timeout=3) as r: got[key] = parse_cur(r.read())
                except Exception: pass
        if "pointer" not in got: got["pointer"] = soft_arrow()
        old = gs("get", "org.gnome.desktop.interface", "cursor-theme") or "Adwaita"
        os.makedirs(THEME_DIR + "/cursors", exist_ok=True); os.makedirs(os.path.dirname(RESTORE), exist_ok=True)
        json.dump({"old": old}, open(RESTORE, "w"))
        open(THEME_DIR + "/index.theme", "w").write("[Icon Theme]\nName=HelperMCP remote\nInherits=%s\n" % old)
        for key, img in got.items():
            for nm in NAMES[key]: open(THEME_DIR + "/cursors/" + nm, "wb").write(xcursor_bytes(img))
        gs("set", "org.gnome.desktop.interface", "cursor-theme", THEME); return True
    except Exception as e:
        print("[overlay] cursor theme:", repr(e), file=sys.stderr); restore_theme(); return False

def theme_done():
    global SYS
    SYS = THEME_RESULT[0]; return False
THEME_RESULT = [False]
def theme_worker():
    THEME_RESULT[0] = apply_theme(); GLib.idle_add(theme_done)
import threading
threading.Thread(target=theme_worker, daemon=True).start()
GLib.unix_signal_add(GLib.PRIORITY_HIGH, signal.SIGTERM, lambda: (Gtk.main_quit(), False)[1])

try:
    import ctypes
    _xl = ctypes.CDLL("libX11.so.6"); _xf = ctypes.CDLL("libXfixes.so.3")
    _xl.XOpenDisplay.restype = ctypes.c_void_p; _xl.XOpenDisplay.argtypes = [ctypes.c_char_p]; _xl.XDefaultRootWindow.restype = ctypes.c_ulong; _xl.XDefaultRootWindow.argtypes = [ctypes.c_void_p]
    _xl.XFlush.argtypes = [ctypes.c_void_p]; _xf.XFixesHideCursor.argtypes = _xf.XFixesShowCursor.argtypes = [ctypes.c_void_p, ctypes.c_ulong]
    _xd = _xl.XOpenDisplay(None); _xroot = _xl.XDefaultRootWindow(_xd)
except Exception: _xd = None
real_hidden = [False]
def real_pointer(hide):
    if _xd and hide != real_hidden[0]:
        try: (_xf.XFixesHideCursor if hide else _xf.XFixesShowCursor)(_xd, _xroot); _xl.XFlush(_xd)
        except Exception: pass
        real_hidden[0] = hide

def in_panel(x, y):
    return any(st[1][0] <= x < st[1][0] + st[1][2] and st[1][1] <= y < st[1][1] + st[1][3] for st in strips)

def ease_out(p): return 1 - (1 - p) ** 3


def draw_cursor(_, cr):
    cr.set_operator(cairo.OPERATOR_SOURCE); cr.set_source_rgba(0, 0, 0, 0); cr.paint(); cr.set_operator(cairo.OPERATOR_OVER)
    cr.push_group()   # fade by painting the group with alpha (window opacity is not honoured by every compositor)
    now = time.monotonic(); r_, g_, b_ = col(); px, py = pointer()
    for (t0, x, y) in trail:                             # soft comet tail while moving
        age = now - t0
        if 0 <= age < 0.3:
            cr.arc(HX + x - px + 3, HY + y - py + 5, 6 * (1 - age / 0.3) + 1, 0, 2 * math.pi)
            cr.set_source_rgba(r_, g_, b_, 0.32 * (1 - age / 0.3)); cr.fill()
    pa = now - pressed_t
    s = 1.4 * (1 - 0.16 * math.sin(math.pi * pa / 0.2)) if 0 <= pa < 0.2 else 1.4
    if dragging: s = 1.4 * 0.9
    if dragging:                                          # grabbing: a pulsing ring around the tip
        rr = 22 + 3 * math.sin(now * 8)
        cr.arc(HX, HY, rr, 0, 2 * math.pi); cr.set_source_rgba(r_, g_, b_, 0.18); cr.fill_preserve()
        cr.set_source_rgba(r_, g_, b_, 0.85); cr.set_line_width(2.4); cr.stroke()
    halo = cairo.RadialGradient(HX + 6, HY + 8, 2, HX + 6, HY + 8, 52)   # soft light around the pointer, like Codex
    halo.add_color_stop_rgba(0, r_, g_, b_, 0.78); halo.add_color_stop_rgba(0.45, r_, g_, b_, 0.34); halo.add_color_stop_rgba(1, r_, g_, b_, 0)
    cr.set_source(halo); cr.arc(HX + 6, HY + 8, 52, 0, 2 * math.pi); cr.fill()
    if True:   # the real pointer is hidden while the AI works: this arrow takes its place
        cr.save(); cr.translate(HX, HY); cr.rotate(lean); cr.scale(s, s)
        cr.move_to(*ARROW[0])
        for p in ARROW[1:]: cr.line_to(*p)
        cr.close_path(); cr.set_line_join(cairo.LINE_JOIN_ROUND); cr.set_line_cap(cairo.LINE_CAP_ROUND)
        path = cr.copy_path()
        cr.save(); cr.translate(1.5, 3)                        # soft drop shadow
        for lw, a in ((11, 0.05), (8, 0.07), (5, 0.10)):
            cr.new_path(); cr.append_path(path); cr.set_source_rgba(0.02, 0.05, 0.15, a); cr.set_line_width(lw); cr.stroke()
        cr.restore()
        for lw, a in ((10, 0.10), (7, 0.16), (4.5, 0.26)):      # coloured glow
            cr.new_path(); cr.append_path(path); cr.set_source_rgba(r_, g_, b_, a); cr.set_line_width(lw); cr.stroke()
        cr.new_path(); cr.append_path(path); cr.set_line_width(3.2); cr.set_source_rgba(1, 1, 1, 1); cr.stroke_preserve()   # rounded corners
        grad = cairo.LinearGradient(0, 0, 0, 27); grad.add_color_stop_rgb(0, 1, 1, 1); grad.add_color_stop_rgb(1, 0.82, 0.89, 1)
        cr.set_source(grad); cr.fill_preserve()
        cr.set_source_rgba(r_, g_, b_, 0.55); cr.set_line_width(1.1); cr.stroke(); cr.restore()
    sa = now - scroll_t
    if scroll_dir and 0 <= sa < 0.7:                      # scrolling: chevrons travel in the scroll direction
        for k in range(3):
            q = ((sa / 0.7) + k / 3.0) % 1.0
            yy = HY + 26 + scroll_dir * (6 + 26 * q) + (-26 if scroll_dir < 0 else 0)
            cr.set_source_rgba(r_, g_, b_, 0.9 * (1 - q)); cr.set_line_width(3); cr.set_line_cap(cairo.LINE_CAP_ROUND)
            cr.move_to(HX + 34, yy - 4 * scroll_dir); cr.line_to(HX + 41, yy + 3 * scroll_dir); cr.line_to(HX + 48, yy - 4 * scroll_dir); cr.stroke()
    ta = now - typing_t
    if 0 <= ta < 1.6:                                     # typing: three pulsing dots
        cr.rectangle(0, 0, 0, 0)
        for k in range(3):
            a = 0.35 + 0.65 * max(0, math.sin(ta * 9 - k * 0.9))
            cr.arc(HX + 30 + k * 9, HY + 40, 3.2, 0, 2 * math.pi); cr.set_source_rgba(r_, g_, b_, a); cr.fill()
    cr.pop_group_to_source(); cr.paint_with_alpha(max(0.0, min(1.0, opacity)))

def draw_ripple(_, cr):
    cr.set_operator(cairo.OPERATOR_SOURCE); cr.set_source_rgba(0, 0, 0, 0); cr.paint(); cr.set_operator(cairo.OPERATOR_OVER)
    if not rip: return
    now = time.monotonic(); x, y, t0, (r_, g_, b_) = rip
    for delay, base in ((0.0, 8), (0.16, 4)):             # two rings, the second one follows a moment later
        p = (now - t0 - delay) / 0.6
        if 0 <= p <= 1:
            rad = base + 72 * ease_out(p)
            cr.arc(RW / 2, RW / 2, rad, 0, 2 * math.pi); cr.set_source_rgba(r_, g_, b_, 0.12 * (1 - p)); cr.fill_preserve()
            cr.set_source_rgba(r_, g_, b_, 0.9 * (1 - p) ** 1.3); cr.set_line_width(3.4 * (1 - p) + 1); cr.stroke()
    p0 = (now - t0) / 0.3
    if 0 <= p0 <= 1:
        cr.arc(RW / 2, RW / 2, 9 * (1 - p0) + 2, 0, 2 * math.pi); cr.set_source_rgba(1, 1, 1, 0.9 * (1 - p0)); cr.fill()

cursor.connect("draw", draw_cursor); ripple.connect("draw", draw_ripple)

def show(win, name):
    if not shown[name]: win.show_all(); click_through(win); shown[name] = True
def hide(win, name):
    if shown[name]: win.hide(); shown[name] = False

def tick():
    global opacity, rip
    now = time.monotonic(); px, py = pointer()
    if not trail or (trail[-1][1], trail[-1][2]) != (px, py): trail.append((now, px, py))
    global lean, lastp
    if lastp: lean += (max(-0.5, min(0.5, (px - lastp[0]) * 0.045)) - lean) * 0.22      # the nose leans into the direction of movement
    lastp = (px, py)
    target = 1.0 if (now - last_active < 8.0 or dragging) else 0.0
    opacity += (target - opacity) * 0.22
    if (opacity < 0.03 and target == 0.0) or now < pre_until: hide(cursor, "cursor"); real_pointer(False)   # pre_until: a click on the panel needs the pointer free for a moment
    else:
        real_pointer(True); show(cursor, "cursor"); cursor.move(px - HX, py - HY); cursor.get_window().raise_(); cursor.queue_draw()
    for st in strips:   # over-the-panel glow strips: out of the way while the pointer is on them
        x, y, w_, h_ = st[1]; inside = x <= px < x + w_ and y <= py < y + h_
        if inside and st[2]: st[0].hide(); st[2] = False
        elif not inside and not st[2]: st[0].show_all(); click_through(st[0]); st[2] = True
    if rip and now - rip[2] > 0.9: rip = None
    if rip:
        show(ripple, "ripple"); ripple.move(int(rip[0] - RW / 2), int(rip[1] - RW / 2)); ripple.get_window().raise_(); ripple.queue_draw()
    else: hide(ripple, "ripple")
    return True

def set_state(s):
    global state
    if s == state: return
    state = s
    for w in glows: w.queue_draw()
    for w in pills: w.queue_draw()

def on_line(line):
    global last_active, pressed_t, dragging, scroll_dir, scroll_t, typing_t, rip, pre_until
    f = line.split(); now = time.monotonic()
    if not f: return
    if f[0] == "state" and len(f) > 1: set_state(f[1]); return
    if f[0] == "pre":                               # about to click: over the panel the arrow window would swallow the click
        px, py = pointer()
        if in_panel(px, py): pre_until = now + 0.5
        return
    last_active = now
    if f[0] == "click" and len(f) >= 4:
        pressed_t = now; rip = (float(f[1]), float(f[2]), now, VIOLET if f[3] == "right" else col())
    elif f[0] == "down": dragging = True; pressed_t = now
    elif f[0] == "up":
        dragging = False
        if len(f) >= 3: rip = (float(f[1]), float(f[2]), now, col())
    elif f[0] == "scroll" and len(f) > 1: scroll_dir = 1 if float(f[1]) > 0 else -1; scroll_t = now
    elif f[0] == "typing": typing_t = now

def on_stdin(chan, cond):
    if cond & GLib.IO_HUP and not (cond & GLib.IO_IN): Gtk.main_quit(); return False
    try:
        status, line, _, _ = chan.read_line()
        if status == GLib.IOStatus.NORMAL: on_line(line)
        elif status == GLib.IOStatus.EOF: Gtk.main_quit(); return False
    except Exception: pass
    return True

def watchdog():
    try: os.kill(ppid, 0)            # agent gone (window closed, crash): remove the overlay too
    except OSError: Gtk.main_quit(); return False
    for w in glows + pills:
        if w.get_window() and w.get_visible(): w.get_window().raise_()
    return True

chan = GLib.IOChannel.unix_new(0); chan.set_flags(GLib.IOFlags.NONBLOCK)
chan.set_close_on_unref(False)
GLib.io_add_watch(chan, GLib.PRIORITY_DEFAULT, GLib.IO_IN | GLib.IO_HUP, on_stdin)
GLib.timeout_add(16, tick)
GLib.timeout_add(120, lambda: ([w.queue_draw() for w in pills] if state == "lost" else None) or True)   # orange label pulses
GLib.timeout_add(1500, watchdog)
GLib.timeout_add(1000, lambda: ([w.queue_draw() for w in pills]) or True)   # the session clock in the label
Gtk.main()
restore_theme()
'''


def overlay_send(line):
    """Tell the overlay about connection state and effects (click ripple, drag, scroll ...). Never raises."""
    try:
        if OVERLAY_PROC and OVERLAY_PROC.stdin:
            OVERLAY_PROC.stdin.write((line + "\n").encode()); OVERLAY_PROC.stdin.flush()
    except Exception: pass


def overlay_start():
    global OVERLAY_PROC
    if os.environ.get("HELPER_NO_OVERLAY") or not GUI["type"]: return
    try:
        OVERLAY_PROC = subprocess.Popen([sys.executable, "-c", OVERLAY, t("overlay"), str(os.getpid()), t("lost")],
                                        stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, env=dict(os.environ, HM_RELAY=RELAY))
    except Exception: pass


def cleanup():
    for c in CHILDREN.values(): c.kill()
    if OVERLAY_PROC:
        try: OVERLAY_PROC.terminate(); OVERLAY_PROC.wait(3)   # lets it put the cursor theme back
        except Exception:
            try: OVERLAY_PROC.kill()
            except Exception: pass
    for p in TMP: shutil.rmtree(p, ignore_errors=True)


# ---- relay protocol -----------------------------------------------------------------------------------
def api(path, data=None, token=None, timeout=40):
    req = urllib.request.Request(RELAY + path, method="POST" if data is not None else "GET")
    if token: req.add_header("Authorization", "Bearer " + token)
    if data is not None:
        req.add_header("Content-Type", "application/json"); data = json.dumps(data).encode()
        if len(data) > 2048: data = gzip.compress(data, 5); req.add_header("Content-Encoding", "gzip")   # weak links: big outputs shrink a lot
    with urllib.request.urlopen(req, data, timeout=timeout) as r:
        raw = r.read()
        return (r.status, json.loads(raw) if raw else None)


def post_result(res, token):
    """Send a tool result. Screenshots go as the raw JPEG body (no base64 inflation), everything else as (gzipped) JSON."""
    d = res.get("data") if res.get("ok") else None
    if isinstance(d, dict) and isinstance(d.get("jpeg"), (bytes, bytearray)):
        meta = {k: v for k, v in d.items() if k not in ("jpeg", "mime")}
        req = urllib.request.Request(RELAY + "/a/result", data=bytes(d["jpeg"]), method="POST")
        req.add_header("Authorization", "Bearer " + token); req.add_header("Content-Type", d.get("mime") or "image/jpeg")
        req.add_header("X-Result-Id", res["id"]); req.add_header("X-Result-Meta", urllib.parse.quote(json.dumps(meta)))
        urllib.request.urlopen(req, timeout=60).read()
    else:
        api("/a/result", res, token, timeout=60)


TOOLS = dict(move=move, drag=drag, fetch_file=fetch_file, screenshot=screenshot, press_key=press_key, click=click, scroll=scroll, type_text=type_text, run=run,
             read_file=read_file, write_file=write_file, list_dir=list_dir, sysinfo=sysinfo,
             start_process=start_process, mcp_start=mcp_start, mcp_tools=mcp_tools, mcp_call=mcp_call, mcp_stop=mcp_stop)


GUI_TOOLS = {"click", "move", "drag", "scroll", "type_text", "press_key"}   # one X11 connection: never two at once
GUI_LOCK, ASK_LOCK = threading.Lock(), threading.Lock()


def handle(cmd, mode, token):
    """One tool call, in its own thread: a slow install or render never blocks screenshots, the live viewer or other calls."""
    name, args = cmd["tool"], cmd["args"]
    print(f"[helper] {name} {json.dumps(args, ensure_ascii=False)[:200]}", flush=True)
    res = {"id": cmd["id"]}
    try:
        if mode == "ask" and name in ASK_TOOLS:
            with ASK_LOCK:
                if input(t("allow")).strip().lower() not in ("y", "yes", "д", "да"): raise RuntimeError("User denied this action.")
        if name in GUI_TOOLS:
            with GUI_LOCK: res.update(ok=True, data=TOOLS[name](args))
        else:
            res.update(ok=True, data=TOOLS[name](args))
    except Exception as e:  # report every failure to the operator
        res.update(ok=False, error=f"{type(e).__name__}: {e}")
    for attempt in range(5):   # a lost result would leave the operator waiting for a call that already finished
        try: post_result(res, TOKEN or token); break
        except urllib.error.HTTPError as e:
            if e.code in (401, 410): break
            time.sleep(1 + attempt)
        except Exception: time.sleep(1 + attempt)


NET = {"s": "ok"}
LAST_OK = [time.time()]   # last time the relay answered a poll (the watchdog flips to 'lost' when it is too old)
POLL_TIMEOUT = 22         # the relay answers within 15 s; anything longer is a dead connection


def net_state(st):
    if NET["s"] == st: return
    NET["s"] = st
    print("[helper] " + ("connection lost, retrying ..." if st == "lost" else "connection restored"), flush=True)
    overlay_send("state " + st)   # the overlay turns orange while the link is down


def register(mode, resume=None):
    body = {"os": platform.platform(), "host": socket.gethostname(), "user": getpass.getuser(), "mode": mode}
    if resume: body["resume"] = resume   # the server may have forgotten us (restart, long outage): ask for the same code back
    _, reg = api("/a/register", body, timeout=20)
    return reg


def main():
    global TOKEN
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0)); signal.signal(signal.SIGHUP, lambda *_: sys.exit(0))  # run cleanup()
    find_gui()
    mode = os.environ.get("HELPER_MODE")
    if mode not in ("ask", "full"):
        mode = "full" if input(t("mode")).strip() == "2" else "ask"
    wait = 1.0
    while True:   # the server can be unreachable right at the start (no internet yet, VPN still connecting): keep trying
        try: reg = register(mode); break
        except Exception as e:
            print(f"[helper] cannot reach the server ({type(e).__name__}), retrying ...", flush=True); time.sleep(min(wait, 10.0)); wait *= 1.7
    token = TOKEN = reg["token"]; code = reg["code"]; LAST_OK[0] = time.time()
    print(f"\n  {t('banner')}  {code}\n  {t('tell')}\n", flush=True)
    overlay_start()
    pool = ThreadPoolExecutor(max_workers=8)
    fails, delay = 0, 1.0
    def watchdog():   # a connection can die silently (the poll just hangs): do not stay blue for long
        while True:
            time.sleep(2)
            if time.time() - LAST_OK[0] > POLL_TIMEOUT + 4: net_state("lost")
    threading.Thread(target=watchdog, daemon=True).start()
    try:
        while True:
            failed = False
            try:
                status, cmd = api("/a/poll", token=token, timeout=POLL_TIMEOUT)
            except urllib.error.HTTPError as e:
                status = cmd = None
                if e.code == 410: print("session closed (ended by the helper)"); return
                if e.code == 401:   # unknown to the server: it was reset or we were away too long -> register again, same code if possible
                    try:
                        reg = register(mode, code); token = TOKEN = reg["token"]
                        print(f"[helper] registered again, session code: {reg['code']}", flush=True)
                        code = reg["code"]; fails, delay = 0, 1.0; LAST_OK[0] = time.time(); net_state("ok"); continue
                    except Exception: pass
                failed = True
            except Exception:   # no internet, DNS, VPN switch, TLS, timeouts ... keep trying
                status = cmd = None; failed = True
            if failed:
                fails += 1
                if fails >= 2: net_state("lost")
                time.sleep(min(delay, 10.0) * (0.8 + 0.4 * random.random())); delay *= 1.7
                continue
            fails, delay = 0, 1.0; LAST_OK[0] = time.time(); net_state("ok")
            if status != 200 or not cmd: continue
            if cmd["tool"] == "bye": print("session closed"); return
            pool.submit(handle, cmd, mode, token)
    except KeyboardInterrupt:
        pass
    finally:
        pool.shutdown(wait=False, cancel_futures=True)
        cleanup()
        try: api("/a/bye", {}, TOKEN, timeout=5)
        except Exception: pass


if __name__ == "__main__":
    main()
