// Real relay lifecycle, synthetic PC: no native input or network changes.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {once} from 'node:events';
import {fileURLToPath} from 'node:url';
import {createHash} from 'node:crypto';
import {createAdmin} from '../admin.mjs';

const dir=fs.mkdtempSync(path.join(os.tmpdir(),'hm-session-state-'));
const port=22000+Math.floor(Math.random()*1000), base=`http://127.0.0.1:${port}`, key='state-fixture-only';
const credentials=createAdmin(dir);
const sleep=ms=>new Promise(resolve=>setTimeout(resolve,ms));
let child, output='';
async function start() {
  child=spawn(process.execPath,[fileURLToPath(new URL('../server.js',import.meta.url))],{
    env:{...process.env,PORT:String(port),OPERATOR_KEY:key,STATE_FILE:path.join(dir,'state.json'),ADMIN_DIR:dir},stdio:'pipe'});
  child.stdout.on('data',b=>output+=b);child.stderr.on('data',b=>output+=b);
  for(let n=0;n<80;n++){try{if((await fetch(base+'/health')).ok)return;}catch{}await sleep(100);}
  throw Error('Relay did not start: '+output);
}
async function halt(){if(!child||child.exitCode!==null)return;const done=once(child,'exit');child.kill();await done;}
const post=(url,b,token)=>fetch(base+url,{method:'POST',headers:{'content-type':'application/json',Authorization:'Bearer '+token},body:JSON.stringify(b)});
const status=async()=>{const r=await fetch(base+'/admin/status',{headers:{Authorization:'Bearer '+key}});assert.equal(r.status,200);return r.json();};
async function loginAdmin() {
  const login = await post('/admin/api/login',{user:credentials.user,pass:credentials.password},'');
  assert.equal(login.status,200);
  const cookie = login.headers.get('set-cookie').split(';')[0];
  const {csrf} = await login.json();
  return (route, body) => fetch(base+'/admin/api/'+route, body === undefined
    ? {headers:{cookie}}
    : {method:'POST',headers:{cookie,'x-csrf':csrf,'content-type':'application/json'},body:JSON.stringify(body)});
}
try {
  await start();
  const reg=await(await post('/a/register',{os:'Windows (synthetic)',host:'Offline-fixture',user:'Test',mode:'auto',persist:true},'')).json();
  assert.equal((await status()).counts.online,1);
  assert.equal((await post('/a/bye',{final:false},reg.token)).status,200);
  let s=await status();assert.equal(s.counts.online,0,'normal window close remained online');
  assert.ok(s.sessions[0].last_seen_s<3,'normal close erased the last contact timestamp');
  await sleep(10500); // include an actual server maintenance sweep
  s=await status();assert.equal(s.counts.sessions,1,'normal window close deleted the kept session');
  const age=s.sessions[0].last_seen_s;
  await halt();await start();
  s=await status();assert.equal(s.counts.sessions,1);assert.equal(s.counts.online,0,'restart invented an online PC');
  assert.ok(s.sessions[0].last_seen_s>=age,'restart reset last-seen age');
  const poll=await fetch(base+'/a/poll?w=0',{headers:{Authorization:'Bearer '+reg.token}});
  assert.ok([200,204].includes(poll.status),'saved token stopped working');
  if(poll.status===200){const command=await poll.json();await post('/a/result',{id:command.id,ok:true,data:{text:'ok'}},reg.token);}
  s=await status();assert.equal(s.counts.online,1);assert.equal(s.sessions[0].code,reg.code);
  await post('/a/bye',{final:true},reg.token);
  assert.equal((await status()).counts.sessions,0,'confirmed end retained the session');

  const fixture = { os:'Windows synthetic', host:'Forgotten fixture', mode:'auto', persist:true, device_id:'forgotten-test-device' };
  const previous = await (await post('/a/register',fixture,'')).json();
  assert.equal((await post('/a/bye',{final:false},previous.token)).status,200);
  let admin = await loginAdmin();
  assert.equal((await admin('end',{code:previous.code})).status,200);
  assert.equal((await admin('look',{code:previous.code,glow:true})).status,200);
  await halt();await start();
  admin = await loginAdmin();
  const remembered = (await (await admin('sessions')).json()).find(row=>row.code===previous.code);
  assert.ok(remembered?.ended && remembered.glow && !remembered.online,'End or relay restart lost the device record or its appearance');
  assert.equal((await admin('open',{code:previous.code})).status,404,'ended device offered a control link');
  assert.equal((await post('/a/register',{...fixture,resume:previous.code,resume_token:previous.token},'')).status,410);
  const forgotten = await (await post('/a/register',fixture,'')).json();
  assert.equal(forgotten.code,previous.code,'an intentional fresh run lost its remembered device');
  assert.notEqual(forgotten.token,previous.token);
  assert.equal(forgotten.look.glow,true,'a new session lost its remembered appearance');
  assert.equal((await post('/a/bye',{final:false},forgotten.token)).status,200);
  const forget = await admin('forget',{code:forgotten.code});
  assert.equal(forget.status,200);
  await halt();await start();
  const resume = { ...fixture, resume:forgotten.code, resume_token:forgotten.token };
  assert.equal((await status()).counts.sessions,0,'a relay restart restored a forgotten offline session');
  assert.equal((await post('/a/register',resume,'')).status,410,'a restart lost the revocation');
  const fresh = await post('/a/register',fixture,'');
  assert.equal(fresh.status,200,'the device could not start a fresh session');
  assert.notEqual((await fresh.json()).code,forgotten.code,'a clean start inherited the forgotten code');
  await halt();
  const legacyToken='legacy-fixture-token';
  const created=Date.now()-86400_000;
  fs.writeFileSync(path.join(dir,'state.json'),JSON.stringify({
    sessions:[{code:'LEGA-CY23',th:createHash('sha256').update(legacyToken).digest('hex'),created,persist:true,info:{os:'Windows synthetic legacy'},events:[]}],
    revoked:[createHash('sha256').update(forgotten.token).digest('hex')],
    devices:[{dh:'remembered-fixture',code:'SAVE-TEST'}],
    endedDevices:[{code:'SAVE-TEST',info:{host:'Stopped fixture'},mode:'auto',lastSeen:created,ended:true}],
  }));
  await start();
  assert.equal((await post('/a/register',resume,'')).status,410,'token worked after the temporary code cooldown was absent');
  admin = await loginAdmin();
  assert.equal((await admin('forget',{code:'SAVE-TEST'})).status,200,'an ended device cannot be forgotten without a live session');
  assert.ok(!(await (await admin('sessions')).json()).some(row=>row.code==='SAVE-TEST'));
  s=await status();assert.equal(s.counts.online,0);
  assert.equal(s.sessions[0].last_seen_s,null,'legacy creation time was presented as last contact');
  const legacyPoll=await fetch(base+'/a/poll?w=0',{headers:{Authorization:'Bearer '+legacyToken}});
  assert.ok([200,204].includes(legacyPoll.status));
  if(legacyPoll.status===200){const command=await legacyPoll.json();await post('/a/result',{id:command.id,ok:true,data:{text:'ok'}},legacyToken);}
  s=await status();assert.equal(s.counts.online,1);assert.ok(s.sessions[0].last_seen_s!==null&&s.sessions[0].last_seen_s<3,'real contact did not replace legacy unknown');
  await post('/a/bye',{final:true},legacyToken);
  console.log('Kept window-close survives cleanup, restart stays offline until authenticated poll, same token/code PASS');
  console.log('Offline Forget persists before acknowledgement, and old credentials stay revoked after the code cooldown PASS');
}catch(e){console.error(output);throw e;}finally{await halt();fs.rmSync(dir,{recursive:true,force:true});}
