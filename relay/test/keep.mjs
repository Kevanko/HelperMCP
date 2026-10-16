// Session keeping: the session and its code survive internet loss, a killed agent (reboot), a restarted relay; pausing works;
// only the user's confirmed end removes it. Uses the Python agent.   node relay/test/keep.mjs
import { spawn, spawnSync } from 'node:child_process';
import assert from 'node:assert/strict';
import os from 'node:os';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const PORT = 18900 + Math.floor(Math.random() * 90), BASE = `http://127.0.0.1:${PORT}`, KEY = 'keep-test-key';
const STATE = path.join(os.tmpdir(), `hm-keep-${PORT}.json`), SDIR = fs.mkdtempSync(path.join(os.tmpdir(), 'hm-keepstate-'));
const kids = [];
const stop = () => kids.forEach((k) => { try { k.kill('SIGKILL'); } catch { /* gone */ } });
process.on('exit', stop);
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

const startRelay = () => { const r = spawn('node', [path.join(root, 'relay/server.js')], { env: { ...process.env, PORT, OPERATOR_KEY: KEY, IDLE_MS: '3000', STATE_FILE: STATE }, stdio: 'inherit' }); kids.push(r); return r; };
let relay = startRelay();
for (let i = 0; i < 50; i++) { try { if ((await fetch(BASE + '/health')).ok) break; } catch { /* starting */ } await sleep(100); }
const PS = (process.env.AGENT || (process.platform === 'win32' ? 'ps' : 'py')) === 'ps';
const src = await (await fetch(BASE + (PS ? '/h' : '/p'))).text();
const file = path.join(SDIR, 'a.py'); fs.writeFileSync(file, src);
const TOKEN_FILE = path.join(SDIR, 'token.txt');
const killAgent = (a) => { if (PS) spawnSync('taskkill', ['/PID', String(a.pid), '/T', '/F']); else a.kill('SIGKILL'); };
let agentOut = '';
const startAgent = (again = false) => { const env = { ...process.env, ...(again ? {} : { HELPER_MODE: 'full', HELPER_PERSIST: '1' }),   // a restart after a reboot gets no hints: the saved session alone must decide, and nothing may be asked
    HELPER_STATE_DIR: SDIR, HELPER_NO_AUTOSTART: '1', HELPER_NO_OVERLAY: '1', HELPER_TOKEN_FILE: TOKEN_FILE };
  const a = PS ? spawn('powershell', ['-NoProfile', '-Command', `[Net.ServicePointManager]::SecurityProtocol=3072; irm ${BASE}/h | iex`], { env }) : spawn('python3', [file], { env }); kids.push(a); a.stdout.on('data', (d) => (agentOut += d)); a.stderr.on('data', (d) => (agentOut += d)); return a; };

let client = new Client({ name: 'keep', version: '0' });
await client.connect(new StreamableHTTPClientTransport(new URL(BASE + '/mcp'), { requestInit: { headers: { Authorization: 'Bearer ' + KEY } } }));
const call = async (name, args = {}) => { const r = await client.callTool({ name, arguments: args }); return { err: !!r.isError, text: r.content.find((c) => c.type === 'text')?.text ?? '' }; };
const sessions = async () => JSON.parse((await call('list_sessions')).text);
const waitFor = async (fn, what, ms = 15000) => { const t0 = Date.now(); while (Date.now() - t0 < ms) { const v = await fn(); if (v) return v; await sleep(200); } assert.fail('timeout: ' + what + '\n--- agent output ---\n' + agentOut); };

let agent = startAgent();
const code = (await waitFor(async () => (await sessions())[0]?.code, 'registration'));
assert.equal((await sessions())[0].kept, true, 'the session is marked as kept');
assert.match((await call('run', { session: code, command: 'echo one' })).text, /one/);
const sfile = path.join(SDIR, 'session.json');
await waitFor(async () => fs.existsSync(sfile) && fs.existsSync(TOKEN_FILE), 'the saved session + token files', 20000);
const saved = JSON.parse(fs.readFileSync(sfile, 'utf8').replace(/^﻿/, ''));
assert.equal(saved.code, code);
saved.token = fs.readFileSync(TOKEN_FILE, 'utf8').trim();   // the agent wrote the plaintext token here under HELPER_TOKEN_FILE (DPAPI-encrypted in session.json)
assert.ok(saved.token, 'the agent saved a non-empty token');
console.log('kept session saved ok');

