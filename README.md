# HelperMCP

Remote help for friends' computers, driven by any AI that speaks MCP (Claude, Cursor, Codex, your own agent).

A friend opens a link and pastes **one line**; you give your AI the code on their screen; the AI then works on their PC as if it were its own: looks at the screen, runs programs, reads and edits files and configs, and can use **any other MCP server on their PC** (browser, filesystem, …) through the same bridge. Nothing is installed on their side.

*Русская версия ниже / Russian version below.*

```
 friend's PC                relay (your server)               you
┌────────────┐  HTTPS   ┌──────────────────────┐   MCP    ┌─────────────┐
│ agent      │ ───────► │ /a/*  agent API      │ ◄─────── │ any AI with │
│ (PS / py)  │ long-poll│ /mcp, /s/<code>/mcp  │          │ MCP client  │
│  └ child MCP servers (Playwright, …)         │          └─────────────┘
└────────────┘          └──────────────────────┘
```

The agent only makes outbound HTTPS requests, so no port forwarding or public IP is needed on the friend's side.

## 1. Install the relay on your server (one command)

```bash
curl -fsSL https://raw.githubusercontent.com/Kevanko/HelperMCP/master/install.sh | sudo bash -s -- --domain help.example.com
```

Needs a Linux server with a domain pointing at it (ports 80/443 free). It installs Docker if missing, starts the relay with automatic HTTPS (Caddy) and prints everything you need: the friend link, the MCP URL and your operator key. Without `--domain` it serves plain HTTP on `http://<ip>:8444` (testing only). Re-run the same command to update.

Already have nginx/certbot? Skip Caddy: set `TLS_CERT`/`TLS_KEY` in `.env` (the relay serves TLS itself and reloads renewed certificates), or put the relay behind your proxy and set `PUBLIC_URL`. See `.env.example`.

## 2. Friend's side

Send the friend your relay link (`https://help.example.com/`): it shows the line for their system.

| OS | One line |
|----|----------|
| Windows 10/11 (PowerShell) | `[Net.ServicePointManager]::SecurityProtocol=3072; irm https://help.example.com/h \| iex` |
| Ubuntu / Linux / macOS | `python3 <(curl -fsSL https://help.example.com/p)` |

The script runs in memory (Windows) or from a pipe (Linux), asks for a mode and prints a code like `K7M2-QX9P`. Closing the window or Ctrl+C ends access.

* **Ask mode (default):** the friend types `y` for every command, file write, click, keystroke and MCP-server start/call. Screenshots, file reads and directory listings need no confirmation.
* **Full mode:** no prompts.
* Everything the AI does is printed in the friend's console.
* While a helper is connected, **every screen gets a soft glowing edge and a "Remote control" label on top** (like Codex). It ignores the mouse, stays on top, and disappears when the window is closed, even if the agent is killed.
* **The AI's mouse is visible.** The pointer glides to its targets (eased, speed by distance) instead of jumping, and a big cursor with a soft glow and a comet tail follows it. Clicks send a ripple, the cursor squeezes on press; drags show a ring around the pointer; scrolling shows chevrons, typing shows pulsing dots. The **real mouse pointer is replaced for the whole connection** (every app, taskbar included) by a soft rounded arrow, or by your own cursor pack: drop `pointer.cur`, `link.cur`, `beam.cur` (and optionally `help`, `precision`, `unavailable`, `vert`, `horz`, `move`, `dgn1`, `dgn2`, `working.ani`, `busy.ani`) into `data/cursor/` on the relay and agents fetch them at start. The old pointer comes back when the session ends (Windows: system cursors via `SetSystemCursor`; Linux/GNOME: a temporary Xcursor theme in `~/.icons` selected through gsettings). While the AI works (and 8 s after) its own soft arrow replaces the pointer: it leans into the direction of movement, glows, ripples on clicks and shows drag, scroll and typing cues; while text is typed the arrow travels along the line under the letters. The arrow and the session pointer come from your cursor pack (a little bigger than the original). The label on top shows the session clock.
* **Connection state is visible.** Blue edge = connected. If the link breaks (internet lost, VPN switch, sleep, server restart) the edge and the label turn **orange** ("Connection lost, reconnecting...") until the agent is back.

**Linux:** the agent finds the user's desktop session by itself (also when started over SSH) and drives the mouse/keyboard through X11 directly, so nothing has to be installed (`scrot`/`python3-gi`, present on most desktops, are used for screenshots and the overlay). On **Wayland** screenshots (needs `grim`/`gnome-screenshot`), commands, files and browsers work, but mouse/keyboard control does not: log in with "Ubuntu on Xorg" for that.

## 3. Connect your AI (once)

```
claude mcp add --transport http helper https://help.example.com/mcp --header "Authorization: Bearer YOUR_OPERATOR_KEY"
```

