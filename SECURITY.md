# Security

HelperMCP is a remote-control tool. Treat it like one.

## Model

* **Friend (agent side)** explicitly runs the one-liner, picks a mode, and can stop at any time by closing the window or pressing Ctrl+C. In *ask* mode every command, program start, file write, file copy, click, keystroke and MCP-server start/call needs a typed `y`. Every action is echoed in their console, and a glowing edge + "Remote control" label is shown on every screen while a helper is connected.
* **Operator** authenticates to `/mcp` with `OPERATOR_KEY` (constant-time compared; after 20 wrong keys an IP is locked out for 10 minutes). Anyone with the key can act on every connected agent: keep it secret and rotate it by changing the env var.
* **Agents** authenticate with a random 256-bit token issued at registration; the relay stores only its SHA-256 (`data/state.json`, mode 0600). The short session code is only a label for the operator and grants nothing by itself.
* **Links** (live viewer `/v/<token>`, file downloads `/f/<id>/<name>`) are unguessable (144 / 96 bits), tied to one session or one file, and expire (viewer 12 h, files 24 h). They do not reveal the operator key. Anyone who has such a link can use it, so share it only with people who may see that screen or file.
* Agent sessions are dropped after 5 minutes without a poll (not while a call is running); the agent then registers again. At most 10 sessions per IP and 200 in total.
* After the server lost its state the agent re-registers and asks for its old session code; the server hands it out if it is free. Codes are labels and never grant access (that takes the operator key), but anyone who knows a code and registers first could receive the commands meant for that PC: treat codes as private until the session ends.
* The agent only makes outbound requests; the relay never connects into the friend's network.

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
