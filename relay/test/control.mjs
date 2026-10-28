// Synthetic desktops: exercise real relay/admin/viewer lifecycle without sending
// a single input event or network mutation to the developer's own desktop.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import http from 'node:http';
import zlib from 'node:zlib';
import { spawn } from 'node:child_process';
import { fileURLToPath } from 'node:url';
import { createAdmin } from '../admin.mjs';
import WebSocket from 'ws';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');
const temp = fs.mkdtempSync(path.join(os.tmpdir(), 'hm-control-'));
const port = 20500 + Math.floor(Math.random() * 1000), base = `http://127.0.0.1:${port}`;
const creds = createAdmin(temp), agents = [], commands = [], sleep = (ms) => new Promise((r) => setTimeout(r, ms));
let stopping = false, server;
function stop() { stopping = true; for (const a of agents) { a.abort.abort(); a.upload?.destroy(); } server?.kill(); }
process.on('exit', stop);
function crc(buf) { let c = 0xffffffff; for (const b of buf) { c ^= b; for(let n=0;n<8;n++)c=(c>>>1)^((c&1)?0xedb88320:0); } return (c^0xffffffff)>>>0; }
function png() {
  const chunk=(type,data)=>{const b=Buffer.concat([Buffer.from(type),data]);const h=Buffer.alloc(4),t=Buffer.alloc(4);h.writeUInt32BE(data.length);t.writeUInt32BE(crc(b));return Buffer.concat([h,b,t]);};
  const w=960,h=540,raw=Buffer.alloc((w*3+1)*h);
  for(let y=0;y<h;y++)for(let x=0;x<w;x++){const o=y*(w*3+1)+1+x*3;const card=x>80&&x<650&&y>80&&y<420;raw[o]=card?20:5;raw[o+1]=card?45:18;raw[o+2]=card?32:12;}
  const header=Buffer.alloc(13);header.writeUInt32BE(w);header.writeUInt32BE(h,4);header[8]=8;header[9]=2;
  return Buffer.concat([Buffer.from([137,80,78,71,13,10,26,10]),chunk('IHDR',header),chunk('IDAT',zlib.deflateSync(raw)),chunk('IEND',Buffer.alloc(0))]);
}
const picture=png();
function frame(type,payload){const h=Buffer.alloc(5);h.writeUInt32BE(payload.length);h[4]=type.charCodeAt(0);return Buffer.concat([h,payload]);}
function startStream(a) {
  if(a.upload)return;
  const req=http.request(base+'/a/stream',{method:'POST',headers:{Authorization:'Bearer '+a.token,'content-type':'application/octet-stream'}},(r)=>r.resume());
  a.upload=req;req.on('error',()=>{});req.on('close',()=>{if(a.upload===req)a.upload=null;clearInterval(timer);});
  const meta=Buffer.from(JSON.stringify({w:960,h:540,ox:0,oy:0,sc:1,mons:[[0,0,960,540,1]],mon:-1})),len=Buffer.alloc(2);len.writeUInt16BE(meta.length);
  const send=()=>{if(!req.destroyed)req.write(frame('K',Buffer.concat([len,meta,picture])));};
  const timer=setInterval(send,300);send();
}
async function post(url,body,headers={}) { return fetch(url,{method:'POST',headers:{'content-type':'application/json',...headers},body:JSON.stringify(body)}); }
async function fakeAgent(host,pointer=0,realtime=0) {
  const a=await(await post(base+'/a/register',{os:'Windows 11 (synthetic fixture)',host,user:'Test',mode:'auto',persist:true,viewer_pointer:pointer,viewer_keyboard:pointer,viewer_realtime:realtime})).json();
  a.abort=new AbortController();agents.push(a);
  a.inputLines=[];
  if(realtime){const stream=await fetch(base+'/a/input',{headers:{Authorization:'Bearer '+a.token},signal:a.abort.signal});assert.equal(stream.status,200);
    a.inputLoop=(async()=>{let buffer='';try{for await(const chunk of stream.body){buffer+=Buffer.from(chunk).toString();let n;while((n=buffer.indexOf('\n'))>=0){const line=buffer.slice(0,n);buffer=buffer.slice(n+1);if(line)a.inputLines.push(line);}}}catch(e){if(!stopping)throw e;}})();}
  a.loop=(async()=>{while(!stopping){try{
    if(a.pausePolling){await sleep(20);continue;}
    const r=await fetch(base+'/a/poll?w=0',{headers:{Authorization:'Bearer '+a.token},signal:a.abort.signal});
    if(r.status===204){await sleep(50);continue;}if(!r.ok)break;
    const c=await r.json();commands.push({code:a.code,tool:c.tool,args:c.args});
    if(c.tool==='stream'){if(c.args.on)startStream(a);else{a.upload?.end();a.upload=null;}}
    let data={text:'ok'};
    if(c.tool==='screenshot')data={jpeg:picture.toString('base64'),mime:'image/png',h:'fixture',sc:1};
    if(c.tool==='sysdata')data={text:JSON.stringify(c.args.kind==='procs'?{p:[]}:c.args.kind==='adapters'?'Ethernet [Up] if=14 1 Gbit/s; synthetic fixture':{})};
    if(c.tool==='net_check')data={text:JSON.stringify({fixture:true,mode:c.args.mode,routes:[]})};
    if(c.tool==='net_recover')data={text:JSON.stringify(c.args.op==='start'?{job:'1234567890abcdef12345678',status:'worker_running'}:c.args.op==='list'?{jobs:[]}:{id:c.args.job,status:'rolled_back'})};
    if(c.tool==='fetch_file')data={text:'http://127.0.0.1:9222/json'};
    await post(base+'/a/result',{id:c.id,ok:true,data},{Authorization:'Bearer '+a.token});
  }catch(e){if(!stopping)await sleep(100);}}})();
  return a;
}
try {
  server=spawn('node',[path.join(root,'relay/server.js')],{env:{...process.env,PORT:String(port),OPERATOR_KEY:'control-fixture-only',STATE_FILE:path.join(temp,'relay-state.json'),ADMIN_DIR:temp},stdio:'pipe'});
  for(let n=0;n<80;n++){try{if((await fetch(base+'/health')).ok)break;}catch{}await sleep(100);}
  const bootstrap=await fetch(base+'/h'),bytes=new Uint8Array(await bootstrap.arrayBuffer());
  assert.equal(bootstrap.headers.get('cache-control'),'no-store','bootstrap can cache an old agent');
  assert.equal(bytes[0],35,'raw PS bootstrap starts with BOM instead of a comment');
  const first=await fakeAgent('Desk-A',1),second=await fakeAgent('Desk-B');
  const login=await post(base+'/admin/api/login',{user:creds.user,pass:creds.password});assert.equal(login.status,200);
  const cookie=/hm_admin=[0-9a-f]+/.exec(login.headers.get('set-cookie'))[0],csrf=(await login.json()).csrf;
  const H={cookie,'x-csrf':csrf};
  const admin=(name,b)=>b===undefined?fetch(base+'/admin/api/'+name,{headers:{cookie}}):post(base+'/admin/api/'+name,b,H);
  await admin('settings',{glow:true,sound:true});
  let list=await(await admin('sessions')).json();assert.ok(list.every(s=>s.glow&&s.sound));
  await admin('look',{code:first.code,glow:false});
  list=await(await admin('sessions')).json();assert.equal(list.find(s=>s.code===first.code).glow,false);assert.equal(list.find(s=>s.code===second.code).glow,true);
  await admin('settings',{glow:false});list=await(await admin('sessions')).json();assert.ok(list.every(s=>!s.glow&&s.sound));
  await admin('settings',{sound:false});
  const urls=await(await admin('open',{code:first.code})).json();
  const viewer=urls.watch,ctl=new URL(urls.control).hash.slice(3),client='a'.repeat(32),other='b'.repeat(32);
  const CH={'x-ctl':ctl,'x-viewer-client':client};
  assert.equal((await post(viewer+'/look',{note:'  Desktop   diagnosis  '},CH)).status,200);
  assert.equal((await(await fetch(viewer+'/state')).json()).look.note,'Desktop diagnosis');
  assert.equal((await post(viewer+'/look',{glow:true,sound:false,banner:false,timer:false},CH)).status,200);
  const appearance=(await(await fetch(viewer+'/state')).json()).look;
  assert.equal(appearance.glow,true);assert.equal(appearance.banner,false);assert.equal(appearance.timer,false);
  const unaffected=(await(await admin('sessions')).json()).find(s=>s.code===second.code);
  assert.equal(unaffected.glow,false,'appearance changed another person');
  assert.equal((await admin('look',{code:first.code,banner:true,timer:true})).status,200);
  assert.equal((await(await fetch(viewer+'/state')).json()).look.banner,true,'admin per-person banner switch was ignored');
  assert.equal((await post(viewer+'/look',{banner:true})).status,403,'watch link changed the banner');
  assert.equal((await(await fetch(viewer+'/state')).json()).live_pointer,true,'new agent live pointer not advertised');
  assert.equal((await post(viewer+'/network',{kind:'jobs'})).status,403,'watch link could start network operations');
  assert.equal((await post(viewer+'/network',{kind:'script'},CH)).status,400,'viewer allowed arbitrary scenario');
  assert.equal((await post(viewer+'/network',{kind:'status',job:'invalid'},CH)).status,400,'viewer accepted malformed job');
  assert.equal((await post(viewer+'/network',{kind:'selftest',interface_index:-1},CH)).status,400,'viewer accepted invalid interface');
  let network=await post(viewer+'/network',{kind:'routes'},CH);
  assert.equal(JSON.parse((await network.json()).text).mode,'routes');
  network=await post(viewer+'/network',{kind:'selftest',interface_index:14,steps:[{op:'adapter_disable',interface_index:14}]},CH);
  const job=JSON.parse((await network.json()).text).job;
  assert.equal(job,'1234567890abcdef12345678');
  const sent=commands.find(c=>c.tool==='net_recover'&&c.args.op==='start');
  assert.deepEqual(sent.args,{op:'start',template:'guard-selftest',interface_index:14},'viewer forwarded unapproved mutation fields');
  assert.equal((await post(viewer+'/network',{kind:'rollback',job},CH)).status,200);
  assert.equal((await post(viewer+'/takeover',{on:true},CH)).status,200);
  const upload=await fetch(viewer+'/upload?drop=1&name='+encodeURIComponent('../Тестовый файл.txt'),{method:'POST',headers:CH,body:'private fixture content'});
  assert.equal(upload.status,200);
  const copied=commands.find(c=>c.tool==='push_file');assert.equal(copied.args.path,'~/Downloads/Helper Transfers/Тестовый файл.txt');assert.equal(copied.args.unique,true);
  const uploaded=await fetch(copied.args.url);assert.equal(uploaded.status,200);assert.equal(await uploaded.text(),'private fixture content');assert.ok(uploaded.headers.get('content-disposition').includes("filename*=UTF-8''"),'Unicode filename lost or unsafe header');
  assert.equal((await fetch(viewer+'/upload?drop=1&name=x',{method:'POST',body:'denied'})).status,403,'watch link uploaded a file');
  assert.equal(commands.filter(c=>c.tool==='start_process').length,0,'drop executed a file');
  assert.equal((await post(viewer+'/get',{path:'malicious-client.txt'},CH)).status,503,'remote client could send the operator browser to a local service');
  const gesture='1'.repeat(32);
  assert.equal((await post(viewer+'/input',{a:'pointer',phase:'down',gesture,seq:1,x:10,y:20},CH)).status,200);
  assert.equal((await post(viewer+'/input',{a:'pointer',phase:'up',gesture,seq:2,x:40,y:50},CH)).status,200);
  assert.equal((await(await fetch(viewer+'/state')).json()).live_keyboard,true);
  assert.equal((await post(viewer+'/input',{a:'keyboard',phase:'down',vk:162,seq:3},CH)).status,200);
  assert.equal((await post(viewer+'/input',{a:'keyboard',phase:'up',vk:162,seq:4},CH)).status,200);
  assert.equal((await post(viewer+'/input',{a:'keyboard',phase:'down',vk:1000,seq:5},CH)).status,400);
  const keyboard=commands.find(c=>c.tool==='viewer_pointer'&&c.args.op==='kdown');
  assert.equal(keyboard.args.x,162);assert.equal(keyboard.args.owner,commands.find(c=>c.tool==='viewer_pointer'&&c.args.op==='down').args.owner);
  const pointerLog=await(await fetch(viewer+'/log')).json();
  assert.ok(pointerLog.filter(e=>e.tool==='viewer_pointer').every(e=>!e.args.includes('owner')&&!e.args.includes('gesture')),'pointer logs leaked protocol identifiers');
  const pointer=commands.find(c=>c.tool==='viewer_pointer'&&c.args.op==='down');
  assert.match(pointer.args.owner,/^[a-f0-9]{64}$/);assert.equal(pointer.args.gesture,gesture);
  assert.equal((await post(viewer+'/input',{a:'pointer',phase:'down',gesture,seq:-1},CH)).status,400);
  assert.equal((await post(viewer+'/takeover',{on:false},CH)).status,200);
  assert.equal((await post(viewer+'/input',{a:'pointer',phase:'down',gesture,seq:3,x:10,y:20},CH)).status,409,'pointer reacquired control after handback');
  assert.equal((await post(viewer+'/takeover',{on:true},CH)).status,200);
  assert.equal((await post(viewer+'/input',{a:'move',x:10,y:20},CH)).status,200);
  assert.deepEqual(commands.find(c=>c.tool==='move').args,{x:10,y:20,raw:true,viewer_input:true},'human input entered the slow AI path');
  assert.equal((await post(viewer+'/input',{a:'drag',x:1,y:2,x2:3,y2:4,button:'right'},CH)).status,200);
  assert.equal(commands.find(c=>c.tool==='drag').args.button,'right','completed-drag fallback lost the selected mouse button');
  assert.equal((await post(viewer+'/takeover',{on:false},{'x-ctl':ctl,'x-viewer-client':other})).status,409,'another tab stole ownership');
  const live=await fetch(viewer+'/live',{headers:{'x-viewer-client':client}});assert.equal(live.status,200);const reader=live.body.getReader();await reader.read();
  assert.equal((await(await fetch(viewer+'/state')).json()).stream.codec,'h264','legacy video-capable viewer blocked video');
  const jpegAbort=new AbortController();const jpeg=await fetch(viewer+'/live?codec=jpeg',{signal:jpegAbort.signal,headers:{'x-viewer-client':other}});
  assert.equal(jpeg.status,200);assert.equal((await(await fetch(viewer+'/state')).json()).stream.codec,'jpeg','unsupported browser did not get compatible mode');
  jpegAbort.abort();
  for(let n=0;n<30;n++){if((await(await fetch(viewer+'/state')).json()).stream.codec==='h264')break;await sleep(20);if(n===29)assert.fail('video mode did not recover after JPEG viewer left');}
  assert.equal((await post(viewer+'/disconnect',{},CH)).status,200);
  for(let n=0;n<30;n++){if((await reader.read()).done)break;if(n===29)assert.fail('stream remained open');}
  const state=await(await fetch(viewer+'/state')).json();assert.equal(!!state.takeover,false,'disconnect left manual takeover active');
  assert.equal((await post(viewer+'/input',{a:'key',keys:'x'},CH)).status,409,'disconnected client sent input');
  assert.equal((await fetch(viewer+'/frame',{headers:{'x-viewer-client':client}})).status,409,'disconnected client kept polling frames');
  assert.equal((await post(viewer+'/network',{kind:'jobs'},CH)).status,409,'disconnected viewer issued network command');
  assert.equal((await fetch(viewer+'/state',{headers:{'x-viewer-client':other}})).status,200,'disconnect affected another tab');
  await sleep(300);assert.ok(commands.some(c=>c.tool==='stream'&&c.args.on===false));
  assert.ok(commands.some(c=>c.tool==='viewer_pointer'&&c.args.op==='release'),'disconnect did not release native pointer');
  first.pausePolling=true;await sleep(100);
  const OH={'x-ctl':ctl,'x-viewer-client':other};
  assert.equal((await post(viewer+'/takeover',{on:true},OH)).status,200);
  const beforeInput=commands.filter(c=>c.tool==='press_key').length;
  const queued=post(viewer+'/input',{a:'key',keys:'x'},OH);
  await sleep(100);await post(viewer+'/disconnect',{},OH);
  assert.equal((await queued).status,503,'queued input was not cancelled');
  first.pausePolling=false;await sleep(200);
  assert.equal(commands.filter(c=>c.tool==='press_key').length,beforeInput,'disconnected queued input reached agent');
  console.log('Global/local toggles, guarded network UI, viewer ownership, actual stream close, handback and disconnected-input rejection PASS');
  const realtime=await fakeAgent('Realtime-Desk',1,1);
  const rtUrls=await(await admin('open',{code:realtime.code})).json(),rtViewer=rtUrls.watch,rtSecret=new URL(rtUrls.control).hash.slice(3),rtClient='c'.repeat(32),RH={'x-ctl':rtSecret,'x-viewer-client':rtClient};
  assert.equal((await(await fetch(rtViewer+'/state')).json()).live_realtime,true);
  await post(rtViewer+'/takeover',{on:true},RH);
  async function socket(auth=rtSecret,client=rtClient,origin=base){const ws=new WebSocket(rtViewer.replace('http:','ws:')+'/input-ws',{origin});await new Promise((resolve,reject)=>{ws.once('open',resolve);ws.once('error',reject);});const ready=new Promise(resolve=>{ws.once('message',data=>resolve(JSON.parse(data)));ws.once('close',()=>resolve(null));});ws.send(JSON.stringify({auth,client}));return {ws,ready};}
  const invalid=await socket('wrong-secret');assert.equal(await invalid.ready,null,'watch/control authentication bypass');
  const wrongOwner=await socket(rtSecret,'d'.repeat(32));assert.equal(await wrongOwner.ready,null,'another tab got live input');
  const liveInput=await socket();assert.equal((await liveInput.ready).ready,true);
  for(const action of [{a:'keyboard',phase:'down',vk:162,seq:1},{a:'keyboard',phase:'up',vk:162,seq:2},{a:'pointer',phase:'hover',gesture:'0'.repeat(32),seq:3,x:123,y:456}])liveInput.ws.send(JSON.stringify(action));
  for(let n=0;n<40&&realtime.inputLines.length<3;n++)await sleep(25);
  assert.deepEqual(realtime.inputLines.slice(0,3).map(line=>line.split('|')[1].split(' ')[3]),['kdown','kup','hover'],'WebSocket input lost ordering');
  assert.ok(realtime.inputLines.every(line=>/^\d+\|[a-f0-9]{64} [a-f0-9]{32} /.test(line)),'input protocol lacks owner or expiry');
  const beforeRealtime=commands.filter(c=>c.code===realtime.code&&c.tool==='viewer_pointer').length;
  assert.equal(beforeRealtime,0,'live input still waits in the command polling queue');
  const closed=new Promise(resolve=>liveInput.ws.once('close',resolve));await post(rtViewer+'/takeover',{on:false},RH);await closed;
  assert.ok(realtime.inputLines.some(line=>line.includes(' release ')),'WebSocket handback did not release input');
  await post(rtViewer+'/takeover',{on:true},RH);const closing=await socket();assert.equal((await closing.ready).ready,true);
  const socketGone=new Promise(resolve=>closing.ws.once('close',resolve));closing.ws.close();await socketGone;await sleep(3300);
  assert.equal(!!(await(await fetch(rtViewer+'/state')).json()).takeover,false,'closed browser kept control locked');
  assert.equal((await post(rtViewer+'/takeover',{on:true},{'x-ctl':rtSecret,'x-viewer-client':'e'.repeat(32)})).status,200,'new tab could not acquire control after close');
  await post(rtViewer+'/takeover',{on:false},{'x-ctl':rtSecret,'x-viewer-client':'e'.repeat(32)});
  await post(base+'/a/state',{paused:true},{Authorization:'Bearer '+realtime.token});
  for(let n=0;n<40&&(await(await fetch(rtViewer+'/state')).json()).live_realtime;n++)await sleep(25);
  assert.equal((await(await fetch(rtViewer+'/state')).json()).live_realtime,false,'pause left live input available');
  console.log('Live input WebSocket authentication, owner isolation, ordered direct delivery, handback release and pause PASS');
  if(process.argv.includes('--serve')) {
    const out=process.env.UI_FIXTURE_PATH;
    if(out)fs.writeFileSync(out,JSON.stringify({base,user:creds.user,password:creds.password,control:urls.control,watch:urls.watch,temp}));
    console.log('Synthetic UI fixture running at '+base);
    await new Promise(()=>{});
  }
}finally{stop();}
