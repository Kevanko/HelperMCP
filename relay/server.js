// HelperMCP relay: agents (on friends' PCs) long-poll here; AI clients talk MCP to /mcp or /s/<code>/mcp.
import http from 'node:http';
import https from 'node:https';
import fs from 'node:fs';
import crypto from 'node:crypto';
import QRCode from 'qrcode';
import zlib from 'node:zlib';
import os from 'node:os';
import { pipeline } from 'node:stream/promises';
import { Transform } from 'node:stream';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Server } from '@modelcontextprotocol/sdk/server/index.js';
import { StreamableHTTPServerTransport } from '@modelcontextprotocol/sdk/server/streamableHttp.js';
import { ListToolsRequestSchema, CallToolRequestSchema } from '@modelcontextprotocol/sdk/types.js';

globalThis.crypto ??= crypto.webcrypto; // Node 18 has no global crypto, the MCP SDK needs it
const here = path.dirname(fileURLToPath(import.meta.url));
const PORT = Number(process.env.PORT || 8444);
const PUBLIC_URL = (process.env.PUBLIC_URL || '').replace(/\/$/, '');
const RECIPES_DIR = process.env.RECIPES_DIR || path.join(here, '..', 'recipes');
const AGENT_DIR = process.env.AGENT_DIR || path.join(here, '..', 'agent');
const SESSION_IDLE_MS = Number(process.env.IDLE_MS || 300_000);
const ONLINE_MS = 30_000;   // an agent that has not polled for this long is shown as offline (it polls every <= 15 s)
const POLL_MS = 15_000;   // agents time out a poll after ~22 s, so a silently dead connection (VPN switch, firewall) is noticed quickly
const MAX_SESSIONS = 200;
const MAX_PER_IP = 10;

let OPERATOR_KEY = process.env.OPERATOR_KEY;
if (!OPERATOR_KEY) {
  OPERATOR_KEY = crypto.randomBytes(24).toString('hex');
  console.log(`OPERATOR_KEY not set, generated for this run: ${OPERATOR_KEY}`);
}

const sessions = new Map(); // code -> session
const STATE_FILE = process.env.STATE_FILE || '';   // e.g. /data/state.json; empty = keep everything in memory only
const sha = (x) => crypto.createHash('sha256').update(String(x)).digest('hex');   // agent tokens are stored hashed
// the state file is encrypted (AES-256-GCM, key derived from OPERATOR_KEY): a copy of data/ alone reveals nothing, and it only holds live sessions
const STATE_KEY = crypto.scryptSync(String(process.env.OPERATOR_KEY || ''), 'helpermcp-state-v1', 32);
const seal = (txt) => { const iv = crypto.randomBytes(12), c = crypto.createCipheriv('aes-256-gcm', STATE_KEY, iv); const ct = Buffer.concat([c.update(txt, 'utf8'), c.final()]); return Buffer.concat([Buffer.from('HM1'), iv, c.getAuthTag(), ct]); };
const unseal = (buf) => {
  if (buf.subarray(0, 3).toString() !== 'HM1') return buf.toString('utf8');   // an old plain state file: read once, saved encrypted from then on
  const d = crypto.createDecipheriv('aes-256-gcm', STATE_KEY, buf.subarray(3, 15)); d.setAuthTag(buf.subarray(15, 31));
  return Buffer.concat([d.update(buf.subarray(31)), d.final()]).toString('utf8');
};
let saveTimer = null;
function save() {
  if (!STATE_FILE || saveTimer) return;
  saveTimer = setTimeout(() => {
    saveTimer = null;
    try {
      const out = {
        sessions: [...sessions].map(([code, s]) => ({ code, th: s.th, ip: s.ip, mode: s.mode, info: s.info, created: s.created })),
        viewers: [...viewers].map(([token, v]) => ({ token, code: v.code, exp: v.exp })),
      };
      fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });
      fs.writeFileSync(STATE_FILE + '.tmp', seal(JSON.stringify(out)), { mode: 0o600 });
      fs.renameSync(STATE_FILE + '.tmp', STATE_FILE);
    } catch (e) { console.error('state save failed:', e.message); }
  }, 300);
}
const newSession = (o) => ({ ...o, queue: [], pending: new Map(), waiting: null, waitTimer: null, lastSeen: Date.now(), log: [] });
const viewers = new Map();  // unguessable token -> { code, exp }: lets the operator watch a screen in a browser without exposing OPERATOR_KEY
let lastBase = PUBLIC_URL;  // public URL as seen by the last MCP request (used to build viewer links)
const VIEWER_TTL_MS = 12 * 3600_000;
// files copied from a remote PC to the operator: unguessable link, kept 24 h
const CURSOR_DIR = process.env.CURSOR_DIR || (STATE_FILE ? path.join(path.dirname(STATE_FILE), 'cursor') : path.join(__dirname, 'cursor'));
const APK_FILE = process.env.APK_FILE || (STATE_FILE ? path.join(path.dirname(STATE_FILE), 'apk', 'helpermcp.apk') : path.join(here, '..', 'android', 'helpermcp.apk'));   // the Android app, built from android/ (see README)
const FILES_DIR = process.env.FILES_DIR || (STATE_FILE ? path.join(path.dirname(STATE_FILE), 'files') : path.join(os.tmpdir(), 'helpermcp-files'));
const MAX_FILE = Number(process.env.MAX_FILE_MB || 1024) * 1024 * 1024;
const FILE_TTL_MS = 24 * 3600_000;
const files = new Map();   // id -> { path, name, size, exp, code, key, iv, tag }: encrypted on disk with a key that lives only in memory, deleted with the session
try { fs.rmSync(FILES_DIR, { recursive: true, force: true }); fs.mkdirSync(FILES_DIR, { recursive: true }); } catch { /* best effort */ }
const regRate = new Map();               // ip -> { n, t }: registrations per minute
const authFails = new Map();             // ip -> { n, until }: wrong operator keys
const AUTH_MAX_FAILS = 20, AUTH_WINDOW_MS = 10 * 60_000;
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
  if (!s) return Promise.reject(new Error(`No such session "${code}" (it was never there, or the user closed the helper / pressed Esc). If you were working on it: STOP, do not retry, tell the operator. Use list_sessions.`));
  if (Date.now() - s.lastSeen > ONLINE_MS && !s.pending.size && tool !== 'bye') {
    return Promise.reject(new Error(`The remote PC is offline (last seen ${Math.round((Date.now() - s.lastSeen) / 1000)} s ago: internet/VPN change or sleep). The agent reconnects by itself; try again in a few seconds. list_sessions shows "online".`));
  }
  // in "ask" mode a human must click through prompts, give them time
  if (s.mode === 'ask') timeoutMs += 120_000;
  if (tool === 'screenshot' && !args.view && s.lite) args = { max_width: 1280, quality: 50, ...args };   // slow link: smaller by default
  if (!args.view) { // live-viewer frames are not "actions"
    const a = JSON.stringify(args, (k, v) => (typeof v === 'string' && v.length > 80 ? v.slice(0, 80) + '…' : v));
    s.log.push({ t: Date.now(), tool, args: a === '{}' ? '' : a.slice(0, 160) });
    if (s.log.length > 60) s.log.shift();
  }
  const id = crypto.randomUUID();
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      s.pending.delete(id);
      reject(new Error(`Timed out after ${Math.round(timeoutMs / 1000)}s waiting for the agent (user may not have approved).`));
    }, timeoutMs);
    s.pending.set(id, { resolve, reject, timer, t0: Date.now() - (args.view ? FAKE_LATENCY_MS : 0), tool, view: !!args.view });
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
  sessions.delete(code); s.log.length = 0; s.queue.length = 0;
  for (const [id, f] of files) if (f.code === code) { files.delete(id); fs.rm(f.path, { force: true }, () => {}); }   // files fetched in this session die with it
  for (const [t, v] of viewers) if (v.code === code) { v.last = null; viewers.delete(t); }                          // so do viewer links and their last frame
  save();
  for (const p of s.pending.values()) { clearTimeout(p.timer); p.reject(new Error(why)); }
  if (s.waiting) { clearTimeout(s.waitTimer); json(s.waiting, 410, { error: why }); }
}

