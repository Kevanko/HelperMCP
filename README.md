<div align="center">

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
- **It survives real life.** Lost internet, VPN switch, reboot: the session comes back with the same code.

## What your AI gets

- **Eyes and hands:** a live stream of the screen, screenshots, mouse, keyboard, commands.
- **Files and system in one call:** `tree`, `find` (by name and content), read a range of a file, exact `edit_file`, send a file to the PC, a whole folder back as a zip, and `util` for installs, services, PATH, registry and more — no fragile shell one-liners, no quoting traps.
- **Find the resource hog in one call:** `system` returns every process with its real CPU %, memory, exe path and publisher, flags anything running from a temp/download folder or unsigned, plus disks, network, startup, services and drivers — so "why does this PC lag" is answered instantly and cheaply. `sysinfo` and `system` take tens of milliseconds (no WMI).
- **Self-checks:** every click and keystroke reports what changed on screen, or a loud *NO CHANGE*, so it stops instead of typing into the wrong window.
- **A plan with stages:** each step has its own colour, shown on the friend's screen and in your live view.
- **Other MCP servers on their PC:** a real visible browser (`playwright`), Blender, anything; missing Node / uv are fetched on the fly.
- **Long jobs:** installs and renders don't time out, the AI collects the result later.

The AI opens a **live view** for you right away: a view-only link to share and a control link to click, type and take over, then hand back.

## Android

Install the APK from the QR code on the link page, turn on **HelperMCP** in *Accessibility*, press **Start help**, send the code. The AI can tap, swipe, type, press keys and open apps. The glow follows the phone's real screen shape and camera cutout.

**Live video and the same fast tools as on a PC.** When someone opens the live view, the phone asks once (*Start recording or casting*, whole screen) and streams real H.264 video; if that is declined, it falls back to a few screenshots a second. The live view's System panel shows battery, RAM, network and the apps used lately, and its Files panel browses the phone. After the friend taps **Allow file access** (optional), `tree`, `find`, `read_file`, `edit_file`, `push_file` and `fetch_file` work on `/sdcard`. `system` lists installed apps (`!` = not from a store, or holding accessibility / device-admin power), VPN and private DNS, and which apps have risky powers; `util` opens any Settings screen, checks the network and more, so the AI can verify what the friend says without clicking through menus. In ask mode every file or app action is confirmed on the phone.

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

```bash
cd relay && npm ci && npm test      # relay + real agent + MCP client, end to end
```

CI runs on Windows and Ubuntu, Node 18 and 22.

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