Any MCP client with streamable-HTTP support works: URL `https://help.example.com/mcp`, header `Authorization: Bearer <key>`.

Then say: *"connect to K7M2-QX9P and find why the game crashes"*.

Two ways to connect:

* **`/mcp`**: connect once, every tool takes a `session` argument (the code). Use `list_sessions` to see who is online.
* **`/s/<CODE>/mcp`**: one connection per help session. The friend's PC then looks like your own: no `session` argument, and the tools of any started child MCP server show up as native tools named `<server>__<tool>`. Best when your AI client lets you add a server on the fly.

## Watch what is happening

`open_viewer` returns a link (valid 12 h, usable only for that session; it does not expose your operator key). Open it in a browser and you get a **live view of the remote screen** (about 1 frame/s) next to a log of what the AI is doing. Ask your AI to open it for you, e.g. `start <url>` on Windows or `xdg-open <url>` on Linux. The viewer never moves the mouse and does not change the coordinates the AI clicks with.

## Tools

| Tool | What |
|------|------|
| `sysinfo`, `screenshot`, `run`, `read_file`, `write_file`, `list_dir` | look around, run programs, edit configs. `read_file` returns images (renders, saved screenshots) as images |
| `start_process` | start a program **detached** (GUI apps like Blender or Unity, servers) and keep it running |
| `click`, `move`, `drag`, `scroll`, `type_text`, `press_key` | mouse (smooth glide, drag and drop) and keyboard (`ctrl+c`, `alt+f4`, `win+r`, `enter`), any Unicode text; coordinates are screenshot pixels |
| `mcp_start`, `mcp_tools`, `mcp_call`, `mcp_stop` | run and use **other MCP servers on the friend's PC** |
| `recipe` | verified how-tos for apps (`blender`, the generic `any-app`) |
| `wait_job` | collect the result of a long operation (see below) |
| `open_viewer` | link to a live view of the remote screen + action log |
| `list_sessions`, `end_session` | session management |

## Work on their PC like on your own

The relay hands every connecting AI a short manual (MCP `instructions`): look first, check whether the app is installed, install it if not, start it, start its MCP server, work, clean up. The pieces that make this smooth:

* **Missing runtimes appear on their own.** If a command mentions `node`/`npx`/`npm`/`uv`/`uvx` and it is not installed (or Node is older than 20 for `npx`), a portable copy is downloaded into a temp folder, put on `PATH` for everything you start, and deleted on exit. Python tools get `PYTHONUTF8=1`.
* **Long operations never time out.** Installs, first-time package downloads and renders take minutes; MCP clients give up after about a minute. After ~45 s a call answers `Still running (job X)`; the work continues on the remote PC and `wait_job` collects the result. `timeout_s` on `run`, `mcp_start` and `mcp_call` raises the limits (up to an hour).
* **Never blocked.** Screenshots, `sysinfo` and file reads are answered while a long command runs (the live viewer does not freeze behind an install).
* **Stopping cleans up.** `mcp_stop` and closing the agent kill the whole process tree (`uvx`/`npx` start the real server as a grandchild).
* **Installing apps.** `run` a package manager (`winget install -e --id ...`, `apt`/`flatpak`/`snap`, `brew`); an installer that needs administrator rights shows a UAC prompt the friend has to accept.

### Example: "make a model in Blender"

The AI calls `recipe blender` and does: look for Blender (`winget install` if missing, a background job) → `uvx mcp-for-blender install-addon` and enable the add-on without clicking → `start_process` Blender → `mcp_start uvx blender-mcp` → `execute_blender_code` to build the model → `look` / render + `read_file` to check it. On a PC without a usable GPU there is a no-window mode. Verified on a clean Windows 10 (no Blender, no uv, no Node) and on a PC where Blender was already open. The same pattern works for any app that has an MCP server: `recipe any-app`. Recipes are plain Markdown in [`recipes/`](recipes): add your own.

### Using other MCP servers (e.g. their browser)

```
mcp_start  name="browser" command="playwright"
mcp_call   server="browser" tool="browser_navigate" arguments={"url": "https://example.com"}
```

`command="playwright"` opens a **real, visible Chrome/Edge window** on the friend's screen (their installed browser, sound on, no automation warnings), like a Playwright MCP on your own desktop. Any other stdio MCP server works the same way, several side by side, e.g. `command="npx" args=["-y","@modelcontextprotocol/server-filesystem","C:\\Users\\Friend\\Documents"]`. Servers that talk to a local app (Blender, Unity, ...) need that app and its add-on running on the friend's PC (see the recipes).

## Weak connections

* Screenshots travel as raw JPEG (no base64 inflation), big JSON output is gzipped.
* The live viewer steps its quality up and down to keep about one frame per second, and sends nothing while the screen does not change.
* On a slow link the AI's screenshots shrink on their own; `screenshot` takes `max_width` and `quality`, `monitor=N` crops to one screen.

