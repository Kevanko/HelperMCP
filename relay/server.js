// HelperMCP relay: agents (on friends' PCs) long-poll here; AI clients talk MCP to /mcp or /s/<code>/mcp.
import http from 'node:http';
import https from 'node:https';
import fs from 'node:fs';
import crypto from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import { ListToolsRequestSchema, CallToolRequestSchema } from '@modelcontextprotocol/sdk/types.js';

globalThis.crypto ??= crypto.webcrypto; // Node 18 has no global crypto, the MCP SDK needs it
const here = path.dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.PORT || 8444);
const PUBLIC_URL = (process.env.PUBLIC_URL || '').replace(/\/$/, '');
const AGENT_DIR = process.env.AGENT_DIR || path.join(here, '..', 'agent');
const SESSION_IDLE_MS = 90_000;
const POLL_MS = 25_000;
const MAX_SESSIONS = 200;
const MAX_PER_IP = 10;

let OPERATOR_KEY = process.env.OPERATOR_KEY;
if (!OPERATOR_KEY) {
  OPERATOR_KEY = crypto.randomBytes(24).toString('hex');
  console.log(`OPERATOR_KEY not set, generated for this run: ${OPERATOR_KEY}`);
}

const sessions = new Map(); // code -> session
const ALPHABET = '23456789ABCDEFGHJKMNPQRSTUVWXYZ';
const newCode = () => {
  const b = crypto.randomBytes(8);
  const s = [...b].map((x) => ALPHABET[x % ALPHABET.length]).join('');
  return `${s.slice(0, 4)}-${s.slice(4)}`;
};
const safeEq = (a, b) => {
  const x = Buffer.from(String(a)), y = Buffer.from(String(b));
  return x.length === y.length && crypto.timingSafeEqual(x, y);
};

// ---- session / command plumbing ------------------------------------------
function call(code, tool, args = {}, timeoutMs = 60_000) {
  const s = sessions.get(String(code).toUpperCase());
  if (!s) return Promise.reject(new Error(`No such session "${code}". Use list_sessions.`));
  // in "ask" mode a human must click through prompts, give them time
  if (s.mode === 'ask') timeoutMs += 120_000;
  const id = crypto.randomUUID();
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      s.pending.delete(id);
      reject(new Error(`Timed out after ${Math.round(timeoutMs / 1000)}s waiting for the agent (user may not have approved).`));
    }, timeoutMs);
    s.pending.set(id, { resolve, reject, timer });
    s.queue.push({ id, tool, args });
    flush(s);
  });
}

function flush(s) {
  if (s.waiting && s.queue.length) {
    const res = s.waiting;
    s.waiting = null;
    clearTimeout(s.waitTimer);
    json(res, 200, s.queue.shift());
  }
}

function drop(code, why) {
  const s = sessions.get(code);
  if (!s) return;
  sessions.delete(code);
  for (const p of s.pending.values()) { clearTimeout(p.timer); p.reject(new Error(why)); }
  if (s.waiting) { clearTimeout(s.waitTimer); json(s.waiting, 410, { error: why }); }
}

setInterval(() => {
  for (const [code, s] of sessions) if (Date.now() - s.lastSeen > SESSION_IDLE_MS) drop(code, 'Agent disconnected.');
}, 10_000).unref();

