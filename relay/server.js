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
    s.events.push({ t: Date.now(), type: 'miss', data: { kind, ...info } });
  } catch (e) { console.error('miss log failed:', e.message); }
}
// what the label shows: the current stage (its colour, "2/5 title") and the note
function lookOf(s) {
  const st = s.plan && s.plan.stages[s.plan.current];
  const note = [st ? `${s.plan.current + 1}/${s.plan.stages.length} ${st.title}` : '', s.note || ''].filter(Boolean).join(': ');
  return { color: (st && st.color) || s.lookColor || '', note: note.slice(0, 120) };
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
  if (s.paused && tool !== 'bye' && !(opts.human && tool === 'screenshot')) {   // the live viewer keeps showing the screen while it is paused
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
  if (s.mode === 'ask') timeoutMs += 120_000;
  if (tool === 'screenshot' && !args.view && s.lite) args = { max_width: 1280, quality: 50, ...args };   // slow link: smaller by default
  let argStr = '';
  if (!args.view) { // live-viewer frames are not "actions"
    const a = JSON.stringify(args, (k, v) => (typeof v === 'string' && v.length > 80 ? v.slice(0, 80) + '…' : v));
    argStr = a === '{}' ? '' : a.slice(0, 160);
    s.log.push({ t: Date.now(), tool, args: argStr });
    if (s.log.length > 60) s.log.shift();
  }
  const id = crypto.randomUUID();
  return new Promise((resolve, reject) => {
    const timer = setTimeout(() => {
      s.pending.delete(id); s.queue = s.queue.filter((q) => q.id !== id);   // a caller that gave up must not have its command run later
      reject(new Error(`Timed out after ${Math.round(timeoutMs / 1000)}s waiting for the agent (user may not have approved).`));
    }, timeoutMs);
    s.pending.set(id, { resolve, reject, timer, t0: Date.now() - (args.view ? FAKE_LATENCY_MS : 0), tool, argStr, view: !!args.view });
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

const ended = new Map();   // codes the user (or operator) ended: an agent that still tries to come back with one is told to stop (for an hour)
function drop(code, why) {
  const s = sessions.get(code);
  if (!s) return;
  ended.set(code, Date.now());
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
      s.events.push({ t: Date.now(), type: 'plan', data: { stages: stages.map((x) => x.title) } }); save();
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
      s.events.push({ t: now, type: 'look', data: { note: s.note || '', stage: s.plan ? s.plan.current : null } }); save();
      return { text: await pushLook(c, s) };
    } },
  { name: 'hold', session: true,
    description: 'Put the session on hold when you must stop for a while (your token or rate limit is running out, a long break, waiting for the user). The phone shows an orange "helper is on hold, back soon" label, keeps its screen awake and the session open; your next action continues it. Unlike pause (which the user presses) you start it yourself. Elsewhere it is only logged.',
    props: { reason: str('why you stop'), back_in_minutes: { type: 'integer', minimum: 1, maximum: 1440, description: 'when you expect to continue' } },
    run: async (code, a) => {
      const c = String(code).toUpperCase(); const s = sessions.get(c); if (!s) throw new Error('No such session');
      s.events.push({ t: Date.now(), type: 'hold', data: { reason: String(a.reason || '').slice(0, 200), back_in_minutes: a.back_in_minutes || null } });
      await call(c, 'hold', {}).catch((e) => { if (!/Unknown tool|not available/i.test(e.message)) throw e; });
      return { text: 'on hold: the session stays open and the screen awake; your next action continues' };
    } },
  { name: 'task_done', session: true,
    description: 'Tell the user you have finished the job on this device. A phone shows a green "work finished" label and resets its timer; the session stays open and turns blue again on your next action. Call it when you are done, before you stop.',
    props: { summary: str('one line of what was done') },
    run: async (code, a) => {
      const c = String(code).toUpperCase(); const s = sessions.get(c); if (!s) throw new Error('No such session');
      s.events.push({ t: Date.now(), type: 'done', data: { summary: String(a.summary || '').slice(0, 200) } });
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
      const token = crypto.randomBytes(18).toString('hex');
      const ctl = crypto.randomBytes(12).toString('hex');
      viewers.set(token, { code: c, exp: Date.now() + VIEWER_TTL_MS, ctl }); save();
      return { text: `Watch (view only, safe to share): ${lastBase}/v/${token}\nControl (click, drag, scroll, type, take over from the helper; keep it private): ${lastBase}/v/${token}#c=${ctl}` };
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
1. Look first: sysinfo, then screenshot (what the user sees). Right after connecting call open_viewer and give the operator the Control link at once; if you can run commands on the operator's own machine, open it in their browser (Windows: start "" "<link>"; macOS: open; Linux: xdg-open). Then set_look: a colour you like (once) and a short note of what you are doing; keep the note current.
2. Need an application or MCP server (Blender, Unity, Substance, a browser, ...)? First call recipe (no name = list; "blender" and the generic "any-app" exist). Check whether it is installed (run: Get-Command / where / which / winget list / registry / apt), install it if missing (winget install -e --id ..., apt/flatpak; an installer that needs administrator rights shows a UAC prompt the user must accept: tell them), then continue.
3. GUI apps and anything long-lived: start_process (detached, keeps running). Do not use run for them.
4. MCP servers: mcp_start (command npx / uvx / python / an exe). Portable Node and uv are fetched automatically when missing. command="playwright" opens a real visible browser with sound. Then mcp_call (or <server>__<tool> on /s/<code>/mcp). Prefer a dedicated MCP server over clicking the GUI.
5. Operations that take longer than ~45 s return "Still running (job X)": call wait_job with that id. Raise timeout_s on mcp_start / mcp_call / run for installs and renders.
6. The network may be slow: take screenshots only when needed (monitor=N crops to one screen), avoid huge command output.
7. The user watches the screen: make your work visible. Do windowing with the mouse (drag a title bar to move a window, drag an edge or corner to resize, click the minimise / maximise / close buttons, click taskbar icons to open or hide an app) instead of keyboard shortcuts or commands when a mouse action exists. When you read something on the screen, use trace under the line you are reading (x,y = start of the text, x2,y2 = its end, a few px below the baseline), and move to point at important details before you act on them: the user sees what you are looking at. Skip this for background work (files, commands, MCP calls).
8. Talk to the user while you work. At the start say whether the connection worked (list_sessions, sysinfo) and that the friend can end the session at any time with Esc. Before a group of actions say in one short line what you are going to do, afterwards whether it worked. Bundle small GUI steps (move + click, click + type, drag, scroll) into ONE actions call so the friend confirms once instead of per step. If any call comes back "ended", "denied", "Agent left" or "No such session": stop, do not retry, tell the operator.
9. The session survives internet loss, VPN changes and reboots (the user chose to keep it): it comes back by itself with the same code. If a call says the PC is offline or paused, do not start over: wait_online, then read session_log (it holds the network diagnosis and what the agent already tried) and agent_log, and continue where you stopped. Only the user ending the session in their console ends it.
10. Android phones (os "Android ..."): only screenshot, click (a tap; button=right is a long press), drag (a swipe; hold=true for drag and drop), scroll, type_text (into the focused field: tap it first), press_key (home, back, recents, notifications, quick_settings, enter, backspace, volume_up, volume_down, power, lock, screenshot), start_process (command = app name, package or link), actions and sysinfo exist. There is no shell, no files and no MCP bridge. Coordinates are screenshot pixels; the friend can end the session by tapping the label at the top of the screen.
11. This is the user's real machine: only touch what the task needs, and say what you installed or changed.
12. If you tapped or opened the wrong thing and had to redo it, call report_miss (what you wanted, what happened, what worked). A tap result starting with MISS means nothing tappable was under the finger: read the hint and tap the suggested spot. When the job is finished call task_done. If you must stop for a while (token or rate limit, a long break) call hold first, so the phone stays awake and the session stays open. On a phone you may also call set_look once at the start (a colour you like) and keep its note line current.
13. Work in stages: when you know the steps, call plan (titles + a colour per stage) and set_look {stage} as you move on; keep set_look {note} current.
14. Save tokens and time: do not take a screenshot after every step. Every click, typing and key press reports what changed on the screen; trust it. Take a screenshot when you need to see something new; use region to read small things; an unchanged screen costs one line. Use watch when something happens over time.
15. Stop at the first sign of trouble: if an action reports NO CHANGE (typing that did not appear, a click on nothing), do not continue the plan; look (screenshot or watch), find out why, fix it, then continue.`;

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
      if (t.run) return fmt(await t.run(session, a));
      if (name === 'screenshot') return fmt(await aiShot(session, a));
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
  return `<!doctype html><html lang=en><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1"><meta name=color-scheme content=dark><title>Remote screen ${esc(who)}</title>
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
#cv.ctl{cursor:crosshair;box-shadow:0 0 0 2px var(--warn),0 0 30px rgba(255,209,102,.18)}
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
#log{flex:1;overflow:auto;border-top:1px solid var(--line);padding:.5rem .9rem;font-size:12px}
#log div{padding:1px 0;white-space:nowrap;overflow:hidden;text-overflow:ellipsis}#log b{color:var(--g);font-weight:500}#log i{color:#3f6b50;font-style:normal}#log div:before{content:"$ ";color:#3f6b50}
#kb{position:fixed;left:0;right:0;bottom:0;display:none;gap:.35rem;padding:.5rem .7rem;background:var(--panel2);border-top:1px solid var(--warn);align-items:center;flex-wrap:wrap}
#kb label{color:var(--warn)}#kb input{flex:1;min-width:10rem;background:#010603;border-color:var(--line2)}
@media(max-width:820px){#main{display:block;height:auto}#scr{height:60vh}#cv{max-height:calc(60vh - 28px)}#side{border-left:0;border-top:1px solid var(--line)}#log{max-height:30vh}#who{display:none}}
@media(prefers-reduced-motion:reduce){*{transition:none!important}}
</style>
<div id=top><span id=dot></span><span id=st>…</span><span id=who>${esc(who)}</span>
<select id=mon title=screen><option value="">all screens</option><option>0</option><option>1</option><option>2</option><option>3</option></select>
<button id=ctl hidden></button></div>
<div id=main><div id=scr><div id=frame><i></i><canvas id=cv width=16 height=9></canvas></div><div id=tag></div></div>
<aside id=side><h2 id=hNote></h2><div id=note></div><h2 id=hPlan hidden></h2><ol id=plan></ol><div id=log></div></aside></div>
<div id=kb><label for=txt>$</label><input id=txt autocomplete=off><button id=send></button><button data-k=enter>Enter</button><button data-k=backspace>&#9003;</button><button data-k=tab>Tab</button><button data-k=esc>Esc</button><button data-k=left>&larr;</button><button data-k=up>&uarr;</button><button data-k=down>&darr;</button><button data-k=right>&rarr;</button>${android ? '<button data-k=back>Back</button><button data-k=home>Home</button><button data-k=recents>Recents</button>' : ''}</div>
<script>
const ru=(navigator.language||'').startsWith('ru'),L=ru?{live:'в эфире',wait:'жду кадр…',end:'сеанс завершён',off:'устройство не на связи',paused:'пауза на устройстве',take:'Управлять самому',give:'Вернуть помощнику',tag:'управляете вы, помощник ждёт',send:'Ввести',ph:'текст: Enter — ввести и нажать Enter',note:'Что делает помощник',noNote:'помощник ещё ничего не написал',plan:'План',over:'вы управляете'}:{live:'live',wait:'waiting for a frame…',end:'session ended',off:'device offline',paused:'paused on the device',take:'Take control',give:'Give back to the helper',tag:'you are driving, the helper waits',send:'Type',ph:'text: Enter types it and presses Enter',note:'What the helper is doing',noNote:'nothing from the helper yet',plan:'Plan',over:'you are driving'};
const $=id=>document.getElementById(id),dot=$('dot'),st=$('st'),cv=$('cv'),g=cv.getContext('2d'),log=$('log'),kb=$('kb'),txt=$('txt');
$('hNote').textContent=L.note;$('note').dataset.empty=L.noNote;$('hPlan').textContent=L.plan;
const base=location.pathname.split('/').slice(0,3).join('/');   // /v/<token>: the link has no trailing slash, so a relative URL would resolve to /v/frame
const CTL=(location.hash.match(/c=([0-9a-f]+)/)||[])[1]||'';   // the control secret lives in the #fragment: it never reaches a server log
let ended=false,control=false,meta={ox:0,oy:0,sc:1},seq=0,shown=0,mon='';
$('mon').onchange=e=>{mon=e.target.value};
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
lane();setTimeout(lane,350);   // two frames in flight: the agent never waits for the browser, so the picture keeps moving
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
if(CTL){const b=$('ctl');b.hidden=false;b.textContent=L.take;$('send').textContent=L.send;txt.placeholder=L.ph;
 const set=on=>{control=on;b.className=on?'on':'';b.textContent=on?L.give:L.take;cv.className=on?'ctl':'';kb.style.display=on?'flex':'none';document.documentElement.style.setProperty('--kb',on?(kb.offsetHeight||52)+'px':'0px');$('tag').style.display=on?'block':'none';$('tag').textContent=L.tag;send('/takeover',{on});if(on)txt.focus()};
 b.onclick=()=>set(!control);
 let down=null;
 cv.addEventListener('pointerdown',e=>{if(!control)return;e.preventDefault();try{cv.setPointerCapture(e.pointerId)}catch(_){}down={p:real(e),t:Date.now(),b:e.button}});
 cv.addEventListener('pointerup',e=>{if(!control||!down)return;const u=real(e),d=down;down=null;const moved=Math.hypot(u.x-d.p.x,u.y-d.p.y)/meta.sc;
  if(moved>8)send('/input',{a:'drag',x:d.p.x,y:d.p.y,x2:u.x,y2:u.y,hold:Date.now()-d.t>500});
  else send('/input',{a:'click',x:u.x,y:u.y,button:d.b===2?'right':'left'})});
 cv.addEventListener('contextmenu',e=>{if(control)e.preventDefault()});
 let acc=0,wt=0;cv.addEventListener('wheel',e=>{if(!control)return;e.preventDefault();acc+=Math.sign(e.deltaY)*Math.max(1,Math.round(Math.abs(e.deltaY)/100));clearTimeout(wt);wt=setTimeout(()=>{const p=real(e);send('/input',{a:'scroll',x:p.x,y:p.y,amount:Math.max(-20,Math.min(20,acc))});acc=0},120)},{passive:false});
 $('send').onclick=()=>{if(txt.value){send('/input',{a:'text',text:txt.value});txt.value=''}};
 txt.addEventListener('keydown',e=>{if(e.key==='Enter'&&!e.isComposing){e.preventDefault();if(txt.value)send('/input',{a:'text',text:txt.value});setTimeout(()=>send('/input',{a:'key',keys:'enter'}),350);txt.value=''}});
 kb.querySelectorAll('[data-k]').forEach(x=>x.onclick=()=>send('/input',{a:'key',keys:x.dataset.k}));
 setInterval(()=>{if(control)send('/takeover',{on:true})},60000)}   // the hand-over lasts while this page is in control; the relay lets it lapse a few minutes after the page closes
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

    const vw = p.match(/^\/v\/([0-9a-f]{36})(\/frame|\/log|\/input|\/takeover|\/state)?$/);   // live viewer for the operator (link from open_viewer)
    if (vw) {
      const v = viewers.get(vw[1]);
      if (!v || v.exp < Date.now()) { viewers.delete(vw[1]); return text(res, 404, 'viewer link expired or invalid'); }
      const s = sessions.get(v.code);
      if (!vw[2]) return text(res, 200, viewerPage(s), 'text/html; charset=utf-8');
      if (!s) return json(res, 410, { error: 'session ended' });
      if (vw[2] === '/log') return json(res, 200, s.log.slice(-25));
      if (vw[2] === '/state') return json(res, 200, { plan: s.plan || null, note: s.note || '', color: lookOf(s).color, online: Date.now() - s.lastSeen <= ONLINE_MS, paused: !!s.paused, takeover: takenOver(s), os: s.info?.os || '' });
      if (vw[2] === '/input' || vw[2] === '/takeover') {   // control: needs the secret from the control link
        if (req.method !== 'POST' || !v.ctl || !safeEq(req.headers['x-ctl'] || '', v.ctl)) return json(res, 403, { error: 'this link is view-only' });
        const b = JSON.parse((await body(req, 20_000)) || '{}');
        if (vw[2] === '/takeover') { s.takeover = b.on ? Date.now() : 0; s.events.push({ t: Date.now(), type: b.on ? 'takeover' : 'handback' }); return json(res, 200, { on: !!b.on }); }
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
        old.lastSeen = Date.now(); old.ip = ip; old.mode = info.mode === 'ask' ? 'ask' : 'full'; old.persist = !!info.persist; old.keepMs = /android/i.test(String(info.os || '')) ? 6 * 3600_000 : undefined; old.paused = false;
        old.events.push({ t: Date.now(), type: 'resumed', note: String(info.note || '').slice(0, 300) }); save();
        console.log(`~ ${want} resumed from ${ip}`);
        return json(res, 200, { code: want, token: info.resume_token, resumed: true });
      }
      let code = want && !old ? want : null;   // same code after a server reset
      if (!code) do code = newCode(); while (sessions.has(code));
      const token = crypto.randomBytes(32).toString('hex');
      const s = newSession({
        th: sha(token), ip, mode: info.mode === 'ask' ? 'ask' : 'full', created: Date.now(), persist: !!info.persist, keepMs: /android/i.test(String(info.os || '')) ? 6 * 3600_000 : undefined,   // a phone that vanished is forgotten after 6 h
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
          if (r.ok && r.data?.miss) recordMiss(s, code, 'auto', { tool: pend.tool, args: pend.argStr, note: String(r.data.text || '').slice(0, 400) });
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
      if (p === '/a/state' && req.method === 'POST') {   // the user paused / resumed from the console (Esc menu)
        const st = JSON.parse((await body(req, 2000)) || '{}'); s.paused = !!st.paused;
        s.events.push({ t: Date.now(), type: s.paused ? 'paused' : 'continued' }); save(); return json(res, 200, {});
      }
      if (p === '/a/event' && req.method === 'POST') {   // what the agent saw: outages, repairs, reboots
        const ev = JSON.parse((await body(req, 20_000)) || '{}');
        s.events.push({ t: Date.now(), type: String(ev.type || 'event').slice(0, 40), data: JSON.parse(JSON.stringify(ev, (k, v) => (typeof v === 'string' ? v.slice(0, 3500) : v))) });
        if (s.events.length > 40) s.events.splice(0, s.events.length - 40); save(); return json(res, 200, {});
      }
      if (p === '/a/bye') {
        const b = JSON.parse((await body(req, 2000)) || '{}');
        if (s.persist && !b.final) {   // the window closed / the PC is going down but the user did not end the session: keep it for the PC to come back
          console.log(`- ${code} left (kept)`); s.lastSeen = 0; s.events.push({ t: Date.now(), type: 'agent_left' });
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
