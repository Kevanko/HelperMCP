<div align="center">

<img src="relay/logo.svg" width="96" alt="HelperMCP logo">

# HelperMCP

**Your AI fixes a friend's computer or phone, while they watch.**

[![MCP](https://img.shields.io/badge/MCP-streamable%20HTTP-38ff7a?labelColor=020a06)](#quick-start)
[![Windows](https://img.shields.io/badge/Windows-10%20%2F%2011-38ff7a?labelColor=020a06)](#what-your-friend-sees)
[![Linux](https://img.shields.io/badge/Linux-X11-38ff7a?labelColor=020a06)](#what-your-friend-sees)
[![Android](https://img.shields.io/badge/Android-11%2B-38ff7a?labelColor=020a06)](#android)
[![Self-hosted](https://img.shields.io/badge/server-self--hosted-38ff7a?labelColor=020a06)](#quick-start)

<img src="docs/demo.gif" alt="A friend runs one line and gets a code, sends it to you, you ask your AI, and it installs Blender on the friend's PC" width="900">

[Русская версия ниже](#по-русски)

</div>

Your friend runs one line and gets a code. You give the code to your AI (Claude Code, Codex, Cursor, anything with MCP). It sees their screen, clicks, types, installs and fixes things. You watch live and can take over at any moment.

## Quick start

**1. Install the server** (any Linux server, Docker is installed if missing):

```bash
curl -fsSL https://raw.githubusercontent.com/Kevanko/HelperMCP/master/install.sh | sudo bash
```

It asks for a domain. Have one? Type it and HTTPS sets itself up. No domain? Press Enter and it runs on the server's IP. At the end it prints everything you need.

**2. Connect your AI** (once):

```bash
helpermcp connect claude      # Claude Code: prints the command to paste
helpermcp connect codex       # Codex on Linux / macOS   (codex-win for Windows)
helpermcp connect prompt      # any other AI: a text it reads and connects itself
```

**3. Help a friend:**

```bash
helpermcp link                # the link to send them
```

They open it, run the line for their system and send you the code. Tell your AI:

> help my friend, code 7FBV-HUVJ: Blender won't install

## Server commands

| Command | What it does |
|---|---|
| `helpermcp` | status: address, sessions, what's running |
| `helpermcp panel` | the same, live |
| `helpermcp help` | every command |
| `helpermcp link` | the link for a friend |
| `helpermcp connect [claude \| codex \| codex-win \| other \| prompt]` | how to connect your AI |
| `helpermcp domain help.example.com` | add a domain later (HTTPS turns on) |
| `helpermcp config` | change domain / IP / port step by step |
| `helpermcp key` | new operator key |
| `helpermcp update` | update to the latest version |
| `helpermcp admin` / `admin reset` | the admin panel link and login; a new password |
| `helpermcp report [days]` | what the AI did and where it failed: errors grouped by cause with the call to replay, slow calls, repeated sequences, outages and route switches |
| `helpermcp logs` / `restart` | logs, restart |

## What your friend sees

| System | One line (the link page shows it) |
|---|---|
| Windows 10 / 11 (PowerShell) | `[Net.ServicePointManager]::SecurityProtocol=3072; irm https://your.server/h \| iex` |
| Linux / macOS | `python3 <(curl -fsSL https://your.server/p)` |
| Android 11+ | a small app, the link page has a QR code |

- **Nothing is installed.** The PC agent runs from memory and is gone when the window closes.
- **Everything is visible.** A glowing screen edge, a label with the current step, the AI's own smooth pointer.
- **They stay in charge.** By default every action asks `Y / A(lways) / N`. **Esc** pauses or ends the session.
- **Kept sessions reconnect.** After internet loss, VPN changes or reboot, the agent retries with the saved code when a working route is available.

## The live view: System and Files

On a control link the top bar has **System** and **Files**. System: every process (CPU, memory, publisher, path; click one for its path, command line, parent chain, signature, SHA-256, autostart entries and connections, end it, open its folder, check the hash on VirusTotal), services (start / stop / restart), startup (Run keys, startup folders, logon / boot tasks, Winlogon / IFEO / AppInit tricks, flagged when the file is missing or in a temp folder), performance (CPU and every core, RAM, commit, disk and network throughput), every disk, every network adapter with a per-adapter relay test, a health check (update and Store services, policies, activation, Defender, firewall, pending reboot, hosts, proxy, devices) and every custom policy with what it does. Files: drives, preview without downloading (text, hex, picture, zip contents), copy / cut / paste, new folder or file, rename, delete (Recycle Bin), upload by button or drop, download, search by name or text. The same data is one call for the AI: `system {sections:[...]}`, `fsop`.

## What your AI gets

- **Eyes and hands:** a live stream of the screen, screenshots, mouse, keyboard, commands.
- **The screen as text, not pictures:** `ui_tree` lists a window's controls (name, value, state, position) in a few lines, and `ui_click` / `ui_set` press and fill them by name, through the system's accessibility API (Windows UI Automation, Linux AT-SPI, Android accessibility). Tens of tokens instead of a screenshot, no coordinates to guess, no DPI or layout problems; for games, custom-drawn and administrator windows Windows reads the visible text with its built-in OCR (Linux with `tesseract` installed), and `ui_click` presses it, and a screenshot stays the fallback everywhere.
- **Files and system in one call:** `tree`, `find` (by name and content), read a range of a file, exact `edit_file`, send a file to the PC, a whole folder back as a zip, and `util` for installs, services, PATH, registry and more — no fragile shell one-liners, no quoting traps.
- **Find the resource hog in one call:** `system` returns every process with its real CPU %, memory, exe path and publisher, flags anything running from a temp/download folder or unsigned, plus disks, network, startup, services and drivers — so "why does this PC lag" is answered instantly and cheaply. `sysinfo` and `system` take tens of milliseconds (no WMI).
- **Self-checks:** every click and keystroke reports what changed on screen, or a loud *NO CHANGE*, so it stops instead of typing into the wrong window.
- **A plan with stages:** each step has its own colour, shown on the friend's screen and in your live view.
- **Other MCP servers on their PC:** a real visible browser (`playwright`), Blender, anything; missing Node / uv are fetched on the fly.
- **Long jobs:** installs and renders don't time out, the AI collects the result later.

The AI opens a **live view** for you right away: a view-only link to share and a control link to click, type and take over, then hand back.

## Admin panel

`https://your-server/admin` lists every connected session (device, state, mode, last seen, IP, what the AI did last), opens any of them in the live viewer with the control link, ends a session, changes the glow colour and the task text, and shows the action report. The install script prints the link, the login and a generated password **once** (the password is stored only as a scrypt hash); `helpermcp admin` shows the link and login again, `helpermcp admin reset` makes a new password.

**All devices** changes Glow or Sound for existing devices and future sessions. Each device row has its own Glow and Sound switches; a local change affects only that device. Offline devices receive their saved setting when they reconnect. **Disconnect** closes that viewer's stream, cancels its queued input and gives control back immediately; another open viewer stays connected. Reconnect opens a fresh viewer connection.

Saved sessions stay offline after a relay restart until the PC contacts it again; their last-contact time is retained. Legacy records without a measured contact display unknown until the next connection. Closing a kept Helper window preserves the code for a later restart. Direct viewer clicks, pointer movement, wheel, text and shortcuts skip AI focus restoration and screenshot-comparison delays; AI tool calls retain their normal visual checks.

Updated Windows agents in auto/unattended mode support live held dragging. A separate local pointer worker owns a three-second lease: it releases the button without relay access when keepalives stop, and also releases when its parent exits. Disconnect, handback, focus loss and pointer cancellation request release immediately. Stale sequences cannot restart a cancelled gesture. Old agents, confirm mode, or a failed/slow live-pointer path retain completed dragging. Button transitions are audited; intermediate pointer samples and keepalives do not fill the action log.

It is hardened: cookie sessions (HttpOnly, SameSite=Strict, Secure over HTTPS, 30 min idle / 8 h absolute), a CSRF header on every change plus an Origin check, five wrong passwords lock the address for 15 minutes (the same work is done for a wrong login as for a wrong password), a strict CSP that allows scripts only from the server itself, no operator key anywhere in the page, every admin action in the action log. Put the server behind a domain with HTTPS (`helpermcp domain <name>`) before using it over the internet; `ADMIN_DISABLE=1` switches the panel off.

## A link that holds

The Windows agent retries kept sessions after VPN changes, internet loss and reboots. It can change its own transport without changing the friend's VPN, routes or DNS. If every path to the relay is blocked, remote access still needs a reachable endpoint.

- **Reboot:** the helper starts again with Windows in a visible window and takes the same code back at once; the saved session decides the mode, so nothing is asked.
- **Route layer (Windows):** a local bridge binds its own IPv4 sockets to an adapter. The watchdog checks TLS `/health`, prefers physical adapters, and tests the default route, system proxy and VPN adapters as fallbacks. The alternate relay port 9444 is probed without changing the active endpoint; it must be configured on the server. DNS is refreshed after network changes, with adapter-bound DNS fallback for physical paths. Speed tests do not block the recovery watchdog. WinDivert/WFP filters can still intercept bound sockets.
- **Look at the network:** `system {sections:["reach"]}` lists every adapter (type, speed, IP, gateway, DNS, MAC), which one is the default route, which one the helper uses, whether each reaches the relay, the VPN / DPI-bypass / proxy programs and filter drivers installed, proxies and the hosts file; `connections` shows who talks to whom.
- **Not touched:** outage recovery does not restart adapters, flush shared DNS, change routes, stop zapret or switch VPN/TUN.

## Network diagnosis

The updated Windows agent exposes `net_check`. Start with `{mode:"quick"}` to compare the current default/TUN route with adapter-bound paths. It reports DNS, repeated TCP/TLS/HTTP timings, HTTP status and payload bytes, CPU, memory and adapter counters. Use `interface_index` from `system {sections:["network"]}` for one exact adapter; a missing/down adapter fails without silently using the default route.

Modes: `sites`, `dns`, `speed` (bounded download goodput), `load` (idle/load latency comparison), `inventory` (paged local JSON/YAML/URI subscription exports without credentials), `vpn` (endpoint reachability), `profile` (authenticated HTTP through one local Mihomo YAML/JSON profile using an already installed core, private proxy and bounded child process; no TUN/system proxy changes or application UDP claim) and `rkn` ([RKN Block Checker](https://github.com/MayersScott/rkn-block-checker), pinned to 0.6.0, with isolated adapter-bound sockets and DNS). Reports are compact by default; `detail:true` includes each sample. The live viewer's Network tab has diagnosis, route inspection, recovery jobs/status, a non-mutating guard self-test and rollback. The Windows launcher retries an alternate HTTPS endpoint and keeps startup errors visible.

`vpn` tests endpoint reachability; `profile` verifies HTTP through one authenticated protocol connection. Neither proves application UDP/QUIC, Discord voice or game access. Binding to Ethernet does not bypass zapret/WinDivert. See [the network recipe](recipes/network.md) for commands, evidence limits and recovery rules.

For authorized network changes, `net_recover` runs local background scenarios with a SYSTEM rollback task. It captures undo before each mutation, verifies the task before touching the network, and restores settings even when Helper loses its connection. Templates cover temporary adapter disconnect/cycle, WARP and zapret service A/B, DNS, one stale manual route, and IPv4 MTU. `restore`, `wait` and bound HTTP `probe` steps can run offline; status and probe results remain on the PC. An elevated Helper is required. Recovery cannot guarantee a working physical line or fix an OS/driver hang. See [the recovery recipe](recipes/network-recovery.md).

## The action log

Every call is appended to `data/actions.jsonl` on the server: tool, arguments, result (cut short), time, errors with the hint that was given, and what the agents report (outages with their diagnosis, route switches, resumes). Typed text, file contents and values are never written, only their length; obvious secrets are masked. `helpermcp report [days]` turns it into: failures grouped by cause with the exact call to replay, the slowest calls, sequences that repeat (candidates for one combined tool), stuck loops, and the network events.

## Android

Install the APK from the QR code on the link page, turn on **HelperMCP** in *Accessibility*, press **Start help**, send the code. The AI can tap, swipe, type, press keys and open apps. The glow follows the phone's real screen shape and camera cutout.

**Live video and the same fast tools as on a PC.** When someone opens the live view, the phone asks once (*Start recording or casting*, whole screen) and streams real H.264 video; if that is declined, it falls back to a few screenshots a second. The live view's System panel shows battery, RAM, network and the apps used lately, and its Files panel browses the phone. After the friend taps **Allow file access** (optional), `tree`, `find`, `read_file`, `edit_file`, `push_file` and `fetch_file` work on `/sdcard`. `system` lists installed apps (`!` = not from a store, or holding accessibility / device-admin power), VPN and private DNS, and which apps have risky powers; `util` opens any Settings screen, checks the network and more, so the AI can verify what the friend says without clicking through menus. In ask mode every file or app action is confirmed on the phone. The admin panel can switch a live phone to unattended: no questions, and the phone's button then only pauses (only the admin ends the session; switching the accessibility service off in Settings always stops everything).

To publish your own build: `cd android && ./gradlew assembleRelease -Prelay=https://your.server`, then put the APK at `data/apk/helpermcp.apk` on the server.

<details>
<summary><b>More details</b></summary>

- **Two MCP endpoints.** `/mcp`: one connection, every tool takes a `session` code. `/s/<CODE>/mcp`: per session, the friend's PC looks like your own and their MCP servers show up as native tools.
- **Your own certificate.** Already have nginx / certbot? Set `TLS_CERT` / `TLS_KEY` in `.env`, or put the relay behind your proxy and set `PUBLIC_URL`. See `.env.example`.
- **Cursor pack.** Drop `pointer.cur`, `link.cur`, `beam.cur` (and friends) into `data/cursor/` and agents use them during the session.
- **Recipes.** `recipes/` has step-by-step guides the AI reads (`blender`, `any-app`). Plain Markdown, add your own.
- **Weak connections.** Screenshots are raw JPEG and shrink on slow links, unchanged screens aren't sent, big output is gzipped.
- **Live stream.** The view is a real stream, not a slideshow: Windows sends only the screen tiles that change, Linux with `ffmpeg` sends H.264 (the browser decodes it with WebCodecs), and it steps quality to the link. Behind nginx add `proxy_buffering off; proxy_request_buffering off;` for the `/v/` and `/a/` paths; Caddy needs nothing.
- **Files in the live view.** On the control link a Files panel browses the remote folders, downloads a file with a click, and drops files from your computer straight onto the open folder on the friend's PC.
- **System panel and monitors.** Next to the picture a live panel shows CPU, RAM and the busiest processes (publisher, path, `!` on anything suspicious); on the control link each row has an end-process button. The top bar draws a map of the PC's real monitors with their resolutions: click one, or press `1`–`9` (`0` = all screens).
- **Zoom the preview.** Ctrl + mouse wheel zooms the live picture toward the cursor, drag pans, and a 1:1 button resets — the coordinates you click stay exact while zoomed.
- **Linux.** Mouse and keyboard need X11 ("Ubuntu on Xorg"). On Wayland, screenshots, commands, files and browsers still work.
- **Mistake log.** Missed taps and redone actions are saved with context (`misses` tool) so you can spot patterns.

</details>

## Develop

Run Windows integration tests in a dedicated VM: they create windows and send
mouse/keyboard input. Do not run them on a desktop someone is using.

```bash
cd relay && npm ci && npm test      # relay + real agent + MCP client, end to end
```

CI runs on Windows and Ubuntu, Node 18 and 22.

On Windows, `npm run test:network` covers native networking and offline recovery.
For real profile protocol tests, set `HELPER_TEST_MIHOMO` to an already installed
Mihomo executable, then run `npm run test:profile` and `node test/network-e2e.mjs`
from `relay`. Tests use their own local VLESS fixture, do not download a core,
and verify authentication, HTTP errors, TLS rejection and process/config cleanup.

## Security

Whoever holds the operator key can do what the friend can on their PC while a session is open. Keep it secret, help only people who asked. See [SECURITY.md](SECURITY.md). State is encrypted, files and sessions are deleted at the end.

MIT license.

---

## По-русски

Друг запускает одну строку и получает код. Ты даёшь код своему ИИ (Claude Code, Codex, Cursor, любой с MCP). Он видит экран друга, кликает, печатает, ставит и чинит. Ты смотришь вживую и можешь перехватить управление.

**1. Сервер** (любой Linux):

```bash
curl -fsSL https://raw.githubusercontent.com/Kevanko/HelperMCP/master/install.sh | sudo bash
```

Спросит домен: есть — впиши, HTTPS настроится сам; нет — нажми Enter, заработает по IP. В конце выведет всё нужное.

**2. Подключи ИИ** (один раз):

```bash
helpermcp connect claude      # команда для Claude Code
helpermcp connect codex       # Codex на Linux / macOS   (codex-win для Windows)
helpermcp connect prompt      # любой другой ИИ: текст, по которому он подключится сам
```

**3. Помоги другу:**

```bash
helpermcp link                # ссылка для друга
```

Друг открывает её, запускает строку для своей системы и присылает код. Пишешь ИИ:

> помоги другу, код 7FBV-HUVJ: не ставится Blender

**Остальное:** `helpermcp help` — все команды, `helpermcp` — панель, `helpermcp domain help.example.com` — добавить домен потом, `helpermcp config` — сменить домен / IP / порт, `helpermcp key` — новый ключ, `helpermcp update` — обновиться.

**Друг всё видит и всё решает:** светящаяся рамка, плашка с текущим шагом, плавный курсор ИИ; каждое действие по умолчанию спрашивает `Y / A / N`, **Esc** ставит паузу или завершает. На ПК ничего не устанавливается, на Android — небольшое приложение (QR-код на странице ссылки). Сессия переживает обрыв интернета, смену VPN и перезагрузку.