// ---- MCP tool table -------------------------------------------------------
// agent:true -> forwarded to the agent on the friend's PC; otherwise handled here.
const str = (description) => ({ type: 'string', description });
const num = (description) => ({ type: 'number', description });
const tools = [
  { name: 'list_sessions', description: 'List connected remote machines waiting for help.', props: {}, local: true,
    run: async () => ({
      text: JSON.stringify([...sessions].map(([code, s]) => ({
        code, os: s.info.os, host: s.info.host, user: s.info.user, mode: s.mode,
        connected_s: Math.round((Date.now() - s.created) / 1000),
      })), null, 2),
    }) },
  { name: 'sysinfo', agent: true, description: 'OS, hostname, user, CPU/RAM, screen size, admin status of the remote machine.', props: {} },
  { name: 'screenshot', agent: true, description: 'Screenshot of the remote screen (what the user sees). Click coordinates refer to this image.', props: {} },
  { name: 'run', agent: true, description: 'Run a shell command (PowerShell on Windows, bash on Linux). Returns exit code and combined output.',
    props: { command: str('Command line'), timeout_s: { type: 'integer', minimum: 1, maximum: 600, description: 'default 60' } }, required: ['command'],
    ms: (a) => ((a.timeout_s || 60) + 10) * 1000 },
  { name: 'read_file', agent: true, description: 'Read a text file (first max_bytes, default 200000).',
    props: { path: str('File path'), max_bytes: { type: 'integer', minimum: 1 } }, required: ['path'] },
  { name: 'write_file', agent: true, description: 'Write a text file (UTF-8), overwriting it.',
    props: { path: str('File path'), content: str('New content') }, required: ['path', 'content'] },
  { name: 'list_dir', agent: true, description: 'List a directory (name, type, size, modified).', props: { path: str('Directory path') }, required: ['path'] },
  { name: 'click', agent: true, description: 'Move the mouse to (x,y) in screenshot coordinates and click.',
    props: { x: num('x'), y: num('y'), button: { type: 'string', enum: ['left', 'right', 'middle'] }, double: { type: 'boolean' } }, required: ['x', 'y'] },
  { name: 'type_text', agent: true, description: 'Type text at the current keyboard focus.', props: { text: str('Text') }, required: ['text'] },
  { name: 'press_key', agent: true, description: 'Press a key combo like "enter", "ctrl+c", "alt+f4", "win+r", "ctrl+shift+esc".', props: { keys: str('Key combo') }, required: ['keys'] },
  { name: 'mcp_start', agent: true, ms: () => 300_000,
    description: 'Start another MCP server on the remote PC (e.g. name="browser", command="npx", args=["-y","@playwright/mcp@latest"]). If Node is missing a portable copy is downloaded to a temp dir and removed on exit. Returns its tools; call them with mcp_call (or directly as <name>__<tool> on a /s/<code>/mcp connection).',
    props: { name: str('Short name, e.g. browser'), command: str('Executable, e.g. npx'), args: { type: 'array', items: { type: 'string' } }, env: { type: 'object', additionalProperties: { type: 'string' } } },
    required: ['name', 'command'] },
  { name: 'mcp_tools', agent: true, description: 'List tools of the MCP servers started on the remote PC.', props: {} },
  { name: 'mcp_call', agent: true, ms: () => 120_000, description: 'Call a tool of an MCP server started with mcp_start.',
    props: { server: str('Name given to mcp_start'), tool: str('Tool name'), arguments: { type: 'object' } }, required: ['server', 'tool'] },
  { name: 'mcp_stop', agent: true, description: 'Stop an MCP server started with mcp_start.', props: { name: str('Name') }, required: ['name'] },
  { name: 'end_session', description: 'Disconnect the agent and forget the session.', props: {}, session: true,
    run: async (code) => { await call(code, 'bye').catch(() => {}); drop(code.toUpperCase(), 'Session ended by operator.'); return { text: 'ended' }; } },
];
const byName = new Map(tools.map((t) => [t.name, t]));

const fmt = (d) => {
  if (d?.content) return { content: d.content, isError: !!d.isError }; // passthrough from a child MCP server
  const out = [];
  if (d?.text !== undefined) out.push({ type: 'text', text: String(d.text) });
  if (d?.image) out.push({ type: 'image', data: d.image, mimeType: d.mime || 'image/jpeg' });
  return { content: out.length ? out : [{ type: 'text', text: 'ok' }] };
};

