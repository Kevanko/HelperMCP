// HelperMCP relay: agents (on friends' PCs) long-poll here; AI clients talk MCP to /mcp or /s/<code>/mcp.
import http from 'node:http';
import https from 'node:https';
import fs from 'node:fs';
import crypto from 'node:crypto';
import QRCode from 'qrcode';
import zlib from 'node:zlib';
import os from 'node:os';
import { pipeline } from 'node:stream/promises';
import { makeAdminHandler } from './admin.mjs';
import { load as loadActs, report as buildReport } from './report.mjs';
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
const KEEP_MS = Number(process.env.KEEP_MS || 7 * 24 * 3600_000);   // a session the user chose to keep (survives reboots and outages) waits this long for its PC
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
const devices = new Map(); // sha(device_id) -> code: a permanent identity per install, like an AnyDesk/RustDesk ID
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
        sessions: [...sessions].map(([code, s]) => ({ code, th: s.th, ip: s.ip, mode: s.mode, info: s.info, created: s.created, persist: !!s.persist, keepMs: s.keepMs, paused: !!s.paused, events: (s.events || []).slice(-30) })),
        viewers: [...viewers].map(([token, v]) => ({ token, code: v.code, exp: v.exp, ctl: v.ctl })),
        devices: [...devices].map(([dh, code]) => ({ dh, code })),
      };
      fs.mkdirSync(path.dirname(STATE_FILE), { recursive: true });
      fs.writeFileSync(STATE_FILE + '.tmp', seal(JSON.stringify(out)), { mode: 0o600 });
      fs.renameSync(STATE_FILE + '.tmp', STATE_FILE);
    } catch (e) { console.error('state save failed:', e.message); }
  }, 300);
}
// ---- mistakes: an action that missed (a tap on nothing, a wrong screen) is kept with the path that led to it, to analyse and fix later
const MISS_FILE = process.env.MISS_FILE || (STATE_FILE ? path.join(path.dirname(STATE_FILE), 'misses.jsonl') : path.join(os.tmpdir(), 'helpermcp-misses.jsonl'));
function recordMiss(s, code, kind, info) {
  try {
    const redact = (a) => String(a || '').replace(/("text"\s*:\s*")((?:[^"\\]|\\.)*)(")/g, (_m, p, v, q) => `${p}<${v.length} chars>${q}`);
    const e = { t: new Date().toISOString(), session: code, kind, device: `${s.info?.host || ''} / ${s.info?.os || ''}`, ...info,
      trail: s.log.slice(-8).map((l) => ({ ago_s: Math.round((Date.now() - l.t) / 1000), tool: l.tool, args: redact(l.args) })) };
    fs.appendFileSync(MISS_FILE, JSON.stringify(e) + '\n', { mode: 0o600 });
    if (fs.statSync(MISS_FILE).size > 2_000_000) { const L = fs.readFileSync(MISS_FILE, 'utf8').trim().split('\n'); fs.writeFileSync(MISS_FILE, L.slice(-500).join('\n') + '\n', { mode: 0o600 }); }
    evPush(s, { t: Date.now(), type: 'miss', data: { kind, ...info } });
  } catch (e) { console.error('miss log failed:', e.message); }
}
// ---- the action log: every call (tool, arguments, result, time, errors) and what the agents report (outages, route switches, resumes) is appended to
// data/actions.jsonl and kept, so the failures can be read, reproduced and fixed later (helpermcp report). Typed text, file contents and values are
// never written down (only their length), obvious secrets are masked, results are cut short.
const ACT_FILE = process.env.ACT_FILE || (STATE_FILE ? path.join(path.dirname(STATE_FILE), 'actions.jsonl') : '');
const ACT_MAX = Number(process.env.ACT_MAX_BYTES || 20_000_000);
const HIDE = /("(?:text|content|value|old|new|stdin|body)"\s*:\s*")((?:[^"\\]|\\.)*)(")/g;
const SECRET = /((?:pass(?:word|wd)?|token|secret|api[_-]?key|authorization|bearer)["'\s:=]+)([^\s"',;]{4,})/gi;
const SHOW_OUT = new Set(['run', 'util', 'start_process', 'edit_file', 'push_file', 'fetch_file', 'write_file', 'system', 'sysinfo']);
function actWrite(e) {
  if (!ACT_FILE) return;
  try {
    fs.appendFileSync(ACT_FILE, JSON.stringify(e) + '\n', { mode: 0o600 });
    if (Math.random() < 0.02 && fs.statSync(ACT_FILE).size > ACT_MAX) { fs.renameSync(ACT_FILE, ACT_FILE + '.1'); }   // one older file is kept
  } catch (err) { console.error('action log failed:', err.message); }
}
const sidOf = (s) => (s.sid ??= crypto.randomBytes(3).toString('hex'));
const devOf = (s) => `${s.info?.host || ''}|${s.info?.os || ''}`;
function actCall(s, tool, args, ok, t0, res) {
  try {
    const a = JSON.stringify(args || {}, (k, v) => (k === 'session' ? undefined : typeof v === 'string' && v.length > 300 ? v.slice(0, 300) + '…' : v))
      .replace(HIDE, (_m, p1, v, q) => `${p1}<${v.length} chars>${q}`).replace(SECRET, '$1<hidden>').slice(0, 700);
    const text = ok ? String((res && res.text) ?? '') : String(res || '');
    const e = { t: new Date(t0).toISOString(), sid: sidOf(s), dev: devOf(s), tool, a: a === '{}' ? '' : a, ok, ms: Date.now() - t0, n: ok ? text.length || (res && res.jpeg ? res.jpeg.length : 0) : undefined };
    if (!ok) e.err = text.replace(SECRET, '$1<hidden>').slice(0, 500);
    else if (SHOW_OUT.has(tool)) e.out = text.replace(SECRET, '$1<hidden>').slice(0, 240);
    actWrite(e);
  } catch { /* logging must never break a call */ }
}
function actEvent(s, ev) {
  try { actWrite({ t: new Date(ev.t || Date.now()).toISOString(), sid: sidOf(s), dev: devOf(s), kind: 'event', type: ev.type, data: JSON.stringify(ev.data ?? ev.note ?? '').replace(SECRET, '$1<hidden>').slice(0, 900) }); } catch { /* optional */ }
}
function evPush(s, ev) { s.events.push(ev); actEvent(s, ev); }
// what the label shows: the current stage (its colour, "2/5 title") and the note
function lookOf(s) {
  const st = s.plan && s.plan.stages[s.plan.current];
  const note = [st ? `${s.plan.current + 1}/${s.plan.stages.length} ${st.title}` : '', s.note || ''].filter(Boolean).join(': ');
  return { color: s.lookForce || (st && st.color) || s.lookColor || '', note: note.slice(0, 120) };   // a colour picked by a person wins over the plan's
}
// a person changes the glow colour or the task text from the viewer / the admin panel
async function humanLook(code, color, note) {
  const s = sessions.get(String(code).toUpperCase()); if (!s) throw new Error('No such session');
  if (color !== undefined && color !== '') { if (!/^#[0-9a-f]{6}$/i.test(color)) throw new Error('bad colour (use #RRGGBB)'); s.lookForce = color.toLowerCase(); }
  if (note !== undefined) { s.note = String(note).replace(/\s+/g, ' ').slice(0, 90); s.lastNoteAt = 0; }
  evPush(s, { t: Date.now(), type: 'look', data: { note: s.note || '', color: s.lookForce || '', by: 'operator' } }); save();
  return pushLook(String(code).toUpperCase(), s);
}
async function pushLook(code, s) {
  const l = lookOf(s);
  try { return String((await call(code, 'look', { ...l, force: true })).text || 'ok'); }
  catch (e) { if (/Unknown tool|not available/i.test(e.message)) return 'noted (this agent is too old to show it: the user can restart the helper to update it)'; throw e; }
}
// the AI's screenshots: smaller by default, and an unchanged screen costs a line instead of a picture
async function aiShot(code, a) {
  const s = sessions.get(String(code).toUpperCase()); if (!s) throw new Error(`No such session "${code}"`);
  const key = JSON.stringify([a.monitor ?? null, a.region ?? null, a.max_width ?? null]);
  const args = { max_width: 1366, quality: 60, ...a }; delete args.fresh;
  if (!a.fresh && s.shotKey === key && s.shotHash) args.prev = s.shotHash;
  const d = await callJob(code, 'screenshot', args);
  if (d && (d.same || (args.prev && d.h === args.prev))) return { text: 'The screen is exactly as in your last screenshot (nothing changed). Use fresh:true to get the picture again.' };
  if (d && d.h) { s.shotHash = d.h; s.shotKey = key; }
  return d;
}
// ---- live stream (like a video call): the agent pushes frames over one long upload, the relay fans them out to the open viewers.
// A frame is [u32 length][u8 type][payload]: K = full JPEG ([u16 n][meta JSON][jpeg]), T = changed tiles ([u16 count] then [u16 x][u16 y][u32 n][jpeg]),
// C = H.264 config ([u16 n][meta JSON {codec, w, h, ox, oy, sc}]), V = H.264 access unit ([u8 key][annex-B bytes]), P = ping.
const SHOT_TOOLS = new Set(['click', 'ui_click', 'ui_set', 'move', 'drag', 'scroll', 'type_text', 'press_key', 'actions', 'start_process', 'focus_window']);
const LIVE_BACKLOG = 1_500_000;   // bytes waiting for a slow viewer before it skips frames until the next full picture
function streamCtl(code, s, a) {
  if (s.noStream) return;
  call(code, 'stream', a, 10_000, { human: true }).catch((e) => { if (/Unknown tool|unknown tool/.test(e.message)) s.noStream = true; });   // an old agent: viewers fall back to pictures
}
function wantKey(code, s) { if (Date.now() - (s.keyAt || 0) > 1000) { s.keyAt = Date.now(); streamCtl(code, s, { on: true, mon: s.liveMon ?? -1, key: true }); } }
function liveFrame(code, s, fr) {
  const type = String.fromCharCode(fr[4]);
  const key = type === 'K' || (type === 'V' && (fr[5] & 1));
  if (type === 'C') s.lastC = fr;   // a new viewer needs the decoder settings before the next key frame
  if (type === 'S') { s.lastS = fr; for (const lv of s.live || []) if (lv.res.writableLength < LIVE_BACKLOG) lv.res.write(fr); return; }
  for (const lv of s.live || []) {
    if (lv.res.writableLength > LIVE_BACKLOG) { lv.waitKey = true; wantKey(code, s); continue; }   // the viewer's link is slower than the picture
    if (lv.waitKey && !key && type !== 'C' && type !== 'P') continue;
    if (key) lv.waitKey = false;
    lv.res.write(fr);
  }
}
function liveEnd(s) { for (const lv of s.live || []) { try { lv.res.end(); } catch { /* gone */ } } s.live?.clear(); try { s.ingest?.destroy(); } catch { /* gone */ } }

// a file in transit, encrypted at rest with its own key, deleted with the session (or after 24 h)
async function storeFile(req, rawName, code) {
  const name = String(rawName || 'file').replace(/[^\w.\-]+/g, '_').slice(0, 100) || 'file';
  const id = crypto.randomBytes(12).toString('hex'), fp = path.join(FILES_DIR, id);
  let n = 0;
  const cap = new Transform({ transform(chunk, _e, cb) { n += chunk.length; n > MAX_FILE ? cb(new Error('file too large')) : cb(null, chunk); } });
  const key = crypto.randomBytes(32), iv = crypto.randomBytes(12), enc = crypto.createCipheriv('aes-256-gcm', key, iv);
  try { await pipeline(req, cap, enc, fs.createWriteStream(fp, { mode: 0o600 })); }
  catch (e) { fs.rmSync(fp, { force: true }); throw e; }
  files.set(id, { path: fp, name, size: n, exp: Date.now() + FILE_TTL_MS, code, key, iv, tag: enc.getAuthTag() });
  return { url: `${baseUrl(req)}/f/${id}/${encodeURIComponent(name)}`, size: n, name };
}

function makeViewer(c, base = lastBase) {
  const token = crypto.randomBytes(18).toString('hex'), ctl = crypto.randomBytes(12).toString('hex');
  viewers.set(token, { code: c, exp: Date.now() + VIEWER_TTL_MS, ctl }); save();
  return { watch: `${base}/v/${token}`, control: `${base}/v/${token}#c=${ctl}` };
}
const newSession = (o) => ({ events: [], persist: false, paused: false, ...o, queue: [], pending: new Map(), waiting: null, waitTimer: null, lastSeen: Date.now(), log: [] });
const viewers = new Map();  // unguessable token -> { code, exp }: lets the operator watch a screen in a browser without exposing OPERATOR_KEY
let lastBase = PUBLIC_URL;  // public URL as seen by the last MCP request (used to build viewer links)
const VIEWER_TTL_MS = 12 * 3600_000;
// files copied from a remote PC to the operator: unguessable link, kept 24 h
const CURSOR_DIR = process.env.CURSOR_DIR || (STATE_FILE ? path.join(path.dirname(STATE_FILE), 'cursor') : path.join(here, 'cursor'));
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
// confirm: ask before every action. auto: no questions (the default). unattended: like auto, plus only the admin panel can end it; 'ask'/'full' are what old agents still send
const normMode = (m) => (m === 'confirm' || m === 'unattended' ? m : m === 'ask' ? 'confirm' : 'auto');
const safeEq = (a, b) => {
  const x = Buffer.from(String(a)), y = Buffer.from(String(b));
  return x.length === y.length && crypto.timingSafeEqual(x, y);
};

// ---- session / command plumbing ------------------------------------------
const TAKEOVER_MS = 5 * 60_000;
const takenOver = (s) => s.takeover && Date.now() - s.takeover < TAKEOVER_MS;   // the operator is fixing something by hand in the live viewer
function call(code, tool, args = {}, timeoutMs = 60_000, opts = {}) {
  const s = sessions.get(String(code).toUpperCase());
  if (!s) return Promise.reject(new Error(`No such session "${code}" (it was never there, or the user closed the helper / pressed Esc). If you were working on it: STOP, do not retry, tell the operator. Use list_sessions.`));
  if (s.paused && tool !== 'bye' && !(opts.human && (tool === 'screenshot' || tool === 'stream'))) {   // the live viewer keeps showing the screen while it is paused
    return Promise.reject(new Error('PAUSED by the user (they pressed Esc and chose Pause). The session is kept. Do not retry now: tell the operator, then use wait_online (it also waits for the user to resume) or check session_log.'));
  }
  if (takenOver(s) && !opts.human && tool !== 'bye') {
    return Promise.reject(new Error('TAKEOVER: the operator is fixing something by hand in the live viewer right now. Do not act on this device: wait_online returns when they hand control back; then take a screenshot and continue from the new state.'));
  }
  if (Date.now() - s.lastSeen > ONLINE_MS && !s.pending.size && tool !== 'bye') {
    if (s.persist) return Promise.reject(new Error(`The remote PC is offline (last seen ${Math.round((Date.now() - s.lastSeen) / 1000)} s ago: internet loss, VPN change, sleep or reboot). This session is KEPT and its agent reconnects by itself with the same code. Use wait_online to wait for it, then session_log to read what happened.`));
    return Promise.reject(new Error(`The remote PC is offline (last seen ${Math.round((Date.now() - s.lastSeen) / 1000)} s ago: internet/VPN change or sleep). The agent reconnects by itself; try again in a few seconds. list_sessions shows "online".`));
  }
  // in "ask" mode a human must click through prompts, give them time
  if (s.mode === 'confirm') timeoutMs += 120_000;
  if (tool === 'screenshot' && !args.view && s.lite) args = { max_width: 1280, quality: 50, ...args };   // slow link: smaller by default
  let argStr = '';
  if (!args.view && tool !== 'stream') { // live-viewer frames are not "actions"
    const a = JSON.stringify(args, (k, v) => (typeof v === 'string' && v.length > 80 ? v.slice(0, 80) + '…' : v));
    argStr = a === '{}' ? '' : a.slice(0, 160);
    s.log.push({ t: Date.now(), tool, args: argStr });
    if (s.log.length > 60) s.log.shift();
  }
  const id = crypto.randomUUID(), t0 = Date.now();
  const pr = new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      s.pending.delete(id); s.queue = s.queue.filter((q) => q.id !== id);   // a caller that gave up must not have its command run later
      reject(new Error(`Timed out after ${Math.round(timeoutMs / 1000)}s waiting for the agent (user may not have approved).`));
    }, timeoutMs);
    s.pending.set(id, { resolve, reject, timer, t0: Date.now() - (args.view ? FAKE_LATENCY_MS : 0), tool, argStr, view: !!args.view });
    s.queue.push({ id, tool, args });
    flush(s);
  });
  if (!args.view && tool !== 'stream' && tool !== 'bye') pr.then((d) => actCall(s, tool, args, true, t0, d), (e) => actCall(s, tool, args, false, t0, e.message));
  return pr;
}

function flush(s) {
  if (s.waiting && s.queue.length) {
    const res = s.waiting;
    s.waiting = null;
    clearTimeout(s.waitTimer);
    json(res, 200, s.queue.shift());
  }
}

const ended = new Map();   // codes the user (or operator) ended: an agent that still tries to come back with one is told to stop (for an hour)
function drop(code, why) {
  const s = sessions.get(code);
  if (!s) return;
  ended.set(code, Date.now());
  sessions.delete(code); s.log.length = 0; s.queue.length = 0; liveEnd(s);
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
  for (const [code, s] of sessions) if (!s.pending.size && Date.now() - s.lastSeen > (s.persist ? (s.keepMs || KEEP_MS) : SESSION_IDLE_MS)) drop(code, 'Agent disconnected.');
}, 10_000).unref();

