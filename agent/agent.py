#!/usr/bin/env python3
"""HelperMCP agent for Linux. Python 3 stdlib only (GTK via python3-gi is used if present, for the overlay).
Run: python3 <(curl -fsSL RELAY/p)"""
import base64, ctypes, ctypes.util, getpass, gzip, hashlib, json, math, random, locale, os, platform, queue, shutil, signal, socket, uuid
import re, subprocess, sys, tarfile, tempfile, threading, time
import urllib.parse, urllib.request, urllib.error
from concurrent.futures import ThreadPoolExecutor

RELAY = os.environ.get("HELPER_RELAY") or "__RELAY__"
RU = os.environ.get("HELPER_LANG", "") == "ru"   # the console speaks English; HELPER_LANG=ru for Russian
T = {
    "banner": ("УДАЛЁННАЯ ПОМОЩЬ. Код сессии:", "REMOTE HELP. Session code:"),
    "tell": ("Назови этот код тому, кто тебе помогает. Закрой окно или Ctrl+C - доступ пропадёт.",
             "Give this code to your helper. Close this window or press Ctrl+C to stop."),
    "hdr1": ("УДАЛЁННАЯ ПОМОЩЬ", "REMOTE HELP"), "hdr2": ("Код сессии:", "Session code:"), "copied": ("скопирован в буфер обмена", "copied to the clipboard"),
    "hdr3": ("Esc — завершить сеанс в любой момент", "Esc — end the session at any time"), "hdr4": ("Скажи этот код тому, кто помогает.", "Tell this code to the person who helps you."),
    "stopask": ("не спрашивать про", "stop asking about"),
    "st_conn": ("Подключаюсь к серверу…", "Connecting to the server…"), "st_wait": ("Ожидание помощника… он подключается по коду", "Waiting for the helper to connect with the code…"),
    "st_ok": ("Помощник подключён", "Helper connected"), "st_lost": ("Связь потеряна, переподключение…", "Connection lost, reconnecting…"),
    "overlay_wait": ("Ожидание помощника…", "Waiting for the helper…"),
    "menu_run": ("Меню:  [P] пауза    [X] завершить сеанс    [Esc] назад", "Menu:  [P] pause    [X] end the session    [Esc] back"),
    "menu_paused": ("Пауза.  [R] продолжить    [X] завершить сеанс    [Esc] назад", "Paused.  [R] continue    [X] end the session    [Esc] back"),
    "confirm_end": ("Завершить сеанс полностью? Код перестанет работать, понадобится новый.   [Y] да   [N] нет", "End the session completely? The code stops working and a new one is needed.   [Y] yes   [N] no"),
    "st_paused": ("Пауза: помощник ждёт. Esc — меню", "Paused: the helper is waiting. Esc = menu"),
    "persist_q": ("Сохранять сеанс при потере интернета и после перезагрузки (код не изменится)? [Д/н]: ", "Keep this session through internet loss and reboots (the code stays the same)? [Y/n]: "),
    "overlay_paused": ("Пауза", "Paused"), "resuming": ("Продолжаю прошлый сеанс", "Resuming the previous session"),
    "ready": ("Подключено. Жду действий.", "Connected. Waiting for actions."),
    "mode": ("Режим: [1] спрашивать про каждое действие (рекомендуется)  [2] авто, без вопросов  [3] постоянный доступ (Esc только пауза, завершить может только админ): ",
             "Mode: [1] ask before every action (recommended)  [2] auto, no questions  [3] unattended (Esc only pauses, only the admin ends it): "),
    "allow": ("Разрешить: ", "Allow: "),
    "keys": ("да", "yes"), "always": ("всегда", "always"), "no": ("нет", "no"), "endk": ("завершить сеанс", "end the session"), "until": ("до конца сеанса", "until the session ends"),
    "ok1": ("разрешено", "allowed"), "ok2": ("дальше без вопросов", "no more questions for"), "den": ("отклонено", "denied"), "esc": ("сеанс завершён (Esc)", "session ended (Esc)"),
    "overlay": ("Удалённое управление", "Remote control"),
    "lost": ("Связь потеряна, переподключение…", "Connection lost, reconnecting…"),
}
t = lambda k: T[k][0 if RU else 1]
ASK_TOOLS = {"run", "start_process", "fetch_file", "write_file", "edit_file", "push_file", "fsop", "util", "ui_click", "ui_set", "click", "move", "drag", "type_text", "press_key", "scroll", "actions", "mcp_start", "mcp_call"}
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
        path = capture_file(d); fo = (0, 0, 1.0)
        try:  # crop to one monitor if asked, downscale, remember offset+factor for click coordinates
            import gi; gi.require_version("GdkPixbuf", "2.0"); from gi.repository import GdkPixbuf
            pb = GdkPixbuf.Pixbuf.new_from_file(path); org = (0, 0)
            if want is not None:
                x, y, w, h = mons[int(want)]; pb = pb.new_subpixbuf(x, y, w, h); org = (x, y)
            if a.get("region") and not view:   # a part of the screen, in the coordinates of the last screenshot
                r = a["region"]; x = max(0, int(r["x"] * SCALE + ORIGIN[0])); y = max(0, int(r["y"] * SCALE + ORIGIN[1]))
                w = max(16, min(int(r["w"] * SCALE), pb.get_width() - (x - org[0]))); h = max(16, min(int(r["h"] * SCALE), pb.get_height() - (y - org[1])))
                pb = pb.new_subpixbuf(x - org[0], y - org[1], w, h); org = (x, y)
            w = pb.get_width(); sc = max(1.0, w / cap)
            if sc > 1: pb = pb.scale_simple(cap, int(pb.get_height() / sc), GdkPixbuf.InterpType.BILINEAR)
            if not view: SCALE, ORIGIN = sc, org
            fo = (org[0], org[1], sc)
            _, buf = pb.save_to_bufferv("jpeg", ["quality"], [str(qual)]); mime = "image/jpeg"
        except Exception:
            if not view: SCALE, ORIGIN = 1.0, (0, 0)
            fo = (0, 0, 1.0)
            with open(path, "rb") as f: buf = f.read()
            mime = "image/jpeg" if path.endswith("jpg") else "image/png"
        h = hashlib.md5(buf).hexdigest()
        if a.get("prev") and a["prev"] == h: return {"same": True, "h": h}   # nothing changed: send nothing
        return {"jpeg": bytes(buf), "mime": mime, "h": h, "ox": fo[0], "oy": fo[1], "sc": fo[2]}
    finally:
        shutil.rmtree(d, ignore_errors=True)


# ---- mouse & keyboard (X11 XTest through ctypes: no xdotool needed) ---------------------------------
def pointer_pos():
    X = xlib(); x11 = X["x"]
    r, c = ctypes.c_ulong(), ctypes.c_ulong(); rx, ry, wx, wy, mk = ctypes.c_int(), ctypes.c_int(), ctypes.c_int(), ctypes.c_int(), ctypes.c_uint()
    x11.XQueryPointer(X["d"], x11.XDefaultRootWindow(X["d"]), ctypes.byref(r), ctypes.byref(c), ctypes.byref(rx), ctypes.byref(ry), ctypes.byref(wx), ctypes.byref(wy), ctypes.byref(mk))
    return rx.value, ry.value


def _ease(p):
    """cubic-bezier(0.45, 0, 0.15, 1): a slow start, a quick middle, a long soft landing on the target (what a hand does)"""
    x1, y1, x2, y2 = 0.45, 0.0, 0.15, 1.0; lo, hi = 0.0, 1.0
    for _ in range(18):
        t = (lo + hi) / 2
        if 3 * (1 - t) ** 2 * t * x1 + 3 * (1 - t) * t * t * x2 + t ** 3 < p: lo = t
        else: hi = t
    t = (lo + hi) / 2
    return 3 * (1 - t) ** 2 * t * y1 + 3 * (1 - t) * t * t * y2 + t ** 3


def glide(x, y, dur=None, straight=False):
    """Move the real pointer like a hand would: a slightly curved path, slow start, fast middle, soft landing; paced by the clock (not by sleeps),
    about 120 steps/s. The overlay arrow follows it and turns its tip into the direction of movement."""
    X = xlib(); cx, cy = pointer_pos(); dx, dy = x - cx, y - cy; dist = math.hypot(dx, dy)
    if dist < 2: return
    dur = dur or min(1.3, 0.34 + dist * 0.0006)
    nx, ny = -dy / dist, dx / dist
    if ny > 0: nx, ny = -nx, -ny                      # the arc bulges upwards
    bend = 0.0 if straight else min(90.0, dist * 0.12); qx, qy = (cx + x) / 2 + nx * bend, (cy + y) / 2 + ny * bend
    t0 = time.monotonic(); last = None
    while True:
        p = (time.monotonic() - t0) / dur
        if p >= 1.0: break
        k = _ease(p); px_ = int(round((1 - k) ** 2 * cx + 2 * (1 - k) * k * qx + k * k * x)); py_ = int(round((1 - k) ** 2 * cy + 2 * (1 - k) * k * qy + k * k * y))
        if (px_, py_) != last: X["t"].XTestFakeMotionEvent(X["d"], -1, px_, py_, 0); sync(X); last = (px_, py_)
        time.sleep(0.007)
    X["t"].XTestFakeMotionEvent(X["d"], -1, x, y, 0); sync(X)


def _target(a, kx="x", ky="y"):
    if a.get("raw"): return int(a[kx]), int(a[ky])   # real screen pixels (the live viewer)
    return int(a[kx] * SCALE) + ORIGIN[0], int(a[ky] * SCALE) + ORIGIN[1]