setInterval(() => {
  for (const [t, v] of viewers) if (v.exp < Date.now()) viewers.delete(t);
  for (const [id, f] of files) if (f.exp < Date.now()) { files.delete(id); fs.rm(f.path, { force: true }, () => {}); }
  for (const [ip, f] of authFails) if (Date.now() >= f.until) authFails.delete(ip);
  for (const [ip, r] of regRate) if (Date.now() - r.t > 60_000) regRate.delete(ip);
  // an agent busy with a long call (browser, slow command) doesn't poll; its pending calls have their own timeouts
  for (const [code, s] of sessions) if (!s.pending.size && Date.now() - s.lastSeen > SESSION_IDLE_MS) drop(code, 'Agent disconnected.');
}, 10_000).unref();

// ---- adapting to the network: viewer frames step through quality levels, "lite" mode shrinks the AI's screenshots on slow links
const FAKE_LATENCY_MS = Number(process.env.TEST_FAKE_LATENCY_MS || 0);   // tests only: pretend viewer frames are slow
const LEVELS = [{ max_width: 480, quality: 35 }, { max_width: 640, quality: 45 }, { max_width: 800, quality: 50 }, { max_width: 960, quality: 55 }, { max_width: 1280, quality: 65 }];
const viewParams = (s) => LEVELS[s.vl ?? 3];
function adapt(s, pend, bytes) {
  const dur = Date.now() - pend.t0;
  if (pend.view) {                                   // aim for a frame about every second
    s.vl = s.vl ?? 3;
    if (dur > 1800 && s.vl > 0) { s.vl--; s.fast = 0; }
    else if (dur < 700 && bytes && ++s.fast >= 3 && s.vl < LEVELS.length - 1) { s.vl++; s.fast = 0; }
    else if (dur >= 700) s.fast = 0;
  } else if (pend.tool === 'screenshot' && bytes) {
    s.lite = bytes / Math.max(dur, 1) < 60 && dur > 3000 ? true : (dur < 1500 ? false : s.lite);   // < ~60 KB/s and slow => lite
  }
}

// ---- background jobs: MCP clients time out after ~60 s, remote work (installs, renders, first start of an MCP server) can take minutes
const jobs = new Map();
const SYNC_MS = Number(process.env.JOB_SYNC_MS || 45_000);
async function settle(id, j, ms) {
  let timer;
  const r = await Promise.race([j.p.then(() => 'done'), new Promise((res) => { timer = setTimeout(() => res('pending'), ms); })]);
  clearTimeout(timer);
  if (r === 'done') { jobs.delete(id); if (j.error) throw j.error; return j.result; }
  return { text: `Still running after ${Math.round((Date.now() - j.started) / 1000)} s (job ${id}, ${j.tool}). The work continues on the remote PC: call wait_job {"job":"${id}"} to get the result.` };
}
async function callJob(session, tool, args, ms) {
  const id = crypto.randomBytes(4).toString('hex');
  const j = { started: Date.now(), tool };
  j.p = call(session, tool, args, ms).then((r) => { j.result = r; }, (e) => { j.error = e; });
  jobs.set(id, j);
  return settle(id, j, SYNC_MS);
}
async function waitJob(id, ms) {
  const j = jobs.get(id);
  if (!j) throw new Error(`Unknown or already delivered job "${id}".`);
  return settle(id, j, ms);
}
setInterval(() => { for (const [id, j] of jobs) if (Date.now() - j.started > 3600_000) jobs.delete(id); }, 60_000).unref();

