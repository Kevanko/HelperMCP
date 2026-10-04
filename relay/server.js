// HelperMCP relay: agents (on friends' PCs) long-poll here; Claude talks to /mcp.
import http from 'node:http';
import https from 'node:https';
import fs from 'node:fs';
import crypto from 'node:crypto';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { McpServer } from '@modelcontextprotocol/sdk/server/mcp.js';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import { z } from 'zod';

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
  const s = sessions.get(code.toUpperCase());
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

// ---- MCP ------------------------------------------------------------------
const sess = z.string().describe('Session code shown on the user\'s screen, e.g. K7M2-QX9P');
const fmt = (d) => {
  const out = [];
  if (d?.text !== undefined) out.push({ type: 'text', text: String(d.text) });
  if (d?.image) out.push({ type: 'image', data: d.image, mimeType: d.mime || 'image/jpeg' });
  return { content: out.length ? out : [{ type: 'text', text: 'ok' }] };
};

function buildMcp() {
  const m = new McpServer({ name: 'helpermcp', version: '0.1.0' });
  const tool = (name, description, shape, fn) =>
    m.registerTool(name, { description, inputSchema: shape }, async (a) => {
      try { return fmt(await fn(a)); }
      catch (e) { return { isError: true, content: [{ type: 'text', text: e.message }] }; }
    });
  const agent = (name, argsOf = (a) => a, ms) => async (a) => {
    const { session, ...rest } = a;
    return call(session, name, argsOf(rest), ms?.(rest));
  };

  tool('list_sessions', 'List connected remote machines waiting for help.', {}, async () => ({
    text: JSON.stringify([...sessions].map(([code, s]) => ({
      code, os: s.info.os, host: s.info.host, user: s.info.user, mode: s.mode,
      connected_s: Math.round((Date.now() - s.created) / 1000),
    })), null, 2),
  }));
  tool('sysinfo', 'OS, hostname, user, CPU/RAM, screen size, admin status of the remote machine.', { session: sess }, agent('sysinfo'));
  tool('screenshot', 'Screenshot of the remote screen (what the user sees). Click coordinates refer to this image.', { session: sess }, agent('screenshot'));
  tool('run', 'Run a shell command (PowerShell on Windows, bash on Linux). Returns exit code and combined output.', {
    session: sess, command: z.string(), timeout_s: z.number().int().min(1).max(600).default(60).optional(),
  }, agent('run', (a) => a, (a) => ((a.timeout_s || 60) + 10) * 1000));
  tool('read_file', 'Read a text file (first max_bytes, default 200000).', {
    session: sess, path: z.string(), max_bytes: z.number().int().positive().optional(),
  }, agent('read_file'));
  tool('write_file', 'Write a text file (UTF-8), overwriting it.', { session: sess, path: z.string(), content: z.string() }, agent('write_file'));
  tool('list_dir', 'List a directory (name, type, size, modified).', { session: sess, path: z.string() }, agent('list_dir'));
  tool('click', 'Move the mouse to (x,y) in screenshot coordinates and click.', {
    session: sess, x: z.number(), y: z.number(),
    button: z.enum(['left', 'right', 'middle']).default('left').optional(), double: z.boolean().optional(),
  }, agent('click'));
  tool('type_text', 'Type text at the current keyboard focus.', { session: sess, text: z.string() }, agent('type_text'));
  tool('press_key', 'Press a key combo like "enter", "ctrl+c", "alt+f4", "win+r", "ctrl+shift+esc".', { session: sess, keys: z.string() }, agent('press_key'));
  tool('end_session', 'Disconnect the agent and forget the session.', { session: sess }, async ({ session }) => {
    await call(session, 'bye').catch(() => {});
    drop(session.toUpperCase(), 'Session ended by operator.');
    return { text: 'ended' };
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
    if (p === '/') {
      const b = baseUrl(req);
      return text(res, 200, `HelperMCP relay\n\nWindows (PowerShell):\n  [Net.ServicePointManager]::SecurityProtocol=3072; irm ${b}/h | iex\nLinux:\n  python3 <(curl -fsSL ${b}/p)\n`);
    }

    if (p === '/mcp') {
      if (!safeEq(bearer(req), OPERATOR_KEY)) return json(res, 401, { error: 'bad operator key' });
      if (req.method !== 'POST') return json(res, 405, { error: 'POST only' });
      const raw = await body(req, 1_000_000);
      const server = buildMcp();
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
