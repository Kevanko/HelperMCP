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
import { createAdmin } from '../admin.mjs';

const root = path.join(path.dirname(fileURLToPath(import.meta.url)), '..', '..');
const PORT = 18900 + Math.floor(Math.random() * 90), BASE = `http://127.0.0.1:${PORT}`, KEY = 'keep-test-key';
const SDIR = fs.mkdtempSync(path.join(os.tmpdir(), 'hm-keepstate-')), STATE = path.join(SDIR, 'relay-state.json');
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
const startAgent = (again = false, mode = 'unattended', enableStartup = false) => { const env = { ...process.env, ...(again ? {} : { HELPER_MODE: mode, HELPER_PERSIST: '1' }),
    HELPER_STATE_DIR: SDIR, HELPER_NO_AUTOSTART: enableStartup ? '' : '1', HELPER_NO_OVERLAY: '1', HELPER_LANG: 'en', HELPER_TOKEN_FILE: TOKEN_FILE };
  const a = PS ? spawn('powershell', ['-NoProfile', '-Command', `[Net.ServicePointManager]::SecurityProtocol=3072; irm ${BASE}/h | iex`], { env }) : spawn('python3', [file], { env }); kids.push(a); a.stdout.on('data', (d) => (agentOut += d)); a.stderr.on('data', (d) => (agentOut += d)); return a; };

let client = new Client({ name: 'keep', version: '0' });
await client.connect(new StreamableHTTPClientTransport(new URL(BASE + '/mcp'), { requestInit: { headers: { Authorization: 'Bearer ' + KEY } } }));
const call = async (name, args = {}) => { const r = await client.callTool({ name, arguments: args }); return { err: !!r.isError, text: r.content.find((c) => c.type === 'text')?.text ?? '' }; };
const sessions = async () => JSON.parse((await call('list_sessions')).text);
const waitFor = async (fn, what, ms = 15000) => { const t0 = Date.now(); while (Date.now() - t0 < ms) { const v = await fn(); if (v) return v; await sleep(200); } assert.fail('timeout: ' + what + '\n--- state dir: ' + JSON.stringify(fs.readdirSync(SDIR)) + '\n--- agent output ---\n' + agentOut); };

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

if (PS) {
  const duplicate = startAgent(true);
  await waitFor(() => duplicate.exitCode !== null, 'duplicate Windows launcher exits', 30000);
  assert.equal(duplicate.exitCode, 0, agentOut);
  assert.match(agentOut, /Helper (?:is already running)|Helper уже работает/);
  const active = JSON.parse((await call('session_log', { session: code })).text);
  assert.ok(!active.events.some(e => e.type === 'resumed'), 'second launcher registered the saved session');
  assert.match((await call('run',{session:code,command:'echo original-still-running'})).text, /original-still-running/);
  console.log('Duplicate Windows launcher leaves the original saved session in control PASS');
}

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
const exited = new Promise((resolve) => agent.once('exit', resolve));
killAgent(agent);
await exited;
await post('/a/bye', { final: true }); await sleep(500);
assert.equal((await sessions()).length, 0, 'the confirmed end removes the session');
// The next launch must see the tombstone and clear its stale local state.
// In particular it must neither retry HTTP 410 nor open a replacement session.
agent = startAgent(true);
await waitFor(() => agent.exitCode !== null, 'stale saved session exits on HTTP 410', 25000);
assert.equal(agent.exitCode, 0, agentOut);
assert.equal(fs.existsSync(sfile), false, 'ended session retained on disk');
assert.equal((await sessions()).length, 0, 'restart recreated an ended session');
console.log('Ended saved session is cleared after HTTP 410 PASS');