// ---- adapting to the network: viewer frames step through quality levels, "lite" mode shrinks the AI's screenshots on slow links
const FAKE_LATENCY_MS = Number(process.env.TEST_FAKE_LATENCY_MS || 0);   // tests only: pretend viewer frames are slow
const LEVELS = [{ max_width: 480, quality: 35 }, { max_width: 640, quality: 45 }, { max_width: 800, quality: 50 }, { max_width: 960, quality: 55 }, { max_width: 1280, quality: 65 }];
const viewParams = (s) => LEVELS[s.vl ?? 3];
function adapt(s, pend, bytes) {
  const dur = Date.now() - pend.t0;
  if (pend.view) {                                   // aim for a frame about every second
    s.vl = s.vl ?? 3;
    if (dur > 2200 && s.vl > 0) { s.vl--; s.fast = 0; }
    else if (dur < 900 && bytes && ++s.fast >= 3 && s.vl < LEVELS.length - 1) { s.vl++; s.fast = 0; }
    else if (dur >= 900) s.fast = 0;
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
// wait_screen: instead of the AI taking screenshots in a loop (each one a round trip and a picture), the relay asks the agent for tiny "unchanged" answers
// and returns ONE picture when the screen changed / settled. A change = the picture hash differs (the glow overlay is taken out of the picture).
async function waitScreen(code, a) {
  const s = sessions.get(String(code).toUpperCase()); if (!s) throw new Error(`No such session "${code}"`);
  const until = a.until === 'change' ? 'change' : 'stable', end = Date.now() + Math.min(60, Math.max(1, Number(a.timeout_s) || 10)) * 1000, t0 = Date.now();
  let prev = s.shotHash || null, got = null, quiet = 0, changed = false;
  while (Date.now() < end) {
    const d = await call(code, 'screenshot', { max_width: 1000, quality: 55, ...(prev ? { prev } : {}) }, 30_000);
    if (d && (d.same || (prev && d.h === prev))) { quiet++; if (until === 'stable' && (changed || quiet >= 3) && quiet >= 2) break; }
    else { changed = true; quiet = 0; got = d; if (d.h) { prev = d.h; s.shotHash = d.h; s.shotKey = ''; } if (until === 'change') break; }
    await new Promise((x) => setTimeout(x, 150));
  }
  const secs = ((Date.now() - t0) / 1000).toFixed(1);
  if (!got) return { text: `No change on the screen in ${secs} s.` };
  return got.jpeg ? { ...got, text: `${until === 'change' ? 'The screen changed' : 'The screen settled'} after ${secs} s.` } : { text: `Changed after ${secs} s.` };
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
        connected_s: Math.round((Date.now() - s.created) / 1000), paused: s.paused, kept: s.persist, events: s.events.length,
        last_event: s.events.length ? { type: s.events[s.events.length - 1].type, ago_s: Math.round((Date.now() - s.events[s.events.length - 1].t) / 1000) } : undefined,
      })), null, 2),
    }) },
  { name: 'session_log', session: true,
    description: 'What happened to this remote machine: pauses, outages (with the network diagnosis the agent made and what it tried), reboots, and your recent actions. Read it after a session comes back online, and before repeating work that was interrupted.',
    props: {}, run: async (code) => {
      const s = sessions.get(String(code).toUpperCase()); if (!s) throw new Error('No such session');
      const ago = (t) => Math.round((Date.now() - t) / 1000);
      return { text: JSON.stringify({ online: Date.now() - s.lastSeen <= ONLINE_MS, paused: s.paused, kept_across_reboots: s.persist, last_seen_s: ago(s.lastSeen),
        events: s.events.slice(-15).map((e) => ({ ...(e.data || {}), ago_s: ago(e.t), type: e.type })),
        recent_actions: s.log.slice(-15).map((l) => ({ ago_s: ago(l.t), tool: l.tool, args: l.args })) }, null, 2) };
    } },
  { name: 'report_miss', session: true,
    description: 'Log a mistake you made on this device so it can be analysed and fixed later: you tapped/typed/opened the wrong thing, then corrected it. Call it right after you noticed (the last actions are attached automatically). Example: wanted to open Telegram and check a subscription, tapped beside the icon, got it on the 2nd try.',
    props: { wanted: str('what you meant to do'), happened: str('what actually happened (wrong tap, wrong screen, nothing)'), fixed_by: str('what finally worked'), app: str('app or screen, if known') }, required: ['wanted', 'happened'],
    run: async (code, a) => {
      const s = sessions.get(String(code).toUpperCase()); if (!s) throw new Error('No such session');
      recordMiss(s, String(code).toUpperCase(), 'reported', { wanted: String(a.wanted).slice(0, 300), happened: String(a.happened).slice(0, 400), fixed_by: String(a.fixed_by || '').slice(0, 300), app: String(a.app || '').slice(0, 100) });
      return { text: 'logged' };
    } },
  { name: 'misses', local: true,
    description: 'Read the mistake log (taps that hit nothing, wrong screens, with the path of actions before each) to find patterns and fix the instructions or the app.',
    props: { limit: { type: 'integer', minimum: 1, maximum: 100, description: 'default 20' } },
    run: async (a) => {
      let L = []; try { L = fs.readFileSync(MISS_FILE, 'utf8').trim().split('\n').filter(Boolean).slice(-(a.limit || 20)); } catch { /* none yet */ }
      return { text: L.length ? '[' + L.join(',\n') + ']' : 'no mistakes logged yet' };
    } },
  { name: 'plan', session: true,
    description: 'Split the job into stages the user can follow: each stage has a short title and its own colour (#RRGGBB) that the glow and the label take while you are in it. The live viewer lists the stages and highlights the current one. Call it once when you know the steps (you may call it again if the plan changes), then set_look {stage: N} when you move on.',
    props: { stages: { type: 'array', maxItems: 12, items: { type: 'object', properties: { title: { type: 'string' }, color: { type: 'string', description: '#RRGGBB' } }, required: ['title'] } }, current: { type: 'integer', minimum: 0, description: 'index of the current stage, default 0' } }, required: ['stages'],
    run: async (code, a) => {
      const c = String(code).toUpperCase(); const s = sessions.get(c); if (!s) throw new Error('No such session');
      const hex = (x) => (/^#?[0-9a-f]{6}$/i.test(String(x || '')) ? '#' + String(x).replace('#', '') : '');
      const stages = (a.stages || []).slice(0, 12).map((x) => ({ title: String(x.title || '').replace(/\s+/g, ' ').slice(0, 60), color: hex(x.color) })).filter((x) => x.title);
      if (!stages.length) throw new Error('stages must have at least one title');
      s.plan = { stages, current: Math.max(0, Math.min(stages.length - 1, Number(a.current) || 0)), at: Date.now(), done: [] };
      evPush(s, { t: Date.now(), type: 'plan', data: { stages: stages.map((x) => x.title) } }); save();
      return { text: await pushLook(c, s) };
    } },
  { name: 'set_look', session: true,
    description: 'How your presence looks to the user (the glow and the label on a PC or a phone, and the live viewer). "note" (up to 90 chars): a short line of what you are doing right now, e.g. "Checking the subscription again in 5 min"; keep it current (at most once per 30 s). "stage": move to stage N of your plan (its colour and title show). "color" (#RRGGBB): your colour when you have no plan, chosen once per session.',
    props: { note: str('short status line'), stage: { type: 'integer', minimum: 0, description: 'index of the plan stage you start now' }, color: str('#RRGGBB, once per session (without a plan)') },
    run: async (code, a) => {
      const c = String(code).toUpperCase(); const s = sessions.get(c); if (!s) throw new Error('No such session');
      const now = Date.now();
      if (a.note) { if (s.lastNoteAt && now - s.lastNoteAt < 30_000) throw new Error('The note was changed a moment ago: wait, the user needs time to read it (once per 30 s at most).'); s.lastNoteAt = now; s.note = String(a.note).replace(/\s+/g, ' ').slice(0, 90); }
      if (a.stage !== undefined && s.plan) {
        const n = Math.max(0, Math.min(s.plan.stages.length - 1, Number(a.stage) || 0));
        if (n !== s.plan.current) { if (!s.plan.done.includes(s.plan.current) && n > s.plan.current) s.plan.done.push(s.plan.current); s.plan.current = n; s.plan.at = now; }
      }
      if (a.color && !s.lookColor && /^#?[0-9a-f]{6}$/i.test(a.color)) s.lookColor = '#' + String(a.color).replace('#', '');   // the colour is fixed after the first time
      evPush(s, { t: now, type: 'look', data: { note: s.note || '', stage: s.plan ? s.plan.current : null } }); save();
      return { text: await pushLook(c, s) };
    } },
  { name: 'hold', session: true,
    description: 'Put the session on hold when you must stop for a while (your token or rate limit is running out, a long break, waiting for the user). The phone shows an orange "helper is on hold, back soon" label, keeps its screen awake and the session open; your next action continues it. Unlike pause (which the user presses) you start it yourself. Elsewhere it is only logged.',
    props: { reason: str('why you stop'), back_in_minutes: { type: 'integer', minimum: 1, maximum: 1440, description: 'when you expect to continue' } },
    run: async (code, a) => {
      const c = String(code).toUpperCase(); const s = sessions.get(c); if (!s) throw new Error('No such session');
      evPush(s, { t: Date.now(), type: 'hold', data: { reason: String(a.reason || '').slice(0, 200), back_in_minutes: a.back_in_minutes || null } });
      await call(c, 'hold', {}).catch((e) => { if (!/Unknown tool|not available/i.test(e.message)) throw e; });
      return { text: 'on hold: the session stays open and the screen awake; your next action continues' };
    } },
  { name: 'task_done', session: true,
    description: 'Tell the user you have finished the job on this device. A phone shows a green "work finished" label and resets its timer; the session stays open and turns blue again on your next action. Call it when you are done, before you stop.',
    props: { summary: str('one line of what was done') },
    run: async (code, a) => {
      const c = String(code).toUpperCase(); const s = sessions.get(c); if (!s) throw new Error('No such session');
      evPush(s, { t: Date.now(), type: 'done', data: { summary: String(a.summary || '').slice(0, 200) } });
      await call(c, 'task_done', {}).catch((e) => { if (!/Unknown tool|not available/i.test(e.message)) throw e; });
      return { text: 'marked as finished' };
    } },
  { name: 'wait_online', session: true,
    description: 'Wait until the remote machine is online again and not paused (it reconnects by itself after an internet loss or a reboot, with the same code). Returns when it is back or after timeout_s.',
    props: { timeout_s: { type: 'integer', minimum: 1, maximum: 55, description: 'default 40' } },
    run: async (code, a) => {
      const c = String(code).toUpperCase(); const s = sessions.get(c); if (!s) throw new Error('No such session (it was ended)');
      const until = Date.now() + (a.timeout_s || 40) * 1000;
      while (Date.now() < until) { if (!sessions.has(c)) throw new Error('The session was ended by the user'); if (Date.now() - s.lastSeen <= ONLINE_MS && !s.paused && !takenOver(s)) return { text: 'online' }; await new Promise((r) => setTimeout(r, 1000)); }
      return { text: takenOver(s) ? 'the operator still controls the screen by hand: wait and call wait_online again' : s.paused ? 'still paused by the user' : `still offline (last seen ${Math.round((Date.now() - s.lastSeen) / 1000)} s ago); call wait_online again or ask the operator` };
    } },
  { name: 'agent_log', agent: true, description: 'The last lines of the log the agent keeps on the remote machine (errors, network outages with diagnosis, repairs, reboots). Works after a reboot too.', props: { lines: { type: 'integer', minimum: 5, maximum: 400, description: 'default 80' } } },
  { name: 'sysinfo', agent: true, description: 'OS, hostname, user, CPU/RAM, screen size, admin status of the remote machine.', props: {} },
  { name: 'wait_screen', session: true, description: 'Wait for the screen to react, then get ONE picture: until "change" returns at the first change, "stable" (default) when it has changed and then stopped moving (a page loaded, an installer finished). Much cheaper and faster than taking screenshots in a loop; use it after a click that starts something slow. Returns text only if nothing changed within timeout_s.',
    props: { until: { type: 'string', enum: ['change', 'stable'] }, timeout_s: { type: 'number', minimum: 1, maximum: 60, description: 'default 10' } }, run: (session, a) => waitScreen(session, a) },
  { name: 'watch', agent: true, description: 'Live look: films the screen for a few seconds and returns one picture with the frames in a grid (time and how much changed on each) plus a short text summary. Use it to see what happens over time: a loading bar, an animation, a window that flickers, whether typing or a click had any effect, an error that shows for a moment.',
    props: { seconds: { type: 'number', minimum: 1, maximum: 10, description: 'default 3' }, fps: { type: 'number', minimum: 1, maximum: 5, description: 'frames per second, default 3' }, monitor: { type: 'integer', minimum: 0 },
      region: { type: 'object', properties: { x: { type: 'number' }, y: { type: 'number' }, w: { type: 'number' }, h: { type: 'number' } }, description: 'only this part, in the coordinates of your last screenshot' } },
    ms: (a) => ((a.seconds || 3) + 25) * 1000 },
  { name: 'screenshot', agent: true, description: 'Screenshot of the remote screen (what the user sees): all monitors side by side, or a single one with "monitor" (0-based, see sysinfo). Click/scroll coordinates refer to the last screenshot.',
    props: { monitor: { type: 'integer', minimum: 0, description: 'omit for all monitors' },
      region: { type: 'object', properties: { x: { type: 'number' }, y: { type: 'number' }, w: { type: 'number' }, h: { type: 'number' } }, description: 'only this part, in the coordinates of your last screenshot: sharp and cheap for reading small text; later clicks use the coordinates of this picture' },
      max_width: { type: 'integer', minimum: 320, maximum: 3840, description: 'downscale to this width (default 1366)' },
      quality: { type: 'integer', minimum: 10, maximum: 95, description: 'JPEG quality (default 60)' },
      fresh: { type: 'boolean', description: 'send the picture even if nothing changed since your last screenshot' },
      overlay: { type: 'boolean', description: 'Android only: keep the helper overlay (glow, label, pointer) in the picture, to see exactly how it looks on this phone' } } },
  { name: 'run', agent: true, description: 'Run a shell command (PowerShell on Windows, bash on Linux) and wait for it. Returns exit code and combined output. Portable node/uv fetched by this bridge are on PATH. For GUI apps or anything long-lived use start_process instead. With args the program is started directly, without a shell: every argument arrives exactly as given (no quoting problems, use it for JSON, paths with spaces, quotes, $ & | %).',
    props: { command: str('Command line, or with args: the program (name or full path)'), args: { type: 'array', items: { type: 'string' }, description: 'arguments, passed as they are (no shell)' },
      shell: { type: 'string', enum: ['powershell', 'pwsh', 'cmd', 'bash', 'sh', 'python'], description: 'what runs command (default PowerShell on Windows, bash on Linux); the text is never re-quoted' },
      stdin: str('text sent to the program input'), timeout_s: { type: 'integer', minimum: 1, maximum: 3600, description: 'default 60' }, cwd: str('working directory') }, required: ['command'],
    ms: (a) => ((a.timeout_s || 60) + 10) * 1000 },
  { name: 'start_process', agent: true, description: 'Start a program detached and return immediately; it keeps running (use this for GUI apps such as Blender, Unity, Substance, or servers). Returns pid, whether it is still running, and the first output.',
    props: { command: str('Executable name or full path'), args: { type: 'array', items: { type: 'string' } }, cwd: str('working directory'), env: { type: 'object', additionalProperties: { type: 'string' } }, wait_s: { type: 'number', description: 'seconds to watch for an immediate crash, default 2' } }, required: ['command'] },
  { name: 'read_file', agent: true, description: 'Read a text file (first max_bytes, default 200000). With offset/lines or tail only those lines come back, numbered (cheap: use it for logs and big configs, and to copy exact text for edit_file). Image files (png, jpg, gif, bmp, webp) come back as images, scaled down to max_width.',
    props: { path: str('File path'), offset: { type: 'integer', minimum: 1, description: 'first line (1-based)' }, lines: { type: 'integer', minimum: 1, description: 'how many lines, default 200' }, tail: { type: 'integer', minimum: 1, description: 'the last N lines' },
      max_bytes: { type: 'integer', minimum: 1 }, max_width: { type: 'integer', minimum: 64, maximum: 4096, description: 'images only, default 1600' } }, required: ['path'] },
  { name: 'fetch_file', agent: true, ms: (a) => 3_700_000,
    description: 'Copy a file or a whole folder (sent as one zip) from the remote PC to the operator: returns a download link (valid 24 h). Use it to hand over results (renders, .blend files, logs, archives).',
    props: { path: str('File path on the remote PC') }, required: ['path'] },
  { name: 'write_file', agent: true, description: 'Write a text file (UTF-8), overwriting it (append=true adds to the end; base64=true writes binary content). To change part of a file use edit_file.',
    props: { path: str('File path'), content: str('New content'), append: { type: 'boolean' }, base64: { type: 'boolean', description: 'content is base64 (binary files)' } }, required: ['path', 'content'] },
  { name: 'edit_file', agent: true, description: 'Change part of a text file: replace the exact text old with new. Fails if old is not found or found more than once (add surrounding lines, or all=true). Keeps the encoding, BOM and line endings. Much cheaper and safer than rewriting the file or using sed / PowerShell replace.',
    props: { path: str('File path'), old: str('exact text to replace (copy it from read_file)'), new: str('replacement'), all: { type: 'boolean', description: 'replace every occurrence' } }, required: ['path', 'old', 'new'] },
  { name: 'push_file', agent: true, ms: (a) => 3_700_000, description: 'Send a file to the remote PC: download url (any http link, or a link of a file the operator uploaded in the live view) to path on the remote PC.',
    props: { url: str('http(s) link'), path: str('where to save it on the remote PC (full file path)') }, required: ['url', 'path'] },
  { name: 'tree', agent: true, description: 'Folder tree in one call: folders with their item count, files with size, a few levels deep. Much cheaper than list_dir over and over.',
    props: { path: str('Folder'), depth: { type: 'integer', minimum: 1, maximum: 6, description: 'default 2' }, pattern: str('only files matching this glob, e.g. *.log'), max: { type: 'integer', minimum: 10, maximum: 3000, description: 'lines, default 300' } }, required: ['path'] },
  { name: 'fsop', agent: true, ms: (a) => 300_000, description: 'File operations without shell quoting: mkdir, newfile, copy / move (path -> dest; a folder dest receives the item), rename (path, name), delete (to the Recycle Bin on Windows; permanent:true deletes for good), stat, preview (the start of a text file, a hex dump of a binary, the entries of a zip, a small picture).',
    props: { op: { type: 'string', enum: ['mkdir', 'newfile', 'copy', 'move', 'rename', 'delete', 'stat', 'preview'] }, path: str('item'), dest: str('destination file or folder (copy, move)'), name: str('new name (rename)'), overwrite: { type: 'boolean' }, permanent: { type: 'boolean', description: 'delete: skip the Recycle Bin' } }, required: ['op', 'path'] },
  { name: 'find', agent: true, ms: (a) => 60_000, description: 'Find files by name (glob) and/or by content (regex, case-insensitive): answers path (and size) or path:line: text. Skips .git / node_modules, binary files and files over 5 MB when searching content.',
    props: { path: str('Folder to search'), name: str('file name glob, e.g. *.json or config*'), text: str('regex to search inside files'), max: { type: 'integer', minimum: 1, maximum: 1000, description: 'results, default 100' }, depth: { type: 'integer', minimum: 1, maximum: 50 } }, required: ['path'] },
  { name: 'system', agent: true, ms: (a) => 90_000, description: 'The state of the machine in one call, compact. Sections: overview (OS, uptime, CPU, RAM), disks, processes (top by CPU and RAM), network (EVERY adapter: type, speed, IP, gateway, DNS, MAC, which one is the default route and which one the agent uses), reach (tests each adapter against the relay, lists VPN / DPI-bypass / proxy programs and network filter drivers, proxies, hosts file), connections (TCP connections per process), services (stopped auto-start services / failed units), startup (programs that start with the system), apps (installed programs), events (recent system errors). Default: overview, disks, processes, network.',
    props: { sections: { type: 'array', items: { type: 'string', enum: ['overview', 'disks', 'processes', 'network', 'services', 'startup', 'apps', 'drivers', 'events', 'reach', 'connections', 'perf', 'policy', 'activation', 'health', 'process'] } }, pid: { type: 'integer', description: 'for section process: one process in detail (path, command line, parent chain, publisher, signature, hash, services, autostart entries, connections)' }, top: { type: 'integer', minimum: 3, maximum: 60, description: 'processes / events to show, default 15' } } },
  { name: 'util', agent: true, ms: (a) => (/install|download|zip/.test(a.op) ? 1_900_000 : 120_000),
    description: 'Ready-made, tested operations: right on the first try, no quoting. op: apps (search installed programs: name), install / uninstall (winget / apt id or name), kill (name or pid, whole process tree), service (name, value=start|stop|restart|status), env_get (name; empty = all), env_set (name, value; user scope), path_add (path; user PATH, no setx truncation), reg_get / reg_set (path = HKCU\\..., name, value), reg_find (path = root like HKLM\\SOFTWARE, name = text, value = key|value|data, max; Windows), crash (name = program or empty, value = days: why it died, from the event log: faulting module, exception code, full exe path, the events just before, dump files; Windows), recent (name = filter, value = days: what ran and when, from UserAssist / BAM / Prefetch and recent files; Windows), ffind (instant file search on ALL NTFS disks at once from the file table: name = text or glob like *.log, path = limit to a folder or disk like D:\\Games, value = new to list the newest first, max; needs administrator, else use find; Windows), elevate (restart the helper as administrator: the friend accepts one Windows prompt, the session continues; Windows), browser (extensions of Chrome / Edge / Brave / Opera / Yandex / Firefox per profile: on/off, size, what they can read, heaviest first, plus memory of the browser processes by kind; max; Windows), bsod (blue screens: bugcheck code and parameters read from the dump with what the code usually means, the events 15 minutes before; exact driver when cdb is installed; value = days; Windows), health (a quick check from logs and counters, under 10 s: name = boot | disks | heat | drivers, empty = all: boot time and what slowed it, SMART and disk errors, free space, CPU / GPU throttling, GPU driver resets, broken devices, failed updates, WHEA hardware errors; Windows), threats (read-only facts for a suspected infection, nothing is guessed from file names: what the antivirus found and whether it removed it, whether its protection was switched off, its exclusions (a whole drive excluded is flagged), remote / network logins and failed-password bursts, Remote Desktop on, services and scheduled tasks installed lately; value = days, default 14; the security log and exclusions need administrator; Windows), appinfo (what Windows knows by a program name, a part of a window title or a pid: running processes with exe path, full command line, version, publisher; Start menu shortcuts with target and arguments; App Paths; Store apps with their AUMID; the PATH; Windows), launch (start a program by its name, a path, a Start menu shortcut or a Store app, with args: [..] passed exactly; name = program or path; Windows), open (url or path with the default app), clipboard_get / clipboard_set (value), dns_flush, net_test (host, port: DNS + TCP check), ports (name = port number: who listens), download (url -> path, resumes), zip (path -> dest), unzip (path -> dest), shortcut (path = target, dest = .lnk file).',
    props: { op: { type: 'string', enum: ['apps', 'install', 'uninstall', 'kill', 'service', 'env_get', 'env_set', 'path_add', 'reg_get', 'reg_set', 'reg_find', 'crash', 'recent', 'ffind', 'elevate', 'browser', 'bsod', 'health', 'threats', 'appinfo', 'launch', 'open', 'clipboard_get', 'clipboard_set', 'dns_flush', 'net_test', 'ports', 'download', 'zip', 'unzip', 'shortcut'] },
      name: str('program / service / variable / value name, process name or pid, port'), value: str('value / action'), path: str('file, folder or registry path'), dest: str('destination'), url: str('link'), host: str('host for net_test'), port: { type: 'integer' }, args: { type: 'array', items: { type: 'string' }, description: 'launch: arguments' }, max: { type: 'integer' } }, required: ['op'] },
  { name: 'list_dir', agent: true, description: 'List a directory (name, type, size, modified).', props: { path: str('Directory path') }, required: ['path'] },
  { name: 'click', agent: true, description: 'Move the mouse to (x,y) in screenshot coordinates and click.',
    props: { x: num('x'), y: num('y'), button: { type: 'string', enum: ['left', 'right', 'middle'] }, double: { type: 'boolean' } }, required: ['x', 'y'] },
  { name: 'ui_tree', agent: true, ms: (a) => 30_000, description: 'The controls of a window as TEXT, one line each: [id] type "name" =value @x,y flags. Much cheaper (tens of tokens instead of a picture) and exact: read it first, then act with ui_click / ui_set by id or by name. Default: the window in front; window = part of a title or process name picks another. query keeps only lines with that text. x,y are screenshot pixels (the centre), so click {x,y} still works as a fallback. In a window that shows no controls (a game, a custom-drawn or administrator window) Windows (built-in OCR) and Linux (when tesseract is installed) also read the visible text from the picture (ocr lines with x,y; ui_click with that text presses it); elsewhere, or if that finds nothing, use screenshot. Windows, Linux (AT-SPI) and Android.',
    props: { window: str('part of the window title or process name (default: the window in front)'), query: str('keep only controls whose name, value or id contains this text'), max: { type: 'integer', minimum: 10, maximum: 400, description: 'default 120' }, all: { type: 'boolean', description: 'also list plain labels and unnamed containers (default: only controls and named text)' } } },
  { name: 'ui_click', agent: true, ms: (a) => 40_000, description: 'Press a control through the system (Invoke / Toggle / Select / click action), no mouse movement guessing: by id from the last ui_tree, or by name (+ type) in the window in front. Several matches: the answer lists them with ids, repeat with id. Falls back to a real click at the control centre when the control has no action, and on Windows / Linux (with tesseract) to text found on the screen by OCR when no control has that name. Reports what changed on the screen. Use it instead of click whenever ui_tree shows the control.',
    props: { id: { type: 'integer', description: 'id from the last ui_tree' }, name: str('control name (exact, then starts-with, then contains; any case)'), type: str('button, edit, check, combo, link, menuitem, tab, listitem, ... (narrows a name)'), window: str('part of the window title or process name'), double: { type: 'boolean' }, right: { type: 'boolean', description: 'right click / long press' } } },
  { name: 'ui_set', agent: true, ms: (a) => 40_000, description: 'Put text into an edit control or choose a value (combo box / slider) directly, by id from the last ui_tree or by name: replaces the content, no typing, no focus tricks, works for any text length. Reports the value read back.',
    props: { id: { type: 'integer', description: 'id from the last ui_tree' }, name: str('control name'), value: str('the text / value to set'), window: str('part of the window title or process name') }, required: ['value'] },
  { name: 'focus_window', agent: true, description: 'Bring a window to the front by a part of its title or by its process name, through the system (no clicking). Use it before typing or pressing keys whenever the right window may not have the focus: safer than clicking on the window. Without arguments it lists the open windows.',
    props: { title: str('part of the window title, any case'), process: str('process name, e.g. notepad, chrome, telegram') } },
  { name: 'trace', agent: true, description: 'Read along: the pointer goes to (x,y) and slides slowly under a line of text to (x2,y2), no click, like a person following text with the cursor. Use it whenever you read something on the screen or point the user at an important detail, so they see what you are looking at.',
    props: { x: { type: 'number' }, y: { type: 'number' }, x2: { type: 'number' }, y2: { type: 'number' } }, required: ['x', 'y', 'x2', 'y2'] },
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
      const l = makeViewer(c);
      return { text: `Watch (view only, safe to share): ${l.watch}\nControl (click, drag, scroll, type, take over from the helper; keep it private): ${l.control}` };
    } },
  { name: 'end_session', description: 'Disconnect the agent and forget the session.', props: {}, session: true,
    run: async (code) => { await call(code, 'bye').catch(() => {}); drop(code.toUpperCase(), 'Session ended by operator.'); return { text: 'ended' }; } },
];
const byName = new Map(tools.map((t) => [t.name, t]));

