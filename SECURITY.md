# Security

HelperMCP is a remote-control tool. Treat it like one.

## Model

* **Friend (agent side)** explicitly runs the one-liner, picks a mode, and can stop at any time by closing the window or pressing Ctrl+C. In *ask* mode every command, program start, file write, file copy, click, keystroke and MCP-server start/call needs a typed `y`. Every action is echoed in their console, and a glowing edge + "Remote control" label is shown on every screen while a helper is connected.
* **Operator** authenticates to `/mcp` with `OPERATOR_KEY` (constant-time compared; after 20 wrong keys an IP is locked out for 10 minutes). Anyone with the key can act on every connected agent: keep it secret and rotate it by changing the env var.
* **Agents** authenticate with a random 256-bit token issued at registration; the relay stores only its SHA-256 (`data/state.json`, mode 0600). The short session code is only a label for the operator and grants nothing by itself.
* **Links** (live viewer `/v/<token>`, file downloads `/f/<id>/<name>`) are unguessable (144 / 96 bits), tied to one session or one file, and expire (viewer 12 h, files 24 h). They do not reveal the operator key. Anyone who has such a link can use it, so share it only with people who may see that screen or file.
* A plain session is dropped after 5 minutes without a poll (not while a call is running). A session the friend chose to **keep** (asked once when the helper starts) survives internet loss, VPN changes and reboots for up to 7 days: it stays listed as offline, the helper resumes it with the same code after the PC is back, and it ends only when the friend confirms the end in the Esc menu (or the operator ends it). Resuming needs the session's secret token (stored encrypted for the Windows user via DPAPI, `0600` on Linux), not just the code. At most 10 sessions per IP and 200 in total.
* After the server lost its state the agent re-registers and asks for its old session code; the server hands it out if it is free. Codes are labels and never grant access (that takes the operator key), but anyone who knows a code and registers first could receive the commands meant for that PC: treat codes as private until the session ends.
* The agent only makes outbound requests; the relay never connects into the friend's network.

## Isolation and data handling

* **What a client PC can reach on the server:** only its own session through `/a/*`, with its own random 256-bit token (stored hashed). The agent script carries no secret (just the relay's public address); it cannot call `/mcp` (needs the operator key), cannot see other sessions, viewer links or files, and registering is rate limited (20 per minute and 10 live sessions per IP, 200 in total). Public routes are only the landing page, the scripts, the cursor pack and the Android app.
* **Encryption in transit:** everything runs over HTTPS (TLS, certificates checked by the agents). The relay sees the traffic in memory while it forwards it; there is no end-to-end encryption between the PC and the AI client.
* **Nothing outlives the session:** logs, queues, the last viewer frame and viewer links are dropped the moment a session ends (Esc, closed window, `end_session`, or 5 minutes without a poll). Files copied with `fetch_file` are deleted with their session (and in any case after 24 h). The relay's `files/` folder is emptied at every start.
* **Encryption at rest:** each fetched file is stored AES-256-GCM encrypted with a random key that exists only in the relay's memory (after a restart the files are unreadable and deleted). `state.json` (live sessions, so that a relay restart does not drop them) is AES-256-GCM encrypted with a key derived from `OPERATOR_KEY` and holds no screen content, file content or commands.
* **On the friend's PC / phone:** nothing is installed. The script runs from memory, temporary files (cursor pack, overlay script, sounds) are removed on exit, the session code is removed from the clipboard when the session ends, and the system cursors / cursor theme are put back.
* **Container:** the relay runs with a read-only root filesystem, no Linux capabilities, `no-new-privileges`, and memory / process limits (`docker-compose.yml`). Responses carry `nosniff`, `no-referrer`, HSTS and a strict Content-Security-Policy.

## Staying connected

* **Esc is a menu, not an exit:** pause / continue / end. Ending asks for a second confirmation. While paused every action is refused with a clear message and the session stays.
* **Local state** (kept only when the friend chose to keep the session): `session.json` (encrypted token), the autostart entry (Windows: HKCU Run, Linux: ~/.config/autostart) and `agent.log` in `%APPDATA%\HelperMCP` / `~/.local/state/helpermcp`. All of it is removed when the session is ended.
* **Network outage diagnosis:** after ~4 s without the relay the agent records adapters, route, gateway, internet, DNS and TCP to the relay and classifies the cause; after ~10 s it makes **one** repair attempt (flush DNS; restart the active adapter if it has the rights; it never touches a VPN) and writes everything to `agent.log`. When the link is back the report goes to the relay (`session_log`, `agent_log` for the operator).

## What a connected AI can do

Everything the friend's user account can: run commands and start programs, read/write files, copy files out (`fetch_file` uploads them to the relay for 24 h), see the screen, use mouse and keyboard, start MCP servers. Installing software that needs administrator rights still needs the friend to accept the UAC prompt. In *full* mode nothing is confirmed; use *ask* mode for people you do not fully trust.

## Known limits

* **Child MCP servers (`mcp_start`) can do anything their tools allow** (a browser with the friend's logins, a filesystem server, Blender scripts, …). In ask mode starting one and every call to it needs approval, in full mode nothing does.
* **Portable runtimes are downloaded on demand** into a temp folder and deleted on exit: Node.js from nodejs.org, uv from github.com/astral-sh, and packages through `npx`/`uvx` from npm/PyPI. This trusts those sources.
* **Serve the relay over HTTPS.** Over plain HTTP the traffic (screenshots, file contents, files in transit) is readable on the network.
* The one-liner executes code fetched from your relay: whoever controls the relay controls the agent script. Host it yourself and protect the server and `data/`.
* *Read-only* tools (screenshot, file read, directory listing) are not confirmed in ask mode. A friend who is not comfortable with that should not run the agent.
* Output sizes are capped (100 KB commands, 25 MB payloads, 1 GB per fetched file); there is no per-operator rate limiting beyond the wrong-key lockout.

## Reporting

Open a private security advisory on the GitHub repository, or email the maintainer. Please don't file public issues for vulnerabilities.