// Exercise the actual consent window and cached-mode launch on the isolated Windows runner.
if (PS && process.env.GITHUB_ACTIONS === 'true') {
  function scheduler(script) {
    const command=Buffer.from("$ErrorActionPreference='Stop'; $ProgressPreference='SilentlyContinue'; " + script,'utf16le').toString('base64');
    const result=spawnSync('powershell',['-NoProfile','-NonInteractive','-EncodedCommand',command],
      { encoding:'utf8',timeout:25000,env:{...process.env,HELPER_FIXTURE_DIR:SDIR} });
    if(result.error) throw result.error;
    assert.equal(result.status,0,result.stderr);
    return result.stdout.trim();
  }
  const ownedTask = '$task=Get-ScheduledTask -TaskName HelperMCP -ErrorAction SilentlyContinue; ' +
    'if ($task -and $task.Actions[0].Arguments -match "-EncodedCommand ([A-Za-z0-9+/=]+)$") { ' +
    '$command=[Text.Encoding]::Unicode.GetString([Convert]::FromBase64String($Matches[1])); ' +
    '$expected = Join-Path ([IO.Path]::GetFullPath($env:HELPER_FIXTURE_DIR)) "agent.ps1"; ' +
    'if ($command.IndexOf($expected, [StringComparison]::OrdinalIgnoreCase) -lt 0) { throw "Unexpected HelperMCP task" } } else { $task=$null }; ';
  assert.equal(scheduler('if (Get-ScheduledTask -TaskName HelperMCP -ErrorAction SilentlyContinue) { "existing" }'),'',
    'a task already exists on the disposable runner');
  const responder = path.join(SDIR, 'accept-fixture-dialog.ps1');
  fs.writeFileSync(responder, [
    'param([int]$AgentPid, [string]$ButtonName = "Allow")',
    '$ErrorActionPreference = "Stop"',
    'Add-Type -AssemblyName UIAutomationClient, UIAutomationTypes',
    '$element = [Windows.Automation.AutomationElement]',
    '$pidMatch = [Windows.Automation.PropertyCondition]::new($element::ProcessIdProperty, $AgentPid)',
    '$titleMatch = [Windows.Automation.PropertyCondition]::new($element::NameProperty, "HelperMCP")',
    '$match = [Windows.Automation.AndCondition]::new([Windows.Automation.Condition[]]@($pidMatch, $titleMatch))',
    '$button = [Windows.Automation.PropertyCondition]::new($element::NameProperty, $ButtonName)',
    'Add-Type -Namespace Fixture -Name Window -MemberDefinition @\'',
    '[StructLayout(LayoutKind.Sequential)] public struct Point { public int X; public int Y; }',
    '[DllImport("user32.dll")] public static extern IntPtr WindowFromPoint(Point point);',
    '[DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd, out uint pid);',
    '[DllImport("user32.dll")] public static extern bool SetCursorPos(int x, int y);',
    '[DllImport("user32.dll")] public static extern bool SetProcessDPIAware();',
    '[DllImport("user32.dll")] public static extern void mouse_event(uint flags, uint x, uint y, uint data, UIntPtr extra);',
    '\'@',
    '[void][Fixture.Window]::SetProcessDPIAware()',
    '$until = [DateTime]::UtcNow.AddSeconds(25)',
    'do {',
    '  $window = $element::RootElement.FindFirst("Children", $match)',
    '  if ($window) {',
    '    $accept = $window.FindFirst("Descendants", $button)',
    '    if ($accept) {',
    '      $invoke = $null',
    '      if ($accept.TryGetCurrentPattern([Windows.Automation.InvokePattern]::Pattern, [ref]$invoke)) { $invoke.Invoke(); exit 0 }',
    '      $rect = $accept.Current.BoundingRectangle',
    '      if (-not $rect.IsEmpty) {',
    '        $point = New-Object "Fixture.Window+Point"',
    '        $point.X = [int]($rect.X + $rect.Width / 2); $point.Y = [int]($rect.Y + $rect.Height / 2)',
    '        $hwnd = [Fixture.Window]::WindowFromPoint($point); [uint32]$owner = 0',
    '        [void][Fixture.Window]::GetWindowThreadProcessId($hwnd, [ref]$owner)',
    '        if ($owner -eq $AgentPid -and [Fixture.Window]::SetCursorPos($point.X, $point.Y)) {',
    '          [Fixture.Window]::mouse_event(2, 0, 0, 0, [UIntPtr]::Zero)',
    '          [Fixture.Window]::mouse_event(4, 0, 0, 0, [UIntPtr]::Zero)',
    '          exit 0',
    '        }',
    '      }',
    '    }',
    '  }',
    '  Start-Sleep -Milliseconds 100',
    '} while ([DateTime]::UtcNow -lt $until)',
    'throw "Fixture consent button did not appear"',
  ].join('\n'));
  async function answerDialog(target, request, button='Allow') {
    const responderProc = spawn('powershell',['-NoProfile','-STA','-File',responder,String(target.pid),button]);
    kids.push(responderProc);
    let details='';
    responderProc.stderr.on('data',data=>details+=data);
    const closed=new Promise((resolve,reject)=>{
      responderProc.once('error',reject);
      responderProc.once('close',resolve);
    });
    const [result,exit] = await Promise.all([request(),closed]);
    assert.equal(exit,0,details + '\n' + agentOut.slice(-2600));
    return result;
  }
  async function approve(target, session) {
    const result = await answerDialog(target, () => call('request_access',{session}));
    assert.ok(!result.err && /Access approved/.test(result.text),result.text);
  }
  let fixtureError;
  try {
    // Keep the ordinary logon path on Node 18 and exercise the local tray
    // preference through the same real Task Scheduler workflow on Node 22.
    const startInTray = process.versions.node.startsWith('22.');
    agent=startAgent(false,'auto',true);
    const mode2=await waitFor(async()=>(await sessions()).find(s=>s.online && s.mode==='auto'),'mode 2 registration');
    const args={session:mode2.code};
    assert.match((await call('open_viewer',args)).text,/ACCESS_REQUIRED|request access/i);
    const askedAt=Date.now();
    await approve(agent,mode2.code);
    const view=await call('open_viewer',args);
    assert.ok(!view.err,view.text);
    const watch=view.text.match(/https?:\/\/\S+?\/v\/[0-9a-f]+(?=\s|$|#)/)[0];
    await waitFor(()=>fs.existsSync(sfile),'mode 2 saved before process exit');
    await waitFor(()=>scheduler(ownedTask+'if ($task) { $task.Triggers[0].CimClass.CimClassName }')==='MSFT_TaskLogonTrigger',
      'Helper installed its logon task',20000);
    if(startInTray) {
      // Verify the real Windows dialog and the persisted choice before logon.
      const creds=createAdmin(SDIR);
      const auth=await fetch(BASE+'/admin/api/login',{method:'POST',headers:{'content-type':'application/json'},
        body:JSON.stringify({user:creds.user,pass:creds.password})});
      assert.equal(auth.status,200);
      const cookie=auth.headers.get('set-cookie').split(';')[0], {csrf}=await auth.json();
      const preferences={startup:true,quiet:false,start_in_tray:true};
      const request=()=>fetch(BASE+'/admin/api/launch-preferences',{method:'POST',
        headers:{cookie,'x-csrf':csrf,'content-type':'application/json'},
        body:JSON.stringify({code:mode2.code,preferences})});
      const prefsFile=path.join(SDIR,'preferences.json');
      const readPrefs=()=>fs.existsSync(prefsFile)?JSON.parse(fs.readFileSync(prefsFile,'utf8').replace(/^\uFEFF/,'')):null;
      const before=readPrefs();
      const declined=await answerDialog(agent, request, 'Decline');
      assert.equal(declined.status,409);
      assert.deepEqual(readPrefs(),before,'declining the native dialog changed launch settings');
      const approved=await answerDialog(agent, request);
      assert.equal(approved.status,200);
      assert.deepEqual((await approved.json()).preferences,preferences);
      assert.deepEqual(readPrefs(),preferences);
      console.log('Native Windows launch settings dialog preserves the prior choice on decline and persists only after approval PASS');
    }
    const endedMode2=new Promise(resolve=>agent.once('exit',resolve));
    killAgent(agent);
    await endedMode2;
    scheduler(ownedTask+'if (-not $task) { throw "Helper logon task missing" }; Start-ScheduledTask -InputObject $task');
    await waitFor(async()=>{
      const log=JSON.parse((await call('session_log',args)).text);
      return log.events.some(e=>e.type==='resumed');
    },'mode 2 saved credential resumed at logon',25000);
    const resumed=(await sessions()).find(s=>s.code===mode2.code);
    assert.ok(resumed.online && resumed.mode==='auto' && resumed.kept,'logon lost mode 2 or its code');
    const blocked=await call('run',{...args,command:'echo should-not-run'});
    assert.ok(blocked.err && /ACCESS_REQUIRED/.test(blocked.text),blocked.text);
    assert.equal((await fetch(watch)).status,404,'old viewer remained valid across restart');
    const resumedToken=fs.readFileSync(TOKEN_FILE,'utf8').trim();
    assert.equal((await fetch(BASE+'/a/input',{headers:{Authorization:'Bearer '+resumedToken}})).status,409,'native input was available without consent');
    await sleep(Math.max(0,10_100-(Date.now()-askedAt)));
    const processFilter = startInTray
      ? '$filePattern=[regex]::Escape([IO.Path]::GetFullPath($env:HELPER_FIXTURE_DIR))+"\\\\detach-[0-9a-f]{32}\\.ps1"; ' +
        '$found=@(Get-CimInstance Win32_Process -Filter "Name = \'powershell.exe\'" | Where-Object { $_.CommandLine -match $filePattern }); '
      : '$action=$task.Actions[0].Arguments; $found=@(Get-CimInstance Win32_Process -Filter "Name = \'powershell.exe\'" | ' +
        'Where-Object { $_.CommandLine -and $_.CommandLine.EndsWith($action) }); ';
    const scheduledPid=Number(scheduler(ownedTask+'if (-not $task) { throw "Helper logon task missing" }; ' + processFilter +
      'if ($found.Count -ne 1) { throw "The scheduled Helper process is ambiguous or missing" }; $found[0].ProcessId'));
    assert.ok(Number.isInteger(scheduledPid) && scheduledPid>0);
    await approve({pid:scheduledPid},mode2.code);
    assert.match((await call('run',{...args,command:'echo approved-again'})).text,/approved-again/);
    assert.ok(!(await call('end_session',args)).err);
    await waitFor(() => !fs.existsSync(sfile) && scheduler(ownedTask + 'if ($task) { "registered" }') === '',
      'ending mode 2 removes both the saved session and the logon task', 20000);
    console.log('Windows Task Scheduler launches mode 2 with the same code, revokes the old viewer, requires fresh local consent and removes autostart when ended PASS');
    if(startInTray) console.log('Saved local preference starts the scheduled Helper in the notification area PASS');
  } catch (error) {
    fixtureError = error;
    throw error;
  } finally {
    try {
      scheduler(ownedTask+'if ($task) { Stop-ScheduledTask -InputObject $task -ErrorAction SilentlyContinue; ' +
        'try { Unregister-ScheduledTask -InputObject $task -Confirm:$false } catch { ' +
        'if (Get-ScheduledTask -TaskName HelperMCP -ErrorAction SilentlyContinue) { throw } } }');
    } catch (error) {
      if (!fixtureError) throw error;
      console.error('Fixture cleanup also failed:', error.message);
    }
  }
}
console.log('ALL PASSED');
stop(); fs.rmSync(STATE, { force: true }); process.exit(0);