// ---- MCP tool table -------------------------------------------------------
// agent:true -> forwarded to the agent on the friend's PC; otherwise handled here.
const str = (description) => ({ type: 'string', description });
const num = (description) => ({ type: 'number', description });
const tools = [
  { name: 'list_sessions', description: 'List connected remote machines waiting for help.', props: {}, local: true,
    run: async () => ({
      text: JSON.stringify([...sessions].map(([code, s]) => ({
        code, os: s.info.os, host: s.info.host, user: s.info.user, mode: s.mode,
        online: Date.now() - s.lastSeen <= ONLINE_MS, last_seen_s: Math.round((Date.now() - s.lastSeen) / 1000),
        connected_s: Math.round((Date.now() - s.created) / 1000),
      })), null, 2),
    }) },
  { name: 'sysinfo', agent: true, description: 'OS, hostname, user, CPU/RAM, screen size, admin status of the remote machine.', props: {} },
  { name: 'screenshot', agent: true, description: 'Screenshot of the remote screen (what the user sees): all monitors side by side, or a single one with "monitor" (0-based, see sysinfo). Click/scroll coordinates refer to the last screenshot.',
    props: { monitor: { type: 'integer', minimum: 0, description: 'omit for all monitors' },
      max_width: { type: 'integer', minimum: 320, maximum: 3840, description: 'downscale to this width (default 1920; use less on slow links)' },
      quality: { type: 'integer', minimum: 10, maximum: 95, description: 'JPEG quality (default 70)' } } },
  { name: 'run', agent: true, description: 'Run a shell command (PowerShell on Windows, bash on Linux) and wait for it. Returns exit code and combined output. Portable node/uv fetched by this bridge are on PATH. For GUI apps or anything long-lived use start_process instead.',
    props: { command: str('Command line'), timeout_s: { type: 'integer', minimum: 1, maximum: 3600, description: 'default 60' }, cwd: str('working directory') }, required: ['command'],
    ms: (a) => ((a.timeout_s || 60) + 10) * 1000 },
  { name: 'start_process', agent: true, description: 'Start a program detached and return immediately; it keeps running (use this for GUI apps such as Blender, Unity, Substance, or servers). Returns pid, whether it is still running, and the first output.',
    props: { command: str('Executable name or full path'), args: { type: 'array', items: { type: 'string' } }, cwd: str('working directory'), env: { type: 'object', additionalProperties: { type: 'string' } }, wait_s: { type: 'number', description: 'seconds to watch for an immediate crash, default 2' } }, required: ['command'] },
  { name: 'read_file', agent: true, description: 'Read a text file (first max_bytes, default 200000). Image files (png, jpg, gif, bmp, webp) come back as images, scaled down to max_width: use it to look at renders and saved screenshots.',
    props: { path: str('File path'), max_bytes: { type: 'integer', minimum: 1 }, max_width: { type: 'integer', minimum: 64, maximum: 4096, description: 'images only, default 1600' } }, required: ['path'] },
  { name: 'fetch_file', agent: true, ms: (a) => 3_700_000,
    description: 'Copy a file from the remote PC to the operator: returns a download link (valid 24 h). Use it to hand over results (renders, .blend files, logs, archives).',
    props: { path: str('File path on the remote PC') }, required: ['path'] },
  { name: 'write_file', agent: true, description: 'Write a text file (UTF-8), overwriting it.',
    props: { path: str('File path'), content: str('New content') }, required: ['path', 'content'] },
  { name: 'list_dir', agent: true, description: 'List a directory (name, type, size, modified).', props: { path: str('Directory path') }, required: ['path'] },
  { name: 'click', agent: true, description: 'Move the mouse to (x,y) in screenshot coordinates and click.',
    props: { x: num('x'), y: num('y'), button: { type: 'string', enum: ['left', 'right', 'middle'] }, double: { type: 'boolean' } }, required: ['x', 'y'] },
  { name: 'move', agent: true, description: 'Glide the mouse pointer to (x,y) in screenshot coordinates without clicking (hover, open menus that open on hover).',
    props: { x: num('x'), y: num('y') }, required: ['x', 'y'] },
  { name: 'drag', agent: true, description: 'Drag with the mouse: press at (x,y), glide to (x2,y2) with the button held, release. Coordinates are screenshot pixels.',
    props: { x: num('x'), y: num('y'), x2: num('x2'), y2: num('y2'), button: { type: 'string', enum: ['left', 'right', 'middle'] }, hold: { type: 'boolean', description: 'Android: long-press first, then move (drag and drop of icons / list items); without it the drag is a swipe' } }, required: ['x', 'y', 'x2', 'y2'] },
  { name: 'scroll', agent: true, description: 'Scroll the mouse wheel (positive amount = down, negative = up), optionally at (x,y) in screenshot coordinates.',
    props: { amount: { type: 'integer', description: 'wheel notches, default 3' }, x: num('x'), y: num('y') } },
  { name: 'type_text', agent: true, description: 'Type text at the current keyboard focus.', props: { text: str('Text') }, required: ['text'] },
  { name: 'press_key', agent: true, description: 'Press a key combo like "enter", "ctrl+c", "alt+f4", "win+r", "ctrl+shift+esc".', props: { keys: str('Key combo') }, required: ['keys'] },
  { name: 'actions', agent: true, ms: (a) => 30000 + (a.steps || []).length * 20000,
    description: 'A short sequence of small GUI steps done as ONE action the friend confirms once (move + click, click + type, drag, scroll, key presses). Prefer this over separate click / move / type_text calls. Coordinates are screenshot pixels. Stops at the first failing step.',
    props: { steps: { type: 'array', minItems: 1, maxItems: 20, items: { type: 'object', properties: {
      do: { type: 'string', enum: ['move', 'click', 'drag', 'scroll', 'type', 'key', 'wait'], description: 'move | click | drag | scroll | type (text) | key (keys) | wait (ms)' },
      x: num('x'), y: num('y'), x2: num('x2'), y2: num('y2'), button: { type: 'string', enum: ['left', 'right', 'middle'] }, double: { type: 'boolean' }, hold: { type: 'boolean' },
      amount: { type: 'integer' }, text: str('text to type'), keys: str('key combo'), ms: { type: 'integer', description: 'wait milliseconds, up to 5000' } }, required: ['do'] } } },
    required: ['steps'] },
  { name: 'mcp_start', agent: true, ms: (a) => ((a.timeout_s || 240) + 30) * 1000,
    description: 'Start another MCP server on the remote PC and use it through this bridge (any stdio MCP server: browser, Blender via uvx blender-mcp, filesystem, ...). Browser: name="browser", command="playwright" opens a real, visible Chrome/Edge window on the user\'s screen with sound on. Any other server: command="npx", args=["-y","<package>"] (or uvx, python, an exe). If Node >= 20 is missing a portable copy is downloaded to a temp dir and removed on exit. Returns its tools; call them with mcp_call (or directly as <name>__<tool> on a /s/<code>/mcp connection).',
    props: { name: str('Short name, e.g. browser'), command: str('Executable, e.g. npx'), args: { type: 'array', items: { type: 'string' } }, env: { type: 'object', additionalProperties: { type: 'string' } }, cwd: str('working directory'), timeout_s: { type: 'integer', minimum: 10, maximum: 1800, description: 'time allowed for the server to start (first start may download packages), default 240' } },
    required: ['name', 'command'] },
  { name: 'mcp_tools', agent: true, description: 'List tools of the MCP servers started on the remote PC.', props: {} },
  { name: 'mcp_call', agent: true, ms: (a) => ((a.timeout_s || 110) + 15) * 1000, description: 'Call a tool of an MCP server started with mcp_start.',
    props: { server: str('Name given to mcp_start'), tool: str('Tool name'), arguments: { type: 'object' }, timeout_s: { type: 'integer', minimum: 5, maximum: 3600, description: 'default 110; raise it for renders, imports, long generations' } }, required: ['server', 'tool'] },
  { name: 'recipe', always: true, local: true,
    description: 'Verified step-by-step instructions for setting up and driving an application on the remote PC (check/install the app, its MCP add-on, start it, start its MCP server). Call without a name to list them: e.g. "blender"; "any-app" is the generic pattern for any app that has an MCP server (Unity, Substance, ...).',
    props: { name: str('recipe name; omit to list') },
    run: async (a) => {
      const files = fs.existsSync(RECIPES_DIR) ? fs.readdirSync(RECIPES_DIR).filter((f) => f.endsWith('.md')).map((f) => f.slice(0, -3)) : [];
      if (!a.name) return { text: 'Recipes: ' + files.join(', ') };
      if (!/^[a-z0-9_-]+$/.test(a.name) || !files.includes(a.name)) throw new Error(`No recipe "${a.name}". Available: ${files.join(', ')}`);
      return { text: fs.readFileSync(path.join(RECIPES_DIR, a.name + '.md'), 'utf8') };
    } },
  { name: 'wait_job', always: true, local: true,
    description: 'Long operations return "still running (job X)" after about 45 s so the call does not time out. Call this with that job id to wait for the result; the work keeps going on the remote PC meanwhile.',
    props: { job: str('Job id from the "still running" message'), wait_s: { type: 'integer', minimum: 1, maximum: 55, description: 'default 40' } }, required: ['job'],
    run: async (a) => waitJob(a.job, (a.wait_s || 40) * 1000) },
  { name: 'mcp_stop', agent: true, description: 'Stop an MCP server started with mcp_start.', props: { name: str('Name') }, required: ['name'] },
  { name: 'open_viewer', session: true, props: {},
    description: 'Get a link to a live view of the remote screen (updates about once a second, plus a log of what the AI is doing). Open it in a browser so the operator can watch; on the operator\'s PC e.g. `start <url>` (Windows), `xdg-open <url>` (Linux), `open <url>` (macOS).',
    run: async (code) => {
      const c = code.toUpperCase();
      if (!sessions.has(c)) throw new Error(`No such session "${code}" (it was never there, or the user closed the helper / pressed Esc). If you were working on it: STOP, do not retry, tell the operator. Use list_sessions.`);
      const token = crypto.randomBytes(18).toString('hex');
      viewers.set(token, { code: c, exp: Date.now() + VIEWER_TTL_MS }); save();
      return { text: `${lastBase}/v/${token}` };
    } },
  { name: 'end_session', description: 'Disconnect the agent and forget the session.', props: {}, session: true,
    run: async (code) => { await call(code, 'bye').catch(() => {}); drop(code.toUpperCase(), 'Session ended by operator.'); return { text: 'ended' }; } },
];
const byName = new Map(tools.map((t) => [t.name, t]));

