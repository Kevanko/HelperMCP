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
  const r = spawn('node', [path.join(root, 'relay/server.js')], { env: { ...process.env, PORT, OPERATOR_KEY: KEY, IDLE_MS: '3000', JOB_SYNC_MS: '3000', TEST_FAKE_LATENCY_MS: process.env.GUI ? '2500' : '0', STATE_FILE: STATE }, stdio: 'inherit' });
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
assert.ok(imgRes.content.some((c) => c.type === 'image' && c.data.length > 20), 'read_file must return an image for .png'); console.log('read_file image ok');

// fetch_file: a file travels from the remote PC to the operator through the relay
const blob = Buffer.alloc(300_000); for (let i = 0; i < blob.length; i++) blob[i] = (i * 7 + 3) & 255;
const blobPath = path.join(tmp, 'blob.bin'); fs.writeFileSync(blobPath, blob);
const ff = txt(await tool('fetch_file', { session: code, path: blobPath }));
const furl = /(http\S+\/f\/\S+)\s+\(300000 bytes/.exec(ff)?.[1];
assert.ok(furl, 'fetch_file must return a link, got: ' + ff);
assert.ok(Buffer.from(await (await fetch(furl)).arrayBuffer()).equals(blob), 'downloaded file must be identical');
assert.equal((await fetch(BASE + '/f/' + '0'.repeat(24) + '/x')).status, 404); console.log('fetch_file ok');
// privacy: files rest encrypted on the relay's disk, the state file is encrypted, and both are gone with the session
globalThis.__furl = furl;

// files without shell one-liners: tree, find, line ranges, exact edits, append / binary writes, files both ways, folders as zip
const ft = path.join(tmp, 'tree'); fs.mkdirSync(path.join(ft, 'sub', 'deep'), { recursive: true });
fs.writeFileSync(path.join(ft, 'a.log'), 'one\ntwo NEEDLE here\nthree\n'); fs.writeFileSync(path.join(ft, 'sub', 'b.txt'), 'nothing'); fs.writeFileSync(path.join(ft, 'sub', 'deep', 'c.log'), 'x\r\nNeedle again\r\n');
const tre = txt(await tool('tree', { session: code, path: ft, depth: 3 }));
assert.match(tre, /sub\/\s+\(2\)/); assert.match(tre, /a\.log\s+\d+B/); assert.match(tre, /c\.log/); console.log('tree ok');
assert.doesNotMatch(txt(await tool('tree', { session: code, path: ft, depth: 3, pattern: '*.log' })), /b\.txt/);
const byName = txt(await tool('find', { session: code, path: ft, name: '*.log' }));
assert.match(byName, /a\.log/); assert.match(byName, /c\.log/); assert.doesNotMatch(byName, /b\.txt/);
const byText = txt(await tool('find', { session: code, path: ft, text: 'needle' }));
assert.match(byText, /a\.log:2: two NEEDLE here/); assert.match(byText, /c\.log:2: Needle again/); console.log('find ok');
const rng = txt(await tool('read_file', { session: code, path: path.join(ft, 'a.log'), offset: 2, lines: 1 }));
assert.match(rng, /^2\ttwo NEEDLE here\n\[lines 2-2 of 3\]$/); assert.match(txt(await tool('read_file', { session: code, path: path.join(ft, 'a.log'), tail: 1 })), /^3\tthree/); console.log('read_file ranges ok');
const crlf = path.join(ft, 'sub', 'deep', 'c.log');
assert.match(txt(await tool('edit_file', { session: code, path: crlf, old: 'x\nNeedle', new: 'y\nPin' })), /replaced 1/);
assert.equal(fs.readFileSync(crlf, 'utf8'), 'y\r\nPin again\r\n', 'edit_file keeps CRLF');
fs.writeFileSync(path.join(ft, 'dup.txt'), 'ab ab');
const amb = await raw('edit_file', { session: code, path: path.join(ft, 'dup.txt'), old: 'ab', new: 'c' });
assert.ok(amb.isError && /found 2 times/.test(txt(amb)) && /HINT:/.test(txt(amb)), 'ambiguous edit fails with a hint: ' + txt(amb));
assert.match(txt(await tool('edit_file', { session: code, path: path.join(ft, 'dup.txt'), old: 'ab', new: 'c', all: true })), /replaced 2/);
assert.equal(fs.readFileSync(path.join(ft, 'dup.txt'), 'utf8'), 'c c'); console.log('edit_file ok');
await tool('write_file', { session: code, path: path.join(ft, 'dup.txt'), content: '+tail', append: true });
assert.equal(fs.readFileSync(path.join(ft, 'dup.txt'), 'utf8'), 'c c+tail');
await tool('write_file', { session: code, path: path.join(ft, 'bin.dat'), content: Buffer.from([0, 255, 1, 128]).toString('base64'), base64: true });
assert.deepEqual([...fs.readFileSync(path.join(ft, 'bin.dat'))], [0, 255, 1, 128]); console.log('write_file append / base64 ok');
const pushed = path.join(ft, 'in', 'blob-copy.bin');
assert.match(txt(await tool('push_file', { session: code, url: globalThis.__furl, path: pushed })), /saved/);
assert.ok(fs.readFileSync(pushed).equals(blob), 'push_file delivers the exact bytes'); console.log('push_file ok');
const fz = txt(await tool('fetch_file', { session: code, path: path.join(ft, 'sub') }));
const zurl = /(http\S+\/f\/\S+\.zip)/.exec(fz)?.[1]; assert.ok(zurl, 'a folder comes back as a zip link: ' + fz);
const zip = Buffer.from(await (await fetch(zurl)).arrayBuffer());
assert.equal(zip.slice(0, 2).toString(), 'PK'); assert.ok(zip.includes(Buffer.from('b.txt')) && zip.includes(Buffer.from('c.log')), 'zip holds the folder'); console.log('fetch_file folder ok');

// system state and ready-made utilities
const sy = txt(await tool('system', { session: code }));
console.log(sy.slice(0, 1800)); assert.match(sy, /== overview/); assert.match(sy, /== disks/); assert.match(sy, /== processes/); assert.match(sy, /== network/); console.log('system ok');
assert.match(sy, /cpu%|pcpu|cpu/i, 'processes show cpu usage');
const drv = txt(await tool('system', { session: code, sections: ['drivers'] }));
assert.ok(/running|third-party|module/i.test(drv), 'drivers section answers: ' + drv.slice(0, 80)); console.log('system processes + drivers ok');
assert.match(txt(await tool('util', { session: code, op: 'env_get', name: 'PATH' })), useps ? /process: .+/ : /.+/);
assert.match(txt(await tool('util', { session: code, op: 'net_test', host: '127.0.0.1', port: PORT })), /tcp \d+: open/);
const zp = path.join(tmp, 'tree-copy.zip');
assert.match(txt(await tool('util', { session: code, op: 'zip', path: ft, dest: zp })), /tree-copy\.zip/);
assert.match(txt(await tool('util', { session: code, op: 'unzip', path: zp, dest: path.join(tmp, 'unz') })), /extracted/);
assert.ok(fs.existsSync(path.join(tmp, 'unz', 'tree', 'a.log')), 'unzip restores the folder'); console.log('util ok');

// no quoting traps: arguments reach the program byte for byte, and a missing program gets a hint
const tricky = `a "b" 'c' $d & | %e% \\ "\\"x\\\\" ü`;
const argOut = txt(await tool('run', { session: code, command: 'node', args: ['-e', 'process.stdout.write(JSON.stringify(process.argv.slice(1)))', tricky, '', 'two words'] }));
assert.equal(argOut.replace(/^\[exit 0\]\n/, ''), JSON.stringify([tricky, '', 'two words']), 'args arrive exactly: ' + argOut);
assert.match(txt(await tool('run', { session: code, command: 'node', args: ['-e', 'process.stdin.pipe(process.stdout)'], stdin: 'piped-in' })), /piped-in/); console.log('run args / stdin ok');
const nf = await raw('run', { session: code, command: 'definitely-not-a-program-xyz --version' });
assert.match(nf.content.map((c) => c.text).join(' '), /HINT: The program is not installed/);
assert.match(txt(await tool('misses', { limit: 5 })), /"hint":"not-found-cmd"/, 'the failure is in the mistake log'); console.log('error hint + mistake log ok');
const FDIR = path.join(path.dirname(STATE), 'files');
for (const f of fs.readdirSync(FDIR)) assert.ok(!fs.readFileSync(path.join(FDIR, f)).includes(blob.subarray(1000, 1064)), 'a fetched file must not be readable on the relay disk');
await new Promise((r) => setTimeout(r, 500));
assert.ok(!fs.readFileSync(STATE, 'utf8').includes(code), 'the state file must be encrypted');

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
const viewLink = (t) => t.match(/https?:\/\/\S+?\/v\/[0-9a-f]+(?=\s|$|#)/)[0];   // open_viewer gives a view link and a control link
const vurl0 = viewLink(txt(await tool('open_viewer', { session: code })));
await new Promise((x) => setTimeout(x, 500));          // let the debounced state file be written
relay.kill(); await new Promise((x) => setTimeout(x, 800));
relay = await startRelay();
const after = JSON.parse(txt(await tool('list_sessions')));
assert.ok(after.some((x) => x.code === code), 'session must be restored from the state file');
assert.match(txt(await tool('run', { session: code, command: 'echo after-restart' })), /after-restart/);
assert.match(await (await fetch(vurl0)).text(), /Remote screen/);
console.log('relay restart: session + agent + viewer link survive ok');

// resilience: the relay is gone for a few seconds (outage) and comes back WITHOUT its state (fresh server): the agent registers again and keeps the same code
relay.kill(); await new Promise((x) => setTimeout(x, 9000));
fs.rmSync(STATE, { force: true });
relay = await startRelay();
let back = [];
for (let i = 0; i < 40 && !back.some((x) => x.code === code); i++) { await new Promise((x) => setTimeout(x, 500)); back = JSON.parse(txt(await tool('list_sessions'))); }
assert.ok(back.some((x) => x.code === code && x.online), `agent must re-register with the same code, got ${JSON.stringify(back)}`);
assert.match(txt(await tool('run', { session: code, command: 'echo after-reset' })), /after-reset/);
assert.match(agentOut, /connection lost|Связь потеряна|Connection lost/i); assert.match(agentOut, /connection restored|registered again|Связь восстановлена|Connection restored/i);
console.log('outage + fresh server: agent reconnects with the same code ok');

// live viewer: link from open_viewer, page, action log, frame (frame needs a desktop: GUI=1)
const vtxt = txt(await tool('open_viewer', { session: code })); const vurl = viewLink(vtxt);
assert.ok(/#c=[0-9a-f]{24}/.test(vtxt), 'open_viewer also gives a control link');
assert.match(vurl, new RegExp(`^${BASE}/v/[0-9a-f]{36}$`));
const page = await (await fetch(vurl)).text();
assert.match(page, /Remote screen/);
// regression: /v/<token> has no trailing slash, so a relative fetch('frame') resolved to /v/frame (404) and the viewer stayed empty
assert.ok(!/fetch\('(frame|log)/.test(page) && page.includes("location.pathname.split('/').slice(0,3)"), 'viewer must build absolute frame/log URLs');
const vlog = await (await fetch(vurl + '/log')).json();
assert.ok(vlog.some((e) => e.tool === 'run') && !vlog.some((e) => e.args.includes('view')), 'log shows actions, not viewer frames');
assert.equal((await fetch(BASE + '/v/' + '0'.repeat(36))).status, 404);
assert.equal((await fetch(vurl + '/input', { method: 'POST', body: '{"a":"key","keys":"x"}' })).status, 403, 'the view-only link cannot control');
if (process.env.GUI) { const fr = await fetch(vurl + '/frame'); assert.equal(fr.headers.get('content-type'), 'image/jpeg'); assert.ok((await fr.arrayBuffer()).byteLength > 1000); }
console.log('viewer ok');
// files from the live view (control link only): browse, download, drop a file onto the PC; the AI hears about the upload
const ctl = { 'x-ctl': /#c=([0-9a-f]+)/.exec(vtxt)[1] };
assert.equal((await fetch(vurl + '/ls?path=' + encodeURIComponent(tmp))).status, 403, 'view-only link cannot browse files');
const lsj = await (await fetch(vurl + '/ls?path=' + encodeURIComponent(tmp), { headers: ctl })).json();
assert.match(lsj.text, /tree\/\s+\(\d+\)/); assert.match(lsj.text, /blob\.bin/);
const gj = await (await fetch(vurl + '/get', { method: 'POST', headers: { ...ctl, 'content-type': 'application/json' }, body: JSON.stringify({ path: blobPath }) })).json();
assert.ok(Buffer.from(await (await fetch(gj.text.split(' ')[0])).arrayBuffer()).equals(blob), 'download from the viewer');
const uj = await (await fetch(vurl + '/upload?name=' + encodeURIComponent('от оператора.txt') + '&dir=' + encodeURIComponent(tmp), { method: 'POST', headers: ctl, body: 'hello from the viewer' })).json();
assert.ok(uj.path && fs.readFileSync(uj.path, 'utf8') === 'hello from the viewer', 'upload lands on the PC: ' + JSON.stringify(uj));
assert.match((await tool('sysinfo', { session: code })).content.map((c) => c.text).join(' '), /The operator put these files on the remote PC/); console.log('viewer files ok');
const victim = spawn(process.execPath, ['-e', 'setTimeout(()=>{}, 60000)']); kids.push(victim);
await new Promise((x) => setTimeout(x, 400));
assert.equal((await fetch(vurl + '/kill', { method: 'POST', body: JSON.stringify({ pid: victim.pid }) })).status, 403, 'view-only link cannot end processes');
const kj = await fetch(vurl + '/kill', { method: 'POST', headers: { ...ctl, 'content-type': 'application/json' }, body: JSON.stringify({ pid: victim.pid }) });
assert.equal(kj.status, 200, 'control link ends a process: ' + await kj.text());
await new Promise((x) => setTimeout(x, 800));
assert.throws(() => process.kill(victim.pid, 0), /ESRCH|kill/, 'the process is gone'); console.log('viewer kill ok');

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
  // the pointer glides to the target (move) and ends up exactly there
  await tool('screenshot', { session: code });                         // sets the coordinate system the AI uses
  const where = async () => txt(await tool('run', { session: code, command: useps
    ? "Add-Type -AssemblyName System.Windows.Forms; $p = [Windows.Forms.Cursor]::Position; \"$($p.X),$($p.Y)\""
    : "python3 -c \"import gi; gi.require_version('Gdk','3.0'); from gi.repository import Gdk; print(*Gdk.Display.get_default().get_default_seat().get_pointer().get_position()[1:], sep=',')\"" }));
  const sh = await tool('screenshot', { session: code });
  await tool('move', { session: code, x: 400, y: 300 });
  const m1 = /(\d+),(\d+)/.exec(await where());
  assert.ok(m1, 'pointer position unreadable');
  await tool('move', { session: code, x: 600, y: 420 });
  const m2 = /(\d+),(\d+)/.exec(await where());
  assert.ok(Math.abs(m2[1] - m1[1]) > 50 && Math.abs(m2[2] - m1[2]) > 30, `the pointer must have moved between targets: ${m1[0]} -> ${m2[0]}`);
  console.log(`move ok (pointer ${m1[0]} -> ${m2[0]})`);
  // adaptive viewer: frames pretend to be slow (2.5 s) -> the relay steps the quality down and the frames shrink
  const vlevels = [], vsizes = [];
  for (let i = 0; i < 8 && vlevels.at(-1) !== 0; i++) {
    const fr = await fetch(vurl + '/frame?' + i);
    if (fr.status === 200) { vlevels.push(Number(fr.headers.get('x-quality'))); vsizes.push((await fr.arrayBuffer()).byteLength); }
    await new Promise((x) => setTimeout(x, 100));
  }
  assert.equal(vlevels.at(-1), 0, `viewer must step down to the lowest quality on a slow link: ${vlevels}`);
  assert.ok(vsizes.length === 1 || vsizes.at(-1) < vsizes[0], `frames must shrink: ${vsizes}`);
  console.log(`viewer adapts to a slow link ok (levels ${vlevels}, bytes ${vsizes})`);
  const shot = await tool('screenshot', { session: code });
  assert.ok(shot.content.some((c) => c.type === 'image' && c.data.length > 200)); console.log('screenshot ok');
  // live stream (like a video call): a full picture first, then only the tiles that changed while the pointer moves
  const ac = new AbortController(), lr = await fetch(vurl + '/live', { signal: ac.signal });
  assert.equal(lr.status, 200);
  const rd = lr.body.getReader(), seen = [], t0 = Date.now(); let lbuf = Buffer.alloc(0);
  const mover = (async () => { await new Promise((x) => setTimeout(x, 1500)); for (let i = 0; i < 8; i++) await tool('move', { session: code, x: 300 + i * 70, y: 320 + (i % 2) * 60 }); })();
  while (Date.now() - t0 < 9000) {
    const { value, done } = await rd.read(); if (done) break;
    lbuf = Buffer.concat([lbuf, Buffer.from(value)]);
    while (lbuf.length >= 5) { const n = lbuf.readUInt32BE(0); if (lbuf.length < 5 + n) break; seen.push({ ty: String.fromCharCode(lbuf[4]), n, t: Date.now() - t0 }); if (lbuf[4] === 83 && !globalThis.__snap) globalThis.__snap = JSON.parse(lbuf.subarray(5, 5 + n).toString('utf8')); lbuf = lbuf.subarray(5 + n); }
  }
  ac.abort(); await mover;
  const firstK = seen.find((f) => f.ty === 'K')?.t, tiles = seen.filter((f) => f.ty === 'T');
  assert.ok(firstK !== undefined && firstK < 3000, 'a full picture arrives within 3 s: ' + JSON.stringify(seen.slice(0, 5)));
  assert.ok(tiles.length >= 3, 'changed tiles stream while the pointer moves: ' + JSON.stringify(seen.slice(0, 20)));
  const snap = globalThis.__snap; assert.ok(snap && snap.p.length && snap.p.every((r) => r.length === 7 && typeof r[1] === 'string' && typeof r[2] === 'number' && typeof r[3] === 'number' && (r[6] === '' || r[6] === '!')), 'System snapshot rows are [pid, name, cpu, mem, publisher, path, flag]: ' + JSON.stringify(snap?.p?.[0]));
  assert.ok(snap.mem >= 0 && snap.ramTotal > 0 && snap.n > 0, 'snapshot totals');
  assert.ok(seen.some((f) => f.ty === 'S'), 'the live System panel snapshot arrives with the stream: ' + JSON.stringify(seen.map((f) => f.ty).join('')));
  console.log(`live stream ok (first picture after ${firstK} ms, ${seen.filter((f) => f.ty === 'K').length} full + ${tiles.length} tile frames, ${Math.round(seen.reduce((a, f) => a + f.n, 0) / 1024)} KB in 9 s)`);
}

await tool('end_session', { session: code });
await new Promise((r) => setTimeout(r, 500));
assert.equal(JSON.parse(txt(await tool('list_sessions'))).length, 0); console.log('end ok');
assert.equal((await fetch(globalThis.__furl)).status, 404, 'files of an ended session must be deleted'); console.log('privacy ok');
// brute-force guard: many wrong operator keys get locked out (run last: it blocks this IP for a while)
let last = 0;
for (let i = 0; i < 22; i++) last = (await fetch(BASE + '/mcp', { method: 'POST', headers: { Authorization: 'Bearer wrong-' + i } })).status;
assert.equal(last, 429); console.log('operator key brute-force guard ok');
console.log('ALL PASSED');
stop();
process.exit(0);
