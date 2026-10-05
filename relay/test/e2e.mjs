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

const relay = spawn('node', [path.join(root, 'relay/server.js')], { env: { ...process.env, PORT, OPERATOR_KEY: KEY, IDLE_MS: '3000' }, stdio: 'inherit' });
kids.push(relay);
for (let i = 0; i < 50; i++) { try { if ((await fetch(BASE + '/health')).ok) break; } catch {} await new Promise((r) => setTimeout(r, 100)); }

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
const tool = async (name, args = {}) => client.callTool({ name, arguments: args });
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

const slow = txt(await tool('run', { session: code, command: useps ? 'Start-Sleep 20' : 'sleep 20', timeout_s: 1 }));
assert.match(slow, /timeout/); console.log('timeout ok');

// bridge: start another MCP server on the "friend's PC" and use it through the relay
const echoJs = path.join(root, 'relay/test/echo-mcp.mjs');
const started = txt(await tool('mcp_start', { session: code, name: 'echo', command: 'node', args: [echoJs] }));
assert.match(started, /echo: 1 tools: say/); console.log('mcp_start ok');
if (process.env.PORTABLE) { assert.match(agentOut, /downloading portable Node/); console.log('portable node ok'); }
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
const busy = txt(await tool('run', { session: code, command: useps ? 'Start-Sleep 6; echo done' : 'sleep 6; echo done', timeout_s: 30 }));
assert.match(busy, /done/); console.log('long call survives idle limit ok');

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

const bad = await tool('run', { session: 'NOPE-NOPE', command: 'x' });
assert.ok(bad.isError); console.log('bad session ok');

if (process.env.GUI) {
  const shot = await tool('screenshot', { session: code });
  assert.ok(shot.content.some((c) => c.type === 'image' && c.data.length > 1000)); console.log('screenshot ok');
}

await tool('end_session', { session: code });
await new Promise((r) => setTimeout(r, 500));
assert.equal(JSON.parse(txt(await tool('list_sessions'))).length, 0); console.log('end ok');
console.log('ALL PASSED');
stop();
process.exit(0);