// the PC dies (reboot / power): the session must stay, with the same code, offline
killAgent(agent);
await sleep(6000);   // longer than IDLE_MS (3 s): a plain session would be gone by now
let s = (await sessions()).find((x) => x.code === code); assert.ok(s, 'a kept session survives the idle timeout');
await waitFor(async () => !(await sessions()).find((x) => x.code === code).online, 'goes offline', 40000);
const off = await call('run', { session: code, command: 'echo x' }); assert.ok(off.err && /KEPT/.test(off.text), 'offline message says the session is kept: ' + off.text);
console.log('agent killed: session kept offline ok');

// it comes back by itself: same code, nothing to re-send
agent = startAgent(true);
await waitFor(async () => (await sessions()).find((x) => x.code === code)?.online, 'agent back online', 20000);
assert.equal((await sessions()).length, 1, 'no second session was created');
assert.match((await call('run', { session: code, command: 'echo two' })).text, /two/);
const log1 = JSON.parse((await call('session_log', { session: code })).text); assert.ok(log1.events.some((e) => e.type === 'resumed'), 'session_log shows the resume');
console.log('resumed with the same code ok');

// the relay restarts and forgets nothing it needs
relay.kill('SIGKILL'); await sleep(500); relay = startRelay();
for (let i = 0; i < 50; i++) { try { if ((await fetch(BASE + '/health')).ok) break; } catch { /* starting */ } await sleep(100); }
await client.close().catch(() => {}); client = new Client({ name: 'keep2', version: '0' }); await client.connect(new StreamableHTTPClientTransport(new URL(BASE + '/mcp'), { requestInit: { headers: { Authorization: 'Bearer ' + KEY } } }));
await waitFor(async () => (await sessions()).find((x) => x.code === code)?.online, 'back after a relay restart', 30000);
assert.match((await call('run', { session: code, command: 'echo three' })).text, /three/); console.log('relay restart ok');

// pause (what the Esc menu does): calls are refused with a clear message, the session stays, continue works
const token = saved.token;
const post = (p, b) => fetch(BASE + p, { method: 'POST', headers: { Authorization: 'Bearer ' + token, 'content-type': 'application/json' }, body: JSON.stringify(b) });
await post('/a/state', { paused: true });
const pz = await call('run', { session: code, command: 'echo no' }); assert.ok(pz.err && /PAUSED/.test(pz.text), pz.text);
assert.match((await call('wait_online', { session: code, timeout_s: 2 })).text, /paused/); assert.equal((await sessions())[0].paused, true);
await post('/a/state', { paused: false });
assert.match((await call('wait_online', { session: code, timeout_s: 5 })).text, /online/);
assert.match((await call('run', { session: code, command: 'echo four' })).text, /four/); console.log('pause / continue ok');

// the outage report the agent sends
await post('/a/event', { type: 'outage', duration_s: 12, class: 'dns', actions: ['flush dns'], diagnosis: '{"x":1}' });
const log2 = JSON.parse((await call('session_log', { session: code })).text); assert.ok(log2.events.some((e) => e.type === 'outage' && e.class === 'dns' && e.duration_s === 12), 'outage report is readable');
assert.match((await call('agent_log', { session: code })).text, /session .* (started|resumed)/); console.log('outage report + agent_log ok');

// only a confirmed end removes it (the final bye the Esc menu sends)
await post('/a/bye', { final: true }); await sleep(500);
assert.equal((await sessions()).length, 0, 'the confirmed end removes the session');
console.log('ALL PASSED');
stop(); fs.rmSync(STATE, { force: true }); process.exit(0);