// fixed = session code for /s/<code>/mcp (tools then have no "session" argument and child tools appear as <server>__<tool>)
function buildMcp(fixed) {
  const m = new Server({ name: 'helpermcp', version: '0.2.0' }, { capabilities: { tools: {} } });
  const sessionProp = { session: str("Session code shown on the user's screen, e.g. K7M2-QX9P") };

  m.setRequestHandler(ListToolsRequestSchema, async () => {
    const list = tools
      .filter((t) => !(fixed && t.local))
      .map((t) => {
        const needsSession = (t.agent || t.session) && !fixed;
        return {
          name: t.name, description: t.description,
          inputSchema: {
            type: 'object',
            properties: { ...(needsSession ? sessionProp : {}), ...t.props },
            required: [...(needsSession ? ['session'] : []), ...(t.required || [])],
          },
        };
      });
    if (fixed) {
      try {
        const kids = await call(fixed, 'mcp_tools', {}, 10_000);
        for (const k of JSON.parse(kids.text)) {
          list.push({ name: `${k.server}__${k.name}`, description: `[${k.server}] ${k.description || ''}`, inputSchema: k.inputSchema || { type: 'object' } });
        }
      } catch { /* agent gone or no children: builtin tools only */ }
    }
    return { tools: list };
  });

  m.setRequestHandler(CallToolRequestSchema, async ({ params }) => {
    const { name } = params;
    const a = { ...(params.arguments || {}) };
    try {
      const session = fixed || a.session;
      delete a.session;
      const t = byName.get(name);
      if (!t && fixed && name.includes('__')) { // child MCP tool, called directly
        const i = name.indexOf('__');
        return fmt(await call(session, 'mcp_call', { server: name.slice(0, i), tool: name.slice(i + 2), arguments: a }, 120_000));
      }
      if (!t) throw new Error(`Unknown tool ${name}`);
      if (t.local) return fmt(await t.run());
      if (!session) throw new Error('"session" is required (code shown on the user\'s screen)');
      if (t.run) return fmt(await t.run(session));
      return fmt(await call(session, name, a, t.ms?.(a)));
    } catch (e) {
      return { isError: true, content: [{ type: 'text', text: e.message }] };
    }
  });
  return m;
}

