import assert from 'node:assert/strict';
import fs from 'node:fs';
import vm from 'node:vm';
const source=fs.readFileSync(new URL('../server.js',import.meta.url),'utf8');
const queue=source.slice(source.indexOf('function queuePicture('),source.indexOf('const sleep=ms=>',source.indexOf('function queuePicture(')));
assert.ok(queue.includes('renderPending>=3'));
const ctx=vm.createContext({renderPending:0,renderEpoch:0,waitFull:false,ended:false,chain:Promise.resolve(),abort:{abort(){ctx.aborted++}},aborted:0});
vm.runInContext(queue,ctx);
const calls=[],gates=[];
ctx.draw=valid=>new Promise(resolve=>{calls.push(valid);gates.push(resolve)});
vm.runInContext('queuePicture(draw,true)',ctx);await new Promise(r=>setImmediate(r));
vm.runInContext('queuePicture(draw,false);queuePicture(draw,false);queuePicture(draw,false)',ctx);
assert.equal(ctx.renderPending,3);assert.equal(ctx.aborted,1);assert.equal(ctx.waitFull,true);
assert.equal(calls[0](),false,'stale decode must not draw after overflow');
gates.shift()();await ctx.chain;assert.equal(ctx.renderPending,0);assert.equal(calls.length,1,'stale queued tiles were decoded');
vm.runInContext('queuePicture(draw,false)',ctx);assert.equal(ctx.renderPending,0,'dependent tiles accepted before full frame');
vm.runInContext('queuePicture(draw,true)',ctx);await new Promise(r=>setImmediate(r));assert.equal(ctx.waitFull,false);assert.equal(calls.at(-1)(),true);
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
 size(){},g:{drawImage:f=>drawn.push(f)},monMap(){},sysPanel(){},abort:{abort(){video.aborted++;}},aborted:0});
vm.runInContext(source.slice(source.indexOf('function handle(ty,p)'),source.indexOf('async function live(){')),video);
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
