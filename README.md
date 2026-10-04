# HelperMCP

Remote help for friends' computers, driven by Claude (or any MCP client).
A friend pastes **one line**; you tell Claude the code on their screen; Claude can then look at their screen, run commands, read files and click, as if sitting at their PC. Nothing is installed on their side.

*Русская версия ниже / Russian version below.*

```
 friend's PC                relay (your server)               you
┌────────────┐  HTTPS   ┌─────────────────────┐   MCP    ┌─────────────┐
│ agent      │ ───────► │ /a/*  agent API     │ ◄─────── │ Claude Code │
│ (PS / py)  │ long-poll│ /mcp  MCP endpoint  │  /mcp    │ / Desktop   │
└────────────┘          └─────────────────────┘          └─────────────┘
```

The agent only makes outbound HTTPS requests, so no port forwarding or public IP is needed on the friend's side.

## Friend's side

| OS | One line |
|----|----------|
| Windows 10/11 (PowerShell) | `[Net.ServicePointManager]::SecurityProtocol=3072; irm https://YOUR_HOST:8444/h \| iex` |
| Ubuntu / Linux / macOS | `python3 <(curl -fsSL https://YOUR_HOST:8444/p)` |

The script runs in memory (Windows) or from a pipe (Linux), asks which mode to use, and prints a code like `K7M2-QX9P`. Close the window or press Ctrl+C and the access is gone.

* **Ask mode (default):** the friend must type `y` for every command, file write, click, keystroke. Screenshots, file reads and directory listings need no confirmation.
* **Full mode:** no prompts.
* Everything Claude does is printed in the friend's console.

Linux GUI control needs an X11 session and `sudo apt install xdotool scrot`. On Wayland only commands and files work.

## Your side

1. Deploy the relay (below), keep the `OPERATOR_KEY` secret.
2. Add it to Claude Code once:

```
claude mcp add --transport http helper https://YOUR_HOST:8444/mcp --header "Authorization: Bearer YOUR_OPERATOR_KEY"
```

3. Tell Claude: *"connect to K7M2-QX9P and find why Steam doesn't start"*.

### Tools

`list_sessions`, `sysinfo`, `screenshot`, `run`, `read_file`, `write_file`, `list_dir`, `click`, `type_text`, `press_key`, `end_session`.
`click` coordinates are in screenshot pixels. Keys use the form `ctrl+c`, `alt+f4`, `win+r`, `enter`.

## Deploy the relay

Needs Docker (or Node 18+) and a TLS certificate for your domain (Let's Encrypt works).

```bash
cp .env.example .env      # set OPERATOR_KEY, PUBLIC_URL, TLS_CERT, TLS_KEY
docker compose up -d --build
```

The relay terminates TLS itself and re-reads the certificate every 12 h, so certbot renewals need no restart. Without `TLS_CERT` it serves plain HTTP: only fine behind your own reverse proxy (then set `PUBLIC_URL`). Without Docker: `cd relay && npm ci && node server.js`.

Test everything end to end: `cd relay && npm test` (starts relay + a real agent + an MCP client).

## Security

See [SECURITY.md](SECURITY.md). Short version: this tool gives whoever holds `OPERATOR_KEY` the same power as the friend has on their PC, for as long as the friend leaves the window open. Only run it for people who asked you to, and only share the one-liner with them.

## License

MIT

---

# HelperMCP (по-русски)

Удалённая помощь друзьям через Claude (или любой MCP-клиент). Друг вставляет **одну строку**, ты говоришь Claude код с его экрана, и Claude смотрит экран, запускает команды, читает файлы и кликает мышью, как будто сидит за его ПК. Устанавливать ничего не нужно.

**У друга**

* Windows 10/11, PowerShell: `[Net.ServicePointManager]::SecurityProtocol=3072; irm https://ТВОЙ_ХОСТ:8444/h | iex`
* Ubuntu/Linux: `python3 <(curl -fsSL https://ТВОЙ_ХОСТ:8444/p)`

Скрипт спросит режим (спрашивать про каждое действие или полный доступ) и покажет код вида `K7M2-QX9P`. Закрыл окно, и доступ исчез.

**У тебя**

1. Подними relay: `cp .env.example .env`, заполни, `docker compose up -d --build`.
2. Один раз подключи к Claude Code: `claude mcp add --transport http helper https://ТВОЙ_ХОСТ:8444/mcp --header "Authorization: Bearer ТВОЙ_OPERATOR_KEY"`
3. Напиши Claude: «подключись к K7M2-QX9P и выясни, почему не запускается Steam».

Безопасность: см. [SECURITY.md](SECURITY.md). `OPERATOR_KEY` держи в секрете, ссылку давай только тем, кто сам попросил о помощи.