const fmt = (d) => {
  if (d?.content) return { content: d.content, isError: !!d.isError }; // passthrough from a child MCP server
  const out = [];
  if (d?.text !== undefined) out.push({ type: 'text', text: String(d.text) });
  if (d?.jpeg) out.push({ type: 'image', data: d.jpeg.toString('base64'), mimeType: d.mime || 'image/jpeg' });
  if (d?.same) out.push({ type: 'text', text: 'screen unchanged' });
  return { content: out.length ? out : [{ type: 'text', text: 'ok' }] };
};

// fixed = session code for /s/<code>/mcp (tools then have no "session" argument and child tools appear as <server>__<tool>)
const INSTRUCTIONS = `You are connected to a REMOTE computer (a friend's PC or server) through HelperMCP. Work on it as if it were your own machine.
Workflow for any task:
1. Look first: sysinfo, then screenshot (what the user sees). Use open_viewer so the operator can watch live.
2. Need an application or MCP server (Blender, Unity, Substance, a browser, ...)? First call recipe (no name = list; "blender" and the generic "any-app" exist). Check whether it is installed (run: Get-Command / where / which / winget list / registry / apt), install it if missing (winget install -e --id ..., apt/flatpak; an installer that needs administrator rights shows a UAC prompt the user must accept: tell them), then continue.
3. GUI apps and anything long-lived: start_process (detached, keeps running). Do not use run for them.
4. MCP servers: mcp_start (command npx / uvx / python / an exe). Portable Node and uv are fetched automatically when missing. command="playwright" opens a real visible browser with sound. Then mcp_call (or <server>__<tool> on /s/<code>/mcp). Prefer a dedicated MCP server over clicking the GUI.
5. Operations that take longer than ~45 s return "Still running (job X)": call wait_job with that id. Raise timeout_s on mcp_start / mcp_call / run for installs and renders.
6. The network may be slow: take screenshots only when needed (monitor=N crops to one screen), avoid huge command output.
7. The user watches the screen: make your work visible. Do windowing with the mouse (drag a title bar to move a window, drag an edge or corner to resize, click the minimise / maximise / close buttons, click taskbar icons to open or hide an app) instead of keyboard shortcuts or commands when a mouse action exists. When you read or check something, use move to glide the pointer to the text you are reading first (like a person following a line with the cursor). Skip this for background work (files, commands, MCP calls).
8. Talk to the user while you work. At the start say whether the connection worked (list_sessions, sysinfo) and that the friend can end the session at any time with Esc. Before a group of actions say in one short line what you are going to do, afterwards whether it worked. Bundle small GUI steps (move + click, click + type, drag, scroll) into ONE actions call so the friend confirms once instead of per step. If any call comes back "ended", "denied", "Agent left" or "No such session": stop, do not retry, tell the operator.
9. Android phones (os "Android ..."): only screenshot, click (a tap; button=right is a long press), drag (a swipe; hold=true for drag and drop), scroll, type_text (into the focused field: tap it first), press_key (home, back, recents, notifications, quick_settings, enter, backspace, volume_up, volume_down, power, lock, screenshot), start_process (command = app name, package or link), actions and sysinfo exist. There is no shell, no files and no MCP bridge. Coordinates are screenshot pixels; the friend can end the session by tapping the label at the top of the screen.
10. This is the user's real machine: only touch what the task needs, and say what you installed or changed.`;

