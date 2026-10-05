// End-to-end: relay + real agent + MCP client. Run: cd relay && npm test
// Uses the PowerShell agent on Windows, the Python agent elsewhere. Set AGENT=py|ps to force.
import { spawn } from 'node:child_process';
import assert from 'node:assert/strict';
import os from 'node:os';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const PORT = 18000 + Math.floor(Math.random() * 1000), KEY = 'testkey', BASE = `http://127.0.0.1:${PORT}`;
const kids = [];
const stop = () => kids.forEach((k) => k.kill());
process.on('exit', stop);

const STATE = path.join(os.tmpdir(), `hm-state-${PORT}.json`);
fs.rmSync(STATE, { force: true });
const startRelay = async () => {
  const r = spawn('node', [path.join(root, 'relay/server.js')], { env: { ...process.env, PORT, OPERATOR_KEY: KEY, IDLE_MS: '3000', JOB_SYNC_MS: '3000', STATE_FILE: STATE }, stdio: 'inherit' });
  kids.push(r);
  for (let i = 0; i < 50; i++) { try { if ((await fetch(BASE + '/health')).ok) break; } catch {} await new Promise((x) => setTimeout(x, 100)); }
  return r;
};
let relay = await startRelay();

// the real install path: fetch the script from the relay, like `irm | iex` would
// PORTABLE=1: hide Node from the agent to test the portable-Node download
const agentEnv = { ...process.env, HELPER_MODE: 'full', HELPER_DEBUG: '1', HELPER_INIT_TIMEOUT: '25', HELPER_NO_OVERLAY: '1' };
if (process.env.PORTABLE) {
  for (const k of Object.keys(agentEnv)) if (k.toUpperCase() === 'PATH') agentEnv[k] = agentEnv[k].split(path.delimiter).filter((p) => !/node/i.test(p)).join(path.delimiter);
}
const useps = (process.env.AGENT || (process.platform === 'win32' ? 'ps' : 'py')) === 'ps';
const src = await (await fetch(BASE + (useps ? '/h' : '/p'))).text();
assert.ok(!src.includes('__RELAY__') || src.includes(BASE), 'relay URL must be baked in');
const tmp = fs.mkdtempSync(path.join(os.tmpdir(), 'hm-'));
const file = path.join(tmp, useps ? 'a.ps1' : 'a.py');
fs.writeFileSync(file, (useps ? '﻿' : '') + src); // PS 5.1 reads BOM-less files as ANSI
const agent = useps
  ? spawn('powershell', ['-NoProfile', '-Command', `[Net.ServicePointManager]::SecurityProtocol=3072; irm ${BASE}/h | iex`], { env: agentEnv }) // the real one-liner
  : spawn('python3', [file], { env: agentEnv });
kids.push(agent);
let agentOut = '';
agent.stdout.on('data', (d) => (agentOut += d));
agent.stderr.on('data', (d) => (agentOut += d));
process.on('uncaughtException', (e) => { console.error(e.message, '\n--- agent output ---\n' + agentOut); process.exit(1); });

