#!/usr/bin/env python3
"""HelperMCP agent for Linux/macOS. Stdlib only. Run: python3 <(curl -fsSL RELAY/p)"""
import base64, getpass, json, locale, os, platform, queue, shutil, socket, subprocess, sys, tarfile, tempfile, threading, time
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
}
t = lambda k: T[k][0 if RU else 1]
ASK_TOOLS = {"run", "write_file", "click", "type_text", "press_key", "mcp_start", "mcp_call"}
NODE_VERSION = "v22.11.0"
NODE_DIR = None   # temp dir of the portable Node, if we had to download one
NODE_BIN = None
CHILDREN = {}     # name -> Child (other MCP servers running on this PC)
MAX_OUT = 100_000
scale = 1.0  # screenshot px -> real px (always 1 here: we never resize)


def api(path, data=None, token=None, timeout=40):
    req = urllib.request.Request(RELAY + path, method="POST" if data is not None else "GET")
    if token: req.add_header("Authorization", "Bearer " + token)
    if data is not None:
        req.add_header("Content-Type", "application/json")
        data = json.dumps(data).encode()
    with urllib.request.urlopen(req, data, timeout=timeout) as r:
        raw = r.read()
        return (r.status, json.loads(raw) if raw else None)


def sh(cmd, timeout=60):
    p = subprocess.run(cmd, shell=isinstance(cmd, str), capture_output=True, text=True,
                       timeout=timeout, errors="replace")
    return p.returncode, (p.stdout + p.stderr)


def clip(s):
    return s if len(s) <= MAX_OUT else s[:MAX_OUT] + f"\n...[truncated {len(s) - MAX_OUT} chars]"


def need(prog, hint):
    if not shutil.which(prog):
        raise RuntimeError(f"'{prog}' not found. Ask the user to run: {hint}")


def screenshot(_):
    if not (os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY") or sys.platform == "darwin"):
        raise RuntimeError("No graphical session (DISPLAY not set).")
    d = tempfile.mkdtemp()
    try:
        jpg, png = os.path.join(d, "s.jpg"), os.path.join(d, "s.png")
        tries = [("scrot", ["scrot", "-o", "-q", "70", jpg], jpg),
                 ("import", ["import", "-window", "root", "-quality", "70", jpg], jpg),
                 ("gnome-screenshot", ["gnome-screenshot", "-f", png], png),
                 ("grim", ["grim", png], png),
                 ("spectacle", ["spectacle", "-b", "-n", "-o", png], png),
                 ("screencapture", ["screencapture", "-x", png], png)]
        for prog, cmd, out in tries:
            if shutil.which(prog):
                subprocess.run(cmd, capture_output=True, timeout=20)
                if os.path.exists(out) and os.path.getsize(out) > 0:
                    with open(out, "rb") as f:
                        return {"image": base64.b64encode(f.read()).decode(),
                                "mime": "image/jpeg" if out == jpg else "image/png"}
        raise RuntimeError("No screenshot tool. Ask the user to run: sudo apt install scrot")
    finally:
        shutil.rmtree(d, ignore_errors=True)


KEYMAP = {"enter": "Return", "esc": "Escape", "backspace": "BackSpace", "del": "Delete", "delete": "Delete",
          "pageup": "Prior", "pagedown": "Next", "win": "super", "windows": "super", "ctrl": "ctrl",
          "space": "space", "tab": "Tab"}


def press_key(a):
    need("xdotool", "sudo apt install xdotool  (X11 sessions only)")
    combo = "+".join(KEYMAP.get(k.lower(), k) for k in a["keys"].split("+"))
    sh(["xdotool", "key", combo])
    return {"text": "ok"}


def click(a):
    need("xdotool", "sudo apt install xdotool  (X11 sessions only)")
    btn = {"left": "1", "middle": "2", "right": "3"}[a.get("button", "left")]
    sh(["xdotool", "mousemove", str(int(a["x"])), str(int(a["y"])), "click", "--repeat",
        "2" if a.get("double") else "1", btn])
    return {"text": "ok"}


def type_text(a):
    need("xdotool", "sudo apt install xdotool  (X11 sessions only)")
    sh(["xdotool", "type", "--delay", "20", "--", a["text"]])
    return {"text": "ok"}


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
        "python": platform.python_version(), "cpus": os.cpu_count(), "root": os.geteuid() == 0 if hasattr(os, "geteuid") else None,
        "display": os.environ.get("DISPLAY") or os.environ.get("WAYLAND_DISPLAY"),
        "session": os.environ.get("XDG_SESSION_TYPE"),
        "uptime": sh("uptime -p")[1].strip(), "mem": sh("free -h | sed -n 2p")[1].strip(),
        "disk": sh("df -h / | tail -1")[1].strip(),
    }, indent=2, ensure_ascii=False)}


