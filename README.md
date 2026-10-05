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

Linux GUI control needs X11 and `sudo apt install xdotool scrot`; on Wayland only commands, files and child MCP servers work.

## 3. Connect your AI (once)

```
claude mcp add --transport http helper https://help.example.com/mcp --header "Authorization: Bearer YOUR_OPERATOR_KEY"
```

Any MCP client with streamable-HTTP support works: URL `https://help.example.com/mcp`, header `Authorization: Bearer <key>`.

Then say: *"connect to K7M2-QX9P and find why the game crashes"*.

Two ways to connect:

* **`/mcp`**: connect once, every tool takes a `session` argument (the code). Use `list_sessions` to see who is online.
* **`/s/<CODE>/mcp`**: one connection per help session. The friend's PC then looks like your own: no `session` argument, and the tools of any started child MCP server show up as native tools named `<server>__<tool>`. Best when your AI client lets you add a server on the fly.

## Tools

| Tool | What |
|------|------|
| `sysinfo`, `screenshot`, `run`, `read_file`, `write_file`, `list_dir` | look around, run programs, edit configs |
| `click`, `type_text`, `press_key` | mouse and keyboard (`ctrl+c`, `alt+f4`, `win+r`, `enter`); click coordinates are screenshot pixels |
| `mcp_start`, `mcp_tools`, `mcp_call`, `mcp_stop` | run and use **other MCP servers on the friend's PC** |
| `list_sessions`, `end_session` | session management |

### Using other MCP servers (e.g. their browser)

```
mcp_start  name="browser" command="npx" args=["-y", "@playwright/mcp@latest"]
mcp_call   server="browser" tool="browser_navigate" arguments={"url": "https://example.com"}
```

Any stdio MCP server works the same way. If Node.js (`npx`) is missing, the agent downloads a portable copy into a temp folder (ask mode: after the friend approves) and deletes it on exit. This is tested end to end with the real Playwright MCP.

## Develop and test

```bash
cd relay && npm ci && npm test      # relay + real agent + MCP client, end to end
```

`AGENT=ps|py` picks the agent, `PORTABLE=1` hides Node to test the portable-Node download. CI runs on Windows and Ubuntu with Node 18 and 22.

## Security

See [SECURITY.md](SECURITY.md). Short version: whoever holds `OPERATOR_KEY` has the same power as the friend on their PC while the window is open. Only run it for people who asked for help, and only send the link to them.

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

**Браузер друга:** `mcp_start name="browser" command="npx" args=["-y","@playwright/mcp@latest"]`. Если Node нет, агент скачает портативную копию во временную папку и удалит при выходе.

Безопасность: см. [SECURITY.md](SECURITY.md). Ключ держи в секрете, ссылку давай только тем, кто сам попросил о помощи.