const client = new Client({ name: 'test', version: '0' });
await client.connect(new StreamableHTTPClientTransport(new URL(BASE + '/mcp'), { requestInit: { headers: { Authorization: 'Bearer ' + KEY } } }));
const raw = async (name, args = {}) => client.callTool({ name, arguments: args });
// like a well-behaved AI: a "still running (job X)" answer is followed by wait_job
const tool = async (name, args = {}) => {
  let r = await raw(name, args);
  for (let i = 0; i < 20; i++) {
    const j = /Still running .*?\(job (\w+)/.exec(r.content?.[0]?.text || '');
    if (!j) break;
    r = await raw('wait_job', { job: j[1], wait_s: 20 });
  }
  return r;
};
const txt = (r) => r.content.find((c) => c.type === 'text')?.text ?? '';

let code;
for (let i = 0; i < 100 && !code; i++) {
  code = JSON.parse(txt(await tool('list_sessions')))[0]?.code;
  if (!code) await new Promise((r) => setTimeout(r, 200));
}
assert.ok(code, 'agent never registered. agent output:\n' + agentOut);
console.log('session', code);

const info = txt(await tool('sysinfo', { session: code }));
assert.match(info, /user/i); console.log('sysinfo ok');

const echo = txt(await tool('run', { session: code, command: 'echo hello-мир' }));
assert.match(echo, /exit 0/); assert.match(echo, /hello-мир/); console.log('run ok (utf-8)');

const f = path.join(tmp, 'f.txt');
assert.match(txt(await tool('write_file', { session: code, path: f, content: 'привет\nline2' })), /written/);
assert.equal(txt(await tool('read_file', { session: code, path: f })), 'привет\nline2');
assert.match(txt(await tool('list_dir', { session: code, path: tmp })), /f\.txt/); console.log('files ok');

// big output: travels gzipped, arrives intact (and is capped with a marker)
const big = txt(await tool('run', { session: code, command: useps ? "'x' * 200000" : "head -c 200000 /dev/zero | tr '\\0' x" }));
assert.ok(big.length > 90000 && /truncated/.test(big) && /xxxxxxxx/.test(big), 'len=' + big.length + ' head=' + JSON.stringify(big.slice(0, 80)) + ' tail=' + JSON.stringify(big.slice(-60))); console.log('gzip big output ok');

const slow = txt(await tool('run', { session: code, command: useps ? 'Start-Sleep 20' : 'sleep 20', timeout_s: 1 }));
assert.match(slow, /timeout/); console.log('timeout ok');

// bridge: start another MCP server on the "friend's PC" and use it through the relay
const echoJs = path.join(root, 'relay/test/echo-mcp.mjs');
const started = txt(await tool('mcp_start', { session: code, name: 'echo', command: 'node', args: [echoJs] }));
assert.match(started, /echo: 1 tools: say/); console.log('mcp_start ok');
if (process.env.PORTABLE) { assert.match(agentOut, /downloading portable Node/); console.log('portable node ok'); }
if (process.env.PORTABLE) { assert.match(txt(await tool('run', { session: code, command: 'npx --version', timeout_s: 300 })), /\d+\.\d+\.\d+/); console.log('run sees portable npx ok'); }
assert.equal(txt(await tool('mcp_call', { session: code, server: 'echo', tool: 'say', arguments: { msg: 'привет' } })), 'echo:привет');
console.log('mcp_call ok (via /mcp)');

// transparent mode: /s/<code>/mcp shows the child tools as native ones, no "session" argument
const c2 = new Client({ name: 'test2', version: '0' });
await c2.connect(new StreamableHTTPClientTransport(new URL(`${BASE}/s/${code}/mcp`), { requestInit: { headers: { Authorization: 'Bearer ' + KEY } } }));
const names = (await c2.listTools()).tools.map((t) => t.name);
assert.ok(names.includes('echo__say') && names.includes('run') && !names.includes('list_sessions'), names.join());
assert.ok(!(await c2.listTools()).tools.find((t) => t.name === 'run').inputSchema.properties.session);
assert.equal((await c2.callTool({ name: 'echo__say', arguments: { msg: 'hi' } })).content[0].text, 'echo:hi');
assert.match((await c2.callTool({ name: 'run', arguments: { command: 'echo direct' } })).content[0].text, /direct/);
console.log('transparent /s/<code>/mcp ok');
await c2.close();
await tool('mcp_stop', { session: code, name: 'echo' });

// an agent busy longer than the idle limit must not be dropped (regression: browser calls > 90 s killed the session)
const busy = txt(await raw('run', { session: code, command: useps ? 'Start-Sleep 8; echo done' : 'sleep 8; echo done', timeout_s: 30 }));
// longer than JOB_SYNC_MS: the relay answers "still running (job X)" instead of letting the MCP client time out, wait_job delivers the result
const jobId = /job (\w+)/.exec(busy)?.[1];
assert.ok(jobId, 'expected a background job, got: ' + busy);
const waited = txt(await raw('wait_job', { job: jobId, wait_s: 25 }));
assert.match(waited, /done/); console.log('long call survives idle limit + wait_job ok');
await assert.rejects(raw('wait_job', { job: jobId }).then((r) => { if (r.isError) throw new Error(txt(r)); }), /Unknown or already delivered/);

// images come back as images (renders, saved screenshots)
const png = path.join(tmp, 'pixel.png');
fs.writeFileSync(png, Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==', 'base64'));
const imgRes = await tool('read_file', { session: code, path: png });
assert.ok(imgRes.content.some((c) => c.type === 'image' && c.data.length > 100), 'read_file must return an image for .png'); console.log('read_file image ok');

// responsiveness: a light request is answered while a long command is still running (viewer frames never freeze behind installs/renders)
const long1 = raw('run', { session: code, command: useps ? 'Start-Sleep 12; echo long-done' : 'sleep 12; echo long-done', timeout_s: 40 });
await new Promise((x) => setTimeout(x, 1500));
const tq = Date.now(); const siq = txt(await tool('sysinfo', { session: code })); const dq = Date.now() - tq;
assert.match(siq, /user/i); assert.ok(dq < 8000, `sysinfo must not wait behind a long run (${dq} ms)`);
let lr = await long1; for (let i = 0; i < 10 && /Still running .*?\(job (\w+)/.test(lr.content[0].text); i++) lr = await raw('wait_job', { job: /job (\w+)/.exec(lr.content[0].text)[1], wait_s: 20 });
assert.match(lr.content[0].text, /long-done/); console.log(`concurrency ok (sysinfo answered in ${dq} ms during a 12 s command)`);

// start_process: detached launch, reports crashes right away
const sp = txt(await tool('start_process', { session: code, command: 'node', args: ['-e', 'setTimeout(() => {}, 4000)'], wait_s: 1 }));
assert.match(sp, /started pid \d+, still running/);
const sp2 = txt(await tool('start_process', { session: code, command: 'node', args: ['-e', 'console.log("hi-from-child"); process.exit(3)'], wait_s: 2 }));
assert.match(sp2, /exited with code 3/); assert.match(sp2, /hi-from-child/);
assert.ok((await tool('start_process', { session: code, command: 'definitely-not-a-command-xyz' })).isError);
console.log('start_process ok');

// persistence: the relay restarts in the middle of a session; the agent keeps polling, the session and the viewer link survive
const vurl0 = txt(await tool('open_viewer', { session: code }));
await new Promise((x) => setTimeout(x, 500));          // let the debounced state file be written
relay.kill(); await new Promise((x) => setTimeout(x, 800));
relay = await startRelay();
const after = JSON.parse(txt(await tool('list_sessions')));
assert.ok(after.some((x) => x.code === code), 'session must be restored from the state file');
assert.match(txt(await tool('run', { session: code, command: 'echo after-restart' })), /after-restart/);
assert.match(await (await fetch(vurl0)).text(), /Remote screen/);
console.log('relay restart: session + agent + viewer link survive ok');

// live viewer: link from open_viewer, page, action log, frame (frame needs a desktop: GUI=1)
const vurl = txt(await tool('open_viewer', { session: code }));
assert.match(vurl, new RegExp(`^${BASE}/v/[0-9a-f]{36}$`));
const page = await (await fetch(vurl)).text();
assert.match(page, /Remote screen/);
// regression: /v/<token> has no trailing slash, so a relative fetch('frame') resolved to /v/frame (404) and the viewer stayed empty
assert.ok(!/fetch\('(frame|log)/.test(page) && page.includes("location.pathname.split('/').slice(0,3)"), 'viewer must build absolute frame/log URLs');
const vlog = await (await fetch(vurl + '/log')).json();
assert.ok(vlog.some((e) => e.tool === 'run') && !vlog.some((e) => e.args.includes('view')), 'log shows actions, not viewer frames');
assert.equal((await fetch(BASE + '/v/' + '0'.repeat(36))).status, 404);
if (process.env.GUI) { const fr = await fetch(vurl + '/frame'); assert.equal(fr.headers.get('content-type'), 'image/jpeg'); assert.ok((await fr.arrayBuffer()).byteLength > 1000); }
console.log('viewer ok');

// stopping an MCP server must kill the whole process tree (uvx/npx run the real server as a grandchild)
const pidFile = path.join(tmp, 'grandchild.pid');
await tool('mcp_start', { session: code, name: 'tree', command: 'node', args: [echoJs], env: { GRANDCHILD_PIDFILE: pidFile } });
await new Promise((x) => setTimeout(x, 1000));
const gpid = Number(fs.readFileSync(pidFile, 'utf8'));
assert.ok(gpid > 0); process.kill(gpid, 0);                                // alive while the server runs
await tool('mcp_stop', { session: code, name: 'tree' });
await new Promise((x) => setTimeout(x, 2000));
assert.throws(() => process.kill(gpid, 0), /ESRCH|kill/, 'grandchild must be gone after mcp_stop'); console.log('process tree killed ok');

// recipes: verified how-tos for apps (no session needed)
assert.match(txt(await tool('recipe')), /blender.*any-app|any-app.*blender/);
assert.match(txt(await tool('recipe', { name: 'blender' })), /uvx mcp-for-blender install-addon/);
assert.ok((await tool('recipe', { name: '../server' })).isError); console.log('recipes ok');

const bad = await tool('run', { session: 'NOPE-NOPE', command: 'x' });
assert.ok(bad.isError); console.log('bad session ok');

if (process.env.GUI) {
  const size = (r) => Buffer.from(r.content.find((c) => c.type === 'image').data, 'base64').length;
  const full = size(await tool('screenshot', { session: code }));
  const lite = size(await tool('screenshot', { session: code, max_width: 640, quality: 30 }));
  assert.ok(lite < full / 2, `lite screenshot must be much smaller (${lite} vs ${full})`); console.log(`adaptive screenshot ok (${full} -> ${lite} bytes)`);
  const shot = await tool('screenshot', { session: code });
  assert.ok(shot.content.some((c) => c.type === 'image' && c.data.length > 1000)); console.log('screenshot ok');
}

await tool('end_session', { session: code });
await new Promise((r) => setTimeout(r, 500));
assert.equal(JSON.parse(txt(await tool('list_sessions'))).length, 0); console.log('end ok');
// brute-force guard: many wrong operator keys get locked out (run last: it blocks this IP for a while)
let last = 0;
for (let i = 0; i < 22; i++) last = (await fetch(BASE + '/mcp', { method: 'POST', headers: { Authorization: 'Bearer wrong-' + i } })).status;
assert.equal(last, 429); console.log('operator key brute-force guard ok');
console.log('ALL PASSED');
stop();
process.exit(0);
