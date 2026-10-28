// Exercise the shipped browser controller under delayed remote responses.
// No native mouse, keyboard or desktop is involved.
import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
import {randomUUID} from 'node:crypto';

const elements = new Map(), events = new Map(), sent = [], waiting = [];
const sockets=[];
class Socket {constructor(){this.bufferedAmount=0;this.sent=[];sockets.push(this);}send(data){this.sent.push(JSON.parse(data));}close(){this.onclose?.();}}
let failPointer=false;
function element() {
  return { style:{},dataset:{}, handlers:{}, value:'', className:'', offsetHeight:52,
    addEventListener(name, fn) { this.handlers[name]=fn; },
    setAttribute(){}, focus(){}, append(){}, querySelectorAll(){return [];}, setPointerCapture(){} };
}
const $ = (id) => { if(!elements.has(id))elements.set(id,element()); return elements.get(id); };
const ctx = vm.createContext({
  $, CTL:'fixture', L:{take:'take',give:'give'}, ru:false, control:false, ended:false, gone:false,
  base:'/v/fixture', cv:$('cv'), kb:$('kb'), txt:$('txt'), meta:{sc:1}, real:(e)=>({x:e.x,y:e.y}),
  document:{documentElement:{style:{setProperty(){}}},createElement:element},
  window:{},crypto:{randomUUID},addEventListener:(name,fn)=>events.set(name,fn), setInterval(){}, clearInterval(){}, setTimeout, clearTimeout, status(){},
  WebSocket:Socket,location:{protocol:'https:',host:'fixture'},viewerClient:'c'.repeat(32),
  fetch: async (url, opts) => {
    const body=JSON.parse(opts.body);
    if(url.endsWith('/input')) {
      sent.push(body);
      if(failPointer&&body.phase==='down'){failPointer=false;return {ok:false,status:503,json:async()=>({error:'fixture worker denied'})};}
      await new Promise(resolve=>waiting.push(resolve));
    }
    return {ok:true,json:async()=>({})};
  }
});
vm.runInContext(fs.readFileSync(new URL('../viewer-control.js',import.meta.url),'utf8'),ctx);
const tick = () => new Promise(resolve=>setImmediate(resolve));
await $('ctl').onclick();
assert.equal(ctx.control,true);
function key(value, extra={}) { $('cv').handlers.keydown({key:value,preventDefault(){},...extra}); }
key('a'); key('b'); key('c'); key('Enter'); key('d');
assert.deepEqual(sent,[{a:'text',text:'a'}]);
waiting.shift()(); await tick();
assert.deepEqual(sent[1],{a:'text',text:'bc'},'typing was not batched while the remote PC was slow');
waiting.shift()(); await tick();
assert.deepEqual(sent[2],{a:'key',keys:'enter'},'Enter overtook typed text');
waiting.shift()(); await tick();
assert.deepEqual(sent[3],{a:'text',text:'d'});
key('x'); ctx.gone=true; ctx.ended=true; events.get('helper-disconnected')();
waiting.shift()(); await tick();
assert.equal(sent.length,4,'pending input survived disconnect');

ctx.gone=false; ctx.ended=false;
await $('ctl').onclick(); // give back
await $('ctl').onclick(); // take again
key('z'); key('y'); events.get('blur')(); waiting.shift()(); await tick();
assert.equal(sent.length,5,'pending input survived focus loss');
ctx.window.ViewerInput.setPointer(true);
const mouse=(name,x,y)=>$('cv').handlers[name]({x,y,button:0,pointerId:1,preventDefault(){}});
mouse('pointerdown',10,20);
assert.equal(sent[5].phase,'down');
const gesture=sent[5].gesture;
waiting.shift()();await tick();
mouse('pointermove',40,50);await new Promise(resolve=>setTimeout(resolve,120));
assert.equal(sent[6].phase,'move');assert.equal(sent[6].gesture,gesture);
waiting.shift()();await tick();
mouse('pointerup',70,80);assert.equal(sent[7].phase,'up');
assert.equal(sent[7].gesture,gesture);assert.ok(sent[7].seq>sent[6].seq);
waiting.shift()();await tick();
mouse('pointerdown',10,20);events.get('blur')();
assert.equal(sent[9].phase,'cancel','blur did not independently release held pointer');
waiting.shift()();await tick();waiting.shift()();await tick();
failPointer=true;mouse('pointerdown',10,20);await tick();
assert.equal(sent.at(-1).phase,'cancel');waiting.shift()();await tick();
ctx.window.ViewerInput.setPointer(true);mouse('pointerdown',10,20);mouse('pointerup',10,20);
assert.equal(sent.at(-1).a,'click','worker failure did not preserve fallback control');waiting.shift()();await tick();
console.log('Viewer slow-link typing batches, text/Enter ordering, disconnect and blur cancellation PASS');
ctx.window.ViewerInput.setKeyboard(true);
const before=sent.length;
key('Control',{code:'ControlLeft',ctrlKey:true});
key('ArrowLeft',{code:'ArrowLeft',ctrlKey:true});
$('cv').handlers.keyup({key:'ArrowLeft',code:'ArrowLeft',preventDefault(){}});
waiting.shift()();await tick();
assert.equal(sent[before].a,'keyboard');assert.equal(sent[before].vk,162);
assert.equal(sent[before+1].phase,'down');assert.equal(sent[before+1].vk,37);assert.equal(sent[before+1].extended,true);
waiting.shift()();await tick();assert.equal(sent[before+2].phase,'up');
waiting.shift()();await tick();
events.get('blur')();assert.equal(sent.at(-1).phase,'cancel','blur left Ctrl held');
waiting.shift()();await tick();
key('Enter',{code:'NumpadEnter'});waiting.shift()();await tick();
assert.equal(sent.at(-1).vk,13);assert.equal(sent.at(-1).extended,true);
ctx.gone=true;events.get('helper-disconnected')();
assert.equal(waiting.length,0);
console.log('Viewer native key down/up ordering, extended NumpadEnter and focus-loss release PASS');
ctx.gone=false;ctx.ended=false;ctx.window.ViewerInput.setRealtime(true);
const socket=sockets.at(-1);socket.onopen();assert.equal(socket.sent[0].auth,'fixture');
socket.onmessage({data:'{"ready":true}'});
const httpBefore=sent.length;
key('ArrowUp',{code:'ArrowUp'});$('cv').handlers.keyup({key:'ArrowUp',code:'ArrowUp',preventDefault(){}});
assert.deepEqual(socket.sent.slice(1).map(a=>a.phase),['down','up']);
assert.equal(sent.length,httpBefore,'live keys still wait for HTTP acknowledgements');
ctx.gone=true;socket.close();
console.log('Viewer authenticated WebSocket sends ordered down/up without HTTP round trips PASS');
