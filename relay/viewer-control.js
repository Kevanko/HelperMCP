/* Shared viewer state is declared by the page. This controller owns manual input
   and never sends a delayed action after handback, blur or disconnect. */
(function () {
  'use strict';
  $('fs').onclick = async () => {
    try { if (document.fullscreenElement) await document.exitFullscreen(); else await document.documentElement.requestFullscreen(); }
    catch (e) { status(e.message, 'bad'); }
  };
  if (!CTL) return;
  const button = $('ctl'); button.hidden = false; button.textContent = L.take;
  $('send').textContent = L.send; txt.placeholder = L.ph;
  // Direct desktop typing is primary; explicit text entry remains for mobile/IME.
  const textToggle=document.createElement('button');textToggle.textContent=ru?'Текст…':'Text…';
  txt.style.display='none';$('send').style.display='none';
  textToggle.onclick=()=>{const show=txt.style.display==='none';txt.style.display=show?'':'none';$('send').style.display=show?'':'none';(show?txt:cv).focus({preventScroll:true});document.documentElement.style.setProperty('--kb',kb.offsetHeight+'px')};kb.append(textToggle);
  let generation = 0, sending = false, pending = [], down = null, wheel = 0, wheelTimer = null, hoverTimer = null, hover = null, pointerEnabled = false, pointerFailed = false, pointerSeq = 0, keepTimer = null,keyboardEnabled=false,keyboardFailed=false,keyTimer=null;
  const heldKeys=new Map();
  let lookState={glow:false,sound:false,banner:true,timer:true};const lookButtons=new Map();
  const appearance=document.createElement('div');appearance.style.cssText='display:flex;flex-wrap:wrap;gap:.4rem;padding:.6rem .9rem;border-bottom:1px solid var(--line)';
  for(const [key,label] of [['glow',ru?'Подсветка':'Glow'],['sound',ru?'Звук':'Sound'],['banner',ru?'Верхняя плашка':'Top banner'],['timer',ru?'Таймер':'Timer']]){
    const b=document.createElement('button');b.dataset.setting=key;b.onclick=async()=>{b.disabled=true;try{const value=!lookState[key];await request('/look',{[key]:value});lookState[key]=value;paintLook();}catch(e){status(e.message,'bad');}finally{b.disabled=false;}};
    lookButtons.set(key,{b,label});appearance.append(b);
  }
  const description=document.createElement('button');description.dataset.setting='note';description.textContent=ru?'Описание':'Description';
  description.onclick=async()=>{const value=prompt(ru?'Текст верхней плашки (до 90 символов)':'Top banner text (up to 90 characters)',lookState.note||'');if(value===null)return;description.disabled=true;try{const note=value.replace(/\s+/g,' ').trim().slice(0,90);await request('/look',{note});lookState.note=note;}catch(e){status(e.message,'bad');}finally{description.disabled=false;}};
  appearance.append(description);
  if($('side').prepend)$('side').prepend(appearance);else $('side').append(appearance);
  function paintLook(){for(const [key,{b,label}] of lookButtons){const on=!!lookState[key];b.textContent=label+': '+(ru?(on?'вкл':'выкл'):(on?'on':'off'));b.setAttribute('aria-pressed',String(on));}}
  paintLook();
  let realtimeEnabled=false,liveSocket=null,socketReady=false;
  const isLive=action=>action.a==='pointer'||action.a==='keyboard';
  function sendLive(action){if(!socketReady||!liveSocket)return false;if(liveSocket.bufferedAmount>8192){liveSocket.close();clearInput();status(ru?'Канал ввода перегружен — клавиши отпущены':'Input link overloaded — keys released','bad');return true;}liveSocket.send(JSON.stringify(action));return true;}
  function connectInput(){
    if(!realtimeEnabled||!control||gone||liveSocket)return;
    const ws=new WebSocket((location.protocol==='https:'?'wss://':'ws://')+location.host+base+'/input-ws');liveSocket=ws;
    ws.onopen=()=>ws.send(JSON.stringify({auth:CTL,client:viewerClient}));
    ws.onmessage=e=>{try{if(JSON.parse(e.data).ready&&liveSocket===ws){socketReady=true;drain();}}catch{ws.close();}};
    ws.onerror=()=>ws.close();
    ws.onclose=()=>{if(liveSocket!==ws)return;liveSocket=null;socketReady=false;clearInput();if(control&&realtimeEnabled&&!gone)setTimeout(connectInput,750);};
  }
  const keyboardAction=(phase,vk=0,extended=false)=>({a:'keyboard',phase,vk,extended,seq:++pointerSeq});
  async function request(path, body) {
    const r = await fetch(base + path, { method: 'POST', headers: { 'content-type': 'application/json', 'x-ctl': CTL }, body: JSON.stringify(body) });
    const j = await r.json().catch(() => ({}));
    if (!r.ok) throw new Error(j.error || 'HTTP ' + r.status);
    return j;
  }
  const pointerAction = (phase,d,p=d.p) => ({ a:'pointer',phase,gesture:d.gesture,seq:++pointerSeq,...p,button:d.button===2?'right':d.button===1?'middle':'left' });
  function clearInput() {
    const held=down; generation++; pending=[]; down=null; hover=null; wheel=0;
    clearTimeout(wheelTimer);clearTimeout(hoverTimer);clearInterval(keepTimer);hoverTimer=null;keepTimer=null;
    if(held?.live && !gone)request('/input',pointerAction('cancel',held)).catch(()=>{});
    if(heldKeys.size){heldKeys.clear();if(!gone)request('/input',keyboardAction('cancel')).catch(()=>{});}clearInterval(keyTimer);keyTimer=null;
  }
  window.ViewerInput={setPointer(on){if(pointerEnabled && !on)clearInput();pointerEnabled=on&&!pointerFailed;},setKeyboard(on){if(keyboardEnabled&&!on)clearInput();keyboardEnabled=on&&!keyboardFailed;},setRealtime(on){realtimeEnabled=on;if(on)connectInput();else if(liveSocket)liveSocket.close();},setLook(value){lookState={...lookState,...value};paintLook();}};
  async function drain() {
    if (sending) return;
    sending = true;
    try {
      while (pending.length && control && !ended && !gone) {
        const next = pending.shift();
        if (next.generation !== generation) continue;
        if(isLive(next.action)&&sendLive(next.action))continue;
        try { await request('/input', next.action); }
        catch (e) {
          const pointer=next.action.a==='pointer';if(pointer&&!realtimeEnabled){pointerFailed=true;pointerEnabled=false;}
          if(next.action.a==='keyboard'&&!realtimeEnabled){keyboardFailed=true;keyboardEnabled=false;}
          clearInput(); if (!gone) status(e.message+(pointer?(ru?' · доступно обычное перетаскивание':' · completed drag remains available'):''), 'bad'); break;
        }
      }
    } finally { sending = false; }
  }
  function input(action) {
    if (!control || ended || gone) return;
    if(realtimeEnabled&&isLive(action)&&!socketReady&&!['up','cancel'].includes(action.phase)){connectInput();status(ru?'Подключаю канал ввода…':'Connecting input channel…','bad');return;}
    if(!sending&&!pending.length&&isLive(action)&&sendLive(action))return;
    if(action.a==='keyboard'&&action.phase==='up')pending=pending.filter(x=>!(x.action.a==='keyboard'&&x.action.phase==='keep'));
    if(action.a==='keyboard'&&action.phase==='keep'&&pending.some(x=>x.action.a==='keyboard'&&x.action.phase==='keep'))return;
    const last = pending[pending.length - 1];
    if (last && last.generation === generation) {
      // Keep ordering around Enter/shortcuts, but batch typing and replace stale
      // pointer positions while a slow remote request is in flight.
      if (action.a === 'text' && last.action.a === 'text' && last.action.text.length + action.text.length <= 2000) { last.action.text += action.text; return; }
      if (action.a === 'move' && last.action.a === 'move') { last.action = action; return; }
      if (action.a==='pointer' && last.action.a==='pointer' && action.gesture===last.action.gesture && ['move','keep'].includes(action.phase) && ['move','keep'].includes(last.action.phase)) {
        if(action.phase==='keep' && last.action.phase==='move') action.phase='move'; last.action=action; return;
      }
    }
    if (pending.length >= 128) { clearInput();status(ru ? 'Очередь ввода заполнена — клавиши отпущены, дождитесь ответа ПК' : 'Input queue full — keys released, wait for the remote PC', 'bad'); return; }
    pending.push({ generation, action }); drain();
  }
  function paint(on) {
    control = on; clearInput(); button.className = on ? 'on' : ''; button.textContent = on ? L.give : L.take;
    button.setAttribute('aria-pressed', String(on)); cv.className = on ? 'ctl' : '';
    kb.style.display = on ? 'flex' : 'none'; document.documentElement.style.setProperty('--kb', on ? (kb.offsetHeight || 52) + 'px' : '0px');
    $('tag').style.display = on ? 'block' : 'none'; $('tag').textContent = L.tag+(on?(ru?' · нажмите экран и печатайте':' · click the screen and type'):'');
    if(on)connectInput();else if(liveSocket)liveSocket.close();
  }
  async function take(on) {
    button.disabled = true;
    if (!on) paint(false);
    try { await request('/takeover', { on }); if (!gone) { paint(on); if (on) cv.focus({ preventScroll: true }); } }
    catch (e) { paint(false); if (!gone) status(e.message, 'bad'); }
    finally { button.disabled = gone; }
  }
  button.onclick = () => take(!control);
  cv.addEventListener('pointerdown', (e) => {
    if (!control || gone || down || e.button < 0 || e.button > 2) return;
    e.preventDefault(); cv.focus({ preventScroll: true });
    if(realtimeEnabled&&!socketReady){connectInput();status(ru?'Подключаю канал ввода…':'Connecting input channel…','bad');return;}
    try { cv.setPointerCapture(e.pointerId); } catch {}
    down = { p: real(e), t: Date.now(), button: e.button, id: e.pointerId, live:pointerEnabled };
    if(down.live) {
      down.gesture=crypto.randomUUID().replaceAll('-',''); input(pointerAction('down',down));
      clearInterval(keepTimer);keepTimer=setInterval(()=>{if(down?.live && control && !gone)input(pointerAction('keep',down));},500);
    }
  });
  cv.addEventListener('pointerup', (e) => {
    if (!control || gone || !down || e.pointerId !== down.id) return;
    const d = down, end = real(e); down = null;
    clearInterval(keepTimer);clearTimeout(hoverTimer);keepTimer=null;hoverTimer=null;hover=null;
    if(d.live)input(pointerAction('up',d,end));
    else if (Math.hypot(end.x - d.p.x, end.y - d.p.y) / meta.sc > 8) input({ a: 'drag', ...d.p, x2: end.x, y2: end.y, hold: Date.now() - d.t > 500, button:d.button===2?'right':d.button===1?'middle':'left' });
    else input({ a: 'click', ...end, button: d.button === 2 ? 'right' : d.button === 1 ? 'middle' : 'left' });
  });
  cv.addEventListener('pointercancel', clearInput);
  cv.addEventListener('lostpointercapture', (e) => { if(down && down.id===e.pointerId)clearInput(); });
  cv.addEventListener('pointermove', (e) => {
    if (!control || gone || (down && !down.live)) return;
    hover = real(e);
    if(down?.live)down.p=hover;
    if (hoverTimer) return;
    hoverTimer = setTimeout(() => { hoverTimer = null; const p = hover; hover = null; if (p && control && !gone) input(down?.live?pointerAction('move',down,p):realtimeEnabled&&pointerEnabled?pointerAction('hover',{gesture:'0'.repeat(32),button:0,p}):{ a: 'move', ...p }); }, 16);
  });
  cv.addEventListener('contextmenu', (e) => { if (control) e.preventDefault(); });
  cv.addEventListener('wheel', (e) => {
    if (!control || gone || e.ctrlKey || e.metaKey) return;
    e.preventDefault(); wheel += Math.sign(e.deltaY) * Math.max(1, Math.round(Math.abs(e.deltaY) / 100));
    const point = real(e); clearTimeout(wheelTimer);
    wheelTimer = setTimeout(() => { const amount = Math.max(-20, Math.min(20, wheel)); wheel = 0; input({ a: 'scroll', ...point, amount }); }, 100);
  }, { passive: false });
  const keys = { Escape: 'esc', Enter: 'enter', Backspace: 'backspace', Delete: 'delete', Tab: 'tab', ArrowLeft: 'left', ArrowRight: 'right', ArrowUp: 'up', ArrowDown: 'down', Home: 'home', End: 'end', PageUp: 'pageup', PageDown: 'pagedown', Insert: 'insert', ' ': 'space' };
  const physical={Escape:27,Enter:13,NumpadEnter:13,Backspace:8,Delete:46,Tab:9,ArrowLeft:37,ArrowRight:39,ArrowUp:38,ArrowDown:40,Home:36,End:35,PageUp:33,PageDown:34,Insert:45,ShiftLeft:160,ShiftRight:161,ControlLeft:162,ControlRight:163,AltLeft:164,AltRight:165,MetaLeft:91,MetaRight:92};
  function nativeCode(e){const code=e.code||e.key,modified=e.ctrlKey||e.altKey||e.metaKey;return physical[code]||(code==='Space'?32:/^F(?:[1-9]|1[0-9]|2[0-4])$/.test(code)?111+Number(code.slice(1)):/^Key[A-Z]$/.test(code)&&(modified||e.key.toUpperCase()===code.slice(3))?code.charCodeAt(3):/^Digit[0-9]$/.test(code)&&(modified||e.key===code.slice(5))?code.charCodeAt(5):0);}
  cv.addEventListener('keydown', (e) => {
    if (!control || gone || e.isComposing) return;
    // Ctrl+Alt+Shift is the local escape chord, so focus can always leave the PC.
    if (e.ctrlKey && e.altKey && e.shiftKey) { e.preventDefault(); take(false); return; }
    if(realtimeEnabled&&!socketReady){e.preventDefault();connectInput();status(ru?'Подключаю канал ввода…':'Connecting input channel…','bad');return;}
    if ((e.ctrlKey || e.metaKey) && e.key.toLowerCase() === 'v') return; // paste event supplies text, never both text and Ctrl+V
    const vk=keyboardEnabled?nativeCode(e):0;
    if(vk){e.preventDefault();const extended=['Insert','Delete','Home','End','PageUp','PageDown','ArrowLeft','ArrowRight','ArrowUp','ArrowDown','ControlRight','AltRight','MetaLeft','MetaRight','NumpadEnter'].includes(e.code||e.key);heldKeys.set(e.code||e.key,{vk,extended});input(keyboardAction('down',vk,extended));if(!keyTimer)keyTimer=setInterval(()=>{if(heldKeys.size&&control&&!gone)input(keyboardAction('keep'));},500);return;}
    if (['Shift','Control','Alt','Meta'].includes(e.key)) return;
    const key = keys[e.key] || (/^F(?:[1-9]|1[0-9]|2[0-4])$/.test(e.key) ? e.key.toLowerCase() : e.key.length === 1 ? e.key.toLowerCase() : '');
    if (!key) return;
    e.preventDefault();
    if (e.key.length === 1 && !e.ctrlKey && !e.metaKey && !e.altKey) input({ a: 'text', text: e.key });
    else input({ a: 'key', keys: [e.ctrlKey ? 'ctrl' : '', e.metaKey ? 'win' : '', e.altKey ? 'alt' : '', e.shiftKey ? 'shift' : '', key].filter(Boolean).join('+') });
  });
  cv.addEventListener('keyup',e=>{const key=heldKeys.get(e.code||e.key);if(!key)return;e.preventDefault();heldKeys.delete(e.code||e.key);if(control&&!gone)input(keyboardAction('up',key.vk,key.extended));if(!heldKeys.size){clearInterval(keyTimer);keyTimer=null;}});
  cv.addEventListener('paste', (e) => { if (!control || gone) return; e.preventDefault();if(heldKeys.size){heldKeys.clear();clearInterval(keyTimer);keyTimer=null;input(keyboardAction('cancel'));}input({ a: 'text', text: (e.clipboardData?.getData('text/plain') || '').slice(0, 2000) }); });
  cv.addEventListener('compositionend', (e) => { if (e.data) input({ a: 'text', text: e.data }); });
  function type(enter) { const value = txt.value; txt.value = ''; if (value) input({ a: 'text', text: value }); if (enter) input({ a: 'key', keys: 'enter' }); }
  $('send').onclick = () => type(false);
  txt.addEventListener('keydown', (e) => { if (e.key === 'Enter' && !e.isComposing) { e.preventDefault(); type(true); } });
  kb.querySelectorAll('[data-k]').forEach((b) => { b.onclick = () => input({ a: 'key', keys: b.dataset.k }); });
  for (const [text, key] of [['Ctrl+C','ctrl+c'],['Ctrl+V','ctrl+v'],['Alt+Tab','alt+tab'],['Win','win']]) {
    const b = document.createElement('button'); b.textContent = text; b.onclick = () => input({ a: 'key', keys: key }); kb.append(b);
  }
  addEventListener('blur', clearInput);
  cv.addEventListener('blur', clearInput);
  addEventListener('visibilitychange',()=>{if(document.hidden)clearInput();});
  addEventListener('pagehide', clearInput);
  addEventListener('helper-disconnected', clearInput);
  let transferQueue=Promise.resolve();
  const fileDrag=e=>Array.from(e.dataTransfer?.types||[]).includes('Files');
  cv.addEventListener('dragover',e=>{if(!fileDrag(e))return;e.preventDefault();e.dataTransfer.dropEffect=control&&!gone?'copy':'none';});
  cv.addEventListener('drop',e=>{
    if(!fileDrag(e))return;e.preventDefault();e.stopPropagation();
    if(!control||gone||ended){status(ru?'Сначала включите управление для копирования файлов':'Take control to copy files','bad');return;}
    clearInput();const files=Array.from(e.dataTransfer.files||[]);
    if(files.length>32){status(ru?'Перетащите не больше 32 файлов за раз':'Drop at most 32 files at once','bad');return;}
    for(const file of files)transferQueue=transferQueue.then(async()=>{
      if(gone||ended||!control)return;
      status((ru?'Копирую на удалённый ПК: ':'Copying to remote PC: ')+file.name,'on');
      const r=await fetch(base+'/upload?drop=1&name='+encodeURIComponent(file.name),{method:'POST',headers:{'x-ctl':CTL},body:file});
      const j=await r.json();if(!r.ok)throw Error(j.error||'Upload failed');
      status((ru?'Скопировано: ':'Copied: ')+j.path,'on');
    }).catch(e=>{if(!gone)status(e.message,'bad');});
  });
  // Never navigate to an untrusted dropped URL or implicitly upload text/HTML.
  addEventListener('dragover',e=>{if(fileDrag(e))e.preventDefault();});
  addEventListener('drop',e=>{if(fileDrag(e))e.preventDefault();});
  setInterval(() => { if (control && !gone) request('/takeover', { on: true }).catch((e) => { paint(false); if (!gone) status(e.message, 'bad'); }); }, 30000);
})();
