# Blender (modelling, scenes, rendering) via blender-mcp
Verified on Windows 10/11 with Blender 5.2 and mcp-for-blender 2.x, including a clean machine without Blender or uv. Blender must run on the remote PC with the MCP add-on enabled; the MCP server (`uvx blender-mcp`) talks to it on localhost:9876.

## 1. Is Blender there?
- Windows: `Get-ChildItem 'C:\Program Files\Blender Foundation\*\blender.exe'`, also `Get-Command blender`, Steam: `...\Steam\steamapps\common\Blender\blender.exe`
- Linux: `which blender; ls /snap/bin/blender; flatpak list | grep -i blender`
- macOS: `ls /Applications/Blender*.app/Contents/MacOS/Blender`
- Already running? `Get-Process blender` / `pgrep -x blender`. If the user has Blender open **do not close it**: use the open one (then only check that its port answers), or start a second instance.

## 2. Not installed? Install it (big download: run as a background job, wait_job)
- Windows: `winget install -e --id BlenderFoundation.Blender --accept-package-agreements --accept-source-agreements --silent --disable-interactivity` (about 350 MB, 2-3 minutes; a UAC prompt may appear: tell the user to accept it). No winget: download the .msi from https://www.blender.org/download/ and `msiexec /i blender.msi /qn`.
- Ubuntu: `flatpak install -y flathub org.blender.Blender` (per user, no password) or `sudo snap install blender --classic` / `sudo apt install blender` (sudo needs the user's password: ask them).
- macOS: `brew install --cask blender`.
- Weak connection: tell the user the size first; use generous `timeout_s`.

## 3. Install and enable the add-on (no clicking)
A Blender that was never opened has no user folder yet. Create it, then install the add-on there (`uv`/`uvx` is fetched automatically by the bridge if missing):
```powershell
$exe = (Get-ChildItem 'C:\Program Files\Blender Foundation\*\blender.exe' | Sort-Object FullName | Select-Object -Last 1).FullName
$ver = ((& $exe --version | Select-Object -First 1) -replace '^Blender (\d+\.\d+).*', '$1')       # e.g. 5.2
$env:BLENDERMCP_ADDONS_DIR = "$env:APPDATA\Blender Foundation\Blender\$ver\scripts\addons"
New-Item -ItemType Directory -Force $env:BLENDERMCP_ADDONS_DIR | Out-Null
uvx mcp-for-blender install-addon
```
(Linux: `~/.config/blender/<ver>/scripts/addons`, macOS: `~/Library/Application Support/Blender/<ver>/scripts/addons`.)
Enable it once, with Blender **not running** (headless, saves the preference):
```
blender --background --python-expr "import bpy, addon_utils; ok = addon_utils.enable('blender_mcp', default_set=True); bpy.ops.wm.save_userpref(); print('ENABLED', bool(ok))"
```
Headless Blender is slow on weak machines (minutes): use a big `timeout_s`. The add-on starts its server by itself when Blender opens (auto-start on, port 9876).

## 4. Start Blender (GUI, stays open)
`start_process` with the blender executable (not `run`); read the returned first output. Check the port: `Get-NetTCPConnection -LocalPort 9876 -State Listen` / `ss -ltn | grep 9876`.
If the output says "A graphics card and driver with support for OpenGL 4.3 or higher is required" (old GPU, virtual machine, remote desktop session), Blender cannot open a window: tell the user, and use the **no-window mode** below.

## 4b. No-window mode (no GPU / servers)
The add-on refuses `blender -b`, but the server can be started from a small script that also pumps its command queue. Everything except viewport screenshots (`look`) works; render with Cycles on the CPU.
1. Write this to a file (write_file), e.g. `%TEMP%\hm-keepalive.py`:
```python
import bpy, time, addon_utils, sys
addon_utils.enable('blender_mcp', default_set=False)
mod = sys.modules['blender_mcp']
class _App:                       # the add-on refuses to start in `blender -b`
    def __getattr__(self, n): return False if n == 'background' else getattr(bpy.app, n)
class _Bpy:
    app = _App()
    def __getattr__(self, n): return getattr(bpy, n)
srv = mod.BlenderMCPServer(port=9876)
real = mod.bpy
mod.bpy = _Bpy()
try: srv.start()
finally: mod.bpy = real
bpy.types.blendermcp_server = srv
print("BLENDER_MCP_HEADLESS running=%s" % srv.running, flush=True)
while True:
    try: srv._drain_command_queue()
    except Exception as e: print("drain error:", e, flush=True)
    time.sleep(0.05)
```
2. `start_process command=<blender> args=["--background","--python","<that file>"] wait_s=20`: the output must say `BlenderMCP server started on localhost:9876`.
On Linux with a display server missing you can alternatively use `xvfb-run -a blender` (GUI mode in a virtual display).

## 5. Start the MCP server through the bridge
`mcp_start name="blender" command="uvx" args=["blender-mcp"] timeout_s=600` (the first start downloads packages).
Useful tools: `get_scene_info`, `execute_blender_code` (any bpy Python), `look` (viewport screenshot, GUI mode only), `get_addon_status`, `import_asset`, `search_assets`.

## 6. Work
Prefer `execute_blender_code` for modelling (primitives, modifiers, materials, cameras), then check the result (`look`, or render to a PNG and `read_file` it: images come back as images) and fix. Save with `bpy.ops.wm.save_as_mainfile(filepath=...)` and tell the user where the file is. Use `open_viewer` so the operator can watch the Blender window.

## 7. Clean up
`mcp_stop blender` kills the MCP server and its helpers. Leave Blender open if the user may want the result; otherwise close only the instance you started.

## Testing without touching the user's settings
Start Blender with its own profile: env `BLENDER_USER_SCRIPTS`, `BLENDER_USER_CONFIG`, `BLENDER_USER_DATAFILES`, `BLENDER_USER_EXTENSIONS` pointing to a temp folder (`BLENDER_USER_RESOURCE_PATH` is ignored by Blender 5.x), and `BLENDERMCP_ADDONS_DIR=<temp>\scripts\addons` for the install.
