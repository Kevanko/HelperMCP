import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const source=fs.readFileSync(new URL('../server.js',import.meta.url),'utf8');
const queue=source.slice(source.indexOf('function resetPictures('),source.indexOf('const sleep=ms=>',source.indexOf('function queuePicture(')));
assert.ok(queue.includes('renderPending>=3'));
const ctx=vm.createContext({renderPending:0,renderEpoch:0,waitFull:false,ended:false,chain:Promise.resolve(),abort:{abort(){ctx.aborted++}},aborted:0});
vm.runInContext(queue,ctx);
const calls=[],gates=[];
ctx.draw=valid=>new Promise(resolve=>{calls.push(valid);gates.push(resolve)});
vm.runInContext('queuePicture(draw,true)',ctx);await new Promise(r=>setImmediate(r));
vm.runInContext('queuePicture(draw,false);queuePicture(draw,false);queuePicture(draw,false)',ctx);
assert.equal(ctx.renderPending,0);assert.equal(ctx.aborted,1);assert.equal(ctx.waitFull,true);
assert.equal(calls[0](),false,'stale decode must not draw after overflow');
vm.runInContext('queuePicture(draw,false)',ctx);assert.equal(ctx.renderPending,0,'dependent tiles accepted before full frame');
vm.runInContext('queuePicture(draw,true)',ctx);await new Promise(r=>setImmediate(r));assert.equal(ctx.waitFull,false);assert.equal(calls.at(-1)(),true);
assert.equal(calls.length,2,'a new stream waited for the unresolved image from an older stream');
gates.shift()();await new Promise(r=>setImmediate(r));
assert.equal(ctx.renderPending,1,'a stale decode completion affected the new stream queue');
ctx.ended=true;assert.equal(calls.at(-1)(),false,'disconnected viewer still paints');gates.shift()();await ctx.chain;
console.log('Browser decode queue bounded to 3, stale draws cancelled, full-frame resync and disconnect PASS');

const decoders=[],drawn=[];
class Decoder {
 constructor(callbacks){this.callbacks=callbacks;this.state='unconfigured';this.decodeQueueSize=0;this.chunks=[];decoders.push(this);}
 configure(value){this.config=value;this.state='configured';}
 close(){this.state='closed';}
 decode(value){this.chunks.push(value);}
}
const video=vm.createContext({ended:false,dec:null,renderEpoch:0,waitFull:false,meta:{},window:{VideoDecoder:Decoder},VideoDecoder:Decoder,
 EncodedVideoChunk:class {constructor(value){Object.assign(this,value);}},performance:{now:()=>10},DataView,TextDecoder,td:new TextDecoder(),frames:0,
 paintedAt:0,paintSerial:0,displayCodec:'',st:{},ru:false,
 size(){},g:{drawImage:f=>drawn.push(f)},monMap(){},sysPanel(){},resetPictures(){},abort:{abort(){video.aborted++;}},aborted:0});
vm.runInContext(source.slice(source.indexOf('function painted(codec)'),source.indexOf('async function live(){')),video);
const statistics=Buffer.from(JSON.stringify({capture_fps:30,sent_fps:3,capture_ms:2,prepare_ms:5,encode_write_ms:8}));
video.handle('Q',statistics);
assert.match(video.st.title,/Capture 30\.0 fps · sent 3\.0 fps/);
assert.equal(video.paintSerial,0,'capture telemetry was treated as a visible frame');
assert.equal(video.streamStall(8000,0,7999,false,0,false,false),'initial-frame','metadata kept a blank stream open');
assert.equal(video.streamStall(8000,0,7999,true,100,true,false),'no-video-frame','stalled H.264 did not trigger recovery');
assert.equal(video.streamStall(8000,0,0,false,0,false,false),'no-packets','a network loss was mistaken for an unsupported codec');
assert.equal(video.streamStall(8000,0,500,true,100,true,false),'no-packets','an interrupted connection forced a codec downgrade');
assert.equal(video.streamStall(8000,0,7999,true,100,false,false),'','a still JPEG desktop triggered recovery');
assert.equal(video.streamStall(23000,0,500,true,100,false,false),'no-packets');
assert.equal(video.streamStall(42000,0,41999,true,100,false,false),'no-refresh','telemetry covered a frozen JPEG stream');
const config=Buffer.from(JSON.stringify({codec:'avc1.42c01e',w:640,h:360,ox:0,oy:0,sc:1,mon:0,mons:[[0,0,640,360,1]]}));
const packet=Buffer.alloc(config.length+2);packet.writeUInt16BE(config.length);config.copy(packet,2);
video.handle('C',packet);const firstDecoder=decoders.at(-1);
video.handle('V',Buffer.from([0,1]));assert.equal(firstDecoder.chunks.length,0,'delta accepted before initial IDR');
video.handle('V',Buffer.from([1,1]));assert.equal(firstDecoder.chunks.length,1);
video.handle('C',packet);const currentDecoder=decoders.at(-1);assert.equal(firstDecoder.state,'closed');
let closed=0;firstDecoder.callbacks.output({close(){closed++;}});assert.equal(drawn.length,0,'stale decoder painted after reconfiguration');assert.equal(closed,1);
currentDecoder.callbacks.output({displayWidth:640,displayHeight:360,close(){closed++;}});assert.equal(drawn.length,1);assert.equal(closed,2);
currentDecoder.decodeQueueSize=4;video.handle('V',Buffer.from([0,1]));assert.equal(video.aborted,1,'decoder backlog was allowed to grow');
currentDecoder.callbacks.error(new Error('decoder failed'));assert.equal(video.dec,null);assert.equal(video.aborted,2);
assert.equal(vm.runInContext('noVideo',video),true,'decoder failure did not negotiate JPEG fallback');
console.log('Video decoder ownership, frame disposal, bounded queue, IDR resync and JPEG fallback PASS');

// A relay keepalive proves transport only. Close a ping-only stream and negotiate
// the same codec on the next attempt, without waiting for the page to reload.
const liveFunction=source.slice(source.indexOf('async function live(){'),source.indexOf('(async()=>{while(!ended){',source.indexOf('async function live(){')));
let clock=0, timer, seenSignal, reads=0;
const playback=vm.createContext({
 AbortController,performance:{now:()=>clock},window:{VideoDecoder:Decoder},document:{hidden:false},
 setInterval(fn){timer=fn;return 1},clearInterval(){timer=null},base:'/fixture',mon:'',noVideo:false,paintSerial:0,paintedAt:0,
 dec:null,bytes:0,renderPending:0,streamStall:video.streamStall,resetPictures(){},accessEnded(){return false},handle(){},
 async fetch(url,{signal}){
  assert.match(url,/codec=h264$/);
  seenSignal=signal;
  return {ok:true,body:{getReader(){return {read(){
   if(reads++===0)return Promise.resolve({value:Uint8Array.of(0,0,0,0,80)});
   return new Promise((_,reject)=>signal.addEventListener('abort',()=>reject(Error('aborted')),{once:true}));
  }}}}};
 }
});
vm.runInContext(liveFunction,playback);
const pingOnly=playback.live();
await new Promise(r=>setImmediate(r));
clock=8000;
timer();
assert.equal(await pingOnly,false);
assert.equal(seenSignal.aborted,true);
assert.equal(playback.noVideo,false,'a ping-only link incorrectly disabled video');
console.log('Relay keepalive alone cannot mask a stalled stream or permanently disable H.264 PASS');