def watch(a):
    """a few seconds of the screen as one picture: frames in a grid; the text says when and how much it changed"""
    import gi; gi.require_version("GdkPixbuf", "2.0"); from gi.repository import GdkPixbuf
    sec = min(10.0, max(1.0, float(a.get("seconds") or 3))); fps = min(3.0, max(1.0, float(a.get("fps") or 2)))   # a screen grab here takes a while
    n = max(2, min(24, int(round(sec * fps)))); cols = 2 if n <= 4 else 3 if n <= 9 else 4; rows = (n + cols - 1) // cols
    tw, sheet, prev, changes, last, t0 = 400, None, None, [], -1.0, time.monotonic()
    d = tempfile.mkdtemp()
    try:
        for i in range(n):
            while time.monotonic() - t0 < i / fps: time.sleep(0.01)
            t = time.monotonic() - t0; pb = GdkPixbuf.Pixbuf.new_from_file(capture_file(d))
            if a.get("monitor") is not None:
                x, y, w, h = monitors()[int(a["monitor"])]; pb = pb.new_subpixbuf(x, y, w, h)
            th = int(tw * pb.get_height() / pb.get_width())
            if sheet is None: sheet = GdkPixbuf.Pixbuf.new(GdkPixbuf.Colorspace.RGB, False, 8, cols * tw, rows * th); sheet.fill(0x020a06ff)
            pb.scale_simple(tw, th, GdkPixbuf.InterpType.BILINEAR).copy_area(0, 0, tw, th, sheet, (i % cols) * tw, (i // cols) * th)
            g = pb.scale_simple(64, 36, GdkPixbuf.InterpType.NEAREST).get_pixels()
            ch = 0.0 if prev is None else sum(1 for k in range(0, min(len(g), len(prev)), 3) if abs(g[k + 1] - prev[k + 1]) > 20) / (len(g) / 3)
            prev = g; changes.append(round(ch * 100, 1))
            if ch >= 0.004: last = t
        _, buf = sheet.save_to_bufferv("jpeg", ["quality"], ["62"])
    finally:
        shutil.rmtree(d, ignore_errors=True)
    moving = sum(1 for c_ in changes[1:] if c_ >= 0.4)
    summ = f"nothing moved during {sec} s" if not moving else (f"changes in {moving} of {n - 1} frames, settled after {last:.1f} s" if last < sec - 2 / fps else f"still changing at the end ({moving} of {n - 1} frames changed)")
    return {"jpeg": bytes(buf), "mime": "image/jpeg", "text": f"{n} frames over {sec} s (left to right, top to bottom), {summ}. Change per frame (%): {', '.join(map(str, changes))}"}


def focus_window(a):
    """bring a window to the front by title or process name through the window manager (wmctrl), without clicking"""
    if not shutil.which("wmctrl"): raise RuntimeError("wmctrl is not installed here: click the window's title bar instead (or run: sudo apt install wmctrl)")
    rows = subprocess.run(["wmctrl", "-lp"], capture_output=True, text=True).stdout.splitlines()
    if not a.get("title") and not a.get("process"): return {"text": "open windows: " + " | ".join(r.split(None, 4)[-1] for r in rows if len(r.split(None, 4)) == 5)}
    want = (a.get("title") or "").lower()
    for r in rows:
        p = r.split(None, 4)
        if len(p) < 5: continue
        name = ""
        try: name = open(f"/proc/{p[2]}/comm").read().strip()
        except Exception: pass
        if (want and want in p[4].lower()) or (a.get("process") and a["process"].lower() in name.lower()):
            subprocess.run(["wmctrl", "-ia", p[0]]); time.sleep(0.25); return {"text": "focused: " + p[4]}
    raise RuntimeError("No such window. Open windows: " + " | ".join(r.split(None, 4)[-1] for r in rows if len(r.split(None, 4)) == 5))


# --- ui:begin   ui_tree / ui_click / ui_set: the controls of a window as text through AT-SPI (GTK, Qt, Electron and Chrome with accessibility on)
UI = {"cache": [], "picked": None, "init": False}
UI_INTER = {"button", "toggle", "check", "radio", "edit", "link", "listitem", "menuitem", "combo", "slider", "spinner", "tabitem", "treeitem", "document"}
UI_ROLES = {"push button": "button", "toggle button": "toggle", "check box": "check", "check menu item": "check", "radio button": "radio", "radio menu item": "radio",
            "entry": "edit", "text": "edit", "password text": "edit", "terminal": "edit", "label": "text", "static": "text", "menu item": "menuitem", "page tab": "tabitem",
            "list item": "listitem", "combo box": "combo", "link": "link", "spin button": "spinner", "slider": "slider", "tree item": "treeitem", "document web": "document",
            "document frame": "document", "document text": "document", "frame": "window", "dialog": "window", "window": "window", "alert": "window"}


def _atspi():
    if not (os.environ.get("DBUS_SESSION_BUS_ADDRESS") or os.path.exists(f"/run/user/{os.getuid()}/bus")): raise RuntimeError("No desktop session bus here (a server or a headless session): there are no windows to read. Use screenshot and click.")
    try:
        import gi
        gi.require_version("Atspi", "2.0")
        from gi.repository import Atspi
        if not UI["init"]: Atspi.init(); UI["init"] = True
        return Atspi
    except Exception as e:
        raise RuntimeError("AT-SPI is not available here (" + str(e).splitlines()[0][:80] + "). Install: sudo apt install gir1.2-atspi-2.0 python3-gi, and enable accessibility "
                           "(gsettings set org.gnome.desktop.interface toolkit-accessibility true). Until then use screenshot and click.")


def _ui_has(At, ss, name):
    try: return ss.contains(getattr(At.StateType, name))
    except Exception: return False


def _ui_node(At, acc, depth):
    try:
        role = acc.get_role_name() or ""; ss = acc.get_state_set()
        if depth and not _ui_has(At, ss, "SHOWING"): return None
        x = y = w = h = 0; comp = acc.get_component_iface()
        if comp:
            r = comp.get_extents(At.CoordType.SCREEN); x, y, w, h = r.x, r.y, r.width, r.height
        typ = UI_ROLES.get(role, role.replace(" ", "")); val = None
        if typ == "edit" and role != "password text":
            ti = acc.get_text_iface()
            if ti:
                n = At.Text.get_character_count(ti); val = At.Text.get_text(ti, 0, min(n, 200)) if n else ""
        has = lambda s: _ui_has(At, ss, s)
        flags = []
        enabled = has("ENABLED") or has("SENSITIVE")
        if not enabled: flags.append("disabled")
        if has("FOCUSED"): flags.append("focused")
        if has("CHECKED"): flags.append("checked")
        if has("SELECTED"): flags.append("selected")
        if has("EXPANDED"): flags.append("expanded")
        elif has("EXPANDABLE"): flags.append("collapsed")
        if typ == "edit" and not has("EDITABLE"): flags.append("readonly")
        return {"acc": acc, "type": typ, "name": (acc.get_name() or "").strip(), "val": val, "flags": flags, "enabled": enabled, "x": x, "y": y, "w": w, "h": h, "role": role}
    except Exception: return None


def _ui_walk(At, root, limit=6000, secs=8):
    out, budget, stop = [], [limit], time.time() + secs
    def rec(acc, depth):
        if budget[0] <= 0 or time.time() > stop or depth > 40: return
        budget[0] -= 1
        n = _ui_node(At, acc, depth)
        if n is None and depth: return
        if n: out.append(n)
        try: cnt = acc.get_child_count()
        except Exception: return
        for i in range(min(cnt, 400)):
            try: ch = acc.get_child_at_index(i)
            except Exception: continue
            if ch is not None: rec(ch, depth + 1)
            if budget[0] <= 0 or time.time() > stop: break
    rec(root, 0)
    return out


def _ui_ancestors():
    out, p = set(), os.getpid()
    for _ in range(25):
        out.add(p)
        try: p = int(open(f"/proc/{p}/stat").read().rsplit(")", 1)[1].split()[1])
        except Exception: break
        if p <= 1: break
    return out


def _ui_window(At, key):
    desk = At.get_desktop(0); wins = []
    for i in range(desk.get_child_count()):
        app = desk.get_child_at_index(i)
        if app is None: continue
        try: an = app.get_name() or ""; pid = app.get_process_id()
        except Exception: continue
        for j in range(app.get_child_count()):
            w = app.get_child_at_index(j)
            if w is None: continue
            try: ss = w.get_state_set(); wins.append((w, an, w.get_name() or "", pid, _ui_has(At, ss, "ACTIVE"), _ui_has(At, ss, "SHOWING")))
            except Exception: continue
    key = (key or "").lower()
    if key:
        for w, an, title, pid, act, show in wins:
            if key in title.lower() or key in an.lower(): return w, an, title
    else:
        ours = _ui_ancestors()   # the terminal this agent runs in is not what the helper wants to read
        for want_active in (True, False):
            for w, an, title, pid, act, show in wins:
                if pid not in ours and show and (act or not want_active) and title: return w, an, title
    raise RuntimeError(("No such window." if key else "No window in front.") + " Open windows: " + " | ".join(f"{an}: {cut(title, 50)}" for w, an, title, pid, act, show in wins if title))


def _ui_wanted(n, allv):
    if n["w"] <= 0 or n["h"] <= 0: return False
    if allv: return True
    if n["type"] in ("window", "text"): return bool(n["name"])
    if n["type"] not in UI_INTER: return False
    return bool(n["name"] or n["val"]) or n["type"] in ("edit", "document")


def _ui_c(n): return int(n["x"] + n["w"] / 2), int(n["y"] + n["h"] / 2)


def _ui_sc(cx, cy): return int((cx - ORIGIN[0]) / SCALE), int((cy - ORIGIN[1]) / SCALE)   # real pixels -> screenshot pixels


def _ui_ocr(rect):
    """the text of a window that shows no controls (a game, a self-drawn window), read from its picture by tesseract when it is installed: lines {t, x, y, w, h} in real pixels"""
    exe = shutil.which("tesseract")
    if not exe: raise RuntimeError("OCR needs tesseract (sudo apt install tesseract-ocr); until then use screenshot.")
    import gi; gi.require_version("GdkPixbuf", "2.0"); from gi.repository import GdkPixbuf
    d = tempfile.mkdtemp()
    try:
        pb = GdkPixbuf.Pixbuf.new_from_file(capture_file(d)); x, y, w, h = rect
        x, y = max(0, x), max(0, y); w, h = min(w, pb.get_width() - x), min(h, pb.get_height() - y)
        if w < 8 or h < 8: return []
        png = os.path.join(d, "w.png"); pb.new_subpixbuf(x, y, w, h).savev(png, "png", [], [])
        out = subprocess.run([exe, png, "stdout", "--psm", "11", "tsv"], capture_output=True, text=True, timeout=60).stdout
    finally: shutil.rmtree(d, ignore_errors=True)
    lines = {}
    for ln in out.splitlines()[1:]:
        c = ln.split("\t")
        if len(c) < 12 or not c[11].strip() or float(c[10]) < 30: continue
        l, t, wd, ht = int(c[6]), int(c[7]), int(c[8]), int(c[9])
        o = lines.setdefault(tuple(c[2:5]), {"w": [], "x0": l, "y0": t, "x1": l + wd, "y1": t + ht})
        o["w"].append(c[11]); o["x0"] = min(o["x0"], l); o["y0"] = min(o["y0"], t); o["x1"] = max(o["x1"], l + wd); o["y1"] = max(o["y1"], t + ht)
    return [{"t": " ".join(o["w"]), "x": x + o["x0"], "y": y + o["y0"], "w": o["x1"] - o["x0"], "h": o["y1"] - o["y0"]} for o in lines.values()]


def _ui_rect(w):
    r = w.get_component_iface().get_extents(0)   # 0 = screen coordinates
    return r.x, r.y, r.width, r.height


def _ui_ocr_find(At, name, window):
    w, an, title = _ui_window(At, window); o = _ui_ocr(_ui_rect(w)); low = name.lower()
    hit = [l for l in o if l["t"].strip().lower() == low] or [l for l in o if low in l["t"].lower()]
    if not hit: return None
    if len(hit) > 1: raise RuntimeError(f"Several texts on the screen match '{name}': " + "; ".join(f'"{cut(l["t"], 40)}" at ' + "%d,%d" % _ui_sc(l["x"] + l["w"] // 2, l["y"] + l["h"] // 2) for l in hit[:6]) + ". Use click {x,y} on the one you mean.")
    return hit[0]


def ui_tree(a):
    At = _atspi(); w, an, title = _ui_window(At, a.get("window")); nodes = _ui_walk(At, w)
    UI["cache"] = []; mx = int(a.get("max") or 120); q = (a.get("query") or "").lower(); allv = bool(a.get("all"))
    lines = [f'window "{cut(title, 80)}" ({an})']; shown = total = 0
    for n in nodes[1:]:
        if not _ui_wanted(n, allv): continue
        if q and q not in (n["name"] + " " + (n["val"] or "")).lower(): continue
        total += 1
        if shown >= mx: continue
        shown += 1; UI["cache"].append(n["acc"]); sx, sy = _ui_sc(*_ui_c(n))
        lines.append(f'{shown} {n["type"]}' + (f' "{cut(n["name"], 70)}"' if n["name"] else "") + (f' ="{cut(n["val"], 60)}"' if n["val"] else "") + f" @{sx},{sy}" + "".join(" " + f for f in n["flags"]))
    if not shown or (a.get("ocr") and not q):
        empty = not shown and not q
        head = "\n".join(lines) + ("\nnothing readable here" + (" (this window exposes no controls: a game, a custom-drawn app, or accessibility is off for it)" if empty else f" matches '{q}'") if not shown else "")
        if empty or a.get("ocr"):
            try:
                o = _ui_ocr(_ui_rect(w))
                return {"text": head + ("\ntext read from the picture (OCR; click {x,y} or ui_click {name:\"text\"} presses it):\n" + "\n".join('ocr "%s" @%d,%d' % (cut(l["t"], 70), *_ui_sc(l["x"] + l["w"] // 2, l["y"] + l["h"] // 2)) for l in o[:mx]) if o else "\nOCR found no text either: use screenshot.")}
            except Exception as e: return {"text": head + "\n" + str(e)}
        return {"text": head + ": use screenshot."}
    if total > shown: lines.append(f"... {total - shown} more (use query or max)")
    return {"text": "\n".join(lines)}


def _ui_pick(At, a, typ):
    pid_ = a.get("id"); name = a.get("name") or ""
    if pid_:
        pid_ = int(pid_)
        if pid_ > len(UI["cache"]): raise RuntimeError(f"No control #{pid_}: run ui_tree first, ids come from the last ui_tree")
        acc = UI["cache"][pid_ - 1]
        n = _ui_node(At, acc, 0)
        if not n: raise RuntimeError(f"Control #{pid_} is gone (the window changed): run ui_tree again")
    else:
        if not name: raise RuntimeError("Give an id (from ui_tree) or a name")
        w, an, title = _ui_window(At, a.get("window")); nodes = _ui_walk(At, w); want = (typ or "").lower().replace(" ", "")
        want = {"checkbox": "check", "combobox": "combo", "hyperlink": "link", "radiobutton": "radio", "textbox": "edit", "input": "edit", "field": "edit"}.get(want, want)
        low = name.lower(); best, rank_best = [], 0
        for n in nodes[1:]:
            if n["w"] <= 0 or n["h"] <= 0: continue
            if want and not (n["type"] == want or (want == "tab" and n["type"] == "tabitem") or (want == "menu" and n["type"] == "menuitem") or (want == "item" and n["type"].endswith("item"))): continue
            nm = n["name"].lower(); sc = 3 if nm == low else 2 if nm.startswith(low) else 1 if low in nm else 0
            if not sc: continue
            rank = sc * 10 + (5 if n["type"] in UI_INTER else 0) + (1 if n["enabled"] else 0)
            if rank > rank_best: rank_best, best = rank, []
            if rank == rank_best and not any(o["type"] == n["type"] and abs(o["x"] - n["x"]) < 3 and abs(o["y"] - n["y"]) < 3 for o in best): best.append(n)
        if not best: raise RuntimeError(f"No control named '{name}'" + (f" of type {typ}" if typ else "") + " in this window: run ui_tree (query) to see what is there, or use screenshot.")
        if len(best) > 1:
            UI["cache"] = [o["acc"] for o in best[:8]]
            raise RuntimeError(f"Several controls match '{name}': " + "; ".join(f'#{i} {o["type"]} "{cut(o["name"], 40)}" at {o["x"]},{o["y"]}' for i, o in enumerate(best[:8], 1)) + "; repeat with id (the numbers above) or a more exact name / type.")
        n = best[0]; acc = n["acc"]
    UI["picked"] = n
    return f'{n["type"]} "{cut(n["name"], 50)}"', n


def _ui_do(acc):
    ai = acc.get_action_iface()
    if not ai: return None
    names = [(ai.get_action_name(i) or "").lower() for i in range(ai.get_n_actions())]
    for want in ("click", "press", "activate", "toggle", "select", "jump", "open"):
        if want in names and ai.do_action(names.index(want)): return want
    if names and ai.do_action(0): return names[0]
    return None


def ui_click(a):
    At = _atspi()
    try: d, n = _ui_pick(At, a, a.get("type"))
    except RuntimeError as e:
        if not str(e).startswith("No control named") or a.get("id"): raise
        try: o = _ui_ocr_find(At, a["name"], a.get("window"))
        except RuntimeError as e2:
            if str(e2).startswith("Several texts"): raise
            o = None
        if not o: raise
        sx, sy = _ui_sc(o["x"] + o["w"] // 2, o["y"] + o["h"] // 2)
        return {"text": f"no control of that name, but the text '{o['t']}' is on the screen (OCR): clicked it; " + click({"x": sx, "y": sy, "button": "right" if a.get("right") else "left", "double": bool(a.get("double"))})["text"]}
    sx, sy = _ui_sc(*_ui_c(n))
    if a.get("right") or a.get("double"): return {"text": f"{d}: " + click({"x": sx, "y": sy, "button": "right" if a.get("right") else "left", "double": bool(a.get("double"))})["text"]}
    if not n["enabled"]: raise RuntimeError("the control is disabled")
    overlay_send("active"); glide(sx, sy); overlay_send(f"click {sx} {sy} left")
    try: how = _ui_do(n["acc"])
    except Exception: how = None
    if how is None: return {"text": f"{d}: no action of its own, clicked it; " + click({"x": sx, "y": sy})["text"]}
    time.sleep(0.4); return {"text": f"{d}: pressed ({how})"}


def ui_set(a):
    At = _atspi(); d, n = _ui_pick(At, a, ""); acc = n["acc"]; v = str(a.get("value", "")); sx, sy = _ui_sc(*_ui_c(n))
    overlay_send("active"); glide(sx, sy)
    ei = acc.get_editable_text_iface()
    if ei:
        if not At.EditableText.set_text_contents(ei, v): raise RuntimeError("the control refused the text (read-only?)")
        if n["role"] == "password text": return {"text": f"{d}: set (password, not shown)"}
        ti = acc.get_text_iface(); now = At.Text.get_text(ti, 0, min(At.Text.get_character_count(ti), 200)) if ti else v
        return {"text": f"{d}: " + ("set" if now == v else f'set, but it now holds "{cut(now, 80)}" (the control may reformat the value, or ignore it: check with ui_tree)')}
    comp = acc.get_component_iface()
    if comp: comp.grab_focus()
    time.sleep(0.15); press_key({"keys": "ctrl+a"}); return {"text": f"{d}: typed (it has no direct value access); " + type_text({"text": v})["text"]}
# --- ui:end


def trace(a):
    """read along: to the start of the line, then slide under it at reading pace (no click)"""
    xlib(); overlay_send("active"); x1, y1 = _target(a); x2, y2 = _target(a, "x2", "y2")
    glide(x1, y1); time.sleep(0.14); glide(x2, y2, min(4.0, max(0.5, math.hypot(x2 - x1, y2 - y1) / 520.0)), True); return {"text": "ok"}


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


def focus_window():
    """the window that has the keyboard focus (None when unknown): the terminal where the friend answers takes it, so it is given back afterwards"""
    try:
        X = xlib(); x11 = X["x"]; w = ctypes.c_ulong(); rv = ctypes.c_int()
        x11.XGetInputFocus.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_int)]   # without argtypes the Display pointer is cut to 32 bits: segfault
        x11.XGetInputFocus(X["d"], ctypes.byref(w), ctypes.byref(rv)); return w.value if w.value > 1 else None
    except Exception: return None


def restore_focus(w):
    if not w: return
    try:
        X = xlib(); X["x"].XSetInputFocus.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_ulong]
        X["x"].XSetInputFocus(X["d"], ctypes.c_ulong(w), 1, 0); sync(X); time.sleep(0.15)
    except Exception: pass


ASK_GROUP = {"ui_click": "input", "ui_set": "input", "click": "input", "move": "input", "drag": "input", "scroll": "input", "type_text": "input", "press_key": "input", "actions": "input", "run": "commands",
             "start_process": "commands", "util": "commands", "write_file": "files", "edit_file": "files", "push_file": "files", "fetch_file": "files", "fsop": "files", "mcp_start": "mcp", "mcp_call": "mcp"}
GROUP_LABEL = {"input": ("мышь и клавиатура", "mouse & keyboard"), "commands": ("команды", "commands"), "files": ("файлы", "files"), "mcp": ("MCP", "MCP")}
ALLOWED, AI = set(), {"t": 0.0, "pos": None, "fw": None}
END = threading.Event()
KEYQ = queue.Queue(); PUMP = {"on": False, "old": None}
HDR = 7   # lines of the pinned header
OP = {"seen": False}   # has the helper sent anything yet
ORANGE = "38;5;208"
def c(code, x): return f"\033[{code}m{x}\033[0m"


def cut(x, n): x = str(x).replace("\n", " "); return x if len(x) <= n else x[:n] + "…"


def step_text(st):
    """one small action as a short sentence"""
    d = st.get("do") or ""; x, y = st.get("x"), st.get("y")
    if d == "move": return f"подвинуть мышь к ({x}, {y})" if RU else f"move the mouse to ({x}, {y})"
    if d == "click":
        w = {"right": ("правый клик", "right-click"), "middle": ("средний клик", "middle-click")}.get(st.get("button"), ("нажать", "click"))[0 if RU else 1]
        return (f"двойной клик ({x}, {y})" if RU else f"double-click ({x}, {y})") if st.get("double") else f"{w} ({x}, {y})"
    if d == "drag": return f"перетащить ({x}, {y}) → ({st.get('x2')}, {st.get('y2')})" if RU else f"drag ({x}, {y}) → ({st.get('x2')}, {st.get('y2')})"
    if d == "scroll": return f"прокрутить ({st.get('amount', 3)})" if RU else f"scroll ({st.get('amount', 3)})"
    if d == "type": return 'ввести "' + cut(st.get("text", ""), 60) + '"' if RU else 'type "' + cut(st.get("text", ""), 60) + '"'
    if d == "key": return f"нажать клавиши {st.get('keys')}" if RU else f"press {st.get('keys')}"
    if d == "wait": return f"подождать {st.get('ms', 500)} мс" if RU else f"wait {st.get('ms', 500)} ms"
    return d


def steps_of(name, a):
    """the steps of a tool call; a move right before a click on the same spot is shown as one step"""
    if name == "actions": raw = list(a.get("steps") or [])
    else: raw = [dict(a, do={"type_text": "type", "press_key": "key"}.get(name, name))]
    out = []
    for st in raw:
        if out and out[-1].get("do") == "move" and st.get("do") == "click" and (out[-1].get("x"), out[-1].get("y")) == (st.get("x"), st.get("y")): out.pop()
        out.append(st)
    return out


def describe(name, a):
    if name in ("ui_click", "ui_set"):
        who = a.get("name") or "#" + str(a.get("id")); return [(("нажать: " if RU else "press: ") + cut(who, 60)) if name == "ui_click" else (("ввести в поле " if RU else "fill in ") + cut(who, 40) + ": " + cut(a.get("value", ""), 40))]
    if name in ASK_GROUP and ASK_GROUP[name] == "input": return [step_text(st) for st in steps_of(name, a)]
    ru = RU
    return [{"run": ("команда: ", "command: "), "start_process": ("запустить: ", "start: "), "write_file": ("записать файл: ", "write file: "), "fetch_file": ("скопировать файл: ", "copy file: "), "edit_file": ("изменить файл: ", "edit file: "), "push_file": ("получить файл: ", "receive file: "), "util": ("утилита: ", "utility: "),
             "mcp_start": ("запустить MCP: ", "start MCP: "), "mcp_call": ("вызвать MCP: ", "call MCP: ")}.get(name, (name + " ", name + " "))[0 if ru else 1]
            + cut((a.get("op", "") + " " if name == "util" else "") + (a.get("command") or a.get("path") or a.get("name") or a.get("url") or json.dumps(a, ensure_ascii=False)), 90)]


QUIET = {"ui_tree": ("читаю элементы окна", "reading the window controls"), "watch": ("смотрю, что происходит на экране", "watching the screen"), "trace": ("читаю текст на экране", "reading text on the screen"), "agent_log": ("читаю журнал", "reading the log"), "screenshot": ("смотрю на экран", "looking at the screen"), "sysinfo": ("смотрю сведения о системе", "reading system info"), "list_dir": ("смотрю папку", "listing a folder"),
         "read_file": ("читаю файл", "reading a file"), "mcp_tools": ("смотрю MCP", "listing MCP tools"), "mcp_stop": ("останавливаю MCP", "stopping MCP"),
         "tree": ("смотрю папки", "looking through folders"), "find": ("ищу файлы", "searching files"), "system": ("смотрю состояние системы", "reading the system state")}


LASTQ = [None]
def line_for(name, a):
    if name in QUIET:
        if LASTQ[0] == name: return None   # "looking at the screen" once, not after every picture
        LASTQ[0] = name; return c("2", "  · " + QUIET[name][0 if RU else 1])
    LASTQ[0] = None
    d = describe(name, a)
    return c("36", "  → ") + (d[0] if len(d) == 1 else (c("1", "действия:" if RU else "actions:") + "".join(f"\n      {i}. {x}" for i, x in enumerate(d, 1))))


# ---- sounds: soft bells made on the fly (no files shipped), played by whatever the system has
def make_wav(notes, sr=22050):
    import struct, wave, io
    total = max(st + du for _, st, du, _ in notes); buf = [0.0] * int(sr * (total + 0.1))
    for f, st, du, amp in notes:
        i0 = int(st * sr)
        for i in range(int(du * sr)):
            tt = i / sr; env = (1 - math.exp(-tt * 400)) * math.exp(-tt * 5.5)
            v = amp * env * (math.sin(2 * math.pi * f * tt) + 0.28 * math.sin(2 * math.pi * 2 * f * tt) + 0.08 * math.sin(2 * math.pi * 3.01 * f * tt))
            if i0 + i < len(buf): buf[i0 + i] += v
    bio = io.BytesIO(); w = wave.open(bio, "wb"); w.setnchannels(1); w.setsampwidth(2); w.setframerate(sr)
    w.writeframes(b"".join(struct.pack("<h", max(-32000, min(32000, int(v * 22000)))) for v in buf)); w.close()
    return bio.getvalue()


SOUNDS = {"ask": [(784.0, 0.0, 0.55, 0.5), (1046.5, 0.16, 0.7, 0.5)], "ok": [(523.25, 0.0, 0.5, 0.4), (659.25, 0.12, 0.5, 0.4), (783.99, 0.24, 0.7, 0.4)]}
SOUND_FILES = {}


def play(kind):
    try:
        if kind not in SOUND_FILES:
            f = os.path.join(tempfile.gettempdir(), f"helpermcp-{kind}-{os.getpid()}.wav"); open(f, "wb").write(make_wav(SOUNDS[kind])); SOUND_FILES[kind] = f; TMP.append(f)
        for cmd in (["paplay"], ["pw-play"], ["aplay", "-q"], ["ffplay", "-nodisp", "-autoexit", "-loglevel", "quiet"]):
            if shutil.which(cmd[0]): subprocess.Popen(cmd + [SOUND_FILES[kind]], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); return
        sys.stdout.write("\a"); sys.stdout.flush()
    except Exception: pass


def copy_clip(text):
    for cmd in (["wl-copy"], ["xclip", "-selection", "clipboard"], ["xsel", "--clipboard", "--input"]):
        if shutil.which(cmd[0]):
            try:
                pr = subprocess.Popen(cmd, stdin=subprocess.PIPE, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL, start_new_session=True); pr.stdin.write(text.encode()); pr.stdin.close(); return True
            except Exception: pass
    overlay_send("clip " + text); return bool(OVERLAY_PROC)   # the overlay (GTK) owns the clipboard while the session lasts


def _w():
    try: return max(40, min(200, shutil.get_terminal_size().columns))
    except Exception: return 80


def row(text, code="33", pre=""):
    """one line of the pinned header: a box over the full console width, the text centred, closed on the right"""
    w = _w() - 2; text = text[:w]; l = (w - len(text)) // 2
    return c("33", "│") + " " * l + (c(code, text) if code else text) + " " * (w - len(text) - l) + c("33", "│")


def status_line():
    st = "lost" if NET["s"] == "lost" else ("paused" if PAUSED.is_set() else ("ok" if OP["seen"] else "wait"))
    return row("● " + t("st_ok") if st == "ok" else ("⏸ " + t("st_paused") if st == "paused" else "◌ " + t("st_lost" if st == "lost" else "st_wait")), "1;32" if st == "ok" else "1;" + ORANGE)


def show_status():
    """redraw only the status row of the pinned header"""
    if PUMP.get("hdr") and sys.stdout.isatty():
        sys.stdout.write("\0337\033[5;1H\033[2K" + status_line() + "\0338"); sys.stdout.flush()


def header(code, copied, mode="ask"):
    try: rows = shutil.get_terminal_size().lines
    except Exception: rows = 24
    w = _w() - 2; title = " Remote Help "; l = (w - len(title)) // 2
    tail = "   ✓ copied to the clipboard" if copied else ""
    plain = "Session code   " + code + " " + tail; pad = max(0, (w - len(plain)) // 2)
    code_row = c("33", "│") + " " * pad + c("33", "Session code  ") + c("30;43", f" {code} ") + c("32", tail) + " " * max(0, w - pad - len(plain)) + c("33", "│")
    host = urllib.parse.urlparse(RELAY).hostname or RELAY
    PUMP["hdr"] = True
    mode_text = "unattended access" if mode == "unattended" else "auto, no questions" if mode == "auto" else "ask before every action"
    esc_text = "Press Esc at any time to pause. Only the administrator ends this session." if mode == "unattended" else "Press Esc at any time to pause or end the session."
    sys.stdout.write("\033[2J\033[H" + c("33", "┌" + "─" * l + title + "─" * (w - l - len(title)) + "┐") + "\n" + code_row + "\n"
                     + row("Tell this code to the person who is helping you.") + "\n" + row(f"Mode: {mode_text}   |   Server: {host}", "2;33") + "\n"
                     + status_line() + "\n" + row(esc_text) + "\n" + c("33", "└" + "─" * w + "┘") + "\n" + f"\033[{HDR + 1};{rows}r\033[{HDR + 1};1H")
    sys.stdout.flush()


def end_ui():
    try: sys.stdout.write("\033[r\033[999;1H\n"); sys.stdout.flush()
    except Exception: pass


def key_pump():
    """one reader for the keyboard: Esc ends the session at any moment, the rest goes to the questions"""
    import termios, tty, select
    fd = sys.stdin.fileno(); PUMP["old"] = termios.tcgetattr(fd); tty.setcbreak(fd); PUMP["on"] = True
    import atexit; atexit.register(lambda: (termios.tcsetattr(fd, termios.TCSADRAIN, PUMP["old"]), end_ui()))
    while True:
        try: ch = os.read(fd, 1)
        except OSError: return
        if not ch: return
        if ch == b"\x1b":
            if select.select([fd], [], [], 0.05)[0]:
                os.read(fd, 8); continue                    # an arrow key or similar
            if MODE["m"] == "unattended": set_paused(not PAUSED.is_set())   # mode 3: Esc only pauses, the admin panel ends the session
            else: esc_menu(fd)
            continue
        KEYQ.put(ch.lower().decode(errors="ignore"))


# ---- keeping the session: local state, autostart, a log, network diagnosis and one self-repair attempt --------------------
STATE_DIR = os.environ.get("HELPER_STATE_DIR") or os.path.join(os.environ.get("XDG_STATE_HOME") or os.path.expanduser("~/.local/state"), "helpermcp")
SESSION_FILE = os.path.join(STATE_DIR, "session.json"); LOG_FILE = os.path.join(STATE_DIR, "agent.log")
PAUSED = threading.Event(); FINAL = threading.Event(); PERSIST = {"on": False}; MODE = {"m": "auto"}; CODE = {"c": ""}   # confirm / auto / unattended (Esc only pauses, the admin panel ends it)
AUTOSTART = os.path.expanduser("~/.config/autostart/helpermcp.desktop")


def log(msg):
    try:
        os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
        if os.path.exists(LOG_FILE) and os.path.getsize(LOG_FILE) > 1_000_000: os.replace(LOG_FILE, LOG_FILE + ".1")
        with open(LOG_FILE, "a", encoding="utf-8") as f: f.write(time.strftime("%Y-%m-%d %H:%M:%S ") + str(msg).replace("\n", "\n    ") + "\n")
    except Exception: pass


def boot_time():
    try: return int(time.time() - float(open("/proc/uptime").read().split()[0]))
    except Exception: return 0


def save_session(code, token, mode):
    try:
        os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
        fd = os.open(SESSION_FILE, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f: json.dump({"relay": RELAY, "code": code, "token": token, "mode": mode, "boot": boot_time(), "saved": int(time.time())}, f)
        if os.environ.get("HELPER_TOKEN_FILE"): open(os.environ["HELPER_TOKEN_FILE"], "w").write(token)   # tests only
    except Exception as e: log(f"cannot save the session: {e}")


def load_session():
    try:
        d = json.load(open(SESSION_FILE))
        return d if d.get("relay") == RELAY and d.get("code") and d.get("token") else None
    except Exception: return None


def norm_mode(m):
    """confirm: ask before every action. auto: no questions (the default). unattended: like auto, plus only the admin panel can end it; 'ask'/'full' are what old agents still send"""
    return m if m in ("confirm", "auto", "unattended") else "confirm" if m == "ask" else "auto" if m == "full" else None


DEVICE_FILE = os.path.join(STATE_DIR, "device.json")


def get_device_id():
    """a permanent per-install identity (like an AnyDesk/RustDesk ID): the relay then hands back the same code every time, not a new random one"""
    try:
        d = json.load(open(DEVICE_FILE))
        if d.get("id"): return d["id"]
    except Exception: pass
    did = uuid.uuid4().hex + uuid.uuid4().hex
    try:
        os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
        json.dump({"id": did}, open(DEVICE_FILE, "w"))
    except Exception: pass
    return did


def install_autostart():
    """after a reboot the helper starts again by itself (in a terminal, so the user sees it and can answer questions) and resumes the same session"""
    if os.environ.get("HELPER_NO_AUTOSTART"): return
    try:
        os.makedirs(STATE_DIR, mode=0o700, exist_ok=True)
        with urllib.request.urlopen(RELAY + "/p", timeout=20) as r: open(os.path.join(STATE_DIR, "agent.py"), "wb").write(r.read())   # the one-liner runs from memory: keep a copy
        run = os.path.join(STATE_DIR, "start.sh")
        open(run, "w").write("#!/usr/bin/env bash\nsleep 8\nA=\"" + os.path.join(STATE_DIR, "agent.py") + "\"\nif command -v gnome-terminal >/dev/null; then exec gnome-terminal -- python3 \"$A\"\n"
                              "elif command -v konsole >/dev/null; then exec konsole -e python3 \"$A\"\nelif command -v xfce4-terminal >/dev/null; then exec xfce4-terminal -x python3 \"$A\"\n"
                              "elif command -v x-terminal-emulator >/dev/null; then exec x-terminal-emulator -e python3 \"$A\"\nelse exec xterm -e python3 \"$A\"; fi\n"); os.chmod(run, 0o700)
        os.makedirs(os.path.dirname(AUTOSTART), exist_ok=True)
        open(AUTOSTART, "w").write("[Desktop Entry]\nType=Application\nName=HelperMCP (keeps your help session)\nExec=" + run + "\nX-GNOME-Autostart-enabled=true\n")
        log("autostart installed")
    except Exception as e: log(f"autostart failed: {e}")


def forget_session():
    for f in (SESSION_FILE, AUTOSTART, os.path.join(STATE_DIR, "start.sh"), os.path.join(STATE_DIR, "agent.py")):
        try: os.remove(f)
        except Exception: pass
    log("session ended by the user: saved session and autostart removed")


def set_paused(on, why="user"):
    if on == PAUSED.is_set(): return
    PAUSED.set() if on else PAUSED.clear(); log("paused" if on else "continued")
    try: api("/a/state", {"paused": on}, TOKEN, timeout=8)
    except Exception as e: log(f"could not tell the relay about the pause: {e}")
    overlay_send("state paused" if on else ("state ok" if OP["seen"] else "state wait")); show_status()
    print(c(ORANGE, "  ⏸ " + t("st_paused")) if on else c("32", "  ▶ " + ("продолжаем" if RU else "continuing")), flush=True)


def end_final():
    FINAL.set(); END.set(); log("the user confirmed the end")
    try: api("/a/bye", {"final": True}, TOKEN, timeout=6)
    except Exception: pass
    forget_session(); print(c("33", "  " + t("esc")), flush=True); os.kill(os.getpid(), signal.SIGTERM)


def esc_menu(fd):
    """Esc opens a menu instead of ending anything: pause / continue / end (and an end needs a second confirmation)"""
    import select
    def key():
        while True:
            ch = os.read(fd, 1)
            if not ch: return "esc"
            if ch == b"\x1b":
                if select.select([fd], [], [], 0.05)[0]: os.read(fd, 8); continue
                return "esc"
            return ch.lower().decode(errors="ignore")
    print("\n" + c("1;30;43", "  " + (t("menu_paused") if PAUSED.is_set() else t("menu_run")) + "  "), flush=True)
    while True:
        k = key()
        if k == "p" and not PAUSED.is_set(): set_paused(True); return
        if k == "r" and PAUSED.is_set(): set_paused(False); return
        if k == "x":
            print(c("1;30;43", "  " + t("confirm_end") + "  "), flush=True)
            k2 = key()
            if k2 in ("y", "\n", "\r"): end_final(); return
            print(c("2", "  …"), flush=True); return
        if k in ("esc", "n", "\n", "\r"): return


def run_cmd(cmd, tmo=5):
    try:
        r = subprocess.run(cmd, shell=isinstance(cmd, str), capture_output=True, text=True, timeout=tmo, errors="replace"); return (r.stdout + r.stderr).strip()
    except Exception as e: return f"{type(e).__name__}: {e}"


def can_ping(host):
    try: return subprocess.run(["ping", "-c", "1", "-W", "1", host], capture_output=True, timeout=4).returncode == 0
    except Exception: return False


def diagnose():
    """what exactly is wrong with the network right now: adapters, route, gateway, internet, DNS, the relay itself"""
    u = urllib.parse.urlparse(RELAY); host = u.hostname or ""; port = u.port or (443 if u.scheme == "https" else 80); d = {}
    d["adapters"] = run_cmd("ip -br addr"); d["routes"] = run_cmd("ip route")
    gw = (re.search(r"default via (\S+)", d["routes"]) or [None, None])[1]; d["gateway"] = gw
    links = [ln.split() for ln in run_cmd("ip -br link").splitlines() if ln.strip()]
    real = [x for x in links if x and not re.match(r"lo|docker|veth|br-|virbr", x[0])]
    d["links_up"] = [x[0] for x in real if len(x) > 1 and x[1] in ("UP", "UNKNOWN")]
    d["vpn"] = [x[0] for x in real if re.match(r"tun|tap|wg|ppp|ham|zt|tailscale|Meta|utun|nordlynx", x[0])]
    d["ping_gateway"] = can_ping(gw) if gw else None; d["ping_internet"] = can_ping("1.1.1.1")
    try: socket.getaddrinfo(host, port); d["dns_ok"] = True
    except Exception as e: d["dns_ok"] = False; d["dns_error"] = str(e)[:120]
    try: socket.create_connection((host, port), 3).close(); d["relay_tcp"] = True
    except Exception as e: d["relay_tcp"] = False; d["relay_error"] = f"{type(e).__name__}: {e}"[:150]
    if not d["links_up"]: d["class"] = "no_link"
    elif gw and not d["ping_gateway"]: d["class"] = "lan_down"
    elif not d["ping_internet"]: d["class"] = "isp_down"
    elif not d["dns_ok"]: d["class"] = "dns"
    elif not d["relay_tcp"]: d["class"] = "relay_unreachable" + ("_vpn" if d["vpn"] else "")
    else: d["class"] = "http_or_tls"
    return d


def heal(d):
    """one attempt per outage, by cause: flush DNS, or bring the active connection up again; never touches a VPN"""
    acts = []; cls = d.get("class", "")
    if cls == "dns":
        acts.append("flush dns: " + (run_cmd("resolvectl flush-caches") or "ok"))
    elif cls in ("no_link", "lan_down", "isp_down"):
        if shutil.which("nmcli"):
            for ln in run_cmd("nmcli -t -f NAME,DEVICE,TYPE connection show --active").splitlines():
                parts = ln.split(":")
                if len(parts) >= 3 and parts[2] in ("802-11-wireless", "802-3-ethernet", "ethernet", "wifi"):
                    acts.append(f"nmcli connection up '{parts[0]}': " + (run_cmd(["nmcli", "connection", "up", parts[0]], 25)[:200] or "ok"))
            if not acts: acts.append("no active wifi / ethernet connection to restart")
        else: acts.append("nmcli is not installed: cannot restart the adapter")
    elif cls.endswith("_vpn"): acts.append("a VPN adapter is up (" + ",".join(d.get("vpn", [])) + "): not touched; the relay is unreachable through it")
    else: acts.append("nothing to repair automatically for: " + cls)
    return acts


OUT = {"t0": None, "diag": None, "acts": [], "healed": False}


def outage_tick():
    """called after every failed poll: diagnose after ~4 s, repair once after ~10 s"""
    now = time.time()
    if OUT["t0"] is None: OUT["t0"] = now; log("connection to the relay lost")
    el = now - OUT["t0"]
    if el >= 4 and OUT["diag"] is None:
        OUT["diag"] = diagnose(); d = OUT["diag"]; log("diagnosis: class=%s gateway=%s ping_gw=%s ping_inet=%s dns=%s relay_tcp=%s vpn=%s\n%s" % (d["class"], d["gateway"], d["ping_gateway"], d["ping_internet"], d["dns_ok"], d["relay_tcp"], d["vpn"], d["adapters"]))
    if el >= 10 and OUT["diag"] is not None and not OUT["healed"]:
        OUT["healed"] = True; OUT["acts"] = heal(OUT["diag"]); log("repair attempt: " + " | ".join(OUT["acts"]))


def outage_over():
    if OUT["t0"] is None: return
    el = int(time.time() - OUT["t0"]); d = OUT["diag"]
    if el >= 3:
        log(f"connection restored after {el} s")
        ev = {"type": "outage", "duration_s": el, "class": d["class"] if d else "short", "actions": OUT["acts"], "diagnosis": json.dumps(d, ensure_ascii=False)[:3000] if d else ""}
        try: api("/a/event", ev, TOKEN, timeout=8)
        except Exception as e: log(f"could not send the outage report: {e}")
    OUT.update(t0=None, diag=None, acts=[], healed=False)


def agent_log(a):
    n = int(a.get("lines") or 80)
    try: lines = open(LOG_FILE, encoding="utf-8", errors="replace").read().splitlines()[-n:]
    except Exception: lines = []
    return {"text": "\n".join(lines) or "(the log is empty)"}


def read_key():
    if not PUMP["on"]: raise RuntimeError("No keyboard to ask on (the helper must run in a terminal in ask mode).")
    while not KEYQ.empty(): KEYQ.get_nowait()          # keys typed before the question must not answer it
    while True:
        k = KEYQ.get()
        if k in ("y", "\n", "\r"): return "y"
        if k in ("a", "n"): return k


def focus_window():
    """the window that has the keyboard focus (None when unknown): the terminal where the friend answers takes it, so it is given back afterwards"""
    try:
        X = xlib(); x11 = X["x"]; w = ctypes.c_ulong(); rv = ctypes.c_int()
        x11.XGetInputFocus.argtypes = [ctypes.c_void_p, ctypes.POINTER(ctypes.c_ulong), ctypes.POINTER(ctypes.c_int)]   # without argtypes the Display pointer is cut to 32 bits: segfault
        x11.XGetInputFocus(X["d"], ctypes.byref(w), ctypes.byref(rv)); return w.value if w.value > 1 else None
    except Exception: return None


def restore_focus(w):
    if not w: return
    try:
        X = xlib(); X["x"].XSetInputFocus.argtypes = [ctypes.c_void_p, ctypes.c_ulong, ctypes.c_int, ctypes.c_ulong]
        X["x"].XSetInputFocus(X["d"], ctypes.c_ulong(w), 1, 0); sync(X); time.sleep(0.15)
    except Exception: pass


def ask_permission(name, a):
    g = ASK_GROUP[name]
    if g in ALLOWED: return
    fw = focus_window() or AI["fw"]; label = GROUP_LABEL[g][0 if RU else 1]; d = describe(name, a)
    play("ask")
    try: subprocess.Popen(["notify-send", "-u", "normal", "-t", "15000", "HelperMCP", "\n".join(d)], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    except Exception: pass
    print("\n" + c("1;30;43", f"  ▶ {t('allow')}" + (d[0] if len(d) == 1 else "") + "  ") + ("".join("\n" + c("33", f"      {i}. {x}") for i, x in enumerate(d, 1)) if len(d) > 1 else "")
          + "\n" + c("33", f"    [Y] {t('keys')}    [A] {t('always')}    [N] {t('no')}    [Esc] {t('endk')}") + "\n" + c("2;33", f"    A = {t('stopask')} {label} {t('until')}"), flush=True)
    k = read_key()
    if k == "n": print(c("2", "    " + t("den")), flush=True); raise RuntimeError("The user denied this action. Do not repeat it; ask the operator what to do instead.")
    if k == "a": ALLOWED.add(g); print(c("32", f"    ✔ {t('ok2')}: {label}"), flush=True)
    else: print(c("32", f"    ✔ {t('ok1')}"), flush=True)
    restore_focus(fw)


def resume_state(name, a=None):
    """put the window focus and the pointer back where the previous AI action left them (answering a question moves both)"""
    if name not in GUI_TOOLS or not AI["pos"] or time.time() - AI["t"] > 90: return
    first = (steps_of(name, a or {}) or [{}])[0].get("do")
    if AI["fw"] and focus_window() != AI["fw"]: restore_focus(AI["fw"])
    if first in ("type", "key", "scroll"):
        x, y = pointer_pos()
        if abs(x - AI["pos"][0]) + abs(y - AI["pos"][1]) > 6: overlay_send("active"); glide(*AI["pos"], 0.3)


def mark_state(name):
    if name in GUI_TOOLS: time.sleep(0.08); AI.update(t=time.time(), pos=pointer_pos(), fw=focus_window())


def actions(a):
    """a short list of small GUI steps, confirmed once"""
    steps = list(a.get("steps") or [])[:20]; done = []
    for i, st in enumerate(steps, 1):
        d = st.get("do")
        try:
            if d == "move": move(st)
            elif d == "click": click(st)
            elif d == "drag": drag(st)
            elif d == "scroll": scroll(st)
            elif d == "type": type_text({"text": st["text"]})
            elif d == "key": press_key({"keys": st["keys"]})
            elif d == "wait": time.sleep(min(5000, int(st.get("ms", 500))) / 1000)
            else: raise RuntimeError(f"unknown step '{d}'")
        except Exception as e:
            raise RuntimeError(f"step {i} ({d}) failed: {e}. Steps before it were done: {', '.join(done) or 'none'}.")
        done.append(f"{i}:{d}")
    return {"text": f"ok, {len(done)} step(s) done"}


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
    if a.get("args") is not None: argv = [a["command"]] + [str(x) for x in a["args"]]   # no shell: every argument arrives exactly as given
    else: argv = {"python": [sys.executable, "-c"], "sh": ["sh", "-c"]}.get(a.get("shell"), ["bash", "-c"]) + [a["command"]]
    try:
        p = subprocess.run(argv, input=a.get("stdin"), capture_output=True, text=True, timeout=a.get("timeout_s", 60), errors="replace", env=with_path(), cwd=a.get("cwd"))
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
    path = os.path.expanduser(a["path"]).rstrip("/") or "/"
    if os.path.isdir(path):   # a folder travels as one zip
        z = os.path.join(tempfile.mkdtemp(), os.path.basename(path) + ".zip"); TMP.append(os.path.dirname(z)); zip_dir(path, z); path = z
    size = os.path.getsize(path)
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
    if a.get("offset") or a.get("lines") or a.get("tail"): return read_range(path, a)
    with open(path, "rb") as f:
        return {"text": f.read(a.get("max_bytes", 200_000)).decode("utf-8", "replace")}


def write_file(a):
    data = base64.b64decode(a["content"]) if a.get("base64") else a["content"].encode("utf-8")
    with open(os.path.expanduser(a["path"]), "ab" if a.get("append") else "wb") as f:
        f.write(data)
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


# ---- files: tree, find, ranges, exact edits, transfer both ways ---------------------------------------
SKIP_DIRS = {".git", "node_modules", "__pycache__", ".cache"}


def human(n):
    for u in ("B", "K", "M", "G"):
        if n < 1024 or u == "G": return f"{n:.0f}{u}" if u == "B" else f"{n:.1f}{u}"
        n /= 1024


def tree(a):
    import fnmatch
    root = os.path.expanduser(a.get("path") or "."); depth = min(int(a.get("depth") or 2), 6); pat = a.get("pattern"); cap = int(a.get("max") or 300)
    out, more = [os.path.abspath(root)], [0]
    def walk(d, lvl):
        try: ents = sorted(os.scandir(d), key=lambda e: (not e.is_dir(follow_symlinks=False), e.name.lower()))
        except OSError as e: out.append("  " * lvl + f"[{e.strerror}]"); return
        for e in ents:
            isd = e.is_dir(follow_symlinks=False)
            if not isd and pat and not fnmatch.fnmatch(e.name.lower(), pat.lower()): continue
            if len(out) > cap: more[0] += 1; continue
            if isd:
                try: n = len(os.listdir(e.path))
                except OSError: n = "?"
                out.append("  " * lvl + f"{e.name}/  ({n})")
                if lvl < depth and e.name not in SKIP_DIRS: walk(e.path, lvl + 1)
            else:
                try: out.append("  " * lvl + f"{e.name}  {human(e.stat(follow_symlinks=False).st_size)}")
                except OSError: out.append("  " * lvl + e.name)
    walk(root, 1)
    if more[0]: out.append(f"... {more[0]} more (raise max, lower depth or use find)")
    return {"text": "\n".join(out)}


def find(a):
    import fnmatch
    root = os.path.expanduser(a.get("path") or "."); name = (a.get("name") or "*").lower(); cap = int(a.get("max") or 100)
    rx = re.compile(a["text"], re.I) if a.get("text") else None; maxd = int(a.get("depth") or 20); t0 = time.time()
    out, base = [], os.path.abspath(root).rstrip(os.sep).count(os.sep)
    for d, dirs, files in os.walk(root):
        if os.path.abspath(d).count(os.sep) - base >= maxd: dirs[:] = []
        dirs[:] = [x for x in dirs if x not in SKIP_DIRS]
        for f in files:
            if not fnmatch.fnmatch(f.lower(), name): continue
            p = os.path.join(d, f)
            if not rx:
                try: out.append(f"{p}  {human(os.path.getsize(p))}")
                except OSError: out.append(p)
            else:
                try:
                    if os.path.getsize(p) > 5_000_000: continue
                    with open(p, "rb") as fh: raw = fh.read()
                    if b"\0" in raw[:4096]: continue
                    for i, line in enumerate(_decode(raw)[0].splitlines(), 1):
                        if rx.search(line):
                            out.append(f"{p}:{i}: {line.strip()[:160]}")
                            if len(out) >= cap: break
                except OSError: continue
            if len(out) >= cap: return {"text": "\n".join(out) + f"\n... stopped at {cap} results (raise max or narrow path / name)"}
        if time.time() - t0 > 25: return {"text": "\n".join(out) + "\n... stopped after 25 s (narrow the path)"}
    return {"text": "\n".join(out) or "nothing found"}


def _decode(raw):
    """-> (text, encoding, bom) so an edit writes the file back the way it was."""
    for bom, enc in ((b"\xef\xbb\xbf", "utf-8"), (b"\xff\xfe", "utf-16-le"), (b"\xfe\xff", "utf-16-be")):
        if raw.startswith(bom): return raw[len(bom):].decode(enc), enc, bom
    try: return raw.decode("utf-8"), "utf-8", b""
    except UnicodeDecodeError: return raw.decode("latin-1"), "latin-1", b""


def read_range(path, a):
    with open(path, "rb") as f: text = _decode(f.read())[0]
    L = text.splitlines(); n = len(L)
    if a.get("tail"): start = max(0, n - int(a["tail"])); cnt = int(a["tail"])
    else: start = max(0, int(a.get("offset") or 1) - 1); cnt = int(a.get("lines") or 200)
    part = L[start:start + cnt]
    return {"text": "\n".join(f"{start + i + 1}\t{s}" for i, s in enumerate(part)) + f"\n[lines {start + 1}-{start + len(part)} of {n}]"}


def edit_file(a):
    path = os.path.expanduser(a["path"])
    with open(path, "rb") as f: text, enc, bom = _decode(f.read())
    old, new = a["old"], a.get("new", "")
    if old not in text and "\r\n" in text and "\r\n" not in old:   # the AI writes \n, the file has CRLF
        old, new = old.replace("\n", "\r\n"), new.replace("\n", "\r\n")
    n = text.count(old) if old else 0
    if n == 0: raise RuntimeError("old text not found (it must match exactly, spaces and line breaks included; read_file with offset/lines to copy it)")
    if n > 1 and not a.get("all"): raise RuntimeError(f"old text found {n} times: add surrounding lines to make it unique, or all=true")
    with open(path, "wb") as f: f.write(bom + text.replace(old, new).encode(enc))
    return {"text": f"replaced {n}"}


def push_file(a):
    """operator -> this PC: download a URL (a relay link from the viewer upload, or any http link) to path."""
    path = os.path.expanduser(a["path"]); os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
    req = urllib.request.Request(a["url"], headers={"User-Agent": "helpermcp"})
    n = 0
    with urllib.request.urlopen(req, timeout=3600) as r, open(path + ".part", "wb") as f:
        while True:
            b = r.read(1 << 20)
            if not b: break
            f.write(b); n += len(b)
    os.replace(path + ".part", path)
    return {"text": f"saved {path} ({human(n)})"}


def zip_dir(src, dest):
    import zipfile
    src = os.path.abspath(src)
    with zipfile.ZipFile(dest, "w", zipfile.ZIP_DEFLATED) as z:
        for d, _, files in os.walk(src):
            for f in files:
                p = os.path.join(d, f)
                try: z.write(p, os.path.relpath(p, os.path.dirname(src)))
                except OSError: pass



def fsop(a):
    """make, copy, move, rename, delete (the trash when there is one), look inside a file without downloading it"""
    op = a["op"]; p = os.path.expanduser(a["path"])
    if op == "mkdir": os.makedirs(p, exist_ok=True); return {"text": f"created folder {p}"}
    if op == "newfile":
        if os.path.exists(p): raise RuntimeError(f"already exists: {p}")
        os.makedirs(os.path.dirname(os.path.abspath(p)), exist_ok=True); open(p, "wb").close(); return {"text": f"created file {p}"}
    if op in ("copy", "move"):
        d = os.path.expanduser(a["dest"])
        if os.path.isdir(d): d = os.path.join(d, os.path.basename(p.rstrip("/")))
        if os.path.abspath(d) == os.path.abspath(p): raise RuntimeError("source and destination are the same")
        if os.path.exists(d) and not a.get("overwrite"): raise RuntimeError(f"already exists: {d} (overwrite:true replaces it)")
        if os.path.exists(d) and a.get("overwrite"): shutil.rmtree(d) if os.path.isdir(d) else os.remove(d)
        if op == "copy": shutil.copytree(p, d) if os.path.isdir(p) else shutil.copy2(p, d)
        else: shutil.move(p, d)
        return {"text": f"{'copied' if op == 'copy' else 'moved'} to {d}"}
    if op == "rename":
        n = a.get("name") or ""
        if not n or "/" in n or "\\" in n: raise RuntimeError("bad name")
        os.rename(p, os.path.join(os.path.dirname(p), n)); return {"text": f"renamed to {n}"}
    if op == "delete":
        if not os.path.lexists(p): raise RuntimeError(f"not found: {p}")
        if not a.get("permanent") and shutil.which("gio") and sh(["gio", "trash", p], 20)[0] == 0: return {"text": f"moved to the trash: {p}"}
        shutil.rmtree(p) if os.path.isdir(p) and not os.path.islink(p) else os.remove(p); return {"text": f"deleted for good: {p}"}
    if op == "stat":
        st = os.stat(p); fmt = lambda t: time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(t))
        return {"text": json.dumps({"path": os.path.abspath(p), "dir": os.path.isdir(p), "size": 0 if os.path.isdir(p) else st.st_size, "created": fmt(st.st_ctime), "modified": fmt(st.st_mtime), "attrs": oct(st.st_mode)})}
    if op == "preview":
        if os.path.isdir(p): raise RuntimeError("that is a folder")
        if p.lower().endswith((".png", ".jpg", ".jpeg", ".gif", ".bmp", ".webp")): return read_file({"path": p, "max_width": 1100, "quality": 72})
        st = os.stat(p); mx = int(a.get("max") or 65536); o = {"size": st.st_size, "modified": time.strftime("%Y-%m-%d %H:%M", time.localtime(st.st_mtime)), "truncated": st.st_size > mx}
        if p.lower().endswith((".zip", ".jar", ".apk", ".docx", ".xlsx", ".pptx")):
            import zipfile
            with zipfile.ZipFile(p) as z: o["kind"] = "archive"; o["entries"] = [[i.filename, i.file_size] for i in z.infolist()[:300]]; o["count"] = len(z.infolist())
            return {"text": json.dumps(o)}
        with open(p, "rb") as f: b = f.read(mx)
        bom16 = b[:2] in (b"\xff\xfe", b"\xfe\xff")
        if not bom16 and b"\0" in b[:4096]:
            o["kind"] = "binary"; o["text"] = "".join(f"{r:08x}  {' '.join(f'{c:02x}' for c in b[r:r + 16]):<47}  {''.join(chr(c) if 32 <= c < 127 else '.' for c in b[r:r + 16])}\n" for r in range(0, min(512, len(b)), 16))
        else: o["kind"] = "text"; o["text"] = b.decode("utf-16" if bom16 else "utf-8", "replace").lstrip("\ufeff")
        return {"text": json.dumps(o)}
    raise RuntimeError(f"unknown op '{op}' (mkdir, newfile, copy, move, rename, delete, stat, preview)")


def sysdata(a):
    raise RuntimeError("the System tabs are for Windows PCs; this device answers system {sections: [...]} as text")


# ---- system state in one call, ready-made utilities --------------------------------------------------
def system(a):
    secs = a.get("sections") or ["overview", "disks", "processes", "network"]; top = int(a.get("top") or 15); out = []
    def add(title, cmd):
        out.append(f"== {title}"); out.append(sh(cmd, 20)[1].strip()[:6000])
    for s in secs:
        if s == "overview": add("overview", "uname -srm; uptime -p; free -h | sed -n 2p; nproc")
        elif s == "disks": add("disks", "df -h -x tmpfs -x devtmpfs -x squashfs -x overlay 2>/dev/null")
        elif s == "processes": add("processes (cpu%, mem%)", f"ps -eo pid,pcpu,pmem,comm --sort=-pcpu | head -{top + 1}")
        elif s == "network": add("network", "ip -br addr 2>/dev/null; ip route 2>/dev/null | head -3; grep -m3 nameserver /etc/resolv.conf")
        elif s == "services": add("failed services", "systemctl --failed --no-legend 2>/dev/null | head -30")
        elif s == "reach": add("reach: adapters, default route, VPN / DPI / proxy programs", "ip -br addr 2>/dev/null; ip route get 1.1.1.1 2>/dev/null | head -1; ps -eo pid,comm | grep -Ei 'zapret|nfqws|goodbyedpi|clash|mihomo|v2ray|xray|sing-box|openvpn|wireguard|wg-quick|tailscale|zerotier|hamachi|warp|tor$' | grep -v grep; env | grep -i '_proxy=' ")
        elif s == "connections": add("connections: TCP per process", f"ss -tnpH state established 2>/dev/null | awk '{{print $4, $5, $6}}' | head -{top * 3}")
        elif s == "startup": add("startup: autostart entries, enabled services, cron", "ls ~/.config/autostart /etc/xdg/autostart 2>/dev/null; echo '-- enabled units'; systemctl list-unit-files --state=enabled --no-legend 2>/dev/null | head -60; echo '-- cron'; crontab -l 2>/dev/null | grep -v '^#' | head; ls /etc/cron.d 2>/dev/null")
        elif s == "perf": add("performance", "uptime; echo; top -bn1 | head -12; echo; free -h; echo; df -h / | tail -1; echo; ip -s -br link 2>/dev/null | head -12; (command -v iostat >/dev/null && iostat -x 1 2 | tail -8) || true")
        elif s == "policy": add("policies (managed browsers, sudoers.d, package pins)", "ls /etc/opt/chrome/policies/managed /etc/chromium/policies/managed /etc/firefox/policies 2>/dev/null; ls /etc/sudoers.d 2>/dev/null; cat /etc/apt/preferences 2>/dev/null | head -20; echo 'proxy env:'; env | grep -i '_proxy=' ")
        elif s == "activation": out.append("== activation: not applicable on Linux")
        elif s == "health":
            out.append("== health check")
            def hf(sev, area, msg, fix=""): out.append(f"[{sev}] {area}: {msg}" + (f"  -> {fix}" if fix else ""))
            n = len([l for l in sh("systemctl --failed --no-legend 2>/dev/null", 10)[1].splitlines() if l.strip()])
            hf("BAD" if n else "OK", "services", f"{n} failed unit(s)" if n else "no failed units", "systemctl --failed" if n else "")
            for l in sh("df -P / /home /var 2>/dev/null | tail -n +2", 10)[1].splitlines():
                f = l.split()
                if len(f) >= 5 and f[4].rstrip("%").isdigit() and int(f[4].rstrip("%")) >= 90: hf("BAD", "disk", f"{f[5]} is {f[4]} full", "free space: updates need room")
            if os.path.exists("/var/run/reboot-required"): hf("WARN", "reboot", "a reboot is pending", "restart")
            m = {l.split(":")[0]: int(l.split()[1]) for l in open("/proc/meminfo") if l.split(":")[0] in ("MemTotal", "MemAvailable")}
            if m["MemAvailable"] < 0.08 * m["MemTotal"]: hf("WARN", "memory", "less than 8% of RAM is available", "see system {sections:[processes]}")
            if "synchronized: no" in sh("timedatectl 2>/dev/null", 10)[1]: hf("WARN", "time", "the clock is not synchronized", "timedatectl set-ntp true")
            if os.environ.get("http_proxy") or os.environ.get("https_proxy"): hf("WARN", "proxy", "a proxy is set in the environment")
            out.append("== end")
        elif s == "process":
            pid = int(a.get("pid") or 0)
            if not pid: out.append("== process: give pid")
            else:
                out.append(f"== process {pid} in detail"); r = lambda f: (open(f"/proc/{pid}/{f}", "rb").read() if os.path.exists(f"/proc/{pid}/{f}") else b"")
                try:
                    out.append("path: " + os.readlink(f"/proc/{pid}/exe")); out.append("cmd: " + r("cmdline").replace(b"\0", b" ").decode("utf-8", "replace"))
                    st = dict(l.split(":\t", 1) for l in r("status").decode("utf-8", "replace").splitlines() if ":\t" in l); out.append(f"state: {st.get('State')}; ppid: {st.get('PPid')}; uid: {st.get('Uid', '').split()[0] if st.get('Uid') else ''}; threads: {st.get('Threads')}; rss: {st.get('VmRSS')}")
                    out.append("started: " + time.strftime("%Y-%m-%d %H:%M:%S", time.localtime(os.stat(f"/proc/{pid}").st_ctime)))
                    out.append("connections: " + "; ".join(sh(f"ss -tnpH 2>/dev/null | grep 'pid={pid},' | awk '{{print $1, $4, $5}}' | head -15", 10)[1].splitlines()))
                except OSError as e: out.append(f"cannot read: {e}")
        elif s == "apps": add("apps", "(dpkg-query -W -f='${Package}\\n' 2>/dev/null || rpm -qa) | wc -l; flatpak list --app --columns=application 2>/dev/null | head -40")
        elif s == "drivers": add("loaded kernel modules (lsmod), biggest first", "lsmod | sort -k2 -n -r | head -40")
        elif s == "events": add("recent errors", "journalctl -p err -n 20 --no-pager -q 2>/dev/null")
        else: out.append(f"== {s}: unknown section")
    return {"text": "\n".join(out)}


READONLY_UTIL = {"apps", "env_get", "clipboard_get", "net_test", "ports", "reg_get"}


def util(a):
    import shlex
    q = lambda x: shlex.quote(str(x))
    op = a["op"]; name = a.get("name") or ""; val = a.get("value") or ""; path = os.path.expanduser(a.get("path") or "")
    def run_(cmd, t=600):
        c, o = sh(cmd, t)
        if c: raise RuntimeError(f"[exit {c}] {o.strip()[-1500:]}")
        return o.strip()[-4000:] or "ok"
    if op == "apps":
        return {"text": sh(f"(dpkg-query -W -f='${{Package}} ${{Version}}\\n' 2>/dev/null; flatpak list --app --columns=application,version 2>/dev/null; snap list 2>/dev/null) | grep -i -- {q(name)} | head -50")[1].strip() or "not found"}
    if op == "install":
        if shutil.which("apt-get"): return {"text": run_(f"sudo -n apt-get install -y {q(name)} 2>&1 || pkexec apt-get install -y {q(name)}", 1800)}
        if shutil.which("dnf"): return {"text": run_(f"sudo -n dnf install -y {q(name)}", 1800)}
        return {"text": run_(f"flatpak install -y --noninteractive {q(name)}", 1800)}
    if op == "uninstall":
        return {"text": run_(f"sudo -n apt-get remove -y {q(name)} 2>&1 || flatpak uninstall -y {q(name)}", 1800)}
    if op == "kill":
        if name.isdigit(): os.kill(int(name), signal.SIGTERM); return {"text": "killed " + name}
        return {"text": run_(f"pkill -f -- {q(name)} && echo killed")}
    if op == "service":
        return {"text": run_(f"systemctl {q(val or 'status')} {q(name)} --no-pager 2>&1 | head -20")}
    if op == "env_get": return {"text": os.environ.get(name, "") if name else "\n".join(f"{k}={v[:200]}" for k, v in sorted(os.environ.items()))}
    if op in ("env_set", "path_add"):
        line = f'export PATH="{val or path}:$PATH"' if op == "path_add" else f"export {name}={q(val)}"
        with open(os.path.expanduser("~/.profile"), "a") as f: f.write("\n" + line + "\n")
        return {"text": f"added to ~/.profile: {line} (new logins see it)"}
    if op == "open":
        subprocess.Popen(["xdg-open", a.get("url") or path], start_new_session=True, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL); return {"text": "opened"}
    if op == "clipboard_get": return {"text": run_("xclip -o -selection clipboard 2>/dev/null || xsel -ob")}
    if op == "clipboard_set":
        for c in (["xclip", "-selection", "clipboard"], ["xsel", "-ib"]):
            if shutil.which(c[0]): subprocess.run(c, input=val.encode(), timeout=5); return {"text": "ok"}
        raise RuntimeError("no xclip / xsel on this PC")
    if op == "dns_flush": return {"text": run_("resolvectl flush-caches 2>/dev/null || systemd-resolve --flush-caches; echo flushed")}
    if op == "net_test":
        host = a.get("host") or name; port = int(a.get("port") or 443); lines = []
        try: ip = socket.gethostbyname(host); lines.append(f"dns {host} -> {ip}")
        except OSError as e: return {"text": f"dns {host}: FAILED {e}"}
        t0 = time.time()
        try: socket.create_connection((ip, port), 5).close(); lines.append(f"tcp {port}: open ({(time.time() - t0) * 1000:.0f} ms)")
        except OSError as e: lines.append(f"tcp {port}: FAILED {e}")
        return {"text": "\n".join(lines)}
    if op == "ports": return {"text": sh("ss -ltnup 2>/dev/null" + (f" | grep -- {q(':' + name)}" if name else ""))[1].strip() or "nothing listens there"}
    if op == "download": return push_file({"url": a["url"], "path": path})
    if op == "zip":
        dest = os.path.expanduser(a.get("dest") or path.rstrip("/") + ".zip"); zip_dir(path, dest); return {"text": f"{dest} ({human(os.path.getsize(dest))})"}
    if op == "unzip":
        import zipfile
        dest = os.path.expanduser(a.get("dest") or os.path.splitext(path)[0])
        with zipfile.ZipFile(path) as z: z.extractall(dest)
        return {"text": "extracted to " + dest}
    if op in ("reg_get", "reg_set", "reg_find", "crash", "recent", "ffind", "elevate", "browser", "bsod", "health", "shortcut"): raise RuntimeError(op + " is Windows only")
    raise RuntimeError("unknown op " + op)


# ---- the live picture for the viewer (like a video call): one long upload of frames, on while someone watches -------------------
# With ffmpeg: H.264 (x11grab + libx264, zero latency). Without it: full JPEG pictures from the screenshot tool, a few per second.
SYS_AT = [0.0]
LIVE = {"run": False, "mon": -1, "thread": None, "err": "", "proc": None}


def _frame(t, payload): return len(payload).to_bytes(4, "big") + t.encode() + payload


def _meta(d): b = json.dumps(d).encode(); return len(b).to_bytes(2, "big") + b


def _area(mon):
    mons = monitors()
    if 0 <= mon < len(mons): return mons[mon]
    if mons:
        x0, y0 = min(m[0] for m in mons), min(m[1] for m in mons)
        return x0, y0, max(m[0] + m[2] for m in mons) - x0, max(m[1] + m[3] for m in mons) - y0
    return None


def _h264_frames(mon):
    x, y, w, h = _area(mon) or (0, 0, 0, 0)
    sc = max(1.0, w / 1920.0, h / 1200.0) if w else 1.0
    ow, oh = (int(w / sc) // 2 * 2, int(h / sc) // 2 * 2) if w else (0, 0)
    cmd = ["ffmpeg", "-loglevel", "error", "-f", "x11grab", "-draw_mouse", "1", "-framerate", "15"] + (["-video_size", f"{w}x{h}"] if w else []) + \
          ["-i", f"{os.environ.get('DISPLAY', ':0')}+{x},{y}"] + (["-vf", f"scale={ow}:{oh}"] if w else []) + \
          ["-c:v", "libx264", "-preset", "ultrafast", "-tune", "zerolatency", "-pix_fmt", "yuv420p", "-profile:v", "baseline",
           "-x264-params", "keyint=30:aud=1:repeat-headers=1", "-b:v", "2500k", "-maxrate", "3000k", "-bufsize", "1500k", "-f", "h264", "-"]
    p = subprocess.Popen(cmd, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, env=with_path()); LIVE["proc"] = p
    try: yield from annexb(p.stdout, dict({"w": ow, "h": oh, "ox": x, "oy": y, "sc": sc}, **_mons_json(mon)), lambda: LIVE["run"])
    finally: p.kill(); LIVE["proc"] = None


def annexb(src, meta, alive):
    """H.264 annex-B bytes -> C frames (decoder settings, from each new SPS) and V frames (one access unit each, split at the AUD)"""
    buf, au, sent_sps = b"", [], None
    while alive():
        chunk = src.read1(65536) if hasattr(src, "read1") else src.read(4096)
        if not chunk: break
        buf += chunk
        starts = [m.start() for m in re.finditer(b"\x00\x00\x01", buf)]
        for a_, b_ in zip(starts, starts[1:]):   # every complete NAL unit (the last one may still be growing)
            nal = buf[a_ + 3:b_].rstrip(b"\x00"); kind = nal[0] & 31 if nal else 0
            if kind == 9 and au:   # an access unit delimiter starts the next picture
                key = any((n[0] & 31) == 5 for n in au)
                yield _frame("V", bytes([1 if key else 0]) + b"".join(b"\x00\x00\x00\x01" + n for n in au)); au = []
            if kind == 7 and nal[1:4] != sent_sps:   # sequence parameters: tell the viewer how to decode
                sent_sps = nal[1:4]
                yield _frame("C", _meta(dict(meta, codec="avc1.%02x%02x%02x" % tuple(nal[1:4]))))   # (the monitor map rides in meta)
                if time.time() - SYS_AT[0] >= 2: SYS_AT[0] = time.time(); yield _frame("S", sys_snap().encode())
            if nal: au.append(nal)
        if len(starts) > 1: buf = buf[starts[-1]:]


_SNAP = {"t": 0.0, "cpu": None, "procs": {}, "info": {}}


def sys_snap(top=10):
    """the live System panel: cpu %, ram, busiest + biggest processes; read from /proc, CPU % from the change since the previous call"""
    def stat():
        a = open("/proc/stat").readline().split()[1:]; v = list(map(int, a)); return sum(v), v[3] + (v[4] if len(v) > 4 else 0)
    tot, idle = stat(); now = time.time(); hz = os.sysconf("SC_CLK_TCK"); ncpu = os.cpu_count() or 1
    cpu = 0
    if _SNAP["cpu"]: cpu = round(100 * (1 - (idle - _SNAP["cpu"][1]) / max(1, tot - _SNAP["cpu"][0])))
    mem = {l.split(":")[0]: int(l.split()[1]) * 1024 for l in open("/proc/meminfo") if l.split(":")[0] in ("MemTotal", "MemAvailable")}
    rows, cur, dt = [], {}, max(0.001, now - _SNAP["t"]) * hz * ncpu if _SNAP["t"] else 0
    for pid in filter(str.isdigit, os.listdir("/proc")):
        try:
            f = open(f"/proc/{pid}/stat").read(); name = f[f.index("(") + 1:f.rindex(")")]; r = f[f.rindex(")") + 2:].split()
            ticks = int(r[11]) + int(r[12]); rss = int(r[21]) * os.sysconf("SC_PAGE_SIZE"); cur[pid] = ticks
            c = 100 * (ticks - _SNAP["procs"][pid]) / dt if dt and pid in _SNAP["procs"] else 0
            rows.append((int(pid), name, c, rss))
        except Exception: pass
    _SNAP.update(t=now, cpu=(tot, idle), procs=cur)
    pick, seen = [], set()
    for r in sorted(rows, key=lambda x: -x[2]):
        if len(pick) >= top or r[2] < 0.5: break
        seen.add(r[0]); pick.append(r)
    for r in sorted(rows, key=lambda x: -x[3]):
        if len(pick) >= top + 4: break
        if r[0] not in seen: seen.add(r[0]); pick.append(r)
    out = []
    for pid, name, c, rss in pick:
        i = _SNAP["info"].get(pid)
        if i is None:
            try: path = os.readlink(f"/proc/{pid}/exe")
            except OSError: path = ""
            i = _SNAP["info"][pid] = (path, "!" if path.startswith(("/tmp/", "/dev/shm/", "/var/tmp/")) or path.endswith(" (deleted)") else "")
        out.append([pid, name, round(c, 1), rss, "", i[0], i[1]])
    return json.dumps({"cpu": cpu, "mem": round(100 * (1 - mem["MemAvailable"] / mem["MemTotal"])), "ramFree": mem["MemAvailable"], "ramTotal": mem["MemTotal"], "n": len(rows), "p": out})


def _mons_json(cur):
    return {"mon": cur, "mons": [[x, y, w, h, 1 if i == 0 else 0] for i, (x, y, w, h) in enumerate(monitors())]}


def _jpeg_frames(mon):
    last = None
    while LIVE["run"]:
        t0 = time.time()
        try: d = screenshot({"view": True, "monitor": mon if mon >= 0 else None, "max_width": 1600, "quality": 60, "prev": last})
        except Exception as e: LIVE["err"] = str(e); time.sleep(1); continue
        if not d.get("same"):
            last = d["h"]
            yield _frame("K", _meta(dict({"w": 0, "h": 0, "ox": d.get("ox", 0), "oy": d.get("oy", 0), "sc": d.get("sc", 1)}, **_mons_json(mon))) + d["jpeg"])
        if time.time() - SYS_AT[0] >= 2: SYS_AT[0] = time.time(); yield _frame("S", sys_snap().encode())
        time.sleep(max(0.05, 0.3 - (time.time() - t0)))


def _live_loop():
    while LIVE["run"]:
        mon = LIVE["mon"]
        gen = _h264_frames(mon) if GUI["type"] == "x11" and shutil.which("ffmpeg") else _jpeg_frames(mon)
        def body():
            for fr in gen:
                if not LIVE["run"] or LIVE["mon"] != mon: return
                yield fr
        try:
            req = urllib.request.Request(RELAY + "/a/stream", data=body(), method="POST", headers={"Authorization": "Bearer " + TOKEN, "Content-Type": "application/octet-stream"})
            urllib.request.urlopen(req, timeout=30).read()
        except Exception as e: LIVE["err"] = str(e)
        finally: gen.close()
        if LIVE["run"] and LIVE["mon"] == mon: time.sleep(1)


def stream(a):
    if a.get("on") is False:
        LIVE["run"] = False; p = LIVE["proc"]
        if p: p.kill()
        return {"text": "stopped"}
    mon = int(a["mon"]) if a.get("mon") is not None else -1
    if mon != LIVE["mon"] and LIVE["proc"]: LIVE["proc"].kill()   # another screen: start over
    LIVE["mon"] = mon; LIVE["run"] = True
    if not (LIVE["thread"] and LIVE["thread"].is_alive()):
        LIVE["thread"] = threading.Thread(target=_live_loop, daemon=True); LIVE["thread"].start()
    return {"text": "streaming" + (f" (last error: {LIVE['err']})" if LIVE["err"] else "")}


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
wait_label = sys.argv[4] if len(sys.argv) > 4 else "Waiting for the helper…"
paused_label = sys.argv[5] if len(sys.argv) > 5 else "Paused"
hold_label = sys.argv[6] if len(sys.argv) > 6 else "The helper is on hold"
done_label = sys.argv[7] if len(sys.argv) > 7 else "Done"
away_label = sys.argv[8] if len(sys.argv) > 8 else "The helper has been quiet for a while"
note = ""
BLUE, ORANGE, VIOLET, GREEN = (0x4C / 255, 0x8D / 255, 0xFF / 255), (1.0, 0x8A / 255, 0x1E / 255), (0.66, 0.5, 1.0), (61 / 255, 220 / 255, 132 / 255)
OKC = BLUE   # the AI may pick its own colour (set_look)
WARN = ("lost", "wait", "paused", "hold", "away")
disp = Gdk.Display.get_default()
scr = disp.get_default_screen()
if not scr.is_composited() or scr.get_rgba_visual() is None:
    sys.exit(0)                      # without compositing transparent windows would be opaque black boxes: show nothing
state = "ok"                         # ok | lost (connection to the relay) | wait (nobody has connected with the code yet)
S_DEPTH = 70                         # glow depth in px

def col(): return ORANGE if state in WARN else GREEN if state == "done" else OKC

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
PILL_W = int(max(560, tmp.text_extents(label + "   00:00:00").x_advance, tmp.text_extents(lost_label).x_advance, tmp.text_extents(wait_label).x_advance)) + 58

def make_monitor(mon):
    g = mon.get_geometry()
    W, H = g.width - 1, g.height - 1   # NOT exactly screen-sized: mutter would treat a full-screen window as opaque, stop compositing it and show black
    w = new_window(W, H, g.x, g.y)
    cache = {}
    def surf():
        k = col()
        if k not in cache: cache[k] = build_glow(W, H, k)
        return cache[k][0]
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
    PM = 26   # room around the label for its halo
    pw = new_window(PILL_W + 2 * PM, 36 + 2 * PM, g.x + (g.width - PILL_W) // 2 - PM, g.y + 12 - PM)
    def pdraw(_, cr):
        cr.set_operator(cairo.OPERATOR_SOURCE); cr.set_source_rgba(0, 0, 0, 0); cr.paint(); cr.set_operator(cairo.OPERATOR_OVER); cr.translate(PM, PM)
        r_, g_, b_ = col(); lost = state in WARN; el = int(time.monotonic() - T0)
        clock = ("%d:%02d:%02d" % (el // 3600, el % 3600 // 60, el % 60)) if el >= 3600 else ("%02d:%02d" % (el // 60, el % 60))
        text = {"lost": lost_label, "wait": wait_label, "paused": paused_label, "hold": hold_label, "done": done_label, "away": away_label}.get(state) or ((note[:70] or label) + "   " + clock)
        pulse = 0.55 + 0.45 * (0.5 + 0.5 * math.sin(time.monotonic() * 5)) if lost else 1.0
        cr.select_font_face("Sans", cairo.FONT_SLANT_NORMAL, cairo.FONT_WEIGHT_BOLD); cr.set_font_size(15)
        ext = cr.text_extents(text); ph, rr, pad = 34, 17, 18
        w_ = pad + 10 + 9 + ext.x_advance + pad; x0, y0 = (PILL_W - w_) / 2, 1          # the pill hugs its content and sits in the middle of the window
        def rrect(e):
            cr.new_sub_path(); cr.arc(x0 + w_ - rr, y0 + rr, rr + e, -math.pi / 2, math.pi / 2); cr.arc(x0 + rr, y0 + rr, rr + e, math.pi / 2, 3 * math.pi / 2); cr.close_path()
        if halo_lvl > 0.02:   # working: a soft halo that fades out in every direction, breathes, and comes and goes softly
            br = 0.5 + 0.5 * math.sin(time.monotonic() * 6)
            for i in range(PM, 0, -2):
                rrect(i * 0.9 + 0.0); a = (1 - i / PM) ** 2 * (0.20 + 0.22 * br) * halo_lvl; cr.set_source_rgba(r_, g_, b_, a); cr.set_line_width(2.2); cr.stroke()
        rrect(0)
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
busy_fx = False; halo_lvl = 0.0; busy_off = 0; last_active = 0.0; opacity = 0.0; pre_until = 0.0; lean = 0.0; lastp = None; vel = (0.0, 0.0); rot_tgt = 0.0; moving_t = -9.0; type_anim = None   # (t0, dur, [line lengths])
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

def scale_img(img, k):
    """premultiplied ARGB image scaled by k (smooth)"""
    w, h, hx, hy, data = img; nw, nh = int(round(w * k)), int(round(h * k))
    src = cairo.ImageSurface.create_for_data(bytearray(data), cairo.FORMAT_ARGB32, w, h, w * 4)
    dst = cairo.ImageSurface(cairo.FORMAT_ARGB32, nw, nh); c = cairo.Context(dst); c.scale(nw / w, nh / h)
    c.set_source_surface(src, 0, 0); c.get_source().set_filter(cairo.FILTER_BEST); c.paint()
    return nw, nh, int(round(hx * k)), int(round(hy * k)), bytes(dst.get_data())

PACK = {"arrow": None}   # (surface, hotx, hoty) of the pack's pointer: the AI's arrow looks the same as the cursor theme, only bigger
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
        else:
            w_, h_, hx_, hy_, d_ = got["pointer"]; PACK["arrow"] = (cairo.ImageSurface.create_for_data(bytearray(d_), cairo.FORMAT_ARGB32, w_, h_, w_ * 4), hx_, hy_)
        for key in ("pointer", "link"):
            if key in got: got[key] = scale_img(got[key], 1.35)      # a little bigger than the pack's 32 px
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

def type_offset(now):
    """where the arrow stands while text is typed: it follows the caret (about 7.5 px per character, 20 px per line) just below the text"""
    if not type_anim: return 0, 0
    t0, dur, lines = type_anim; el = now - t0
    if el > dur + 1.2: return 0, 0
    pos = min(el / max(dur, 0.05), 1.0) * (sum(lines) + len(lines) - 1); row = 0
    for ln in lines[:-1]:
        if pos <= ln: break
        pos -= ln + 1; row += 1
    return min(pos, 70) * 7.5, 12 + 20 * row

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
    if PACK["arrow"]:   # the pack's pointer, bigger, leaning into the movement
        sf_, hx_, hy_ = PACK["arrow"]; k = 1.45 * s / 1.4
        cr.save(); cr.translate(HX, HY); cr.rotate(lean); cr.scale(k, k); cr.set_source_surface(sf_, -hx_, -hy_); cr.get_source().set_filter(cairo.FILTER_BEST); cr.paint(); cr.restore()
    else:   # the real pointer is hidden while the AI works: this arrow takes its place
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
    global lean, lastp, vel, rot_tgt, moving_t
    if lastp:   # the tip turns into the direction of movement (the arrow points up-left at rest), and settles back when the pointer stops
        vel = (vel[0] * 0.6 + (px - lastp[0]) * 0.4, vel[1] * 0.6 + (py - lastp[1]) * 0.4)
        if math.hypot(*vel) > 1.6: rot_tgt = math.atan2(vel[1], vel[0]) + 3 * math.pi / 4; moving_t = now
        elif now - moving_t > 0.45: rot_tgt = 0.0
        d = (rot_tgt - lean + math.pi) % (2 * math.pi) - math.pi; lean += d * 0.2
    lastp = (px, py)
    target = 1.0 if (now - last_active < 8.0 or dragging) else 0.0
    opacity += (target - opacity) * 0.22
    if (opacity < 0.03 and target == 0.0) or now < pre_until: hide(cursor, "cursor"); real_pointer(False)   # pre_until: a click on the panel needs the pointer free for a moment
    else:
        real_pointer(True); dx, dy = type_offset(now); show(cursor, "cursor"); cursor.move(px + dx - HX, py + dy - HY); cursor.get_window().raise_(); cursor.queue_draw()
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
    global last_active, pressed_t, dragging, scroll_dir, scroll_t, typing_t, rip, pre_until, type_anim
    f = line.split(); now = time.monotonic()
    if not f: return
    if f[0] == "state" and len(f) > 1:
        global T0
        if f[1] == "ok" and state in ("done", "wait"): T0 = time.monotonic()   # a new piece of work starts the clock again
        set_state(f[1]); return
    if f[0] == "color" and len(f) >= 4:
        global OKC
        OKC = (int(f[1]) / 255, int(f[2]) / 255, int(f[3]) / 255); [w.queue_draw() for w in glows + pills]; return
    if f[0] == "note":
        global note
        note = line.strip()[4:].strip(); [w.queue_draw() for w in pills]; return
    if f[0] in ("busy", "idle"):
        global busy_fx, busy_off
        if busy_off: GLib.source_remove(busy_off); busy_off = 0
        if f[0] == "busy": busy_fx = True; [w.queue_draw() for w in pills]
        else:   # the halo stays through the gap between two calls of the AI
            def off():
                global busy_fx, busy_off
                busy_fx = False; busy_off = 0; [w.queue_draw() for w in pills]; return False
            busy_off = GLib.timeout_add(2500, off)
        return
    if f[0] == "clip" and len(f) > 1:
        cb = Gtk.Clipboard.get(Gdk.SELECTION_CLIPBOARD); cb.set_text(f[1], -1); cb.store(); return
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
    elif f[0] == "type" and len(f) >= 3:
        try: type_anim = (now, float(f[1]), [int(v) for v in f[2].split(",") if v][:30] or [0])
        except ValueError: pass

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
def halo_tick():
    global halo_lvl
    tgt = 1.0 if busy_fx else 0.0; halo_lvl += (tgt - halo_lvl) * (0.3 if tgt else 0.07)
    if halo_lvl < 0.01 and not busy_fx: halo_lvl = 0.0
    if halo_lvl > 0 or state in WARN: [w.queue_draw() for w in pills]
    return True
GLib.timeout_add(60, halo_tick)   # orange label pulses
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
        OVERLAY_PROC = subprocess.Popen([sys.executable, "-c", OVERLAY, t("overlay"), str(os.getpid()), t("lost"), t("overlay_wait"), t("overlay_paused"), ("Помощник на паузе, вернётся" if RU else "The helper is on hold, back soon"), ("Готово: помощник закончил" if RU else "Done: the helper has finished"), ("Помощник давно ничего не делает" if RU else "The helper has been quiet for a while")],
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


TOOLS = dict(fsop=fsop, sysdata=sysdata, agent_log=agent_log, actions=actions, move=move, drag=drag, fetch_file=fetch_file, screenshot=screenshot, press_key=press_key, click=click, scroll=scroll, type_text=type_text, run=run,
             read_file=read_file, write_file=write_file, list_dir=list_dir, sysinfo=sysinfo,
             start_process=start_process, mcp_start=mcp_start, mcp_tools=mcp_tools, mcp_call=mcp_call, mcp_stop=mcp_stop)


PHASE = {"p": "ok", "last": time.time()}
def look(a):
    out = []
    import re as _re
    m = _re.match(r"^#?([0-9a-fA-F]{6})$", str(a.get("color") or ""))
    if m:
        rgb = [int(m.group(1)[i:i + 2], 16) for i in (0, 2, 4)]; mx = max(rgb)
        if mx < 200: rgb = [min(255, int(v * 200 / max(1, mx))) for v in rgb]   # always bright enough to be seen
        overlay_send("color %d %d %d" % tuple(rgb)); out.append("colour set")
    if a.get("note"):
        n = " ".join(str(a["note"]).split())[:90]; overlay_send("note " + n); print(c("36", "  ✎ " + n), flush=True); out.append("note shown")
    return {"text": ", ".join(out) or "nothing to change"}
def hold(a):
    PHASE["p"] = "hold"; overlay_send("state hold"); print(c(ORANGE, "  ⏸ " + ("Помощник на паузе и вернётся" if RU else "The helper is on hold and will be back")), flush=True); return {"text": "ok"}
def task_done(a):
    PHASE["p"] = "done"; overlay_send("state done")
    if PERSIST["on"]:   # a finished job should not reappear after the PC restarts; a new command re-arms it (handle(), below)
        for f in (AUTOSTART, os.path.join(STATE_DIR, "start.sh")):
            try: os.remove(f)
            except Exception: pass
        log("task done: autostart removed (a reboot will not bring the console back)")
    print(c("32", "  ✔ " + ("Помощник закончил работу" if RU else "The helper finished the work")), flush=True); return {"text": "ok"}
def set_mode(a):
    """admin panel only (never offered to the AI): switch confirm / auto / unattended on a live session"""
    m = norm_mode(a.get("mode"))
    if not m: raise ValueError(f"unknown mode '{a.get('mode')}'")
    MODE["m"] = m
    if PERSIST["on"]:
        save_session(CODE["c"], TOKEN, m)
        if not os.environ.get("HELPER_NO_AUTOSTART"): install_autostart()
    log(f"mode changed to {m} (by the administrator)")
    print(c("33", "  " + (f"Администратор сменил режим на {m}" if RU else f"The administrator switched the mode to {m}")), flush=True)
    if sys.stdout.isatty(): header(CODE["c"], False, m)
    return {"text": m}
TOOLS.update(ui_tree=ui_tree, ui_click=ui_click, ui_set=ui_set, look=look, hold=hold, task_done=task_done, set_mode=set_mode, trace=trace, watch=watch, focus_window=focus_window,
             tree=tree, find=find, edit_file=edit_file, push_file=push_file, system=system, util=util, stream=stream)
META = {"look", "hold", "task_done", "stream", "set_mode"}


GUI_TOOLS = {"ui_click", "ui_set", "click", "move", "drag", "scroll", "type_text", "press_key", "actions"}   # one X11 connection: never two at once
GUI_LOCK, ASK_LOCK = threading.Lock(), threading.Lock()


def handle(cmd, mode, token):
    """One tool call, in its own thread: a slow install or render never blocks screenshots, the live viewer or other calls."""
    name, args = cmd["tool"], cmd["args"]
    view = name == "screenshot" and bool((args or {}).get("view"))   # the operator's live viewer: no console line, no state change
    if not view and name not in META:
        PHASE["last"] = time.time()
        if not OP["seen"] or PHASE["p"] != "ok":
            first = not OP["seen"]; was_done = PHASE["p"] == "done"
            OP["seen"] = True; PHASE["p"] = "ok"; overlay_send("state ok"); show_status()
            if first: print(c("32", "  ● " + t("st_ok")), flush=True)
            if was_done and PERSIST["on"]: install_autostart()
        ln = line_for(name, args)
        if ln: print(ln, flush=True)
    quiet_ = name in QUIET or name in META or view
    if not quiet_: overlay_send("busy")
    res = {"id": cmd["id"]}
    try:
        if PAUSED.is_set() and name not in QUIET and name not in META: raise RuntimeError("PAUSED by the user (Esc menu). The session is kept. Do not retry now: use wait_online, then continue.")
        if mode == "confirm" and name in ASK_TOOLS and not (name == "util" and (args or {}).get("op") in READONLY_UTIL) and not (name == "fsop" and (args or {}).get("op") in ("preview", "stat")):
            with ASK_LOCK: ask_permission(name, args)
        if name in GUI_TOOLS:
            with GUI_LOCK: resume_state(name, args); res.update(ok=True, data=TOOLS[name](args)); mark_state(name)
        else:
            res.update(ok=True, data=TOOLS[name](args))
    except Exception as e:  # report every failure to the operator
        res.update(ok=False, error=f"{type(e).__name__}: {e}")
    if not quiet_: overlay_send("idle")
    if not quiet_: print((c("32", "    ✔ " + ("готово" if RU else "done")) if res.get("ok") else c("31", "    ✘ " + cut(res.get("error"), 120))), flush=True)
    for attempt in range(5):   # a lost result would leave the operator waiting for a call that already finished
        try: post_result(res, TOKEN or token); break
        except urllib.error.HTTPError as e:
            if e.code in (401, 410): break
            time.sleep(1 + attempt)
        except Exception: time.sleep(1 + attempt)
    if END.is_set(): print("session closed", flush=True); os.kill(os.getpid(), signal.SIGTERM)   # Esc: leave at once (the main thread runs the cleanup and says bye)


NET = {"s": "ok"}
LAST_OK = [time.time()]   # last time the relay answered a poll (the watchdog flips to 'lost' when it is too old)
POLL_TIMEOUT = 22         # the relay answers within 15 s; anything longer is a dead connection


def net_state(st):
    if NET["s"] == st: return
    NET["s"] = st
    print(c(ORANGE, "  ◌ " + t("st_lost")) if st == "lost" else c("32", "  ● " + ("Связь восстановлена" if RU else "Connection restored")), flush=True)
    overlay_send("state " + ("lost" if st == "lost" else ("paused" if PAUSED.is_set() else (PHASE["p"] if OP["seen"] else "wait"))))   # the overlay turns orange while the link is down or nobody has connected yet
    show_status()


def away_check():   # five minutes without a call from the helper: say so on the label
    if OP["seen"] and PHASE["p"] == "ok" and time.time() - PHASE["last"] > 300 and NET["s"] == "ok":
        PHASE["p"] = "away"; overlay_send("state away")


def register(mode, resume=None, resume_token=None, note=""):
    body = {"os": platform.platform(), "host": socket.gethostname(), "user": getpass.getuser(), "mode": mode, "persist": PERSIST["on"], "note": note, "device_id": get_device_id()}
    if resume: body["resume"] = resume   # the server may have forgotten us (restart, long outage): ask for the same code back
    if resume_token: body["resume_token"] = resume_token   # proof that it is the same PC: the server then keeps everything it has
    _, reg = api("/a/register", body, timeout=20)
    return reg


def main():
    global TOKEN
    signal.signal(signal.SIGTERM, lambda *_: sys.exit(0)); signal.signal(signal.SIGHUP, lambda *_: sys.exit(0))  # run cleanup()
    find_gui()
    saved = None if os.environ.get("HELPER_NEW") else load_session()
    mode = norm_mode((saved or {}).get("mode")) or norm_mode(os.environ.get("HELPER_MODE"))
    if not mode:
        mode = {"2": "auto", "3": "unattended"}.get(input(t("mode")).strip(), "confirm")
    MODE["m"] = mode
    persist = os.environ.get("HELPER_PERSIST")
    if saved: PERSIST["on"] = True
    elif persist in ("0", "1"): PERSIST["on"] = persist == "1"   # tests / an explicit opt-out only: otherwise the session is always kept
    else: PERSIST["on"] = True
    wait = 1.0
    note = ""
    if saved:
        print(c("33", "  " + t("resuming") + " " + saved["code"]), flush=True)
        note = "after a reboot" if abs(saved.get("boot", 0) - boot_time()) > 90 else "restarted"
        log(f"resuming session {saved['code']} ({note})")
    while True:   # the server can be unreachable right at the start (no internet yet, VPN still connecting): keep trying
        try: reg = register(mode, saved["code"], saved["token"], note) if saved else register(mode); break
        except Exception as e:
            print(c(ORANGE, "  ◌ " + t("st_conn") + f" ({type(e).__name__})"), flush=True); log(f"cannot reach the relay at start: {type(e).__name__}"); time.sleep(min(wait, 10.0)); wait *= 1.7
    token = TOKEN = reg["token"]; code = CODE["c"] = reg["code"]; LAST_OK[0] = time.time()
    if PERSIST["on"]:
        save_session(code, token, MODE["m"])
        if not saved: install_autostart()
    log(f"session {code} {'resumed' if reg.get('resumed') else 'started'} persist={PERSIST['on']} relay={RELAY}")
    overlay_start()
    copied = copy_clip(code)
    if sys.stdout.isatty(): header(code, copied, mode)
    else: print(f"\n  {t('banner')}  {code}\n  {t('tell')}\n", flush=True)
    play("ok")
    if sys.stdin.isatty(): threading.Thread(target=key_pump, daemon=True).start()
    overlay_send("state wait")
    if reg.get("resumed") and saved: OP["seen"] = True; overlay_send("state ok"); show_status()
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
                if e.code == 410: print("session closed (ended by the helper)"); FINAL.set(); return
                if e.code == 401:   # unknown to the server (it was reset): register again, same code, same proof
                    try:
                        reg = register(MODE["m"], code, token, "relay lost its state"); token = TOKEN = reg["token"]
                        print(f"[helper] registered again, session code: {reg['code']}", flush=True); log("registered again after the relay lost its state")
                        code = CODE["c"] = reg["code"]; fails, delay = 0, 1.0; LAST_OK[0] = time.time(); net_state("ok")
                        if PERSIST["on"]: save_session(code, token, MODE["m"])
                        continue
                    except urllib.error.HTTPError as e2:
                        if e2.code == 410: print("session closed"); FINAL.set(); return
                    except Exception: pass
                failed = True
            except Exception:   # no internet, DNS, VPN switch, TLS, timeouts ... keep trying
                status = cmd = None; failed = True
            if failed:
                fails += 1
                if fails >= 2: net_state("lost")
                outage_tick()
                time.sleep(min(delay, 10.0) * (0.8 + 0.4 * random.random())); delay *= 1.7
                continue
            if fails: outage_over()
            fails, delay = 0, 1.0; LAST_OK[0] = time.time(); net_state("ok"); away_check()
            if status != 200 or not cmd: continue
            if cmd["tool"] == "bye": print("session closed"); FINAL.set(); return
            pool.submit(handle, cmd, MODE["m"], token)
    except KeyboardInterrupt:
        pass
    finally:
        pool.shutdown(wait=False, cancel_futures=True)
        cleanup()
        final = FINAL.is_set() or not PERSIST["on"]   # a closed window or a reboot keeps a saved session; only the user's confirmed end (or the operator's) ends it
        try: api("/a/bye", {"final": final}, TOKEN, timeout=5)
        except Exception: pass
        log("stopped " + ("(session ended)" if final else "(session kept)"))
        if final: forget_session()


if __name__ == "__main__":
    main()
