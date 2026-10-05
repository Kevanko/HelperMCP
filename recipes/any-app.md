# Any app that has an MCP server (Unity, Substance, Godot, Houdini, Figma, ...)
The same pattern works for every one of them. There is no need for a ready-made recipe.

1. **Find the MCP server.** Search the app's name + "MCP" on GitHub / PyPI / npm. Note: how it starts (`npx -y <pkg>`, `uvx <pkg>`, `python -m ...`, an exe), what the app side needs (a plugin/add-on/package inside the app, a port to listen on), and the port.
2. **Is the app installed on the remote PC?** `Get-Command`, `winget list`, Program Files, registry, `which`, `flatpak list`. Not there: `winget search <app>` then `winget install -e --id <Id>` (Linux: apt/flatpak/snap, macOS: brew). Big installs: background job + `wait_job`; mention a UAC prompt to the user.
3. **Install the app-side plugin** the MCP server needs (copy a file, enable a preference, add a package to the project). Prefer command-line ways over clicking. Check with a screenshot.
4. **Start the app** with `start_process` (detached, stays open) and wait until its port listens (`Get-NetTCPConnection -LocalPort <p> -State Listen` / `ss -ltn`).
5. **Start the MCP server** with `mcp_start name=<app> command=<npx|uvx|python|exe> args=[...] timeout_s=600`. Node and uv are fetched automatically. Check the returned tool list.
6. **Work** through `mcp_call` (or `<app>__<tool>` on a `/s/<code>/mcp` connection). Use `screenshot` / `open_viewer` to see the app itself.
7. **Clean up** with `mcp_stop`. Leave the app open if the user will want the result.

Tips: first start of an MCP server downloads packages (minutes on a weak link): use `timeout_s` and `wait_job`. Apps that are already open: use them, never close the user's work. Test setups in an isolated profile/temp folder when the app allows it.
