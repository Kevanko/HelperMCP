# Security

HelperMCP is a remote-control tool. Treat it like one.

## Model

* **Friend (agent side)** explicitly runs the one-liner, picks a mode, and can stop at any time by closing the window or pressing Ctrl+C. In *ask* mode every command, write, click and keystroke needs a typed `y`. Every action is echoed in their console.
* **Operator** authenticates to `/mcp` with `OPERATOR_KEY` (constant-time compared). Anyone with the key can act on every connected agent: keep it secret and rotate it by changing the env var.
* **Agents** authenticate with a random 256-bit token issued at registration. The short session code is only a label for the operator and grants nothing by itself.
* Agent sessions are dropped after 90 s without a poll. At most 10 sessions per IP and 200 in total.
* The agent only makes outbound requests; the relay never connects into the friend's network.

## Known limits

* **Child MCP servers (`mcp_start`) can do anything their tools allow** (a browser with the friend's logins, a filesystem server, …). In ask mode starting one and every call to it needs approval, in full mode nothing does. Starting one may also download a portable Node.js from nodejs.org into a temp folder.

* **Serve the relay over HTTPS.** Over plain HTTP the traffic (screenshots, file contents) is readable on the network.
* The one-liner executes code fetched from your relay: whoever controls the relay controls the agent script. Host it yourself and protect the server.
* *Read-only* tools (screenshot, file read, directory listing) are not confirmed in ask mode. A friend who is not comfortable with that should not run the agent.
* Output sizes are capped (100 KB commands, 25 MB payloads), but there is no per-operator rate limiting.

## Reporting

Open a private security advisory on the GitHub repository, or email the maintainer. Please don't file public issues for vulnerabilities.
