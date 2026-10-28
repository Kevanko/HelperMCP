// Network tools through the real Windows agent, without mouse/keyboard or UI fixtures.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import crypto from 'node:crypto';
import netSocket from 'node:net';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { Client } from '@modelcontextprotocol/sdk/client/index.js';
import { StreamableHTTPClientTransport } from '@modelcontextprotocol/sdk/client/streamableHttp.js';

if (process.platform !== 'win32') { console.log('Windows network agent integration skipped'); process.exit(0); }
const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'hm-network-'));
const port = 19000 + Math.floor(Math.random() * 1000), base = `http://127.0.0.1:${port}`;
const log = path.join(temp, 'actions.jsonl'), kids = [];
let output = '', client;
const sleep = (ms) => new Promise((resolve) => setTimeout(resolve, ms));
const stop = () => kids.forEach((p) => { try { p.kill(); } catch {} });
process.on('exit', stop);
try {
  kids.push(spawn('node', [path.join(root, 'relay/server.js')], { env: {
    ...process.env, PORT: String(port), OPERATOR_KEY: 'network-test-key', STATE_FILE: path.join(temp, 'state.json'),
    ACT_FILE: log, ADMIN_DIR: path.join(temp, 'admin'),
  }, stdio: 'pipe' }));
  for (let n = 0; n < 80; n++) { try { if ((await fetch(base + '/health')).ok) break; } catch {} await sleep(100); }
  const bootstrap = await (await fetch(base + '/h')).text();
  assert.ok(!/__NETWORK_|__RKN_RUNNER_|__RECOVERY_|__PROFILE_CS__|__YAML_|__BUILD__/.test(bootstrap), 'incomplete bootstrap bundle');
  assert.equal((await fetch(base + '/a/deps/yamldotnet-18.1.0.dll')).status, 401, 'dependency access must require the session token');
  const launcher = await (await fetch(base + '/h.cmd')).text();
  const encoded = /-EncodedCommand ([A-Za-z0-9+/=]+)/.exec(launcher)[1];
  const ps = Buffer.from(encoded, 'base64').toString('utf16le');
  assert.match(ps, /TimeoutSec 12/); assert.match(ps, /startup failed/);
  const agent = spawn('powershell', ['-NoProfile', '-Command', `irm ${base}/h | iex`], { env: {
    ...process.env, HELPER_MODE: 'full', HELPER_STATE_DIR: path.join(temp, 'agent'), HELPER_NO_AUTOSTART: '1', HELPER_NO_OVERLAY: '1',
  } }); kids.push(agent);
  agent.stdout.on('data', (s) => { output += s; }); agent.stderr.on('data', (s) => { output += s; });
  client = new Client({ name: 'network-test', version: '1' });
  await client.connect(new StreamableHTTPClientTransport(new URL(base + '/mcp'), { requestInit: { headers: { Authorization: 'Bearer network-test-key' } } }));
  const text = (r) => r.content.find((c) => c.type === 'text')?.text || '';
  const call = async (name, args = {}) => {
    let result = await client.callTool({ name, arguments: args });
    for (let n = 0; n < 10; n++) {
      const job = /Still running .*?\(job (\w+)/.exec(text(result)); if (!job) break;
      result = await client.callTool({ name: 'wait_job', arguments: { job: job[1], wait_s: 20 } });
    }
    return result;
  };
  let code;
  for (let n = 0; n < 120 && !code; n++) { code = JSON.parse(text(await call('list_sessions')))[0]?.code; if (!code) await sleep(200); }
  assert.ok(code, output);
  const net = async (args) => { const r = await call('net_check', { session: code, ...args }); assert.ok(!r.isError, text(r)); return JSON.parse(text(r)); };
  const common = { mode: 'sites', single_path: true, urls: [base + '/health'], samples: 2, timeout_ms: 500 };
  const templatesResult = await call('net_recover', { session: code, op: 'templates' });
  assert.ok(!templatesResult.isError, text(templatesResult));
  const templates = JSON.parse(text(templatesResult));
  assert.equal(templates.templates.length, 8);
  assert.ok(templates.templates.some((t) => t.id === 'disconnect'));
  const list = await call('net_recover', { session: code, op: 'list' });
  assert.ok(!list.isError, text(list));
  const report = await net(common);
  assert.equal(report.results[0].samples, 2); assert.equal(report.results[0].failed, 0);
  assert.deepEqual(report.results[0].bytes, [2, 2]); assert.deepEqual(report.results[0].http_status, [200]);
  assert.equal(report.results[0].timing_min_median_max.tcp_ms.length, 3);
  const detail = await net({ ...common, detail: true });
  assert.equal(detail.results[0].route.index, 0); assert.ok(detail.results[0].samples.every((s) => s.status === 200 && s.bytes === 2));
  const missing = await call('net_check', { session: code, ...common, interface_index: 2147483647 });
  assert.ok(missing.isError); assert.match(text(missing), /Adapter is down/);
  const secret = 'never-log-this-subscription-token';
  const invalid = await call('net_check', { session: code, ...common, urls: [base + '/sub?token=' + secret] });
  assert.ok(invalid.isError);
  const file = path.join(temp, 'export.txt');
  fs.writeFileSync(file, `vless://${secret}@example.com:443?security=reality#Name\nhy2://${secret}@udp.example.com:8443#Name\n`);
  const inventory = await net({ mode: 'inventory', config_path: file });
  assert.equal(inventory.count, 2); assert.ok(!JSON.stringify(inventory).includes(secret));
  assert.ok(inventory.endpoints.some((e) => e.requires_udp_test));
  // Exercise the first authenticated dependency download, including a corrupt
  // local cache. A fresh process must never load the unverified cached bytes.
  const dependencies = path.join(temp, 'agent', 'dependencies');
  fs.mkdirSync(dependencies, { recursive: true });
  fs.writeFileSync(path.join(dependencies, 'YamlDotNet-18.1.0.dll'), Buffer.alloc(fs.statSync(path.join(root, 'agent/vendor/yamldotnet/YamlDotNet.dll')).size));
  const yaml = `defaults: &base {type: vless, port: 443, uuid: ${secret}}\nproxies:\n- <<: *base\n  server: first.example.com\n- {type: hysteria2, server: udp.example.com, port: 8443, password: ${secret}}\nproxy-providers:\n  private: {url: 'https://private.example/sub?token=${secret}'}\n`;
  const yamlFile = path.join(temp, 'export.yaml'); fs.writeFileSync(yamlFile, yaml);
  const invalidCore = await call('net_check', { session: code, mode: 'profile', config_path: yamlFile, core_path: path.join(temp, 'missing-mihomo.exe'), urls: ['https://example.com/'] });
  assert.ok(invalidCore.isError, 'profile must refuse a missing core before launch');
  assert.match(text(invalidCore), /core_path/); assert.ok(!text(invalidCore).includes(secret));
  const yamlInventory = await net({ mode: 'inventory', config_path: yamlFile });
  assert.equal(yamlInventory.format, 'yaml'); assert.equal(yamlInventory.count, 2, JSON.stringify(yamlInventory));
  assert.deepEqual(yamlInventory.warnings, []); assert.ok(!JSON.stringify(yamlInventory).includes(secret));
  assert.ok(yamlInventory.endpoints.some((e) => e.host === 'udp.example.com' && e.requires_udp_test));
  assert.equal(fs.readFileSync(yamlFile, 'utf8'), yaml, 'inventory modified the client export');
  const yamlManifest = JSON.parse(fs.readFileSync(path.join(root, 'agent/vendor/yamldotnet/manifest.json')));
  assert.equal(crypto.createHash('sha256').update(fs.readFileSync(path.join(dependencies, 'YamlDotNet-18.1.0.dll'))).digest('hex'), yamlManifest.dll_sha256);
  if (process.env.HELPER_TEST_MIHOMO) {
    const uuid = '11111111-2222-3333-4444-555555555555'; let accepted = 0;
    const fixture = netSocket.createServer((socket) => {
      let buffered = Buffer.alloc(0), ready = false;
      socket.setTimeout(8000, () => socket.destroy());
      socket.on('error', () => {});
      socket.on('data', (chunk) => {
        buffered = Buffer.concat([buffered, chunk]);
        if (!ready) {
          if (buffered.length < 22) return;
          const offset = 18 + buffered[17]; if (buffered.length < offset + 5) return;
          const type = buffered[offset + 3];
          const end = offset + 4 + (type === 1 ? 4 : type === 3 ? 16 : 1 + buffered[offset + 4]);
          if (buffered.length < end) return;
          if (buffered[0] !== 0 || buffered.subarray(1, 17).toString('hex') !== uuid.replaceAll('-', '') || buffered[offset] !== 1) { socket.destroy(); return; }
          accepted++; ready = true; buffered = buffered.subarray(end); socket.write(Buffer.from([0, 0]));
        }
        if (buffered.includes('\r\n\r\n')) socket.end('HTTP/1.1 200 OK\r\nContent-Length: 12\r\nConnection: close\r\n\r\nprofile-body');
      });
    });
    await new Promise((resolve) => fixture.listen(0, '127.0.0.1', resolve));
    try {
      const profileFile = path.join(temp, 'mihomo-test.yaml');
      fs.writeFileSync(profileFile, `proxies:\n- {name: fixture, type: vless, server: 127.0.0.1, port: ${fixture.address().port}, uuid: ${uuid}, tls: false}\n`);
      const checked = await net({ mode: 'profile', config_path: profileFile, core_path: process.env.HELPER_TEST_MIHOMO, urls: ['http://fixture.target.invalid/health'] });
      assert.equal(checked.status, 'profile_http_verified', JSON.stringify(checked));
      assert.equal(checked.results[0].bytes, 12); assert.ok(checked.cleanup_complete && accepted > 0);
      assert.ok(!JSON.stringify(checked).includes(uuid));
      console.log('Actual MCP profile dispatch, authenticated VLESS/HTTP and owned-core cleanup PASS');
    } finally { await new Promise((resolve) => fixture.close(resolve)); }
  }
  fs.writeFileSync(yamlFile, `proxies: [{password: '${secret}', server: unclosed`);
  const brokenYaml = await net({ mode: 'inventory', config_path: yamlFile });
  assert.equal(brokenYaml.count, 0); assert.match(brokenYaml.warnings.join(' '), /Invalid YAML/);
  assert.ok(!JSON.stringify(brokenYaml).includes(secret));
  fs.writeFileSync(yamlFile, 'proxies:\n' + Array.from({ length: 150 }, (_, n) => `- {type: vless, server: host${n}.example.com, port: 443, uuid: ${secret}}`).join('\n'));
  const page = await net({ mode: 'inventory', config_path: yamlFile });
  assert.equal(page.count, 150); assert.equal(page.returned_count, 64); assert.equal(page.next_offset, 64);
  const lastPage = await net({ mode: 'inventory', config_path: yamlFile, inventory_offset: 128, inventory_limit: 128 });
  assert.equal(lastPage.endpoints.length, 22); assert.equal(lastPage.next_offset, null);
  assert.equal(lastPage.endpoints[0].host, 'host128.example.com');
  const dns = await net({ mode: 'dns', single_path: true, urls: [base + '/health'], timeout_ms: 300 });
  assert.ok(dns.results.length > 0);
  const routes = await net({mode:'routes'});
  assert.ok(routes.routes.length && routes.interfaces.length);
  const load = await net({ ...common, mode: 'load', load_url: base + '/health' });
  assert.ok(load.load_comparison.idle && load.load_comparison.during_load);
  assert.ok(load.load_comparison.downloaded_bytes <= 3 * 1048576);
  // Real detached recovery process: only wait and HTTP probe, no OS mutation.
  // Its short-lived launcher exits before the work completes.
  const scenario = path.join(temp, 'detached'); fs.mkdirSync(scenario);
  fs.copyFileSync(path.join(root, 'agent/recovery-worker.ps1'), path.join(scenario, 'worker.ps1'));
  fs.copyFileSync(path.join(root, 'agent/network.cs'), path.join(scenario, 'network.cs'));
  fs.writeFileSync(path.join(scenario, 'state.json'), JSON.stringify({
    id:'123456789012345678901234',task_name:'HelperMCP-Test-NeverRegistered-' + port,status:'armed',
    steps:[{op:'wait',seconds:2},{op:'probe',interface_index:0,url:base+'/health'}],undo:[],errors:[],probes:[],
    allow_commit:false,created_utc:new Date().toISOString(),updated_utc:new Date().toISOString(),deadline_utc:new Date(Date.now()+60000).toISOString(),
  }));
  const launchFile=path.join(scenario,'launch.ps1');
  fs.writeFileSync(launchFile, '\ufeff' + `$psi=New-Object Diagnostics.ProcessStartInfo "$env:SystemRoot\\System32\\WindowsPowerShell\\v1.0\\powershell.exe"\n$psi.Arguments='-NoProfile -ExecutionPolicy Bypass -File "${path.join(scenario,'worker.ps1').replaceAll("'","''")}" -JobDirectory "${scenario.replaceAll("'","''")}" -Action run'\n$psi.UseShellExecute=$false\n$psi.CreateNoWindow=$true\n$p=[Diagnostics.Process]::Start($psi)\nWrite-Output $p.Id\n`);
  const launcherChild=spawn('powershell',['-NoProfile','-File',launchFile],{stdio:['ignore','pipe','pipe']});
  await new Promise((resolve,reject)=>{launcherChild.on('exit',(code)=>code===0?resolve():reject(new Error('fixture launcher failed')));launcherChild.on('error',reject);});
  let state;
  for(let n=0;n<150;n++){try{state=JSON.parse(fs.readFileSync(path.join(scenario,'state.json'),'utf8').replace(/^\ufeff/,''));if(state.status==='rolled_back')break;}catch{}await sleep(100);}
  assert.equal(state.status,'rolled_back',JSON.stringify(state));
  assert.equal(state.probes[0].samples[0].status,200);
  console.log('Detached recovery worker completed after launcher exit, no relay commands required PASS');
  if (process.env.NETWORK_LIVE === '1') {
    const index = Number(process.env.NETWORK_TEST_INTERFACE || 0);
    const rkn = await net({ mode: 'rkn', interface_index: index, urls: ['https://www.microsoft.com/'] });
    assert.equal(rkn.checker, 'rkn-block-checker==0.6.0');
    assert.equal(rkn.interface_index, index);
    assert.equal(rkn.report.ad_hoc[0].status_code, 200, JSON.stringify(rkn));
    if (index) { assert.match(rkn.dns_mode, /adapter-bound/); assert.ok(rkn.dns_observations['www.microsoft.com']); }
    console.log('RKN pinned child through real Windows MCP, bound DNS/TCP/TLS/HTTP PASS');
  }
  const actions = fs.readFileSync(log, 'utf8');
  const history = text(await call('session_log', { session: code }));
  assert.ok(!actions.includes(secret) && !history.includes(secret) && !output.includes(secret), 'network input leaked to logs');
  console.log('Windows MCP network: compact/detail, chunked body, exact adapter, DNS, inventory, load and secret redaction PASS');
} catch (e) { console.error(output); throw e; }
finally { if (client) await client.close().catch(() => {}); stop(); }