## Reconnecting by itself

The agent never gives up on a bad connection: failed requests are retried with a growing delay (1 s to 10 s), after two failures the overlay turns orange, and when the link is back everything continues. Connections that died with an old route (VPN switched) are dropped and re-opened. A session is kept for 5 minutes after the agent was last seen; `list_sessions` shows `online` and `last_seen_s`, and a call to an offline PC fails at once with a clear message instead of hanging. If the server forgot the session (restart without `data/`, outage longer than 5 minutes) the agent registers again and asks for **the same code**, so the operator keeps using it.

## Sessions survive restarts

The relay stores sessions (agent tokens hashed) and viewer links in `data/state.json`. Restart or update the server and the agents on the friends' PCs just keep working. Without that file (fresh server) an agent tells the friend to run the command again.

## Develop and test

```bash
cd relay && npm ci && npm test      # relay + real agent + MCP client, end to end
```

`AGENT=ps|py` picks the agent, `GUI=1` also tests screenshots on a real desktop, `PORTABLE=1` hides Node to test the portable-Node download. The suite covers jobs, concurrency, restarts, process trees, recipes, viewer and the bandwidth path. CI runs on Windows and Ubuntu with Node 18 and 22.

## Security

See [SECURITY.md](SECURITY.md). Wrong operator keys are rate-limited per IP. Short version: whoever holds `OPERATOR_KEY` has the same power as the friend on their PC while the window is open. Only run it for people who asked for help, and only send the link to them.

## License

MIT

---

# HelperMCP (по-русски)

Удалённая помощь друзьям через любую ИИ с поддержкой MCP (Claude, Cursor, Codex, свой агент). Друг открывает ссылку и вставляет **одну строку**, ты даёшь ИИ код с его экрана, и она работает на его ПК как на своём: смотрит экран, запускает программы, правит файлы и конфиги игр и может пользоваться **любыми другими MCP-серверами на его ПК** (браузер и т.д.) через тот же мост. Ничего устанавливать не нужно.

**Сервер, одна команда** (нужен домен, указывающий на сервер):

```bash
curl -fsSL https://raw.githubusercontent.com/Kevanko/HelperMCP/master/install.sh | sudo bash -s -- --domain help.example.com
```

Скрипт поставит Docker и HTTPS и выведет ссылку для друга, MCP-адрес и ключ.

**Друг:** открывает твою ссылку и вставляет строку для своей системы (Windows: `irm https://help.example.com/h | iex`). Видит код вида `K7M2-QX9P`, называет тебе. Закрыл окно, и доступ исчез.

**Ты:** один раз подключаешь MCP (`claude mcp add ...`, команду печатает установщик) и пишешь ИИ: «подключись к K7M2-QX9P и выясни, почему вылетает игра». Для прозрачного режима используй `/s/КОД/mcp`: инструменты друга выглядят как твои собственные.

**Во время сессии** на каждом экране друга появляется плашка «Удалённое управление» и мягкое свечение по краям, как в Codex. Мышь и клавиатура работают сквозь неё.

**Браузер друга:** `mcp_start name="browser" command="playwright"` откроет настоящий видимый Chrome/Edge со звуком. Так же можно запускать любые другие MCP-серверы (файлы, Blender и т.д.), несколько одновременно. Если Node 20+ нет, агент скачает портативную копию во временную папку и удалит при выходе.

**Ubuntu:** агент сам находит сессию рабочего стола (даже если запущен по SSH). Для управления мышью нужен X11 («Ubuntu on Xorg»), на Wayland работают команды, файлы и браузер.

Безопасность: см. [SECURITY.md](SECURITY.md). Ключ держи в секрете, ссылку давай только тем, кто сам попросил о помощи.


## Как работать на ПК друга «как на своём» (кратко)

* ИИ при подключении получает инструкцию: посмотреть экран, проверить, стоит ли приложение, поставить, запустить, запустить его MCP, работать, убрать за собой.
* Недостающие `node`/`npx`/`uv`/`uvx` подтягиваются сами (портативные, во временную папку, удаляются при выходе).
* Долгие операции (установка, первый запуск MCP, рендер) не обрываются по таймауту клиента: через ~45 с приходит `Still running (job X)`, результат забирается через `wait_job`.
* Скриншоты и просмотр не «замирают» во время долгой команды. `mcp_stop` и закрытие агента убивают всё дерево процессов.
* `start_process` запускает программы отдельно (Blender, Unity и т.п.), `recipe blender` / `recipe any-app` описывают проверенные сценарии.
* Слабый интернет: картинки без раздувания base64, JSON сжимается, качество кадров просмотра подстраивается, неизменный экран не передаётся, у скриншота есть `max_width` и `quality`.
* Сессии и ссылки просмотра хранятся в `data/state.json` и переживают перезапуск сервера.