// ---- HTTP -----------------------------------------------------------------
function json(res, code, obj) {
  const b = Buffer.from(JSON.stringify(obj));
  res.writeHead(code, { 'content-type': 'application/json; charset=utf-8', 'content-length': b.length });
  res.end(b);
}
const text = (res, code, s, type = 'text/plain; charset=utf-8') => {
  res.writeHead(code, { 'content-type': type });
  res.end(s);
};
function body(req, limit) {
  return new Promise((resolve, reject) => {
    const chunks = []; let n = 0;
    req.on('data', (c) => { n += c.length; if (n > limit) { reject(new Error('too large')); req.destroy(); } else chunks.push(c); });
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}
const baseUrl = (req) => PUBLIC_URL || `${req.headers['x-forwarded-proto'] || (req.socket.encrypted ? 'https' : 'http')}://${req.headers.host}`;
const clientIp = (req) => req.socket.remoteAddress;

function script(req, res, file) {
  let f;
  try { f = fs.readFileSync(path.join(AGENT_DIR, file), 'utf8'); } catch { return text(res, 404, 'not found'); }
  text(res, 200, f.replaceAll('__RELAY__', baseUrl(req)));
}

function landing(req, res) {
  const b = baseUrl(req);
  const ps = `[Net.ServicePointManager]::SecurityProtocol=3072; irm ${b}/h | iex`;
  const sh = `python3 <(curl -fsSL ${b}/p)`;
  const esc = (s) => s.replace(/&/g, '&amp;').replace(/</g, '&lt;');
  text(res, 200, `<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1"><title>Remote help</title>
<style>body{font:16px system-ui;max-width:42rem;margin:2rem auto;padding:0 1rem}pre{background:#111;color:#eee;padding:.8rem;overflow:auto;border-radius:6px}</style>
<h1>Remote help</h1>
<p>Someone is going to help you with your computer. Run <b>one</b> line, then tell them the code it shows. Close the window to stop at any time.</p>
<h3>Windows 10 / 11</h3><p>Open PowerShell (Start, type "powershell") and paste:</p><pre>${esc(ps)}</pre>
<h3>Ubuntu / Linux</h3><pre>${esc(sh)}</pre>
<p><small>Nothing is installed. The script is <a href="${esc(b)}/h">readable here</a>.</small></p>`, 'text/html; charset=utf-8');
}

const bearer = (req) => (req.headers.authorization || '').replace(/^Bearer /i, '');
const byToken = (req) => {
  const t = bearer(req);
  for (const [code, s] of sessions) if (safeEq(s.token, t)) return [code, s];
  return [];
};

async function handler(req, res) {
  const url = new URL(req.url, 'http://x');
  const p = url.pathname;
  try {
    if (p === '/health') return text(res, 200, 'ok');
    if (p === '/h') return script(req, res, 'agent.ps1');
    if (p === '/p') return script(req, res, 'agent.py');
    if (p === '/') return landing(req, res);

    const mcp = p === '/mcp' ? [null] : p.match(/^\/s\/([A-Za-z0-9-]+)\/mcp$/);
    if (mcp) {
      if (!safeEq(bearer(req), OPERATOR_KEY)) return json(res, 401, { error: 'bad operator key' });
      if (req.method !== 'POST') return json(res, 405, { error: 'POST only' });
      const fixed = mcp[1] ? mcp[1].toUpperCase() : null;
      if (fixed && !sessions.has(fixed)) return json(res, 404, { error: `No such session ${fixed}` });
      const raw = await body(req, 1_000_000);
      const server = buildMcp(fixed);
      const transport = new StreamableHTTPServerTransport({ sessionIdGenerator: undefined, enableJsonResponse: true });
      res.on('close', () => { transport.close(); server.close(); });
      await server.connect(transport);
      return transport.handleRequest(req, res, JSON.parse(raw));
    }

    if (p === '/a/register' && req.method === 'POST') {
      const ip = clientIp(req);
      const mine = [...sessions.values()].filter((s) => s.ip === ip).length;
      if (sessions.size >= MAX_SESSIONS || mine >= MAX_PER_IP) return json(res, 429, { error: 'too many sessions' });
      const info = JSON.parse((await body(req, 10_000)) || '{}');
      let code; do code = newCode(); while (sessions.has(code));
      const s = {
        token: crypto.randomBytes(32).toString('hex'), ip, mode: info.mode === 'ask' ? 'ask' : 'full',
        info: { os: String(info.os || '?').slice(0, 100), host: String(info.host || '?').slice(0, 100), user: String(info.user || '?').slice(0, 100) },
        queue: [], pending: new Map(), waiting: null, waitTimer: null, created: Date.now(), lastSeen: Date.now(),
      };
      sessions.set(code, s);
      console.log(`+ ${code} ${s.info.user}@${s.info.host} (${s.info.os}) ${s.mode} from ${ip}`);
      return json(res, 200, { code, token: s.token });
    }

    if (p.startsWith('/a/')) {
      const [code, s] = byToken(req);
      if (!s) return json(res, 401, { error: 'unknown token' });
      s.lastSeen = Date.now();
      if (p === '/a/poll' && req.method === 'GET') {
        if (s.waiting) json(s.waiting, 204, {}); // superseded poll
        s.waiting = res;
        s.waitTimer = setTimeout(() => { s.waiting = null; res.writeHead(204); res.end(); }, POLL_MS);
        res.on('close', () => { if (s.waiting === res) { s.waiting = null; clearTimeout(s.waitTimer); } });
        return flush(s);
      }
      if (p === '/a/result' && req.method === 'POST') {
        const r = JSON.parse(await body(req, 25_000_000));
        const pend = s.pending.get(r.id);
        if (pend) {
          s.pending.delete(r.id); clearTimeout(pend.timer);
          r.ok ? pend.resolve(r.data) : pend.reject(new Error(r.error || 'agent error'));
        }
        return json(res, 200, {});
      }
      if (p === '/a/bye') { console.log(`- ${code} bye`); drop(code, 'Agent left.'); return json(res, 200, {}); }
    }
    json(res, 404, { error: 'not found' });
  } catch (e) {
    if (!res.headersSent) json(res, 400, { error: e.message });
  }
}

const { TLS_CERT, TLS_KEY } = process.env;
let server;
if (TLS_CERT && TLS_KEY) {
  const load = () => ({ cert: fs.readFileSync(TLS_CERT), key: fs.readFileSync(TLS_KEY) });
  server = https.createServer(load(), handler);
  // certbot renews every ~60 days; pick the new files up without a restart
  setInterval(() => { try { server.setSecureContext(load()); } catch (e) { console.error('cert reload failed:', e.message); } }, 12 * 3600_000).unref();
} else {
  server = http.createServer(handler);
}
server.requestTimeout = 0; // long-poll
server.listen(PORT, process.env.HOST || '0.0.0.0', () =>
  console.log(`HelperMCP relay on ${TLS_CERT ? 'https' : 'http'}://0.0.0.0:${PORT}`));
