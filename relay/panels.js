// The System / Files drawer of the live viewer (control link only). Everything that comes from the remote machine is untrusted: it only ever goes
// into the page through textContent, never innerHTML. Data comes from the agent through the relay: /sysdata (JSON), /ls, /preview, /fsop, /act, /get, /upload.
(function () {
  'use strict';
  const P = (window.Panels = {});
  let cfg = null, drawer, tabsEl, body, cur = null, os = '', win = true, clip = null;
  const T = (e, r) => (cfg && cfg.ru ? r : e);
  const $ = (id) => document.getElementById(id);
  const el = (tag, props, ...kids) => {
    const e = document.createElement(tag);
    if (props) for (const k in props) { if (k === 'class') e.className = props[k]; else if (k === 'text') e.textContent = props[k]; else if (k.startsWith('on')) e.addEventListener(k.slice(2), props[k]); else if (props[k] !== false && props[k] != null) e.setAttribute(k, props[k] === true ? '' : props[k]); }
    for (const c of kids.flat()) if (c != null) e.append(c.nodeType ? c : document.createTextNode(String(c)));
    return e;
  };
  const fmtB = (n) => { n = +n || 0; const u = ['B', 'K', 'M', 'G', 'T']; let i = 0; while (n >= 1024 && i < 4) { n /= 1024; i++; } return (i ? n.toFixed(n < 10 ? 1 : 0) : Math.round(n)) + u[i]; };
  const fmtDur = (s) => { s = +s || 0; const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60); return (d ? d + 'd ' : '') + h + 'h ' + m + 'm'; };
  const hdr = () => ({ 'x-ctl': cfg.CTL });
  async function getJson(path) { const r = await fetch(cfg.base + path, { headers: hdr() }); const t = await r.text(); let j = null; try { j = JSON.parse(t); } catch (_) { /* not json */ } if (!r.ok) throw new Error((j && j.error) || t.slice(0, 200)); return j; }
  const api = (kind, q) => getJson('/sysdata?kind=' + kind + (q || ''));
  async function post(path, b) { const r = await fetch(cfg.base + path, { method: 'POST', headers: { 'content-type': 'application/json', 'x-ctl': cfg.CTL }, body: JSON.stringify(b) }); const j = await r.json().catch(() => ({})); if (!r.ok) throw new Error(j.error || 'failed'); return j; }
  const copyText = (t) => { try { navigator.clipboard.writeText(t); } catch (_) { /* no clipboard permission */ } };

  // a sortable, filterable table; rows are arrays or objects, columns say how to read, show and class a cell
  function table(cols, opt) {
    opt = opt || {};
    const t = el('table', { class: 'pt' }), head = el('tr'), tb = el('tbody');
    let rows = [], sortK = opt.sort || null, asc = !!opt.asc, sel = null;
    cols.forEach((c) => { const th = el('th', { text: c.label, class: c.r ? 'r' : '' }); th.addEventListener('click', () => { if (!c.val) return; if (sortK === c.k) asc = !asc; else { sortK = c.k; asc = !!c.asc; } draw(); }); head.append(th); });
    t.append(el('thead', null, head), tb);
    function draw() {
      let r = rows.slice(); const c = cols.find((x) => x.k === sortK);
      if (c && c.val) r.sort((a, b) => { const x = c.val(a), y = c.val(b); return (x < y ? -1 : x > y ? 1 : 0) * (asc ? 1 : -1); });
      const f = document.createDocumentFragment();
      r.slice(0, 2500).forEach((row) => {
        const tr = el('tr', { class: [opt.cls ? opt.cls(row) : '', sel != null && opt.key && opt.key(row) === sel ? 'sel' : ''].join(' ') });
        cols.forEach((c2) => { const v = c2.show ? c2.show(row) : ''; tr.append(el('td', { class: (c2.r ? 'r ' : '') + (c2.cls ? c2.cls(row) : ''), title: c2.tip ? c2.tip(row) : null }, v)); });
        tr.addEventListener('click', () => { sel = opt.key ? opt.key(row) : null; [...tb.children].forEach((x) => x.classList.remove('sel')); tr.classList.add('sel'); if (opt.onSelect) opt.onSelect(row); });
        f.append(tr);
      });
      tb.replaceChildren(f);
    }
    return { el: t, set(r) { rows = r; draw(); }, select(k) { sel = k; }, count: () => rows.length };
  }
  const bar = (pct, cls) => el('div', { class: 'bar2' }, el('i', { class: cls || (pct > 90 ? 'red' : pct > 75 ? 'hot' : ''), style: 'width:' + Math.max(0, Math.min(100, pct)) + '%' }));
  const msgBox = () => el('div', { class: 'msg' });
  const loading = (box) => box.replaceChildren(el('div', { class: 'find mut', text: T('loading…', 'загрузка…') }));
  const fail = (box, e) => box.replaceChildren(el('div', { class: 'find bad', text: String(e && e.message || e) }));
  function kv(o, skip) { const dl = el('dl'); for (const k in o) { if (skip && skip.includes(k)) continue; let v = o[k]; if (v == null || v === '' || (Array.isArray(v) && !v.length)) continue; if (Array.isArray(v)) v = v.join('\n'); dl.append(el('dt', { text: k.replace(/_/g, ' ') }), el('dd', { text: String(v) })); } return dl; }
  const sparkDraw = (cv, hist, max, color) => {
    const w = cv.width = cv.clientWidth * (devicePixelRatio || 1) || 300, h = cv.height = 46 * (devicePixelRatio || 1), g = cv.getContext('2d'); g.clearRect(0, 0, w, h);
    if (hist.length < 2) return; const m = max || Math.max(1, ...hist); g.strokeStyle = color || '#38ff7a'; g.lineWidth = 1.5 * (devicePixelRatio || 1); g.beginPath();
    hist.forEach((v, i) => { const x = (i / (hist.length - 1)) * w, y = h - (Math.min(v, m) / m) * (h - 4) - 2; i ? g.lineTo(x, y) : g.moveTo(x, y); }); g.stroke();
  };

  // ---- Processes
  function Procs(box) {
    let stopped = false, rows = [], filter = '', tree = false, tm = null, hover = false;
    const msg = msgBox(), pd = el('div', { class: 'pd', hidden: true });
    const fi = el('input', { type: 'text', placeholder: T('filter: name, pid, path, publisher', 'фильтр: имя, pid, путь, издатель'), oninput: () => { filter = fi.value.toLowerCase(); draw(); } });
    const cb = el('input', { type: 'checkbox', onchange: () => { tree = cb.checked; draw(); } }), cnt = el('span', { class: 'mut' });
    const tbl = table([
      { k: 'pid', label: 'PID', r: 1, show: (r) => r.pid, val: (r) => r.pid, asc: 1 },
      { k: 'name', label: T('Name', 'Имя'), show: (r) => (tree ? ' '.repeat(r.d * 2) + (r.d ? '└ ' : '') : '') + r.name, val: (r) => r.name.toLowerCase(), asc: 1, tip: (r) => r.path },
      { k: 'cpu', label: 'CPU %', r: 1, show: (r) => (r.cpu ? r.cpu.toFixed(1) : ''), val: (r) => r.cpu },
      { k: 'mem', label: T('Memory', 'Память'), r: 1, show: (r) => fmtB(r.ws), val: (r) => r.ws },
      { k: 'priv', label: T('Private', 'Приватная'), r: 1, show: (r) => fmtB(r.priv), val: (r) => r.priv },
      { k: 'thr', label: T('Threads', 'Потоки'), r: 1, show: (r) => r.thr, val: (r) => r.thr },
      { k: 'hnd', label: T('Handles', 'Дескр.'), r: 1, show: (r) => r.hnd, val: (r) => r.hnd },
      { k: 'pub', label: T('Publisher', 'Издатель'), show: (r) => r.pub, val: (r) => r.pub.toLowerCase(), asc: 1 },
      { k: 'path', label: T('Path', 'Путь'), show: (r) => r.path, val: (r) => r.path.toLowerCase(), asc: 1 }],
    { sort: 'cpu', key: (r) => r.pid, cls: (r) => (r.flag ? 'w' : r.pid < 5 ? 'dim' : ''), onSelect: show });
    box.append(el('div', { class: 'pb' }, fi, el('label', null, cb, T('tree', 'дерево')), cnt, el('span', { class: 'sp' }), el('button', { text: '⟳', title: 'refresh', onclick: () => { clearTimeout(tm); tick(); } })), el('div', { class: 'pw' }, el('div', { class: 'pl', onmouseenter: () => { hover = true; }, onmouseleave: () => { hover = false; draw(); } }, tbl.el), pd), msg);   // the rows hold still while the pointer is over the list (they re-sort by CPU every few seconds)
    function draw() {
      if (hover) return;
      let r = rows;
      if (filter) r = r.filter((x) => (x.pid + ' ' + x.name + ' ' + x.path + ' ' + x.pub).toLowerCase().includes(filter));
      if (tree && !filter) {   // parents above children
        const by = new Map(); rows.forEach((x) => { (by.get(x.ppid) || by.set(x.ppid, []).get(x.ppid)).push(x); });
        const ids = new Set(rows.map((x) => x.pid)), out = [], seen = new Set();
        const walk = (x, d) => { if (seen.has(x.pid)) return; seen.add(x.pid); out.push(Object.assign({}, x, { d })); (by.get(x.pid) || []).sort((a, b) => b.cpu - a.cpu).forEach((c) => walk(c, d + 1)); };
        rows.filter((x) => !ids.has(x.ppid) || x.ppid === x.pid || x.pid === 0).sort((a, b) => b.cpu - a.cpu).forEach((x) => walk(x, 0)); r = out;
      } else r = r.map((x) => Object.assign({}, x, { d: 0 }));
      tbl.set(r); cnt.textContent = r.length + (r.length !== rows.length ? ' / ' + rows.length : '') + ' ' + T('processes', 'процессов');
    }
    async function tick() {
      if (stopped) return;
      try { const j = await api('procs'); rows = j.p.map((a) => ({ pid: a[0], ppid: a[1], name: a[2], cpu: a[3], ws: a[4], priv: a[5], thr: a[6], hnd: a[7], path: a[8], pub: a[9], flag: a[10] })); draw(); msg.textContent = ''; }
      catch (e) { msg.textContent = String(e.message || e); }
      if (!stopped) tm = setTimeout(tick, 3000);
    }
    async function show(r) {
      pd.hidden = false; pd.replaceChildren(el('div', { class: 'mut', text: T('reading ' + r.name + '…', 'читаю ' + r.name + '…') }));
      try {
        const d = await api('process', '&pid=' + r.pid);
        const sig = d.signature ? el('span', { class: d.signature === 'Valid' ? 'ok' : 'bad', text: d.signature + (d.signer ? ' · ' + d.signer : '') }) : null;
        const acts = el('div', { class: 'acts' },
          r.pid > 4 ? el('button', { text: T('End process', 'Завершить'), onclick: async () => { if (!confirm(T('End ', 'Завершить ') + r.name + ' (pid ' + r.pid + ')?')) return; try { await post('/kill', { pid: r.pid }); msg.textContent = T('ended ', 'завершён ') + r.name; clearTimeout(tm); setTimeout(tick, 600); } catch (e) { msg.textContent = e.message; } } }) : null,
          d.path ? el('button', { text: T('Show in Files', 'Показать в файлах'), onclick: () => P.open('files', { path: d.path, select: true }) }) : null,
          d.path ? el('button', { text: T('Copy path', 'Копировать путь'), onclick: () => copyText(d.path) }) : null,
          d.sha256 ? el('a', { href: 'https://www.virustotal.com/gui/file/' + d.sha256, target: '_blank', rel: 'noopener noreferrer' }, el('button', { text: 'VirusTotal' })) : null);
        const top = {};
        ['path', 'cmd', 'parents', 'started', 'running_for', 'user', 'company', 'product', 'version', 'description', 'size', 'file_created', 'file_modified', 'sha256', 'services', 'autostart', 'connections'].forEach((k) => { if (d[k] != null) top[k] = d[k]; });
        if (top.running_for != null) top.running_for = top.running_for + ' min'; if (top.size != null) top.size = fmtB(top.size);
        const dl = kv(top); if (sig) { dl.prepend(el('dt', { text: 'signature' }), el('dd', null, sig)); }
        pd.replaceChildren(el('h3', { text: d.name + '  (pid ' + d.pid + ')' }), d.trust ? el('div', { class: 'bad', text: '! ' + d.trust }) : null, acts, dl, el('div', { class: 'mut', text: fmtB(d.mem_ws) + ' RAM, ' + d.threads + ' threads, ' + d.handles + ' handles' }));
      } catch (e) { pd.replaceChildren(el('div', { class: 'bad', text: String(e.message || e) })); }
    }
    tick();
    return { stop() { stopped = true; clearTimeout(tm); } };
  }

  // ---- Services
  function Services(box) {
    let rows = [], filter = '', st = '', hideMs = true;
    const msg = msgBox(), fi = el('input', { type: 'text', placeholder: T('filter', 'фильтр'), oninput: () => { filter = fi.value.toLowerCase(); draw(); } });
    const ss = el('select', { onchange: () => { st = ss.value; draw(); } }, el('option', { value: '', text: T('all states', 'все состояния') }), el('option', { value: 'Running', text: 'Running' }), el('option', { value: 'Stopped', text: 'Stopped' }));
    const cb = el('input', { type: 'checkbox', checked: true, onchange: () => { hideMs = cb.checked; draw(); } }), cnt = el('span', { class: 'mut' });
    let sel = null; const btn = (v) => el('button', { text: v, onclick: () => act(v.toLowerCase()) });
    const bs = el('span', null, btn('Start'), ' ', btn('Stop'), ' ', btn('Restart'));
    const tbl = table([
      { k: 'name', label: T('Name', 'Имя'), show: (r) => r.name, val: (r) => r.name.toLowerCase(), asc: 1 },
      { k: 'disp', label: T('Display name', 'Описание'), show: (r) => r.disp, val: (r) => r.disp.toLowerCase(), asc: 1 },
      { k: 'state', label: T('State', 'Состояние'), show: (r) => r.state, val: (r) => r.state, cls: (r) => (r.state === 'Running' ? 'ok' : 'mut') },
      { k: 'start', label: T('Start', 'Запуск'), show: (r) => r.start, val: (r) => r.start, cls: (r) => (r.start === 'Disabled' ? 'bad' : '') },
      { k: 'acct', label: T('Account', 'Учётка'), show: (r) => r.acct, val: (r) => r.acct },
      { k: 'pid', label: 'PID', r: 1, show: (r) => (r.pid || ''), val: (r) => r.pid },
      { k: 'exe', label: T('File', 'Файл'), show: (r) => r.exe, val: (r) => r.exe.toLowerCase(), asc: 1 }],
    { sort: 'name', asc: 1, key: (r) => r.name, cls: (r) => (r.ms ? 'dim' : ''), onSelect: (r) => { sel = r; msg.textContent = r.name + ' — ' + r.disp; } });
    box.append(el('div', { class: 'pb' }, fi, ss, el('label', null, cb, T('hide Microsoft', 'скрыть Microsoft')), cnt, el('span', { class: 'sp' }), bs, el('button', { text: '⟳', onclick: load })), el('div', { class: 'pw' }, el('div', { class: 'pl' }, tbl.el)), msg);
    function draw() { const r = rows.filter((x) => (!hideMs || !x.ms) && (!st || x.state === st) && (!filter || (x.name + ' ' + x.disp + ' ' + x.exe).toLowerCase().includes(filter))); tbl.set(r); cnt.textContent = r.length + ' / ' + rows.length; }
    async function load() { loading(msg); try { rows = await api('services'); draw(); msg.textContent = ''; } catch (e) { msg.textContent = e.message; } }
    async function act(v) {
      if (!sel) { msg.textContent = T('pick a service first', 'сначала выберите службу'); return; }
      if (v !== 'start' && !confirm(v + ' ' + sel.name + '?')) return;
      msg.textContent = '…'; try { const j = await post('/act', { act: 'service', name: sel.name, value: v }); msg.textContent = sel.name + ': ' + (j.text || 'ok').slice(0, 200); setTimeout(load, 1500); } catch (e) { msg.textContent = e.message; }
    }
    load(); return { stop() {} };
  }

  // ---- Startup
  function Startup(box) {
    let rows = [], filter = '', only = false;
    const msg = msgBox(), pd = el('div', { class: 'pd', hidden: true }), fi = el('input', { type: 'text', placeholder: T('filter', 'фильтр'), oninput: () => { filter = fi.value.toLowerCase(); draw(); } });
    const cb = el('input', { type: 'checkbox', onchange: () => { only = cb.checked; draw(); } }), cnt = el('span', { class: 'mut' });
    const tbl = table([
      { k: 'flag', label: '!', show: (r) => (r.flag ? '!' : ''), val: (r) => (r.flag ? 0 : 1), cls: () => 'w' },
      { k: 'kind', label: T('Type', 'Тип'), show: (r) => r.kind, val: (r) => r.kind },
      { k: 'name', label: T('Name', 'Имя'), show: (r) => r.name, val: (r) => r.name.toLowerCase(), asc: 1 },
      { k: 'on', label: T('Enabled', 'Включено'), show: (r) => (r.on ? 'yes' : 'off'), val: (r) => (r.on ? 1 : 0), cls: (r) => (r.on ? '' : 'mut') },
      { k: 'cmd', label: T('Command', 'Команда'), show: (r) => r.cmd, val: (r) => r.cmd.toLowerCase(), tip: (r) => r.cmd },
      { k: 'where', label: T('Where', 'Где'), show: (r) => r.where, val: (r) => r.where }],
    { sort: 'flag', asc: 1, key: (r) => r.kind + r.name + r.where, cls: (r) => (r.flag ? 'w' : ''), onSelect: show });
    box.append(el('div', { class: 'pb' }, fi, el('label', null, cb, T('only suspicious (!)', 'только подозрительные (!)')), cnt, el('span', { class: 'sp' }), el('button', { text: '⟳', onclick: load })), el('div', { class: 'pw' }, el('div', { class: 'pl' }, tbl.el), pd), msg);
    function draw() { const r = rows.filter((x) => (!only || x.flag) && (!filter || (x.name + ' ' + x.cmd + ' ' + x.where).toLowerCase().includes(filter))); tbl.set(r); cnt.textContent = r.length + ' / ' + rows.length; }
    function show(r) { pd.hidden = false; pd.replaceChildren(el('h3', { text: r.name }), r.flag ? el('div', { class: 'bad', text: '! ' + r.flag }) : null, el('div', { class: 'acts' }, r.exe ? el('button', { text: T('Show in Files', 'Показать в файлах'), onclick: () => P.open('files', { path: r.exe, select: true }) }) : null, el('button', { text: T('Copy command', 'Копировать команду'), onclick: () => copyText(r.cmd) })), kv({ type: r.kind, where: r.where, enabled: r.on ? 'yes' : 'off (disabled in Task Manager)', command: r.cmd, file: r.exe })); }
    async function load() { loading(msg); try { rows = await api('startup'); draw(); msg.textContent = ''; } catch (e) { msg.textContent = e.message; } }
    load(); return { stop() {} };
  }

  // ---- Performance
  function Perf(box) {
    let stopped = false, tm = null; const hist = { cpu: [], rx: [], tx: [], dr: [], dw: [] };
    const root = el('div'), cards = el('div', { class: 'cards' }), cores = el('div', { class: 'cores' }), msg = msgBox();
    box.append(el('div', { class: 'pl', style: 'overflow:auto;flex:1' }, cards, el('h4', { class: 'mut', style: 'margin:.2rem .7rem', text: T('Cores', 'Ядра') }), cores), msg);
    const cpuC = el('canvas', { class: 'spark' }), netC = el('canvas', { class: 'spark' }), dskC = el('canvas', { class: 'spark' });
    const cCpu = el('div', { class: 'card' }), cRam = el('div', { class: 'card' }), cNet = el('div', { class: 'card' }), cDsk = el('div', { class: 'card' }), cSys = el('div', { class: 'card' });
    cards.append(cCpu, cRam, cNet, cDsk, cSys);
    const push = (a, v) => { a.push(v); if (a.length > 90) a.shift(); };
    async function tick() {
      if (stopped) return;
      try {
        const p = await api('perf'); push(hist.cpu, p.cpu); push(hist.rx, p.rx); push(hist.tx, p.tx); if (p.disk) { push(hist.dr, p.disk.rd); push(hist.dw, p.disk.wr); }
        cCpu.replaceChildren(el('h4', { text: 'CPU' }), el('b', { text: p.cpu + '%' }), el('span', { class: 'mut', text: '  ' + p.cpus + ' ' + T('threads', 'потоков') }), cpuC);
        const used = p.ram.total - p.ram.avail; cRam.replaceChildren(el('h4', { text: 'RAM' }), el('b', { text: p.ram.load + '%' }), el('span', { class: 'mut', text: '  ' + fmtB(used) + ' / ' + fmtB(p.ram.total) }), bar(p.ram.load), el('div', { class: 'mut', text: T('cache ', 'кэш ') + fmtB(p.cache) + ' · ' + T('commit ', 'выдел. ') + fmtB(p.commit.used) + ' / ' + fmtB(p.commit.limit) }), el('div', { class: 'mut', text: T('kernel paged ', 'ядро paged ') + fmtB(p.kpaged) + ' / non-paged ' + fmtB(p.knon) }));
        cNet.replaceChildren(el('h4', { text: T('Network', 'Сеть') }), el('b', { text: '↓ ' + fmtB(p.rx) + '/s' }), el('span', { class: 'mut', text: '  ↑ ' + fmtB(p.tx) + '/s' }), netC, ...p.net.filter((n) => n[1] + n[2] > 0).map((n) => el('div', { class: 'mut', text: n[0] + ': ↓ ' + fmtB(n[1]) + '/s ↑ ' + fmtB(n[2]) + '/s' })));
        cDsk.replaceChildren(el('h4', { text: T('Disk', 'Диск') }), ...(p.disk ? [el('b', { text: T('busy ', 'занят ') + p.disk.busy + '%' }), el('span', { class: 'mut', text: '  q ' + p.disk.q }), dskC, el('div', { class: 'mut', text: T('read ', 'чтение ') + fmtB(p.disk.rd) + '/s · ' + T('write ', 'запись ') + fmtB(p.disk.wr) + '/s' })] : [el('div', { class: 'mut', text: T('counters starting…', 'счётчики запускаются…') })]));
        cSys.replaceChildren(el('h4', { text: T('System', 'Система') }), kv({ processes: p.procs, threads: p.threads, handles: p.handles, uptime: fmtDur(p.up) }));
        cores.replaceChildren(...p.cores.map((c, i) => el('div', { title: 'core ' + i + ': ' + c + '%' }, el('div', { class: 'bar2' }, el('i', { class: c > 90 ? 'red' : c > 70 ? 'hot' : '', style: 'height:' + c + '%' })), el('span', { text: c + '%' }))));
        sparkDraw(cpuC, hist.cpu, 100); sparkDraw(netC, hist.rx.map((v, i) => v + hist.tx[i]), 0, '#ffd166'); sparkDraw(dskC, hist.dr.map((v, i) => v + hist.dw[i]), 0, '#ff8a1e'); msg.textContent = '';
      } catch (e) { msg.textContent = String(e.message || e); }
      if (!stopped) tm = setTimeout(tick, 1500);
    }
    tick(); return { stop() { stopped = true; clearTimeout(tm); } };
  }

  // ---- Disks
  function Disks(box) {
    const list = el('div', { class: 'pl', style: 'overflow:auto;flex:1;padding:.5rem .7rem' }), msg = msgBox(); box.append(el('div', { class: 'pb' }, el('span', { class: 'sp' }), el('button', { text: '⟳', onclick: load })), list, msg);
    async function load() {
      loading(list);
      try {
        const d = await api('disks'); const f = document.createDocumentFragment();
        const dr = [].concat(d.drives || []), ph = [].concat(d.physical || []);
        dr.forEach((x) => { const used = x.total ? 100 * (x.total - x.free) / x.total : 0; f.append(el('div', { class: 'hl', style: 'cursor:pointer', onclick: () => P.open('files', { path: x.name + '\\' }) }, el('b', { class: x.ready ? '' : 'mut', text: x.name }), el('div', { style: 'flex:1' }, el('div', { text: (x.label || T('(no label)', '(без метки)')) + '  ' + x.type + (x.fs ? ' · ' + x.fs : '') }), x.ready ? [bar(used), el('small', { text: fmtB(x.free) + ' ' + T('free of', 'свободно из') + ' ' + fmtB(x.total) + ' (' + Math.round(100 - used) + '% ' + T('free', 'свободно') + ')' })] : el('small', { text: T('not ready', 'не готов') })))); });
        if (ph.length) f.append(el('h4', { class: 'mut', text: T('Physical disks', 'Физические диски') }));
        ph.forEach((x) => f.append(el('div', { class: 'hl' }, el('b', { class: x.health === 'Healthy' ? 'ok' : 'bad', text: x.health }), el('div', null, x.name + ' · ' + x.media + ' · ' + x.bus + ' · ' + fmtB(x.size), el('small', { text: x.status })))));
        list.replaceChildren(f); msg.textContent = '';
      } catch (e) { fail(list, e); }
    }
    load(); return { stop() {} };
  }

  // ---- Network
  function Net(box) {
    const pre = el('pre', { class: 'find', style: 'flex:1;overflow:auto;margin:0' }), msg = msgBox();
    box.append(el('div', { class: 'pb' }, el('button', { text: T('Adapters', 'Адаптеры'), onclick: () => load('adapters') }), el('button', { text: T('Test every adapter against the relay (4 s)', 'Проверить каждый адаптер до сервера (4 с)'), onclick: () => load('reach') }), el('span', { class: 'sp' })), pre, msg);
    async function load(k) { pre.textContent = T('working…', 'проверяю…'); try { pre.textContent = await api(k); } catch (e) { pre.textContent = String(e.message || e); } }
    load('adapters'); return { stop() {} };
  }

  // ---- Health
  function Health(box) {
    const list = el('div', { class: 'pl', style: 'overflow:auto;flex:1' }), msg = msgBox(); box.append(el('div', { class: 'pb' }, el('span', { class: 'mut', text: T('Checks update / Store services, policies, activation, Defender, firewall, disk space, pending reboot, hosts, proxy, devices', 'Проверяет службы обновления и Store, политики, активацию, Defender, фаервол, место, перезагрузку, hosts, прокси, устройства') }), el('span', { class: 'sp' }), el('button', { text: T('Run again', 'Ещё раз'), onclick: load })), list, msg);
    const rank = { bad: 0, warn: 1, ok: 2 };
    async function load() {
      loading(list);
      try { const r = (await api('health')).sort((a, b) => rank[a.sev] - rank[b.sev]); list.replaceChildren(...r.map((x) => el('div', { class: 'hl' }, el('b', { class: x.sev === 'bad' ? 'bad' : x.sev === 'warn' ? 'warn' : 'ok', text: x.sev }), el('div', null, el('span', { class: 'mut', text: x.area + ': ' }), x.msg, x.fix ? el('small', { text: '→ ' + x.fix }) : null)))); }
      catch (e) { fail(list, e); }
    }
    load(); return { stop() {} };
  }

  // ---- Policies
  function Policies(box) {
    let rows = [], only = false, filter = '';
    const msg = msgBox(), fi = el('input', { type: 'text', placeholder: T('filter', 'фильтр'), oninput: () => { filter = fi.value.toLowerCase(); draw(); } }), cb = el('input', { type: 'checkbox', onchange: () => { only = cb.checked; draw(); } }), cnt = el('span', { class: 'mut' }), act = el('div', { class: 'find', style: 'border-bottom:1px solid var(--line)' });
    const tbl = table([
      { k: 'note', label: '!', show: (r) => (r.note ? '!' : ''), val: (r) => (r.note ? 0 : 1), cls: () => 'w' },
      { k: 'key', label: T('Key', 'Ключ'), show: (r) => r.root + '\\' + r.key, val: (r) => (r.root + r.key).toLowerCase(), asc: 1 },
      { k: 'name', label: T('Value', 'Значение'), show: (r) => r.name + ' = ' + r.value, val: (r) => r.name.toLowerCase() },
      { k: 'n', label: T('Effect', 'Что делает'), show: (r) => r.note, val: (r) => r.note, cls: (r) => (r.note ? 'warn' : '') }], { sort: 'note', asc: 1, cls: (r) => (r.note ? 'w' : '') });
    box.append(el('div', { class: 'pb' }, fi, el('label', null, cb, T('only with an effect (!)', 'только со смыслом (!)')), cnt, el('span', { class: 'sp' }), el('button', { text: '⟳', onclick: load })), act, el('div', { class: 'pw' }, el('div', { class: 'pl' }, tbl.el)), msg);
    function draw() { const r = rows.filter((x) => (!only || x.note) && (!filter || (x.root + x.key + x.name + x.value + x.note).toLowerCase().includes(filter))); tbl.set(r); cnt.textContent = r.length + ' / ' + rows.length; }
    async function load() {
      loading(msg);
      try { const [p, a] = await Promise.all([api('policy'), api('activation')]); rows = p; act.textContent = T('Windows activation: ', 'Активация Windows: ') + a.status + (a.name ? ' · ' + a.name : '') + (a.channel ? ' · ' + a.channel : '') + (a.kms ? ' · KMS ' + a.kms : ''); act.className = 'find ' + (a.ok ? 'ok' : 'bad'); draw(); msg.textContent = ''; }
      catch (e) { msg.textContent = e.message; }
    }
    load(); return { stop() {} };
  }

  // ---- text overview for devices without the Windows collectors (Linux, Android)
  function TextTab(sections) {
    return function (box) {
      const pre = el('pre', { class: 'find', style: 'flex:1;overflow:auto;margin:0;white-space:pre-wrap' }), msg = msgBox();
      box.append(el('div', { class: 'pb' }, el('span', { class: 'sp' }), el('button', { text: '⟳', onclick: load })), pre, msg);
      async function load() { pre.textContent = T('loading…', 'загрузка…'); try { const j = await post('/act', { act: 'system', sections }); pre.textContent = j.text; } catch (e) { pre.textContent = String(e.message || e); } }
      load(); return { stop() {} };
    };
  }

  // ---- Files
  function Files(box, arg) {
    const BS = String.fromCharCode(92); let cwd = '', items = [], sel = new Set(), last = null, previewUrl = null;
    const msg = msgBox(), pd = el('div', { class: 'pd', hidden: true }), fp = el('input', { type: 'text', style: 'flex:1;min-width:10rem', spellcheck: false });
    const sep = () => (cwd.includes(BS) || /^[A-Za-z]:/.test(cwd) ? BS : '/');
    const join = (d, n) => (d.endsWith(sep()) ? d + n : d + sep() + n);
    const parent = (d) => { const s = d.includes(BS) || /^[A-Za-z]:/.test(d) ? BS : '/'; let p = d.replace(/[\\/]+$/, ''); const i = p.lastIndexOf(s); if (i < 0) return d; p = p.slice(0, i); return p === '' ? '/' : /^[A-Za-z]:$/.test(p) ? p + BS : p; };
    const chips = el('span', { style: 'display:inline-flex;gap:.25rem;flex-wrap:wrap' });
    const tbl = table([
      { k: 'sel', label: '', show: (r) => el('input', { type: 'checkbox', checked: sel.has(r.name), onclick: (e) => { e.stopPropagation(); if (e.target.checked) sel.add(r.name); else sel.delete(r.name); status(); } }) },
      { k: 'name', label: T('Name', 'Имя'), show: (r) => (r.dir ? r.name + '/' : r.name), val: (r) => (r.dir ? '0' : '1') + r.name.toLowerCase(), asc: 1, cls: (r) => (r.dir ? 'n' : 'f') },
      { k: 'size', label: T('Size', 'Размер'), r: 1, show: (r) => (r.dir ? '' : fmtB(r.size)), val: (r) => (r.dir ? -1 : r.size) },
      { k: 'time', label: T('Modified', 'Изменён'), show: (r) => r.time, val: (r) => r.time }], { sort: 'name', asc: 1, key: (r) => r.name, cls: (r) => 'fl' + (clip && clip.mode === 'cut' && clip.cwd === cwd && clip.names.includes(r.name) ? ' cut' : ''), onSelect: pick });
    tbl.el.classList.add('fl');
    const b = (label, fn, title) => el('button', { text: label, title: title || null, onclick: fn });
    const bUp = b('↑', () => ls(parent(cwd)), 'up'), bGo = b('⟳', () => ls(fp.value), 'go / refresh');
    const upl = el('input', { type: 'file', multiple: true, style: 'display:none', onchange: () => upload([...upl.files]) });
    const q = el('input', { type: 'text', placeholder: T('find in this folder: name (*.log) …', 'искать здесь: имя (*.log) …'), style: 'width:11rem', onkeydown: (e) => { if (e.key === 'Enter') find(); } }), qt = el('input', { type: 'text', placeholder: T('… containing text', '… с текстом'), style: 'width:9rem', onkeydown: (e) => { if (e.key === 'Enter') find(); } });
    const bar1 = el('div', { class: 'pb' }, bUp, fp, bGo, chips), bar2 = el('div', { class: 'pb' },
      b(T('New folder', 'Папка'), () => make('mkdir')), b(T('New file', 'Файл'), () => make('newfile')), b(T('Upload', 'Загрузить'), () => upl.click()), upl,
      b(T('Download', 'Скачать'), download), b(T('Copy', 'Копировать'), () => setClip('copy')), b(T('Cut', 'Вырезать'), () => setClip('cut')), b(T('Paste here', 'Вставить сюда'), paste), b(T('Rename', 'Переименовать'), rename), b(T('Delete', 'Удалить'), del), b(T('Copy path', 'Путь'), () => copyText(sel.size === 1 ? join(cwd, [...sel][0]) : cwd)),
      el('span', { class: 'sp' }), q, qt, b(T('Find', 'Найти'), find));
    const results = el('div', { class: 'find', hidden: true });
    box.append(bar1, bar2, results, el('div', { class: 'pw' }, el('div', { class: 'pl' }, tbl.el), pd), msg);
    const status = () => { msg.textContent = (sel.size ? sel.size + ' ' + T('selected', 'выбрано') + '  ' : '') + (clip ? T('clipboard: ', 'буфер: ') + clip.names.length + ' ' + clip.mode + '  ' : '') + items.length + ' ' + T('items', 'элементов'); };
    const one = () => (sel.size === 1 ? [...sel][0] : null);
    function note(t) { msg.textContent = t; }

    async function ls(path) {
      note('…');
      try {
        let abs = path; if (path === '~' || path === '' ) { const t = await getJson('/ls?path=' + encodeURIComponent('~') + '&mode=tree'); abs = (t.text || '').split('\n')[0] || path; }
        const j = await getJson('/ls?path=' + encodeURIComponent(abs) + '&mode=list'); cwd = abs; fp.value = cwd; sel = new Set(); items = [];
        for (const l of (j.text || '').split('\n')) { const m = /^([d\-?])\s+(\d+)\s+(\d{4}-\d\d-\d\d(?: \d\d:\d\d(?::\d\d)?)?)\s+(.*)$/.exec(l); if (m) items.push({ dir: m[1] === 'd', size: +m[2], time: m[3], name: m[4] }); else { const m2 = /^\?\s+(.*)$/.exec(l); if (m2) items.push({ dir: false, size: 0, time: '', name: m2[1] }); } }
        draw(); status();
      } catch (e) { note(String(e.message || e)); }
    }
    function draw() { tbl.set(items); [...tbl.el.querySelectorAll('tbody tr')].forEach((tr) => { const n = tr.children[1].textContent.replace(/\/$/, ''); tr.addEventListener('dblclick', () => { const it = items.find((x) => x.name === n); if (it && it.dir) ls(join(cwd, n)); }); }); }
    async function pick(r) {
      sel = new Set([r.name]); [...tbl.el.querySelectorAll('tbody input')].forEach((c) => { c.checked = c.closest('tr').children[1].textContent.replace(/\/$/, '') === r.name; }); status();
      if (r.dir) { pd.hidden = true; ls(join(cwd, r.name)); return; }
      pd.hidden = false; pd.replaceChildren(el('h3', { text: r.name }), el('div', { class: 'mut', text: T('loading preview…', 'загружаю предпросмотр…') }));
      try {
        const path = join(cwd, r.name), rs = await fetch(cfg.base + '/preview?path=' + encodeURIComponent(path), { headers: hdr() });
        if (!rs.ok) throw new Error((await rs.json().catch(() => ({}))).error || 'failed');
        const ct = rs.headers.get('content-type') || ''; let body;
        if (ct.startsWith('image/')) { if (previewUrl) URL.revokeObjectURL(previewUrl); previewUrl = URL.createObjectURL(await rs.blob()); body = el('img', { src: previewUrl, alt: r.name }); }
        else {
          const j = await rs.json();
          if (j.kind === 'archive') body = el('pre', { text: (j.entries || []).map((e) => fmtB(e[1]).padStart(7) + '  ' + e[0]).join('\n') + (j.count > 300 ? '\n… ' + j.count + ' entries' : '') });
          else body = el('pre', { text: (j.kind === 'binary' ? T('binary file, first bytes:\n', 'двоичный файл, начало:\n') : '') + (j.text || T('(empty)', '(пусто)')) + (j.truncated ? '\n…' + T(' (start of the file; download for all)', ' (начало файла; скачайте целиком)') : '') });
        }
        pd.replaceChildren(el('h3', { text: r.name }), el('div', { class: 'mut', text: fmtB(r.size) + ' · ' + r.time }), el('div', { class: 'acts' }, b(T('Download', 'Скачать'), download), b(T('Open on the PC', 'Открыть на ПК'), async () => { try { await post('/act', { act: 'open', path }); note(T('opened on the PC', 'открыто на ПК')); } catch (e) { note(e.message); } }), b(T('Copy path', 'Копировать путь'), () => copyText(path))), body);
      } catch (e) { pd.replaceChildren(el('h3', { text: r.name }), el('div', { class: 'bad', text: String(e.message || e) })); }
    }
    const names = () => [...sel];
    async function op(o, p, extra) { return post('/fsop', Object.assign({ op: o, path: p }, extra || {})); }
    async function make(kind) {
      const n = prompt(kind === 'mkdir' ? T('Folder name', 'Имя папки') : T('File name', 'Имя файла')); if (!n) return;
      try { await op(kind, join(cwd, n)); await ls(cwd); note(T('created ', 'создано ') + n); } catch (e) { note(e.message); }
    }
    function setClip(mode) { if (!sel.size) { note(T('select something first', 'сначала выберите')); return; } clip = { mode, cwd, names: names() }; draw(); status(); }
    async function paste() {
      if (!clip) { note(T('the clipboard is empty', 'буфер пуст')); return; }
      let ok = 0, err = ''; for (const n of clip.names) { try { await op(clip.mode === 'cut' ? 'move' : 'copy', join(clip.cwd, n), { dest: cwd }); ok++; } catch (e) { err = e.message; if (/already exists/.test(e.message) && confirm(n + ': ' + T('already exists. Replace?', 'уже есть. Заменить?'))) { try { await op(clip.mode === 'cut' ? 'move' : 'copy', join(clip.cwd, n), { dest: cwd, overwrite: true }); ok++; err = ''; } catch (e2) { err = e2.message; } } } }
      if (clip.mode === 'cut') clip = null; await ls(cwd); note(ok + ' ' + T('done', 'готово') + (err ? '  ' + err : ''));
    }
    async function rename() { const n = one(); if (!n) { note(T('select one item', 'выберите один элемент')); return; } const nn = prompt(T('New name', 'Новое имя'), n); if (!nn || nn === n) return; try { await op('rename', join(cwd, n), { name: nn }); await ls(cwd); } catch (e) { note(e.message); } }
    async function del(ev) {
      if (!sel.size) { note(T('select something first', 'сначала выберите')); return; }
      const perm = ev && ev.shiftKey; if (!confirm((perm ? T('DELETE FOR GOOD ', 'УДАЛИТЬ НАВСЕГДА ') : T('Move to the Recycle Bin: ', 'В корзину: ')) + names().join(', ') + '?')) return;
      let ok = 0, err = ''; for (const n of names()) { try { await op('delete', join(cwd, n), perm ? { permanent: true } : {}); ok++; } catch (e) { err = e.message; } }
      pd.hidden = true; await ls(cwd); note(ok + ' ' + T('deleted', 'удалено') + (err ? '  ' + err : ''));
    }
    async function download() {
      const n = one(); if (!n) { note(T('select one file or folder', 'выберите один файл или папку')); return; }
      note(T('preparing the link…', 'готовлю ссылку…'));
      try { const j = await post('/get', { path: join(cwd, n) }); const u = (j.text || '').split(' ')[0]; if (/^https?:/.test(u)) { window.open(u, '_blank', 'noopener'); note(T('download started: ', 'скачивание: ') + n); } else note(j.text || 'failed'); } catch (e) { note(e.message); }
    }
    async function upload(files) {
      for (const f of files) { note(T('uploading ', 'загружаю ') + f.name + '…'); try { const r = await fetch(cfg.base + '/upload?name=' + encodeURIComponent(f.name) + '&dir=' + encodeURIComponent(cwd), { method: 'POST', headers: hdr(), body: f }), j = await r.json(); if (!r.ok) throw new Error(j.error); note(T('saved: ', 'сохранено: ') + j.path); } catch (e) { note(e.message); } }
      ls(cwd);
    }
    async function find() {
      const name = q.value.trim(), text = qt.value.trim(); if (!name && !text) { results.hidden = true; return; }
      results.hidden = false; results.textContent = T('searching…', 'ищу…');
      try {
        const j = await post('/act', { act: 'find', path: cwd, name, text }); const lines = (j.text || '').split('\n').filter(Boolean);
        results.replaceChildren(...lines.map((l) => { const p = l.replace(/^(.*?)(?::\d+: .*|  [\d.]+[BKMGT])?$/, '$1'); return el('div', { style: 'cursor:pointer;white-space:nowrap;overflow:hidden;text-overflow:ellipsis', title: l, onclick: () => { const d = parent(p); ls(d).then(() => { const n = p.slice(d.length).replace(/^[\\/]+/, ''); const it = items.find((x) => x.name === n); if (it) pick(it); }); } }, l); }), el('div', { class: 'mut', style: 'cursor:pointer', onclick: () => { results.hidden = true; }, text: T('close results', 'закрыть результаты') }));
      } catch (e) { results.textContent = e.message; }
    }
    fp.addEventListener('keydown', (e) => { if (e.key === 'Enter') ls(fp.value); });
    P.drop = (files) => upload(files);
    (async () => {   // drive chips: Windows letters, or the usual roots
      try { if (win) { const d = await api('disks'); chips.replaceChildren(...[].concat(d.drives || []).filter((x) => x.ready).map((x) => el('button', { text: x.name, title: x.label, onclick: () => ls(x.name + BS) }))); } else chips.replaceChildren(el('button', { text: '/', onclick: () => ls('/') }), el('button', { text: '~', onclick: () => ls('~') })); } catch (_) { /* optional */ }
    })();
    if (arg && arg.path) { if (arg.select) { const d = parent(arg.path); ls(d).then(() => { const n = arg.path.slice(d.length).replace(/^[\\/]+/, ''); const it = items.find((x) => x.name === n); if (it) pick(it); }); } else ls(arg.path); } else ls('~');
    return { stop() { P.drop = null; } };
  }

  const TABS = [
    { id: 'procs', label: ['Processes', 'Процессы'], win: 1, fn: Procs }, { id: 'services', label: ['Services', 'Службы'], win: 1, fn: Services }, { id: 'startup', label: ['Startup', 'Автозагрузка'], win: 1, fn: Startup },
    { id: 'perf', label: ['Performance', 'Производительность'], win: 1, fn: Perf }, { id: 'disks', label: ['Disks', 'Диски'], win: 1, fn: Disks }, { id: 'net', label: ['Network', 'Сеть'], win: 1, fn: Net },
    { id: 'health', label: ['Health', 'Здоровье'], win: 1, fn: Health }, { id: 'policy', label: ['Policies', 'Политики'], win: 1, fn: Policies },
    { id: 'ov', label: ['Overview', 'Обзор'], win: 0, fn: TextTab(['overview', 'disks', 'network']) }, { id: 'apps', label: ['Apps', 'Приложения'], win: 0, fn: TextTab(['apps', 'services', 'processes']) },
    { id: 'files', label: ['Files', 'Файлы'], any: 1, fn: Files }];

  function buildTabs() { tabsEl.replaceChildren(...TABS.filter((t) => t.any || (t.win ? win : !win)).map((t) => el('button', { text: T(t.label[0], t.label[1]), 'data-t': t.id, onclick: () => P.open(t.id) }))); }
  P.open = function (id, arg) {
    if (!cfg || !cfg.CTL) return;
    if (!TABS.find((t) => t.id === id && (t.any || (t.win ? win : !win)))) id = win ? 'procs' : 'ov';
    drawer.hidden = false; document.documentElement.style.setProperty('--drw', '1');
    if (cur && cur.stop) cur.stop(); body.replaceChildren(); const t = TABS.find((x) => x.id === id); cur = t.fn(body, arg) || null; P.tab = id;
    [...tabsEl.children].forEach((b) => b.classList.toggle('on', b.dataset.t === id));
  };
  P.close = () => { if (cur && cur.stop) cur.stop(); cur = null; drawer.hidden = true; body.replaceChildren(); };

  P.init = async function (c) {
    cfg = c; if (!cfg.CTL) return;
    try { const s = await (await fetch(cfg.base + '/state')).json(); os = s.os || ''; } catch (_) { /* default: Windows */ }
    win = /windows/i.test(os) || !os;
    drawer = el('div', { id: 'dr', hidden: true }); tabsEl = el('div', { id: 'drt' }); body = el('div', { id: 'drb' });
    drawer.append(el('div', { id: 'drh' }, tabsEl, el('button', { text: '✕', title: 'Esc', onclick: P.close })), body); document.body.append(drawer); buildTabs();
    const top = $('top'), mk = (id, label, tab) => { const x = el('button', { id, text: label, onclick: () => { if (!drawer.hidden && P.tab === tab) P.close(); else P.open(tab); } }); top.insertBefore(x, $('zr')); };
    mk('bsys', T('System', 'Система'), win ? 'procs' : 'ov'); mk('bfil', T('Files', 'Файлы'), 'files');
    document.addEventListener('keydown', (e) => { if (e.key === 'Escape' && !drawer.hidden && !/INPUT|TEXTAREA|SELECT/.test((e.target || {}).tagName || '')) P.close(); });
    document.addEventListener('dragover', (e) => { if (!drawer.hidden && P.drop) { e.preventDefault(); document.body.classList.add('drop'); } });
    document.addEventListener('dragleave', (e) => { if (!e.relatedTarget) document.body.classList.remove('drop'); });
    document.addEventListener('drop', (e) => { document.body.classList.remove('drop'); if (!drawer.hidden && P.drop) { e.preventDefault(); P.drop([...e.dataTransfer.files]); } });
  };
})();
