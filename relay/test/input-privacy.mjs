// A synthetic agent verifies the real relay without touching any desktop.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import os from 'node:os';
import path from 'node:path';
import {spawn} from 'node:child_process';
import {fileURLToPath} from 'node:url';
import {Client} from '@modelcontextprotocol/sdk/client/index.js';
import {StreamableHTTPClientTransport} from '@modelcontextprotocol/sdk/client/streamableHttp.js';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'../..');
const temp=fs.mkdtempSync(path.join(os.tmpdir(),'hm-input-privacy-'));
const port=22000+Math.floor(Math.random()*1000),base=`http://127.0.0.1:${port}`;
const key='input-privacy-fixture',secret='https://fixture.invalid/sub/opaque-private-input-value';
const pause=ms=>new Promise(r=>setTimeout(r,ms));
const post=(url,body,token)=>fetch(base+url,{method:'POST',headers:{'content-type':'application/json',...(token?{Authorization:'Bearer '+token}:{})},body:JSON.stringify(body)});
let stopping=false,client,poller,forwarded;
const abort=new AbortController();
const server=spawn(process.execPath,[path.join(root,'relay/server.js')],{env:{...process.env,PORT:String(port),OPERATOR_KEY:key,STATE_FILE:path.join(temp,'state.json'),ACT_FILE:path.join(temp,'actions.jsonl'),ADMIN_DIR:path.join(temp,'admin')},stdio:'pipe'});
let output='';server.stderr.on('data',d=>output+=d);
process.on('exit',()=>{abort.abort();server.kill();});
try{
 for(let n=0;n<80;n++){try{if((await fetch(base+'/health')).ok)break;}catch{}await pause(100);}
 assert.ok((await fetch(base+'/health')).ok,output);
 const agent=await(await post('/a/register',{os:'Windows 11 (synthetic fixture)',host:'PrivacyFixture',user:'Fixture',mode:'auto'})).json();
 poller=(async()=>{while(!stopping){try{
  const r=await fetch(base+'/a/poll?w=0',{headers:{Authorization:'Bearer '+agent.token},signal:abort.signal});
  if(r.status===204){await pause(30);continue;}if(!r.ok)break;
  const command=await r.json();if(command.tool==='ui_set')forwarded=command.args.value;
  await post('/a/result',{id:command.id,ok:true,data:{text:'set'}},agent.token);
 }catch{if(!stopping)await pause(50);}}})();
 client=new Client({name:'privacy-fixture',version:'1'});
 await client.connect(new StreamableHTTPClientTransport(new URL(base+'/mcp'),{requestInit:{headers:{Authorization:'Bearer '+key}}}));
 const call=(name,args={})=>client.callTool({name,arguments:{session:agent.code,...args}});
 const set=await call('ui_set',{id:1,value:secret});assert.ok(!set.isError);assert.equal(forwarded,secret,'redaction must not alter actual input');
 const history=JSON.stringify(await call('session_log'));
 assert.ok(!history.includes(secret)&&!history.includes('fixture.invalid'),'recent actions exposed an opaque subscription path');
 assert.match(history,/chars/,'recent actions lost useful input metadata');
 await call('report_miss',{wanted:'privacy fixture',happened:'explicit fixture marker'});
 const misses=JSON.stringify(await client.callTool({name:'misses',arguments:{limit:1}}));
 assert.ok(!misses.includes('fixture.invalid'),'mistake trail exposed input');
 const logs=fs.readFileSync(path.join(temp,'actions.jsonl'),'utf8')+fs.readFileSync(path.join(temp,'misses.jsonl'),'utf8');
 assert.ok(!logs.includes(secret)&&!logs.includes('opaque-private-input'),'disk logs exposed input');
 console.log('Input reaches agent unchanged; recent actions, mistake trails and disk logs hide opaque URL values PASS');
}finally{stopping=true;abort.abort();await client?.close();server.kill();await poller;}