// ---- error hints: a failed command gets one line of advice (relay/hints.json), and the failure goes to the mistake log so the same trap is visible next time
const HINTS = (() => { try { return JSON.parse(fs.readFileSync(path.join(here, 'hints.json'), 'utf8')).map((h) => ({ ...h, rx: new RegExp(h.re, 'im') })); } catch { return []; } })();
const HINT_TOOLS = new Set(['run', 'util', 'start_process', 'edit_file', 'push_file', 'fetch_file', 'read_file', 'write_file', 'mcp_start', 'tree', 'find']);
function hintFor(s, code, tool, args, textOut, failed) {
  if (!HINT_TOOLS.has(tool)) return '';
  const ex = /^\[exit (-?\d+)\]/.exec(textOut); if (ex && ex[1] !== '0') failed = true;
  if (/^\[timeout after/.test(textOut)) failed = true;
  if (!failed) return '';
  const h = HINTS.find((x) => x.rx.test(textOut)); if (!h) return '';
  if (s) {
    s.hinted = s.hinted || {};
    if (!s.hinted[h.id] || Date.now() - s.hinted[h.id] > 120_000) {
      s.hinted[h.id] = Date.now();
      recordMiss(s, code, 'auto', { tool, hint: h.id, what: String(args.command || args.op || args.path || '').slice(0, 200), error: textOut.replace(/\s+/g, ' ').slice(0, 300) });
    }
  }
  return 'HINT: ' + h.hint;
}
// the first sysinfo of a session: the traps this kind of system had before (from the mistake log)
function pitfalls(s) {
  const fam = (x) => (/android/i.test(x) ? 'android' : /windows/i.test(x) ? 'windows' : 'linux');
  const mine = fam(s.info?.os || '');
  let L = []; try { L = fs.readFileSync(MISS_FILE, 'utf8').trim().split('\n').slice(-500).map((l) => { try { return JSON.parse(l); } catch { return null; } }).filter((e) => e && fam(e.device || '') === mine); } catch { return ''; }
  const n = {}; for (const e of L) if (e.kind === 'auto' && e.hint) n[e.hint] = (n[e.hint] || 0) + 1;
  const top = Object.entries(n).sort((a, b) => b[1] - a[1]).slice(0, 5).map(([id, k]) => `- (${k}x) ${HINTS.find((h) => h.id === id)?.hint || id}`);
  const rep = L.filter((e) => e.kind === 'reported' && e.fixed_by).slice(-3).map((e) => `- wanted "${e.wanted}", ${e.happened}; worked: ${e.fixed_by}`);
  return top.length || rep.length ? `\nKnown pitfalls on ${mine} machines (from earlier sessions):\n` + [...top, ...rep].join('\n') : '';
}

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
1. Look first: sysinfo, then screenshot (what the user sees). RULE: the moment you start working on a session, open the live view for the operator (the first answer of a session carries its link; open_viewer gives a new one) and give the operator the Control link at once; if you can run commands on the operator's own machine, open it in their browser (Windows: start "" "<link>"; macOS: open; Linux: xdg-open). Then set_look: a colour you like (once) and a short note of what you are doing; keep the note current.
2. Need an application or MCP server (Blender, Unity, Substance, a browser, ...)? First call recipe (no name = list; "blender" and the generic "any-app" exist). Check whether it is installed (run: Get-Command / where / which / winget list / registry / apt), install it if missing (winget install -e --id ..., apt/flatpak; an installer that needs administrator rights shows a UAC prompt the user must accept: tell them), then continue.
3. GUI apps and anything long-lived: start_process (detached, keeps running). Do not use run for them.
4. MCP servers: mcp_start (command npx / uvx / python / an exe). Portable Node and uv are fetched automatically when missing. command="playwright" opens a real visible browser with sound. Then mcp_call (or <server>__<tool> on /s/<code>/mcp). Prefer a dedicated MCP server over clicking the GUI.
5. Operations that take longer than ~45 s return "Still running (job X)": call wait_job with that id. Raise timeout_s on mcp_start / mcp_call / run for installs and renders.
6. The network may be slow: take screenshots only when needed (monitor=N crops to one screen), avoid huge command output.
7. The user watches the screen: make your work visible. Do windowing with the mouse (drag a title bar to move a window, drag an edge or corner to resize, click the minimise / maximise / close buttons, click taskbar icons to open or hide an app) instead of keyboard shortcuts or commands when a mouse action exists. When you read something on the screen, use trace under the line you are reading (x,y = start of the text, x2,y2 = its end, a few px below the baseline), and move to point at important details before you act on them: the user sees what you are looking at. Skip this for background work (files, commands, MCP calls).
8. Talk to the user while you work. At the start say whether the connection worked (list_sessions, sysinfo) and that the friend can end the session at any time with Esc. Before a group of actions say in one short line what you are going to do, afterwards whether it worked. Bundle small GUI steps (move + click, click + type, drag, scroll) into ONE actions call so the friend confirms once instead of per step. If any call comes back "ended", "denied", "Agent left" or "No such session": stop, do not retry, tell the operator.
9. The session survives internet loss, VPN changes and reboots (the user chose to keep it): it comes back by itself with the same code. If a call says the PC is offline or paused, do not start over: wait_online, then read session_log (it holds the network diagnosis and what the agent already tried) and agent_log, and continue where you stopped. Only the user ending the session in their console ends it.
10. Android phones (os "Android ..."): ui_tree (the screen's controls as text), ui_click and ui_set by name or id (use these first, a screenshot only when ui_tree finds nothing), screenshot, click (a tap; button=right is a long press), drag (a swipe; hold=true for drag and drop), scroll, type_text (into the focused field: tap it first), press_key (home, back, recents, notifications, quick_settings, enter, backspace, volume_up, volume_down, power, lock, screenshot), start_process (command = app name, package or link), actions, sysinfo. Also, without tapping: system {sections} (overview with battery and RAM, disks, network with VPN / private DNS, apps = installed apps newest first with ! on anything not from a store or holding accessibility / device-admin / draw-over-apps power, services = which apps have accessibility, device admin and notification access, processes = apps used in the last 24 h), tree / find / list_dir / read_file / edit_file / write_file / push_file / fetch_file over the phone storage (the friend must allow file access once: if it is missing the tool opens that screen itself and says so), and util {op: apps (search by name), kill (background apps), uninstall (opens the app page: tap Uninstall), open (a link, an app, or name "settings:wifi|usage|files|accessibility|apps|battery|storage|security|admin|notifications|overlay|app:<package>"), clipboard_set, net_test, download, zip, unzip}. Use these first to check what the friend says (is the app installed, is a VPN on, what is full) instead of clicking through Settings. There is no shell and no MCP bridge. Coordinates are screenshot pixels; the friend can end the session by tapping the label at the top of the screen.
11. This is the user's real machine: only touch what the task needs, and say what you installed or changed.
12. If you tapped or opened the wrong thing and had to redo it, call report_miss (what you wanted, what happened, what worked). A tap result starting with MISS means nothing tappable was under the finger: read the hint and tap the suggested spot. When the job is finished call task_done. If you must stop for a while (token or rate limit, a long break) call hold first, so the phone stays awake and the session stays open. On a phone you may also call set_look once at the start (a colour you like) and keep its note line current.
13. Work in stages: when you know the steps, call plan (titles + a colour per stage) and set_look {stage} as you move on; keep set_look {note} current.
14. Save tokens and time: do not take a screenshot after every step. Every click, typing and key press reports what changed on the screen; trust it. Take a screenshot when you need to see something new; use region to read small things; an unchanged screen costs one line. Use watch when something happens over time.
15. Stop at the first sign of trouble: if an action reports NO CHANGE (typing that did not appear, a click on nothing), do not continue the plan; look (screenshot or watch), find out why, fix it, then continue.
16. Before typing or pressing keys, make sure the right window has the focus: focus_window is safer than clicking on the window.
16b. Look with ui_tree, not with pictures: it lists the window's controls as a few lines of text (name, value, state, position), exact and about 20 times cheaper than a screenshot. Then press with ui_click and fill with ui_set (by id or name): no coordinates to guess, no layout or DPI problems, and it works on a phone too. Use screenshot only when ui_tree finds nothing (games, custom-drawn or administrator windows) or when you need to see the picture itself; click {x,y} stays the fallback. Prefer a dedicated MCP server (mcp_start / recipe) or a command for the app over clicking at all when one exists.
17. Files and system state without shell one-liners: tree (folders in one call), find (by name and content), read_file with offset/lines/tail (only what you need), edit_file (exact replace, never rewrite a whole file to change a line), push_file (send a file to the PC), fetch_file (a file or folder to the operator), util (install, kill, services, PATH / env, registry, clipboard, network test, ports, download, zip, open, shortcut). They are faster, cheaper and right on the first try.
17b. Speed with the screen: do not loop action -> screenshot -> think. Put several steps in ONE actions call, add shot:true to the action that needs a look at the result (the picture comes back in the same answer, an unchanged screen costs a line), and after something slow starts (a click that loads a page, an installer) call wait_screen (it returns one picture when the screen has changed and settled, or text if nothing moved). Never take screenshots in a loop to wait.
17a. Slow PC / what eats CPU, RAM or disk / anything malicious: ONE call to system {sections:["processes"]} lists every process with its real CPU %, memory, the exe path and who signed it, and marks with ! anything run from a temp or download folder or unsigned outside the normal install dirs. system {} also gives disks, network and startup; add "drivers" and "services". Kill a bad one with util {op:"kill"} and delete its file. sysinfo and system cost tens of ms now: prefer them to a handful of run commands. Network problems on a PC (cuts, slow, a VPN / zapret / proxy in the way): system {sections:["reach"]} lists every adapter with its type, IP, gateway, DNS, which one is the default route, which one the agent talks through, whether each reaches the relay, plus the VPN / DPI-bypass programs, network filter drivers, proxies and hosts entries; {sections:["connections"]} shows who talks to whom. The agent keeps its own link alive by itself (it moves to another adapter when the current route dies, VPN adapters last) and logs every switch.
18. No quoting traps: to start a program with arguments use run {command: "program", args: [...]} (no shell, each argument arrives exactly as given). For a longer script use write_file, then run the file. A failed command may come back with a HINT line: follow it instead of retrying the same thing.`;

function buildMcp(fixed) {
  const m = new Server({ name: 'helpermcp', version: '0.4.0' }, { capabilities: { tools: {} }, instructions: INSTRUCTIONS });
  const sessionProp = { session: str("Session code shown on the user's screen, e.g. K7M2-QX9P") };

  const SHOT_PROP = { shot: { type: 'boolean', description: 'also return the screen as it is after this action (one call instead of action + screenshot)' } };
  m.setRequestHandler(ListToolsRequestSchema, async () => {
    const list = tools
      .filter((t) => !(fixed && t.local && !t.always))
      .map((t) => {
        const needsSession = (t.agent || t.session) && !fixed;
        return {
          name: t.name, description: t.description,
          inputSchema: {
            type: 'object',
            properties: { ...(needsSession ? sessionProp : {}), ...t.props, ...(SHOT_TOOLS.has(t.name) ? SHOT_PROP : {}) },
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
      const wantShot = SHOT_TOOLS.has(name) && a.shot; delete a.shot;
      const out = fmt(t.run ? await t.run(session, a) : name === 'screenshot' ? await aiShot(session, a) : await callJob(session, name, a, t.ms?.(a)));
      if (wantShot) { try { out.content.push(...fmt(await aiShot(session, {})).content); } catch (e) { out.content.push({ type: 'text', text: 'screen after: ' + e.message }); } }
      const sx = sessions.get(String(session).toUpperCase());
      const first = out.content[0]?.type === 'text' ? out.content[0].text : '';
      const hint = hintFor(sx, String(session).toUpperCase(), name, a, first, false);
      if (hint) out.content.push({ type: 'text', text: hint });
      if (name === 'sysinfo' && sx && !sx.pitfallsShown) { sx.pitfallsShown = true; const pf = pitfalls(sx); if (pf) out.content.push({ type: 'text', text: pf }); }
      if (sx?.uploads?.length) { out.content.push({ type: 'text', text: 'The operator put these files on the remote PC from the live view: ' + sx.uploads.splice(0).join('; ') }); }
      if (sx && !sx.viewerShown && name !== 'open_viewer' && name !== 'end_session') {   // the first answer carries the live view: the operator gets it right away
        sx.viewerShown = true; const l = makeViewer(String(session).toUpperCase());
        out.content.push({ type: 'text', text: `LIVE VIEW of this session for the operator: open it in their browser now if you can run commands on their machine (Windows: start "" "${l.control}"; macOS: open; Linux: xdg-open), otherwise give them this link at once: ${l.control}` });
      }
      return out;
    } catch (e) {
      const code = String(fixed || params.arguments?.session || '').toUpperCase();
      const hint = hintFor(sessions.get(code), code, name, params.arguments || {}, e.message, true);
      return { isError: true, content: [{ type: 'text', text: e.message + (hint ? '\n' + hint : '') }] };
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
<ol><li data-i="a1">Scan the code with the phone camera, or open the link, and download the app.</li><li data-i="a2">Allow the install and open <b>HelperMCP</b>. If Google warns about a dangerous app, tap <b>More details</b> → <b>Install anyway</b> (not Cancel). Android 11 or newer.</li><li data-i="a3">Tap <b>Allow control</b>, switch HelperMCP on, then tap <b>Start help</b>.</li></ol>
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
  const android = s && /android/i.test(s.info?.os || '') ? 1 : 0;
  const esc = (x) => x.replace(/&/g, '&amp;').replace(/</g, '&lt;');
  return `<!doctype html><html lang=en><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1"><meta name=color-scheme content=dark><link rel=icon type=image/svg+xml href=/logo.svg><title>Remote screen ${esc(who)}</title>
<style>
:root{--bg:#020a06;--panel:#07140c;--panel2:#0a1d12;--line:#16482b;--line2:#2bb55a;--g:#38ff7a;--fg:#d6ffe4;--mut:#7fae8f;--warn:#ffd166;--hot:#ff8a1e;--st:#38ff7a;--kb:0px}
*{box-sizing:border-box}
html,body{margin:0;height:100%;background:var(--bg);color:var(--fg);font:13px/1.5 ui-monospace,"Cascadia Code","Cascadia Mono",Consolas,"SF Mono",Menlo,monospace}
body:before{content:"";position:fixed;inset:0;pointer-events:none;background:repeating-linear-gradient(0deg,rgba(56,255,122,.03) 0 1px,transparent 1px 3px);z-index:9}
button,select,input{font:inherit;color:var(--fg);background:var(--panel2);border:1px solid var(--line);border-radius:5px;padding:.3rem .65rem}
button{cursor:pointer;transition:border-color .15s,box-shadow .15s}button:hover{border-color:var(--line2);box-shadow:0 0 12px rgba(56,255,122,.15)}
button:focus-visible,select:focus-visible,input:focus-visible{outline:2px solid var(--g);outline-offset:1px}
#top{height:44px;display:flex;align-items:center;gap:.7rem;padding:0 .9rem;border-bottom:1px solid var(--line);background:linear-gradient(180deg,var(--panel2),var(--panel))}
#dot{width:9px;height:9px;border-radius:50%;background:var(--mut);flex:none}#dot.on{background:var(--g);box-shadow:0 0 10px var(--g)}#dot.bad{background:var(--hot);box-shadow:0 0 10px var(--hot)}
#st{color:var(--g);white-space:nowrap}#who{color:var(--mut);overflow:hidden;text-overflow:ellipsis;white-space:nowrap;flex:1;min-width:0}
#ctl{color:#00150a;background:var(--g);border-color:var(--g);font-weight:600}#ctl.on{background:var(--warn);border-color:var(--warn)}
#main{display:grid;grid-template-columns:minmax(0,1fr) 300px;height:calc(100% - 44px - var(--kb))}
#scr{position:relative;display:flex;align-items:center;justify-content:center;min-width:0;min-height:0;padding:14px}
#frame{position:relative;max-width:100%;max-height:100%;display:flex}
#frame:before,#frame:after,#frame i:before,#frame i:after{content:"";position:absolute;width:22px;height:22px;border:2px solid var(--st);transition:border-color .6s}
#frame:before{left:-8px;top:-8px;border-right:0;border-bottom:0}#frame:after{right:-8px;bottom:-8px;border-left:0;border-top:0}
#frame i:before{right:-8px;top:-8px;border-left:0;border-bottom:0}#frame i:after{left:-8px;bottom:-8px;border-right:0;border-top:0}
#cv{max-width:100%;max-height:calc(100vh - 44px - var(--kb) - 28px);background:#000;box-shadow:0 0 0 1px var(--line),0 0 40px rgba(0,0,0,.6);display:block}
#cv{transition:none}#cv.pan{cursor:grab}#zr{padding:.3rem .55rem}#cv.ctl{cursor:crosshair;box-shadow:0 0 0 2px var(--warn),0 0 30px rgba(255,209,102,.18)}
#tag{position:absolute;left:14px;top:12px;color:var(--warn);background:rgba(2,10,6,.85);border:1px solid var(--warn);border-radius:4px;padding:.1rem .5rem;display:none}
#side{border-left:1px solid var(--line);background:var(--panel);display:flex;flex-direction:column;min-height:0}
#side h2{margin:0;padding:.65rem .9rem .35rem;font-size:12px;font-weight:600;color:var(--mut)}
#note{margin:0 .9rem .6rem;padding:.55rem .7rem;border-left:2px solid var(--st);background:rgba(56,255,122,.04);color:var(--fg);min-height:2.4em;transition:border-color .6s}
#note:empty:before{content:attr(data-empty);color:var(--mut)}
#plan{list-style:none;margin:0;padding:0 .9rem .7rem;counter-reset:s}
#plan li{counter-increment:s;position:relative;padding:.28rem 0 .28rem 2rem;color:var(--mut)}
#plan li:before{content:counter(s);position:absolute;left:0;top:.3rem;width:1.35rem;height:1.35rem;border:1px solid var(--c,var(--line2));border-radius:50%;display:grid;place-items:center;font-size:11px;color:var(--c,var(--g))}
#plan li.done{color:var(--mut);text-decoration:line-through;text-decoration-color:rgba(127,174,143,.5)}#plan li.done:before{content:"\\2713"}
#plan li.cur{color:var(--fg)}#plan li.cur:before{background:var(--c,var(--g));color:#00150a;box-shadow:0 0 12px var(--c,var(--g))}
#plan:empty{display:none}
#sys{border-top:1px solid var(--line);padding:0 .9rem .5rem}#sys[hidden]{display:none}
.bar{height:6px;border-radius:3px;background:#0b2415;overflow:hidden;margin:.15rem 0 .4rem}.bar i{display:block;height:100%;background:var(--g);transition:width .5s}.bar i.hot{background:var(--hot)}
#sg{display:flex;justify-content:space-between;color:var(--mut);font-size:12px}#sg b{color:var(--fg);font-weight:500}
#sp{font-size:12px;max-height:30vh;overflow:auto}#sp div{display:grid;grid-template-columns:3.4rem 4.6rem 1fr auto;gap:.4rem;padding:1px 0;align-items:center}#sp div:hover{background:rgba(56,255,122,.06)}
#sp span{overflow:hidden;text-overflow:ellipsis;white-space:nowrap}#sp .w{color:var(--hot)}#sp .x{padding:0 .4rem;border-color:var(--line);color:var(--mut)}#sp .x:hover{color:var(--hot);border-color:var(--hot)}
#mons{display:flex;gap:.3rem;align-items:center}#mons button{padding:.15rem .4rem;line-height:1.1;font-size:11px;display:flex;flex-direction:column;align-items:center;gap:1px}
#mons button.on{border-color:var(--g);box-shadow:0 0 10px rgba(56,255,122,.25);color:var(--g)}#mons button u{display:block;border:1px solid currentColor;text-decoration:none;opacity:.8}
#files{border-top:1px solid var(--line);padding:0 .9rem .6rem}#files[hidden]{display:none}
#fbar{display:flex;gap:.35rem;margin-bottom:.35rem}#fbar input{flex:1;min-width:0;padding:.2rem .45rem;font-size:12px}#fbar button{padding:.2rem .55rem}
#fl{max-height:34vh;overflow:auto;font-size:12px}#fl div{display:flex;gap:.6rem;padding:2px .3rem;border-radius:3px;cursor:pointer;white-space:nowrap}#fl div:hover{background:rgba(56,255,122,.08)}
#fl b{font-weight:500;color:var(--g);overflow:hidden;text-overflow:ellipsis;flex:1}#fl span{flex:1;overflow:hidden;text-overflow:ellipsis}#fl i{font-style:normal;color:var(--mut)}
#fmsg{color:var(--mut);font-size:12px;padding-top:.3rem}body.drop #files{outline:2px dashed var(--warn);outline-offset:-2px}
#log{flex:1;overflow:auto;border-top:1px solid var(--line);padding:.5rem .9rem;font-size:12px}
#log div{padding:1px 0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}#log b{color:var(--g);font-weight:500}#log i{color:#3f6b50;font-style:normal}#log div:before{content:"$ ";color:#3f6b50}
#kb{position:fixed;left:0;right:0;bottom:0;display:none;gap:.35rem;padding:.5rem .7rem;background:var(--panel2);border-top:1px solid var(--warn);align-items:center;flex-wrap:wrap}
#kb label{color:var(--warn)}#kb input{flex:1;min-width:10rem;background:#010603;border-color:var(--line2)}
@media(max-width:820px){#main{display:block;height:auto}#scr{height:60vh}#cv{max-height:calc(60vh - 28px)}#side{border-left:0;border-top:1px solid var(--line)}#log{max-height:30vh}#who{display:none}}
@media(prefers-reduced-motion:reduce){*{transition:none!important}}
</style>
<div id=top><span id=dot></span><span id=st>…</span><span id=who>${esc(who)}</span>
<div id=mons></div>
<button id=zr title="1:1" style="display:none">1:1</button><button id=ctl hidden></button><button id=disc></button></div>
<div id=main><div id=scr><div id=frame><i></i><canvas id=cv width=16 height=9></canvas></div><div id=tag></div></div>
<aside id=side><h2 id=hNote></h2><div id=note></div><h2 id=hPlan hidden></h2><ol id=plan></ol>
<section id=sys hidden><h2 id=hSys style="padding-left:0"></h2><div id=sg></div><div class=bar><i id=bc></i></div><div class=bar><i id=bm></i></div><div id=sp></div></section>
<div id=log></div></aside></div>
<div id=kb><label for=txt>$</label><input id=txt autocomplete=off><button id=send></button><button data-k=enter>Enter</button><button data-k=backspace>&#9003;</button><button data-k=tab>Tab</button><button data-k=esc>Esc</button><button data-k=left>&larr;</button><button data-k=up>&uarr;</button><button data-k=down>&darr;</button><button data-k=right>&rarr;</button>${android ? '<button data-k=back>Back</button><button data-k=home>Home</button><button data-k=recents>Recents</button>' : ''}</div>
<script>
const ru=(navigator.language||'').startsWith('ru'),L=ru?{live:'в эфире',wait:'жду кадр…',end:'сеанс завершён',off:'устройство не на связи',paused:'пауза на устройстве',take:'Управлять самому',give:'Вернуть помощнику',tag:'управляете вы, помощник ждёт',send:'Ввести',ph:'текст: Enter — ввести и нажать Enter',note:'Что делает помощник',noNote:'помощник ещё ничего не написал',plan:'План',over:'вы управляете'}:{live:'live',wait:'waiting for a frame…',end:'session ended',off:'device offline',paused:'paused on the device',take:'Take control',give:'Give back to the helper',tag:'you are driving, the helper waits',send:'Type',ph:'text: Enter types it and presses Enter',note:'What the helper is doing',noNote:'nothing from the helper yet',plan:'Plan',over:'you are driving'};
const $=id=>document.getElementById(id),dot=$('dot'),st=$('st'),cv=$('cv'),g=cv.getContext('2d'),log=$('log'),kb=$('kb'),txt=$('txt');
$('hNote').textContent=L.note;$('note').dataset.empty=L.noNote;$('hPlan').textContent=L.plan;
const base=location.pathname.split('/').slice(0,3).join('/');   // /v/<token>: the link has no trailing slash, so a relative URL would resolve to /v/frame
const CTL=(location.hash.match(/c=([0-9a-f]+)/)||[])[1]||'';   // the control secret lives in the #fragment: it never reaches a server log
let ended=false,control=false,meta={ox:0,oy:0,sc:1},seq=0,shown=0,mon='';

function status(t,cls){st.textContent=t;dot.className=cls||''}
async function fetchFrame(my){try{const r=await fetch(base+'/frame?mon='+mon+'&_='+Date.now());
 if(r.status===410){ended=true;return}
 if(r.status===204){status(L.live,'on');await new Promise(x=>setTimeout(x,250));return}
 if(r.ok){const b=await r.blob();const bmp=await createImageBitmap(b);
  if(my>shown){shown=my;if(cv.width!==bmp.width||cv.height!==bmp.height){cv.width=bmp.width;cv.height=bmp.height}g.drawImage(bmp,0,0);
   meta={ox:+r.headers.get('x-ox')||0,oy:+r.headers.get('x-oy')||0,sc:+r.headers.get('x-sc')||1};status(L.live+'  '+Math.round(b.size/1024)+' KB','on')}
  bmp.close()}
 else{let m='';try{m=(await r.json()).error||''}catch(_){}status(/offline|away|reboot/i.test(m)?L.off:/PAUSED/.test(m)?L.paused:L.wait,'bad');await new Promise(x=>setTimeout(x,1200))}}
 catch(e){status(L.wait,'bad');await new Promise(x=>setTimeout(x,1500))}}
async function lane(){while(!ended){await fetchFrame(++seq);await new Promise(x=>setTimeout(x,10))}status(L.end,'')}
// the live stream: one long download of frames (full pictures, changed tiles, or H.264 video); pictures one by one only if the agent cannot stream
let gone=false,abort=null,noLive=false,gotEver=false,frames=0,bytes=0,dec=null,chain=Promise.resolve();
const sleep=ms=>new Promise(x=>setTimeout(x,ms)),td=new TextDecoder();
setInterval(()=>{if(gotEver&&!noLive&&(frames||dot.className==='on'))status(L.live+'  '+frames+' fps  '+Math.round(bytes/1024)+' KB/s','on');frames=0;bytes=0},1000);   // 0 fps when the screen is still: never a number from seconds ago
const jpeg=b=>createImageBitmap(new Blob([b],{type:'image/jpeg'}));
function size(w,h){if(cv.width!==w||cv.height!==h){cv.width=w;cv.height=h}}
const fmtB=n=>n>=1073741824?(n/1073741824).toFixed(1)+'G':n>=1048576?Math.round(n/1048576)+'M':Math.round(n/1024)+'K';
function sysPanel(j){$('sys').hidden=false;$('hSys').textContent=ru?'Система':'System';
 $('sg').innerHTML=(j.cpu>=0?'<span>CPU <b>'+j.cpu+'%</b></span>':'')+'<span>RAM <b>'+j.mem+'%</b> ('+fmtB(j.ramTotal-j.ramFree)+' / '+fmtB(j.ramTotal)+')</span>'+(j.x?'':'<span>'+j.n+'</span>');
 const c=$('bc'),m=$('bm');c.parentNode.style.display=j.cpu>=0?'':'none';c.style.width=Math.max(0,j.cpu)+'%';c.className=j.cpu>85?'hot':'';m.style.width=j.mem+'%';m.className=j.mem>90?'hot':'';
 const sp=$('sp');sp.textContent='';if(j.x){const d=document.createElement('div');d.style.display='block';d.style.color='var(--mut)';d.textContent=j.x;sp.append(d)}
 for(const r of j.p){const d=document.createElement('div'),a=document.createElement('span'),b=document.createElement('span'),n=document.createElement('span');
  a.textContent=r[2]<0?'':r[2].toFixed(1)+'%';b.textContent=r[3]>0?fmtB(r[3]):'';n.textContent=r[1]+(r[4]?'  ['+r[4]+']':'');n.title=r[5]||'';if(r[6]==='!')n.className='w',n.textContent='! '+n.textContent;
  d.append(a,b,n);
  if(CTL&&r[0]>4){const x=document.createElement('button');x.className='x';x.textContent='\u00d7';x.title=ru?'завершить процесс':'end process';
   x.onclick=async()=>{if(!confirm((ru?'Завершить ':'End ')+r[1]+' (pid '+r[0]+')?'))return;x.disabled=true;
    try{const q=await fetch(base+'/kill',{method:'POST',headers:{'content-type':'application/json','x-ctl':CTL},body:JSON.stringify({pid:r[0]})});if(!q.ok)throw 0;d.style.opacity=.3}catch(e){x.disabled=false}};d.append(x)}
  else d.append(document.createElement('span'));
  sp.append(d)}}
let mapKey='';
function monMap(ms,cur){const k=JSON.stringify(ms)+cur;if(k===mapKey)return;mapKey=k;const box=$('mons');box.textContent='';
 const mk=(v,label,el)=>{const b=document.createElement('button');b.className=String(v)===String(cur)?'on':'';b.title=label;b.append(el);const t=document.createElement('span');t.textContent=label;b.append(t);b.onclick=()=>pick(v);box.append(b)};
 const minx=Math.min(...ms.map(x=>x[0])),miny=Math.min(...ms.map(x=>x[1])),W=Math.max(...ms.map(x=>x[0]+x[2]))-minx,H=Math.max(...ms.map(x=>x[1]+x[3]))-miny,s=34/Math.max(W,H*1.6);
 const all=document.createElement('u');all.style.cssText='position:relative;width:'+Math.round(W*s)+'px;height:'+Math.round(H*s)+'px';
 ms.forEach(x=>{const u=document.createElement('u');u.style.cssText='position:absolute;left:'+Math.round((x[0]-minx)*s)+'px;top:'+Math.round((x[1]-miny)*s)+'px;width:'+Math.max(4,Math.round(x[2]*s))+'px;height:'+Math.max(4,Math.round(x[3]*s))+'px';all.append(u)});
 mk(-1,ru?'все':'all',all);
 ms.forEach((x,i)=>{const u=document.createElement('u');u.style.cssText='width:'+Math.max(10,Math.round(x[2]*s*1.6))+'px;height:'+Math.max(7,Math.round(x[3]*s*1.6))+'px';mk(i,(i+1)+' '+x[2]+'\u00d7'+x[3]+(x[4]?'\u2605':''),u)})}
function pick(v){mon=v<0?'':String(v);if(abort)abort.abort()}
addEventListener('keydown',e=>{if(e.target&&/INPUT|TEXTAREA|SELECT/.test(e.target.tagName)||e.ctrlKey||e.metaKey||e.altKey||control)return;if(!/^[0-9]$/.test(e.key))return;
 const n=+e.key,ms=window.__mons||[];if(n===0)pick(-1);else if(n<=ms.length)pick(n-1)});
function handle(ty,p){const dv=new DataView(p.buffer,p.byteOffset,p.byteLength);
 if(ty==='S'){try{sysPanel(JSON.parse(td.decode(p)))}catch(_){}return}
 if(ty==='K'){const n=dv.getUint16(0),m=JSON.parse(td.decode(p.subarray(2,2+n))),img=p.subarray(2+n);
  if(m.mons){window.__mons=m.mons;monMap(m.mons,m.mon)}
  chain=chain.then(async()=>{const b=await jpeg(img);size(m.w||b.width,m.h||b.height);meta={ox:m.ox,oy:m.oy,sc:m.sc};g.drawImage(b,0,0);b.close();frames++}).catch(()=>{})}
 else if(ty==='T'){const c=dv.getUint16(0),parts=[];let o=2;
  for(let i=0;i<c;i++){const n=dv.getUint32(o+4);parts.push([dv.getUint16(o),dv.getUint16(o+2),p.subarray(o+8,o+8+n)]);o+=8+n}
  chain=chain.then(async()=>{const bs=await Promise.all(parts.map(q=>jpeg(q[2])));bs.forEach((b,i)=>{g.drawImage(b,parts[i][0],parts[i][1]);b.close()});frames++}).catch(()=>{})}
 else if(ty==='C'){const n=dv.getUint16(0),m=JSON.parse(td.decode(p.subarray(2,2+n)));meta={ox:m.ox,oy:m.oy,sc:m.sc};
  if(!('VideoDecoder' in window)){noLive=true;if(abort)abort.abort();return}   // no WebCodecs in this browser: pictures instead
  try{if(dec)dec.close()}catch(_){}
  dec=new VideoDecoder({output:f=>{size(f.displayWidth,f.displayHeight);g.drawImage(f,0,0);f.close();frames++},error:()=>{dec=null}});
  dec.configure({codec:m.codec,optimizeForLatency:true})}
 else if(ty==='V'&&dec&&dec.state==='configured')dec.decode(new EncodedVideoChunk({type:p[0]&1?'key':'delta',timestamp:Math.round(performance.now()*1000),data:p.subarray(1)}))}
async function live(){   // -> true if pictures came
 abort=new AbortController();let got=false;const my=abort;
 const quiet=setTimeout(()=>{if(!got)my.abort()},7000);   // nothing in 7 s: this agent does not stream
 try{const r=await fetch(base+'/live'+(mon?'?mon='+mon:''),{signal:my.signal});
  if(r.status===410){ended=true;return true}
  if(!r.ok||!r.body)return false;
  const rd=r.body.getReader();let buf=new Uint8Array(0);
  for(;;){const x=await rd.read();if(x.done)break;bytes+=x.value.length;
   const nb=new Uint8Array(buf.length+x.value.length);nb.set(buf);nb.set(x.value,buf.length);buf=nb;
   while(buf.length>=5){const n=new DataView(buf.buffer,buf.byteOffset).getUint32(0);if(buf.length<5+n)break;
    const ty=String.fromCharCode(buf[4]),pl=buf.slice(5,5+n);buf=buf.subarray(5+n);
    if(ty!=='P'){got=true;gotEver=true}handle(ty,pl)}}
 }catch(e){}finally{clearTimeout(quiet)}
 return got}
(async()=>{while(!ended){
 if(noLive){lane();setTimeout(lane,350);return}   // two frames in flight: the agent never waits for the browser, so the picture keeps moving
 const ok=await live();if(ended)break;
 if(!ok&&!gotEver)noLive=true;else if(!ok)await sleep(1000)}
 status(L.end,'')})();
const esc=x=>String(x||'').replace(/&/g,'&amp;').replace(/</g,'&lt;');
async function info(){while(!ended){try{
 const r=await fetch(base+'/log');if(r.ok){const a=await r.json();log.innerHTML=a.reverse().map(e=>'<div><i>'+new Date(e.t).toLocaleTimeString()+'</i> <b>'+esc(e.tool)+'</b> '+esc(e.args)+'</div>').join('')}
 const q=await fetch(base+'/state');if(q.ok){const s=await q.json();
  $('note').textContent=s.note||'';const c=s.color||'#38ff7a';document.documentElement.style.setProperty('--st',c);
  const p=s.plan;$('hPlan').hidden=!p;$('plan').innerHTML=p?p.stages.map((x,i)=>'<li style="--c:'+esc(x.color||c)+'" class="'+(i===p.current?'cur':(p.done||[]).includes(i)||i<p.current?'done':'')+'">'+esc(x.title)+'</li>').join(''):'';
  if(!s.online)status(L.off,'bad');else if(s.paused)status(L.paused,'bad')}}catch(e){}
 await new Promise(x=>setTimeout(x,1500))}}
info();
async function send(path,body){try{await fetch(base+path,{method:'POST',headers:{'content-type':'application/json','x-ctl':CTL},body:JSON.stringify(body)})}catch(e){}}
function real(ev){const r=cv.getBoundingClientRect();return{x:Math.round(meta.ox+(ev.clientX-r.left)*(cv.width/r.width)*meta.sc),y:Math.round(meta.oy+(ev.clientY-r.top)*(cv.height/r.height)*meta.sc)}}
// zoom into the picture (wheel to zoom toward the cursor, drag to pan when zoomed; the control coordinates stay correct because real() reads the live box)
let zoom=1,tx=0,ty=0;
function applyZoom(){cv.style.transformOrigin='0 0';cv.style.transform=zoom===1?'':'translate('+tx+'px,'+ty+'px) scale('+zoom+')';$('zr').style.display=zoom>1.01?'inline-flex':'none'}
cv.addEventListener('wheel',e=>{if(control&&!(e.ctrlKey||e.metaKey))return;e.preventDefault();const r=cv.getBoundingClientRect();const nz=Math.min(8,Math.max(1,zoom*(e.deltaY<0?1.2:1/1.2)));const lx=(e.clientX-r.left)/zoom,ly=(e.clientY-r.top)/zoom;tx=e.clientX-nz*lx-(r.left-tx);ty=e.clientY-nz*ly-(r.top-ty);zoom=nz;if(zoom===1){tx=0;ty=0}applyZoom()},{passive:false});
cv.addEventListener('dblclick',()=>{zoom=1;tx=0;ty=0;applyZoom()});
let pan=null;
cv.addEventListener('pointerdown',e=>{if(control||zoom<=1)return;pan={x:e.clientX,y:e.clientY,tx,ty};try{cv.setPointerCapture(e.pointerId)}catch(_){}} );
cv.addEventListener('pointermove',e=>{if(!pan)return;tx=pan.tx+(e.clientX-pan.x);ty=pan.ty+(e.clientY-pan.y);applyZoom()});
addEventListener('pointerup',()=>{pan=null});
$('zr').onclick=()=>{zoom=1;tx=0;ty=0;applyZoom()};
// disconnect: stop watching (the stream closes at once; the helper stops filming 15 s after the last viewer leaves); the same button reconnects
$('disc').textContent=ru?'Отключиться':'Disconnect';$('disc').onclick=()=>{if(ended&&gone){location.reload();return}gone=true;ended=true;if(abort)abort.abort();status(ru?'отключено':'disconnected','');$('disc').textContent=ru?'Подключиться':'Reconnect'};
if(CTL){const b=$('ctl');b.hidden=false;b.textContent=L.take;$('send').textContent=L.send;txt.placeholder=L.ph;
 const set=on=>{control=on;b.className=on?'on':'';b.textContent=on?L.give:L.take;cv.className=on?'ctl':'';kb.style.display=on?'flex':'none';document.documentElement.style.setProperty('--kb',on?(kb.offsetHeight||52)+'px':'0px');$('tag').style.display=on?'block':'none';$('tag').textContent=L.tag;send('/takeover',{on});if(on)txt.focus()};
 b.onclick=()=>set(!control);
 let down=null;
 cv.addEventListener('pointerdown',e=>{if(!control)return;e.preventDefault();try{cv.setPointerCapture(e.pointerId)}catch(_){}down={p:real(e),t:Date.now(),b:e.button}});
 cv.addEventListener('pointerup',e=>{if(!control||!down)return;const u=real(e),d=down;down=null;const moved=Math.hypot(u.x-d.p.x,u.y-d.p.y)/meta.sc;
  if(moved>8)send('/input',{a:'drag',x:d.p.x,y:d.p.y,x2:u.x,y2:u.y,hold:Date.now()-d.t>500});
  else send('/input',{a:'click',x:u.x,y:u.y,button:d.b===2?'right':'left'})});
 cv.addEventListener('contextmenu',e=>{if(control)e.preventDefault()});
 let acc=0,wt=0;cv.addEventListener('wheel',e=>{if(!control||e.ctrlKey||e.metaKey)return;e.preventDefault();acc+=Math.sign(e.deltaY)*Math.max(1,Math.round(Math.abs(e.deltaY)/100));clearTimeout(wt);wt=setTimeout(()=>{const p=real(e);send('/input',{a:'scroll',x:p.x,y:p.y,amount:Math.max(-20,Math.min(20,acc))});acc=0},120)},{passive:false});
 $('send').onclick=()=>{if(txt.value){send('/input',{a:'text',text:txt.value});txt.value=''}};
 txt.addEventListener('keydown',e=>{if(e.key==='Enter'&&!e.isComposing){e.preventDefault();if(txt.value)send('/input',{a:'text',text:txt.value});setTimeout(()=>send('/input',{a:'key',keys:'enter'}),350);txt.value=''}});
 kb.querySelectorAll('[data-k]').forEach(x=>x.onclick=()=>send('/input',{a:'key',keys:x.dataset.k}));
 setInterval(()=>{if(control)send('/takeover',{on:true})},60000)}   // the hand-over lasts while this page is in control; the relay lets it lapse a few minutes after the page closes
</script>
<link rel=stylesheet href=/assets/panels.css><script src=/assets/panels.js></script><script>Panels.init({base:base,CTL:CTL,ru:ru})</script>`;
}

const bearer = (req) => (req.headers.authorization || '').replace(/^Bearer /i, '');
const byToken = (req) => {
  const t = bearer(req);
  const h = sha(t);
  for (const [code, s] of sessions) if (safeEq(h, s.th)) return [code, s];
  return [];
};

// ---- the admin panel (/admin): see admin.mjs
const ADMIN_DIR = process.env.ADMIN_DIR || (STATE_FILE ? path.dirname(STATE_FILE) : path.join(os.tmpdir(), 'helpermcp-admin'));
const adminHandle = makeAdminHandler({
  look: humanLook, call, save, dir: ADMIN_DIR, here, sessions, makeViewer, drop, json, text, body, clientIp, baseUrl, ONLINE_MS,
  audit: (type, data) => { try { actWrite({ t: new Date().toISOString(), sid: 'admin', dev: '', kind: 'event', type, data: JSON.stringify(data) }); } catch { /* optional */ } },
  status: () => ({ version: PKG_VERSION, uptime_s: Math.round(process.uptime()), counts: { sessions: sessions.size, online: [...sessions.values()].filter((x) => Date.now() - x.lastSeen < ONLINE_MS).length, files: files.size, viewers: viewers.size } }),
  report: (days) => {
    const f = ACT_FILE; if (!f) return 'The action log is off (no data directory).';
    const misses = []; try { for (const l of fs.readFileSync(MISS_FILE, 'utf8').split(String.fromCharCode(10))) if (l) misses.push(JSON.parse(l)); } catch { /* none */ }
    const ev = loadActs(f, days); return ev.length ? buildReport(ev, { misses }) : 'Nothing in the log for this period yet.';
  },
});
async function handler(req, res) {
  const url = new URL(req.url, 'http://x');
  const p = url.pathname;
  try {
    res.setHeader('x-content-type-options', 'nosniff'); res.setHeader('referrer-policy', 'no-referrer'); res.setHeader('strict-transport-security', 'max-age=31536000');
    res.setHeader('content-security-policy', "default-src 'none'; img-src 'self' data: blob:; style-src 'unsafe-inline' 'self'; script-src 'unsafe-inline' 'self'; connect-src 'self'; frame-ancestors 'none'");
    if (await adminHandle(req, res, url)) return;
    if (p === '/health') return text(res, 200, 'ok');
    if (p === '/logo.svg' || p === '/favicon.svg' || p === '/favicon.ico') { res.writeHead(200, { 'content-type': 'image/svg+xml', 'cache-control': 'public, max-age=86400' }); return res.end(fs.readFileSync(path.join(here, 'logo.svg'))); }
    if (p === '/assets/panels.js' || p === '/assets/panels.css') {   // the viewer's System / Files drawer
      const f = path.join(here, p.slice(8));
      try { res.writeHead(200, { 'content-type': p.endsWith('.js') ? 'text/javascript; charset=utf-8' : 'text/css; charset=utf-8', 'cache-control': 'no-cache', 'x-content-type-options': 'nosniff' }); return res.end(fs.readFileSync(f)); }
      catch { return text(res, 404, 'not found'); }
    }
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

    const vw = p.match(/^\/v\/([0-9a-f]{36})(\/frame|\/live|\/log|\/input|\/takeover|\/state|\/ls|\/get|\/upload|\/kill|\/sysdata|\/fsop|\/preview|\/act|\/look)?$/);   // live viewer for the operator (link from open_viewer)
    if (vw) {
      const v = viewers.get(vw[1]);
      if (!v || v.exp < Date.now()) { viewers.delete(vw[1]); return text(res, 404, 'viewer link expired or invalid'); }
      const s = sessions.get(v.code);
      if (!vw[2]) return text(res, 200, viewerPage(s), 'text/html; charset=utf-8');
      if (!s) return json(res, 410, { error: 'session ended' });
      if (vw[2] === '/log') return json(res, 200, s.log.slice(-25));
      if (vw[2] === '/live') {   // a video-like stream; 501 = this agent cannot stream, the page then polls pictures
        if (s.noStream) return json(res, 501, { error: 'no stream' });
        const ms = url.searchParams.get('mon'), mon = ms ? Number(ms) : -1; s.liveMon = Number.isInteger(mon) && mon >= 0 && mon < 10 ? mon : -1;
        res.writeHead(200, { 'content-type': 'application/octet-stream', 'cache-control': 'no-store', 'x-accel-buffering': 'no' });
        const lv = { res, waitKey: true }; (s.live ??= new Set()).add(lv);
        if (s.lastC) res.write(s.lastC);
        if (s.lastS) res.write(s.lastS);
        s.keyAt = 0; wantKey(v.code, s);
        const ping = setInterval(() => res.write(Buffer.from([0, 0, 0, 0, 80])), 15_000);   // keeps proxies from closing a quiet stream
        req.on('close', () => {
          clearInterval(ping); s.live?.delete(lv);
          setTimeout(() => { if (!s.live?.size && sessions.get(v.code) === s) streamCtl(v.code, s, { on: false }); }, 15_000);   // nobody watches: the agent stops filming
        });
        return;
      }
      if (vw[2] === '/state') return json(res, 200, { look: { color: s.lookForce || s.lookColor || '', note: s.note || '' }, plan: s.plan || null, note: s.note || '', color: lookOf(s).color, online: Date.now() - s.lastSeen <= ONLINE_MS, paused: !!s.paused, takeover: takenOver(s), os: s.info?.os || '' });
      if (vw[2] === '/kill') {   // end a process from the System panel (control link only)
        if (req.method !== 'POST' || !v.ctl || !safeEq(req.headers['x-ctl'] || '', v.ctl)) return json(res, 403, { error: 'this link is view-only' });
        const b = JSON.parse((await body(req, 2000)) || '{}'), pid = Math.round(Number(b.pid));
        if (!Number.isInteger(pid) || pid < 5) return json(res, 400, { error: 'bad pid' });
        try { const d = await call(v.code, 'util', { op: 'kill', name: String(pid) }, 30_000, { human: true }); evPush(s, { t: Date.now(), type: 'killed', data: { pid, by: 'operator (live view)' } }); return json(res, 200, { text: d?.text || 'killed' }); }
        catch (e) { return json(res, 503, { error: e.message }); }
      }
      if (vw[2] === '/fsop' || vw[2] === '/preview' || vw[2] === '/act') {   // control link only; every change is logged as the operator's
        if (!v.ctl || !safeEq(req.headers['x-ctl'] || '', v.ctl)) return json(res, 403, { error: 'this link is view-only' });
        v.fn = (v.fn || 0) + 1; const nowf = Date.now(); if (nowf - (v.fnt || 0) > 1000) { v.fnt = nowf; v.fn = 1; } if (v.fn > 30) return json(res, 429, { error: 'too fast' });
        try {
          if (vw[2] === '/preview') {
            const d = await call(v.code, 'fsop', { op: 'preview', path: String(url.searchParams.get('path') || '') }, 60_000, { human: true });
            if (d && d.jpeg) { res.writeHead(200, { 'content-type': 'image/jpeg', 'cache-control': 'no-store' }); return res.end(d.jpeg); }
            res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' }); return res.end(String(d?.text || '{}'));
          }
          if (req.method !== 'POST') return json(res, 405, {});
          const b = JSON.parse((await body(req, 20_000)) || '{}');
          if (vw[2] === '/fsop') {
            if (!/^(mkdir|newfile|copy|move|rename|delete|stat)$/.test(String(b.op))) return json(res, 400, { error: 'bad op' });
            const args = { op: b.op, path: String(b.path || ''), ...(b.dest ? { dest: String(b.dest) } : {}), ...(b.name ? { name: String(b.name) } : {}), ...(b.overwrite ? { overwrite: true } : {}), ...(b.permanent ? { permanent: true } : {}) };
            const d = await call(v.code, 'fsop', args, 300_000, { human: true }); evPush(s, { t: Date.now(), type: 'fsop', data: { ...args, by: 'operator (live view)' } }); return json(res, 200, { text: d?.text || 'ok' });
          }
          // /act: a few safe, named actions for the System tabs
          const act = String(b.act || '');
          if (act === 'service') {
            if (!/^[\w .@$-]{1,80}$/.test(String(b.name || '')) || !/^(start|stop|restart)$/.test(String(b.value))) return json(res, 400, { error: 'bad service action' });
            const d = await call(v.code, 'util', { op: 'service', name: String(b.name), value: String(b.value) }, 60_000, { human: true }); evPush(s, { t: Date.now(), type: 'service', data: { name: b.name, value: b.value, by: 'operator (live view)' } }); return json(res, 200, { text: d?.text || 'ok' });
          }
          if (act === 'find') { const d = await call(v.code, 'find', { path: String(b.path || '~'), ...(b.name ? { name: String(b.name) } : {}), ...(b.text ? { text: String(b.text) } : {}), max: 200 }, 60_000, { human: true }); return json(res, 200, { text: d?.text || '' }); }
          if (act === 'open') { const d = await call(v.code, 'util', { op: 'open', path: String(b.path || ''), value: String(b.path || ''), name: String(b.path || '') }, 30_000, { human: true }); evPush(s, { t: Date.now(), type: 'open', data: { path: b.path, by: 'operator (live view)' } }); return json(res, 200, { text: d?.text || 'ok' }); }
          if (act === 'system') { const secs = (Array.isArray(b.sections) ? b.sections : []).filter((x) => /^(overview|disks|processes|network|services|apps|startup|health|policy|perf|connections|drivers|events)$/.test(x)).slice(0, 4); const d = await call(v.code, 'system', { sections: secs.length ? secs : ['overview'], top: 30 }, 90_000, { human: true }); return json(res, 200, { text: d?.text || '' }); }
          return json(res, 400, { error: 'unknown action' });
        } catch (e) { return json(res, 503, { error: e.message }); }
      }
      if (vw[2] === '/look') {   // glow colour and the task text (control link only)
        if (req.method !== 'POST' || !v.ctl || !safeEq(req.headers['x-ctl'] || '', v.ctl)) return json(res, 403, { error: 'this link is view-only' });
        const b = JSON.parse((await body(req, 2000)) || '{}');
        try { return json(res, 200, { text: await humanLook(v.code, b.color, b.note) }); } catch (e) { return json(res, 400, { error: e.message }); }
      }
      if (vw[2] === '/sysdata') {   // the System tabs: JSON from the agent (control link only: command lines and startup entries are not for view-only guests)
        if (!v.ctl || !safeEq(req.headers['x-ctl'] || '', v.ctl)) return json(res, 403, { error: 'this link is view-only' });
        const kind = String(url.searchParams.get('kind') || ''), pid = Math.round(Number(url.searchParams.get('pid') || 0));
        if (!/^(procs|perf|services|startup|disks|policy|health|activation|process|adapters|reach)$/.test(kind)) return json(res, 400, { error: 'bad kind' });
        try { const d = await call(v.code, 'sysdata', { kind, ...(pid ? { pid } : {}) }, 90_000, { human: true }); res.writeHead(200, { 'content-type': 'application/json', 'cache-control': 'no-store' }); return res.end(String(d?.text || 'null')); }
        catch (e) { return json(res, 503, { error: e.message }); }
      }
      if (vw[2] === '/ls' || vw[2] === '/get' || vw[2] === '/upload') {   // files: browse, download, drop a file onto the PC (control link only)
        if (!v.ctl || !safeEq(req.headers['x-ctl'] || '', v.ctl)) return json(res, 403, { error: 'this link is view-only' });
        try {
          if (vw[2] === '/ls') return json(res, 200, await call(v.code, url.searchParams.get('mode') === 'list' ? 'list_dir' : 'tree', url.searchParams.get('mode') === 'list' ? { path: url.searchParams.get('path') || '~' } : { path: url.searchParams.get('path') || '~', depth: 1, max: 500 }, 30_000, { human: true }));
          if (req.method !== 'POST') return json(res, 405, {});
          if (vw[2] === '/get') { const b = JSON.parse((await body(req, 5000)) || '{}'); return json(res, 200, await call(v.code, 'fetch_file', { path: String(b.path || '') }, 3_700_000, { human: true })); }
          const f = await storeFile(req, url.searchParams.get('name'), v.code), dir = String(url.searchParams.get('dir') || '');
          const sep = dir.includes('\\') ? '\\' : '/', dest = dir ? dir.replace(/[\\/]+$/, '') + sep + f.name : f.name;
          const d = await call(v.code, 'push_file', { url: f.url, path: dest }, 3_700_000, { human: true });
          (s.uploads ??= []).push(`${dest} (${f.size} bytes)`);   // the AI hears about it with its next answer
          return json(res, 200, { text: d?.text || 'saved', path: dest });
        } catch (e) { return json(res, 503, { error: e.message }); }
      }
      if (vw[2] === '/input' || vw[2] === '/takeover') {   // control: needs the secret from the control link
        if (req.method !== 'POST' || !v.ctl || !safeEq(req.headers['x-ctl'] || '', v.ctl)) return json(res, 403, { error: 'this link is view-only' });
        const b = JSON.parse((await body(req, 20_000)) || '{}');
        if (vw[2] === '/takeover') { s.takeover = b.on ? Date.now() : 0; evPush(s, { t: Date.now(), type: b.on ? 'takeover' : 'handback' }); return json(res, 200, { on: !!b.on }); }
        v.n = (v.n || 0) + 1; const now = Date.now(); if (now - (v.nt || 0) > 1000) { v.nt = now; v.n = 1; } if (v.n > 25) return json(res, 429, { error: 'too fast' });
        s.takeover = now;   // any input keeps the hand-over alive
        const num = (x) => Math.round(Number(x)), ok = (...xs) => xs.every((x) => Number.isFinite(x) && Math.abs(x) < 100000);
        let tool, a2;
        if (b.a === 'click') { const x = num(b.x), y = num(b.y); if (!ok(x, y)) return json(res, 400, {}); tool = 'click'; a2 = { x, y, raw: true, button: b.button === 'right' ? 'right' : 'left' }; }
        else if (b.a === 'drag') { const x = num(b.x), y = num(b.y), x2 = num(b.x2), y2 = num(b.y2); if (!ok(x, y, x2, y2)) return json(res, 400, {}); tool = 'drag'; a2 = { x, y, x2, y2, raw: true, hold: !!b.hold }; }
        else if (b.a === 'scroll') { const x = num(b.x), y = num(b.y), amount = num(b.amount); if (!ok(x, y, amount)) return json(res, 400, {}); tool = 'scroll'; a2 = { x, y, raw: true, amount: Math.max(-20, Math.min(20, amount)) }; }
        else if (b.a === 'text') { tool = 'type_text'; a2 = { text: String(b.text || '').slice(0, 2000) }; }
        else if (b.a === 'key') { tool = 'press_key'; a2 = { keys: String(b.keys || '').slice(0, 40) }; }
        else return json(res, 400, { error: 'unknown input' });
        try { const d = await call(v.code, tool, a2, 30_000, { human: true }); return json(res, 200, { ok: true, text: d?.text || '' }); }
        catch (e) { return json(res, 503, { error: e.message }); }
      }
      if ((v.inflight || 0) >= 2) { res.writeHead(204); return res.end(); }
      v.inflight = (v.inflight || 0) + 1;
      try {
        const mon = url.searchParams.get('mon'); const extra = /^\d$/.test(mon || '') ? { monitor: Number(mon) } : {};
        const d = await call(v.code, 'screenshot', { view: true, prev: v.hash, ...extra, ...viewParams(s) }, 20_000, { human: true });
        if (d.same) { res.writeHead(204, { 'x-same': '1' }); return res.end(); }   // unchanged screen: nothing to send
        v.hash = d.h; v.last = d.jpeg;
        res.writeHead(200, { 'content-type': 'image/jpeg', 'cache-control': 'no-store', 'x-quality': `${s.vl ?? 3}`, 'x-ox': `${d.ox ?? 0}`, 'x-oy': `${d.oy ?? 0}`, 'x-sc': `${d.sc ?? d.scale ?? 1}` }); return res.end(d.jpeg);
      } catch (e) { return json(res, 503, { error: e.message }); } finally { v.inflight--; }
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
        sessions: [...sessions].map(([code, x]) => ({ code, os: x.info?.os || '', host: x.info?.host || '', user: x.info?.user || '', mode: x.mode, online: now - x.lastSeen < ONLINE_MS, last_seen_s: Math.round((now - x.lastSeen) / 1000), running: x.pending.size, queued: x.queue.length, age_s: Math.round((now - x.created) / 1000), paused: x.paused, kept: x.persist })),
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
      const want = /^[A-Z2-9]{4}-[A-Z2-9]{4}$/.test(info.resume || '') ? info.resume : null;
      const old = want && sessions.get(want);
      if (want && !old && ended.has(want) && Date.now() - ended.get(want) < 3600_000) return json(res, 410, { error: 'this session was ended' });
      if (old && info.resume_token && safeEq(sha(info.resume_token), old.th)) {   // the same PC coming back (internet loss, reboot): same code, same token, nothing lost
        old.lastSeen = Date.now(); old.ip = ip; old.mode = normMode(info.mode); old.persist = !!info.persist; old.keepMs = /android/i.test(String(info.os || '')) ? 6 * 3600_000 : undefined; old.paused = false;
        evPush(old, { t: Date.now(), type: 'resumed', note: String(info.note || '').slice(0, 300) }); save();
        console.log(`~ ${want} resumed from ${ip}`);
        return json(res, 200, { code: want, token: info.resume_token, resumed: true });
      }
      const dh = info.device_id ? sha(String(info.device_id).slice(0, 300)) : null;   // a persistent per-install identity (like an AnyDesk/RustDesk ID): the same device always gets the same code back
      let code = want && !old ? want : null;   // same code after a server reset
      if (!code && dh && devices.has(dh)) code = devices.get(dh);
      if (!code) do code = newCode(); while (sessions.has(code));
      if (dh) { devices.set(dh, code); save(); }
      const token = crypto.randomBytes(32).toString('hex');
      const s = newSession({
        th: sha(token), ip, mode: normMode(info.mode), created: Date.now(), persist: !!info.persist, keepMs: /android/i.test(String(info.os || '')) ? 6 * 3600_000 : undefined,   // a phone that vanished is forgotten after 6 h
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
      if (p === '/a/stream' && req.method === 'POST') {   // the live picture: one long upload, frames forwarded as they come
        try { s.ingest?.destroy(); } catch { /* gone */ }
        s.ingest = req; let buf = Buffer.alloc(0);
        req.on('data', (chunk) => {
          s.lastSeen = Date.now();
          buf = buf.length ? Buffer.concat([buf, chunk]) : chunk;
          while (buf.length >= 5) {
            const n = buf.readUInt32BE(0);
            if (n > 16_000_000) { req.destroy(); return; }
            if (buf.length < 5 + n) break;
            liveFrame(code, s, Buffer.from(buf.subarray(0, 5 + n))); buf = buf.subarray(5 + n);
          }
        });
        req.on('error', () => {});
        req.on('end', () => { if (s.ingest === req) s.ingest = null; json(res, 200, {}); });
        return;
      }
      if (p === '/a/result' && req.method === 'POST') {
        let r;
        const ct = req.headers['content-type'] || '';
        if (ct.startsWith('image/')) {   // screenshots arrive as raw JPEG: no base64 inflation
          const buf = await bodyBuf(req, 25_000_000);
          let meta = {}; try { meta = JSON.parse(decodeURIComponent((req.headers['x-result-meta'] || '{}').replace(/\+/g, '%20'))); } catch { /* optional */ }
          r = { id: req.headers['x-result-id'], ok: true, data: { ...meta, jpeg: buf, mime: ct } };
        } else r = JSON.parse(await body(req, 25_000_000));
        const pend = s.pending.get(r.id);
        if (pend) {
          s.pending.delete(r.id); clearTimeout(pend.timer);
          adapt(s, pend, r.data?.jpeg?.length || 0);
          if (r.ok && r.data?.miss) recordMiss(s, code, 'auto', { tool: pend.tool, args: pend.argStr, note: String(r.data.text || '').slice(0, 400) });
          r.ok ? pend.resolve(r.data) : pend.reject(new Error(r.error || 'agent error'));
        }
        return json(res, 200, {});
      }
      if (p === '/a/file' && req.method === 'POST') {
        try { return json(res, 200, await storeFile(req, url.searchParams.get('name'), code)); } catch (e) { return json(res, 413, { error: e.message }); }
      }
      if (p === '/a/state' && req.method === 'POST') {   // the user paused / resumed from the console (Esc menu)
        const st = JSON.parse((await body(req, 2000)) || '{}'); s.paused = !!st.paused;
        evPush(s, { t: Date.now(), type: s.paused ? 'paused' : 'continued' }); save(); return json(res, 200, {});
      }
      if (p === '/a/event' && req.method === 'POST') {   // what the agent saw: outages, repairs, reboots
        const ev = JSON.parse((await body(req, 20_000)) || '{}');
        evPush(s, { t: Date.now(), type: String(ev.type || 'event').slice(0, 40), data: JSON.parse(JSON.stringify(ev, (k, v) => (typeof v === 'string' ? v.slice(0, 3500) : v))) });
        if (s.events.length > 40) s.events.splice(0, s.events.length - 40); save(); return json(res, 200, {});
      }
      if (p === '/a/bye') {
        const b = JSON.parse((await body(req, 2000)) || '{}');
        if (s.persist && !b.final) {   // the window closed / the PC is going down but the user did not end the session: keep it for the PC to come back
          console.log(`- ${code} left (kept)`); s.lastSeen = 0; evPush(s, { t: Date.now(), type: 'agent_left' });
          for (const pd of s.pending.values()) { clearTimeout(pd.timer); pd.reject(new Error('The agent went away (reboot or closed window). The session is kept: use wait_online.')); } s.pending.clear(); save();
          return json(res, 200, {});
        }
        console.log(`- ${code} bye`); drop(code, 'The user ended the session (confirmed in the console). STOP: do not retry, tell the operator.'); return json(res, 200, {});
      }
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
    for (const v of st.viewers || []) if (v.exp > Date.now()) viewers.set(v.token, { code: v.code, exp: v.exp, ctl: v.ctl });
    for (const x of st.devices || []) devices.set(x.dh, x.code);
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