function buildMcp(fixed) {
  const m = new Server({ name: 'helpermcp', version: '0.4.0' }, { capabilities: { tools: {} }, instructions: INSTRUCTIONS });
  const sessionProp = { session: str("Session code shown on the user's screen, e.g. K7M2-QX9P") };

  m.setRequestHandler(ListToolsRequestSchema, async () => {
    const list = tools
      .filter((t) => !(fixed && t.local && !t.always))
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
        return fmt(await callJob(session, 'mcp_call', { server: name.slice(0, i), tool: name.slice(i + 2), arguments: a }, 125_000));
      }
      if (!t) throw new Error(`Unknown tool ${name}`);
      if (t.local) return fmt(await t.run(a));
      if (!session) throw new Error('"session" is required (code shown on the user\'s screen)');
      if (t.run) return fmt(await t.run(session));
      return fmt(await callJob(session, name, a, t.ms?.(a)));
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
function bodyBuf(req, limit) {
  return new Promise((resolve, reject) => {
    const chunks = []; let n = 0;
    req.on('data', (c) => { n += c.length; if (n > limit) { reject(new Error('too large')); req.destroy(); } else chunks.push(c); });
    req.on('end', () => {
      const raw = Buffer.concat(chunks);
      if (req.headers['content-encoding'] !== 'gzip') return resolve(raw);
      try { resolve(zlib.gunzipSync(raw, { maxOutputLength: limit * 4 })); } catch (e) { reject(e); }   // agents gzip big JSON; cap the inflated size
    });
    req.on('error', reject);
  });
}
const body = async (req, limit) => (await bodyBuf(req, limit)).toString('utf8');
const baseUrl = (req) => PUBLIC_URL || `${req.headers['x-forwarded-proto'] || (req.socket.encrypted ? 'https' : 'http')}://${req.headers.host}`;
const clientIp = (req) => req.socket.remoteAddress;
const PKG_VERSION = (() => { try { return JSON.parse(fs.readFileSync(path.join(here, 'package.json'), 'utf8')).version; } catch { return '?'; } })();

function script(req, res, file) {
  let f;
  try { f = fs.readFileSync(path.join(AGENT_DIR, file), 'utf8'); } catch { return text(res, 404, 'not found'); }
  f = f.replace(/\r\n/g, '\n');
  // PowerShell cannot redefine a type in a session that already has it: the types of the Windows agent get a name that changes with the script, so running the one-liner again in the same window after an update just works
  const build = crypto.createHash('sha256').update(f).digest('hex').slice(0, 6);
  text(res, 200, f.replaceAll('__RELAY__', baseUrl(req)).replaceAll('__BUILD__', build));   // LF whatever the checkout's line endings
}

const LANDING = fs.readFileSync(path.join(here, 'landing.html'), 'utf8');   // the page is a template: relay/landing.html
function landing(req, res) {
  const b = baseUrl(req);
  const ps = `[Net.ServicePointManager]::SecurityProtocol=3072; irm ${b}/h | iex`;
  const cmd = `powershell -NoProfile -ExecutionPolicy Bypass -Command "${ps}"`;
  const sh = `python3 <(curl -fsSL ${b}/p)`;
  const esc = (x) => x.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/"/g, '&quot;');
  const apk = fs.existsSync(APK_FILE);
  const vars = {
    BASE: esc(b), PS: esc(ps), CMD: esc(cmd), SH: esc(sh), PS_ATTR: esc(ps), CMD_ATTR: esc(cmd), SH_ATTR: esc(sh),
    APK_TAB: apk ? '<button class="tab" role="tab" data-p="and">android</button>' : '',
    APK_PANE: apk ? `<section class="win" id="and" role="tabpanel"><div class="bar"><i></i><i></i><i></i><span>~/android</span></div><div class="body">
<div class="qr"><img alt="QR code with the link to the app" src="${esc(b)}/qr.svg?u=${encodeURIComponent(b + '/apk')}"><div>
<ol><li data-i="a1">Scan the code with the phone camera, or open the link, and download the app.</li><li data-i="a2">Allow the install and open <b>HelperMCP</b>.</li><li data-i="a3">Tap <b>Allow control</b>, switch HelperMCP on, then tap <b>Start help</b>.</li></ol>
<div class="cmd"><small data-i="aLink">Link</small><pre>${esc(b)}/apk</pre><button class="cp" data-t="${esc(b)}/apk">Copy</button></div>
<a class="btn" href="${esc(b)}/apk" data-i="aBtn">Download APK</a></div></div></div></section>` : '',
  };
  let html = LANDING;
  for (const [k, v] of Object.entries(vars)) html = html.split(`{{${k}}}`).join(v);
  text(res, 200, html, 'text/html; charset=utf-8');
}

function launcherCmd(b) {
  const lines = ['@echo off', 'title Remote help', `powershell -NoProfile -ExecutionPolicy Bypass -Command "[Net.ServicePointManager]::SecurityProtocol=3072; irm ${b}/h | iex"`, 'pause'];
  return lines.join('\r\n') + '\r\n';
}

function viewerPage(s) {
  const who = s ? `${s.info.user}@${s.info.host}` : '';
  const esc = (x) => x.replace(/&/g, '&amp;').replace(/</g, '&lt;');
  return `<!doctype html><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1"><title>Remote screen ${esc(who)}</title>
<style>html,body{margin:0;height:100%;background:#0b0f16;color:#cfd8e6;font:14px system-ui}
#top{display:flex;align-items:center;gap:10px;padding:8px 14px;background:#111826;border-bottom:1px solid #26324a}
#dot{width:9px;height:9px;border-radius:50%;background:#888}#dot.on{background:#4c8dff;box-shadow:0 0 8px #4c8dff}
#main{display:flex;height:calc(100% - 41px)}#scr{flex:1;display:flex;align-items:center;justify-content:center;min-width:0}
#scr img{max-width:100%;max-height:100%;box-shadow:0 0 0 1px #26324a}
#log{width:340px;overflow:auto;border-left:1px solid #26324a;padding:8px 12px;font:12px ui-monospace,monospace}
#log div{padding:2px 0;border-bottom:1px solid #1a2233;word-break:break-all}#log b{color:#7fb0ff}#log i{color:#6b7a94;font-style:normal}
@media(max-width:800px){#main{flex-direction:column}#log{width:auto;height:30%;border-left:0;border-top:1px solid #26324a}}</style>
<div id=top><span id=dot></span><b id=st>…</b><span style="color:#6b7a94">${esc(who)}</span></div>
<div id=main><div id=scr><img id=img alt=""></div><div id=log></div></div>
<script>
const ru=(navigator.language||'').startsWith('ru'),L=ru?{live:'Идёт сеанс',wait:'Ожидание кадра…',end:'Сеанс завершён'}:{live:'Live',wait:'Waiting for a frame…',end:'Session ended'};
const dot=document.getElementById('dot'),st=document.getElementById('st'),img=document.getElementById('img'),log=document.getElementById('log');
const base=location.pathname.split('/').slice(0,3).join('/');   // /v/<token>: the link has no trailing slash, so a relative URL would resolve to /v/frame
let ended=false;
async function frames(){while(!ended){try{const r=await fetch(base+'/frame?'+Date.now());
 if(r.status===410){ended=true;break}
 if(r.status===204){dot.className='on';st.textContent=L.live;await new Promise(x=>setTimeout(x,600));continue}
 if(r.ok){const b=await r.blob();const u=URL.createObjectURL(b);const o=img.src;img.src=u;if(o.startsWith('blob:'))URL.revokeObjectURL(o);dot.className='on';st.textContent=L.live+' · '+Math.round(b.size/1024)+' KB'}
 else{dot.className='';st.textContent=L.wait;await new Promise(x=>setTimeout(x,1500))}}
 catch(e){dot.className='';st.textContent=L.wait;await new Promise(x=>setTimeout(x,2000))}
 await new Promise(x=>setTimeout(x,150))}
 dot.className='';st.textContent=L.end}
async function logs(){while(!ended){try{const r=await fetch(base+'/log');if(r.ok){const a=await r.json();
 log.innerHTML=a.reverse().map(e=>'<div><i>'+new Date(e.t).toLocaleTimeString()+'</i> <b>'+e.tool+'</b> '+(e.args||'').replace(/&/g,'&amp;').replace(/</g,'&lt;')+'</div>').join('')}}catch(e){}
 await new Promise(x=>setTimeout(x,1500))}}
frames();logs();
</script>`;
}

const bearer = (req) => (req.headers.authorization || '').replace(/^Bearer /i, '');
const byToken = (req) => {
  const t = bearer(req);
  const h = sha(t);
  for (const [code, s] of sessions) if (safeEq(h, s.th)) return [code, s];
  return [];
};

async function handler(req, res) {
  const url = new URL(req.url, 'http://x');
  const p = url.pathname;
  try {
    res.setHeader('x-content-type-options', 'nosniff'); res.setHeader('referrer-policy', 'no-referrer'); res.setHeader('strict-transport-security', 'max-age=31536000');
    res.setHeader('content-security-policy', "default-src 'none'; img-src 'self' data: blob:; style-src 'unsafe-inline'; script-src 'unsafe-inline'; connect-src 'self'; frame-ancestors 'none'");
    if (p === '/health') return text(res, 200, 'ok');
    if (p === '/apk') {   // the Android app (people scan the QR code on the landing page)
      if (!fs.existsSync(APK_FILE)) return text(res, 404, 'The Android app is not installed on this server');
      res.writeHead(200, { 'content-type': 'application/vnd.android.package-archive', 'content-disposition': 'attachment; filename="HelperMCP.apk"', 'cache-control': 'no-cache' });
      return res.end(fs.readFileSync(APK_FILE));
    }
    if (p === '/apk/version') {   // the app asks this to offer an update: helpermcp.json = {"versionCode": N, "versionName": "x.y.z"} next to the APK
      const vf = APK_FILE.replace(/\.apk$/, '.json');
      if (!fs.existsSync(vf)) return text(res, 404, 'no version info');
      res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-cache' }); return res.end(fs.readFileSync(vf));
    }
    if (p === '/qr.svg') {   // QR code of one of our own links
      const u = url.searchParams.get('u') || '';
      if (!u.startsWith(baseUrl(req) + '/') || u.length > 300) return text(res, 400, 'bad link');
      res.writeHead(200, { 'content-type': 'image/svg+xml', 'cache-control': 'max-age=3600' });
      return res.end(await QRCode.toString(u, { type: 'svg', margin: 1, width: 240 }));
    }
    if (p === '/h.cmd') { res.writeHead(200, { 'content-type': 'application/octet-stream', 'content-disposition': 'attachment; filename="remote-help.cmd"', 'cache-control': 'no-cache' }); return res.end(launcherCmd(baseUrl(req))); }
    if (p === '/p.sh') { res.writeHead(200, { 'content-type': 'application/x-sh', 'content-disposition': 'attachment; filename="remote-help.sh"', 'cache-control': 'no-cache' }); return res.end(`#!/usr/bin/env bash
python3 <(curl -fsSL ${baseUrl(req)}/p)
`); }
    if (p === '/h') return script(req, res, 'agent.ps1');
    if (p.startsWith('/cursor/')) {   // optional cursor pack (pointer.cur, link.cur, ...): drop the files into CURSOR_DIR, agents put them on the PC for the session
      const name = p.slice(8), f = path.join(CURSOR_DIR, name);
      if (!/^[a-z0-9_-]{1,30}\.(cur|ani)$/.test(name) || !fs.existsSync(f)) { res.writeHead(404); return res.end(); }
      res.writeHead(200, { 'content-type': 'application/octet-stream', 'cache-control': 'max-age=3600' }); return res.end(fs.readFileSync(f));
    }
    if (p === '/p') return script(req, res, 'agent.py');
    if (p === '/') return landing(req, res);

    const fm = p.match(/^\/f\/([0-9a-f]{24})\/[^/]+$/);   // download of a file fetched from a remote PC
    if (fm) {
      const f = files.get(fm[1]);
      if (!f || f.exp < Date.now()) return text(res, 404, 'file expired or invalid');
      res.writeHead(200, { 'content-type': 'application/octet-stream', 'content-length': f.size, 'content-disposition': `attachment; filename="${f.name}"`, 'cache-control': 'no-store' });
      const dec = crypto.createDecipheriv('aes-256-gcm', f.key, f.iv); dec.setAuthTag(f.tag);
      return pipeline(fs.createReadStream(f.path), dec, res).catch(() => {});
    }

    const vw = p.match(/^\/v\/([0-9a-f]{36})(\/frame|\/log)?$/);   // live viewer for the operator (link from open_viewer)
    if (vw) {
      const v = viewers.get(vw[1]);
      if (!v || v.exp < Date.now()) { viewers.delete(vw[1]); return text(res, 404, 'viewer link expired or invalid'); }
      const s = sessions.get(v.code);
      if (!vw[2]) return text(res, 200, viewerPage(s), 'text/html; charset=utf-8');
      if (!s) return json(res, 410, { error: 'session ended' });
      if (vw[2] === '/log') return json(res, 200, s.log.slice(-25));
      if (v.busy) { res.writeHead(204); return res.end(); }
      v.busy = true;
      try {
        const d = await call(v.code, 'screenshot', { view: true, prev: v.hash, ...viewParams(s) }, 20_000);
        if (d.same) { res.writeHead(204, { 'x-same': '1' }); return res.end(); }   // unchanged screen: nothing to send
        v.hash = d.h; v.last = d.jpeg;
        res.writeHead(200, { 'content-type': 'image/jpeg', 'cache-control': 'no-store', 'x-quality': `${s.vl ?? 3}` }); return res.end(d.jpeg);
      } catch (e) { return json(res, 503, { error: e.message }); } finally { v.busy = false; }
    }

    if (p === '/admin/status') {   // for the `helpermcp` console panel (needs the operator key)
      const ip = clientIp(req), f = authFails.get(ip);
      if (f && f.n >= AUTH_MAX_FAILS && Date.now() < f.until) return json(res, 429, { error: 'too many wrong keys, try again later' });
      if (!safeEq(bearer(req), OPERATOR_KEY)) { const n = (f && Date.now() < f.until ? f.n : 0) + 1; authFails.set(ip, { n, until: Date.now() + AUTH_WINDOW_MS }); return json(res, 401, { error: 'bad operator key' }); }
      authFails.delete(ip);
      const now = Date.now();
      return json(res, 200, {
        version: PKG_VERSION, uptime_s: Math.round(process.uptime()), public_url: PUBLIC_URL || lastBase || '', tls: !!(process.env.TLS_CERT && process.env.TLS_KEY), port: Number(process.env.PORT || 8444),
        state_encrypted: !!STATE_FILE, apk: fs.existsSync(APK_FILE), cursor_pack: fs.existsSync(CURSOR_DIR),
        counts: { sessions: sessions.size, online: [...sessions.values()].filter((x) => now - x.lastSeen < ONLINE_MS).length, files: files.size, viewers: viewers.size, auth_lockouts: authFails.size },
        limits: { max_sessions: MAX_SESSIONS, per_ip: MAX_PER_IP, idle_s: Math.round(SESSION_IDLE_MS / 1000) },
        sessions: [...sessions].map(([code, x]) => ({ code, os: x.info?.os || '', host: x.info?.host || '', user: x.info?.user || '', mode: x.mode, online: now - x.lastSeen < ONLINE_MS, last_seen_s: Math.round((now - x.lastSeen) / 1000), running: x.pending.size, queued: x.queue.length, age_s: Math.round((now - x.created) / 1000) })),
      });
    }
    const mcp = p === '/mcp' ? [null] : p.match(/^\/s\/([A-Za-z0-9-]+)\/mcp$/);
    if (mcp) {
      const ip = clientIp(req), f = authFails.get(ip);
      if (f && f.n >= AUTH_MAX_FAILS && Date.now() < f.until) return json(res, 429, { error: 'too many wrong keys, try again later' });   // brute-force guard
      if (!safeEq(bearer(req), OPERATOR_KEY)) {
        const n = (f && Date.now() < f.until ? f.n : 0) + 1;
        authFails.set(ip, { n, until: Date.now() + AUTH_WINDOW_MS });
        return json(res, 401, { error: 'bad operator key' });
      }
      authFails.delete(ip);
      if (req.method !== 'POST') return json(res, 405, { error: 'POST only' });
      lastBase = baseUrl(req);
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
      const rl = regRate.get(ip) || { n: 0, t: Date.now() }; if (Date.now() - rl.t > 60_000) { rl.n = 0; rl.t = Date.now(); }   // a client PC cannot flood the server with registrations
      if (++rl.n > 20) return json(res, 429, { error: 'slow down' }); regRate.set(ip, rl);
      const info = JSON.parse((await body(req, 10_000)) || '{}');
      let code = /^[A-Z2-9]{4}-[A-Z2-9]{4}$/.test(info.resume || '') && !sessions.has(info.resume) ? info.resume : null;   // same code after a server reset
      if (!code) do code = newCode(); while (sessions.has(code));
      const token = crypto.randomBytes(32).toString('hex');
      const s = newSession({
        th: sha(token), ip, mode: info.mode === 'ask' ? 'ask' : 'full', created: Date.now(),
        info: { os: String(info.os || '?').slice(0, 100), host: String(info.host || '?').slice(0, 100), user: String(info.user || '?').slice(0, 100) },
      });
      sessions.set(code, s); save();
      console.log(`+ ${code} ${s.info.user}@${s.info.host} (${s.info.os}) ${s.mode} from ${ip}`);
      return json(res, 200, { code, token });
    }

    if (p.startsWith('/a/')) {
      const [code, s] = byToken(req);
      if (!s) return json(res, 401, { error: 'unknown token' });
      s.lastSeen = Date.now();
      if (p === '/a/poll' && req.method === 'GET') {
        if (url.searchParams.get('w') === '0' && !s.queue.length) { res.writeHead(204); return res.end(); }   // agent busy with a long call: just peek
        if (s.waiting) json(s.waiting, 204, {}); // superseded poll
        s.waiting = res;
        s.waitTimer = setTimeout(() => { s.waiting = null; res.writeHead(204); res.end(); }, POLL_MS);
        res.on('close', () => { if (s.waiting === res) { s.waiting = null; clearTimeout(s.waitTimer); } });
        return flush(s);
      }
      if (p === '/a/result' && req.method === 'POST') {
        let r;
        const ct = req.headers['content-type'] || '';
        if (ct.startsWith('image/')) {   // screenshots arrive as raw JPEG: no base64 inflation
          const buf = await bodyBuf(req, 25_000_000);
          let meta = {}; try { meta = JSON.parse(decodeURIComponent(req.headers['x-result-meta'] || '{}')); } catch { /* optional */ }
          r = { id: req.headers['x-result-id'], ok: true, data: { ...meta, jpeg: buf, mime: ct } };
        } else r = JSON.parse(await body(req, 25_000_000));
        const pend = s.pending.get(r.id);
        if (pend) {
          s.pending.delete(r.id); clearTimeout(pend.timer);
          adapt(s, pend, r.data?.jpeg?.length || 0);
          r.ok ? pend.resolve(r.data) : pend.reject(new Error(r.error || 'agent error'));
        }
        return json(res, 200, {});
      }
      if (p === '/a/file' && req.method === 'POST') {
        const name = (url.searchParams.get('name') || 'file').replace(/[^\w.\-]+/g, '_').slice(0, 100) || 'file';
        const id = crypto.randomBytes(12).toString('hex'), fp = path.join(FILES_DIR, id);
        let n = 0;
        const cap = new Transform({ transform(chunk, _e, cb) { n += chunk.length; n > MAX_FILE ? cb(new Error('file too large')) : cb(null, chunk); } });
        const key = crypto.randomBytes(32), iv = crypto.randomBytes(12), enc = crypto.createCipheriv('aes-256-gcm', key, iv);
        try { await pipeline(req, cap, enc, fs.createWriteStream(fp, { mode: 0o600 })); }
        catch (e) { fs.rmSync(fp, { force: true }); return json(res, 413, { error: e.message }); }
        files.set(id, { path: fp, name, size: n, exp: Date.now() + FILE_TTL_MS, code, key, iv, tag: enc.getAuthTag() });
        return json(res, 200, { url: `${baseUrl(req)}/f/${id}/${encodeURIComponent(name)}`, size: n });
      }
      if (p === '/a/bye') { console.log(`- ${code} bye`); drop(code, 'The user closed the helper or pressed Esc. STOP: do not retry, tell the operator.'); return json(res, 200, {}); }
    }
    json(res, 404, { error: 'not found' });
  } catch (e) {
    if (!res.headersSent) json(res, 400, { error: e.message });
  }
}

if (STATE_FILE && fs.existsSync(STATE_FILE)) {
  try {
    const st = JSON.parse(unseal(fs.readFileSync(STATE_FILE)));
    for (const x of st.sessions || []) sessions.set(x.code, newSession(x));   // agents have SESSION_IDLE_MS to come back
    for (const v of st.viewers || []) if (v.exp > Date.now()) viewers.set(v.token, { code: v.code, exp: v.exp });
    console.log(`restored ${sessions.size} session(s) from ${STATE_FILE}`);
  } catch (e) { console.error('state load failed:', e.message); }
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