def ensure_node(command):
    """npx/node/npm missing? Download a portable Node into a temp dir (removed on exit)."""
    global NODE_DIR, NODE_BIN
    if command not in ("npx", "node", "npm") or shutil.which(command) or NODE_BIN:
        return
    arch = {"x86_64": "x64", "amd64": "x64", "aarch64": "arm64", "arm64": "arm64"}.get(platform.machine().lower())
    osn = {"Linux": "linux", "Darwin": "darwin"}.get(platform.system())
    if not (arch and osn):
        raise RuntimeError("Node.js is missing and no portable build exists for this system")
    base = f"node-{NODE_VERSION}-{osn}-{arch}"
    NODE_DIR = tempfile.mkdtemp(prefix="helpermcp-node-")
    print("[helper] downloading portable Node.js ...", flush=True)
    pkg = os.path.join(NODE_DIR, "n.tar.xz")
    urllib.request.urlretrieve(f"https://nodejs.org/dist/{NODE_VERSION}/{base}.tar.xz", pkg)
    with tarfile.open(pkg) as t:
        t.extractall(NODE_DIR)
    NODE_BIN = os.path.join(NODE_DIR, base, "bin")


class Child:
    """One stdio MCP server running on this PC."""
    def __init__(self, command, args, env):
        e = dict(os.environ, **(env or {}))
        if NODE_BIN:
            e["PATH"] = NODE_BIN + os.pathsep + e.get("PATH", "")
        self.p = subprocess.Popen([command] + list(args or []), stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  stderr=subprocess.DEVNULL, env=e, text=True, encoding="utf-8", bufsize=1)
        self.q, self.n, self.tools = queue.Queue(), 0, []
        threading.Thread(target=self._read, daemon=True).start()

    def _read(self):
        for line in self.p.stdout:
            self.q.put(line)
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
            except queue.Empty: raise RuntimeError(f"MCP server timed out on {method}")
            if line is None: raise RuntimeError("MCP server exited")
            try: m = json.loads(line)
            except ValueError: continue
            if m.get("id") == self.n and "method" not in m:
                if "error" in m: raise RuntimeError(m["error"].get("message", str(m["error"])))
                return m["result"]


def mcp_start(a):
    name = a["name"]
    if name in CHILDREN: raise RuntimeError(f"'{name}' is already running")
    ensure_node(a["command"])
    c = Child(a["command"], a.get("args"), a.get("env"))
    try:
        c.rpc("initialize", {"protocolVersion": "2024-11-05", "capabilities": {},
                             "clientInfo": {"name": "helpermcp", "version": "0.2"}}, timeout=240)
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


def cleanup():
    for c in CHILDREN.values():
        try: c.p.kill()
        except Exception: pass
    if NODE_DIR: shutil.rmtree(NODE_DIR, ignore_errors=True)


TOOLS = dict(screenshot=screenshot, press_key=press_key, click=click, type_text=type_text, run=run,
             read_file=read_file, write_file=write_file, list_dir=list_dir, sysinfo=sysinfo,
             mcp_start=mcp_start, mcp_tools=mcp_tools, mcp_call=mcp_call, mcp_stop=mcp_stop)


def main():
    mode = os.environ.get("HELPER_MODE")
    if mode not in ("ask", "full"):
        mode = "full" if input(t("mode")).strip() == "2" else "ask"
    _, reg = api("/a/register", {"os": platform.platform(), "host": socket.gethostname(),
                                 "user": getpass.getuser(), "mode": mode})
    token = reg["token"]
    print(f"\n  {t('banner')}  {reg['code']}\n  {t('tell')}\n", flush=True)
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
