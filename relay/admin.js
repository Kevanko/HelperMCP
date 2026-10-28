// HelperMCP admin panel (script from the server itself; no inline code). Everything shown comes through textContent.
(function () {
  'use strict';
  const app = document.getElementById('app'); let csrf = '', timer = null, tab = 'sessions', refreshDevices = () => {};
  const el = (tag, props, ...kids) => {
    const e = document.createElement(tag);
    if (props) for (const k in props) { if (k === 'class') e.className = props[k]; else if (k === 'text') e.textContent = props[k]; else if (k === 'style') e.style.cssText = props[k]; else if (k.startsWith('on')) e.addEventListener(k.slice(2), props[k]); else if (props[k] != null && props[k] !== false) e.setAttribute(k, props[k] === true ? '' : props[k]); }
    for (const c of kids.flat()) if (c != null) e.append(c.nodeType ? c : document.createTextNode(String(c)));
    return e;
  };
  async function call(path, body) {
    const r = await fetch('/admin/api/' + path, body === undefined ? { credentials: 'same-origin' } : { method: 'POST', credentials: 'same-origin', headers: { 'content-type': 'application/json', 'x-csrf': csrf }, body: JSON.stringify(body) });
    const j = await r.json().catch(() => ({})); if (!r.ok) { const e = new Error(j.error || 'failed'); e.status = r.status; throw e; } return j;
  }
  const ago = (s) => (s < 60 ? s + ' s' : s < 3600 ? Math.round(s / 60) + ' min' : s < 86400 ? Math.round(s / 3600) + ' h' : Math.round(s / 86400) + ' d');
  const dur = (s) => { const d = Math.floor(s / 86400), h = Math.floor((s % 86400) / 3600), m = Math.floor((s % 3600) / 60); return (d ? d + 'd ' : '') + h + 'h ' + m + 'm'; };

  // small inline icons (no icon font, no network): outline glyphs for actions, filled glyphs for OS marks
  const SVGNS = 'http://www.w3.org/2000/svg';
  function svgEl(tag, attrs) { const e = document.createElementNS(SVGNS, tag); for (const k in attrs) e.setAttribute(k, attrs[k]); return e; }
  function icon(name, size) {
    const s = svgEl('svg', { viewBox: '0 0 16 16', width: size || 15, height: size || 15, class: 'ic ic-' + name, 'aria-hidden': 'true' });
    const outline = (d) => { s.setAttribute('fill', 'none'); s.setAttribute('stroke', 'currentColor'); s.setAttribute('stroke-width', '1.4'); s.setAttribute('stroke-linecap', 'round'); s.setAttribute('stroke-linejoin', 'round'); s.append(svgEl('path', { d })); };
    const filled = (...ds) => { s.setAttribute('fill', 'currentColor'); for (const d of ds) s.append(svgEl('path', { d })); };
    switch (name) {
      case 'open': outline('M6 3H3.5A1.5 1.5 0 0 0 2 4.5v8A1.5 1.5 0 0 0 3.5 14h8a1.5 1.5 0 0 0 1.5-1.5V10 M9 2h5v5 M14 2 7 9'); break;
      case 'eye': outline('M1.5 8S4 3 8 3s6.5 5 6.5 5-2.5 5-6.5 5-6.5-5-6.5-5z M8 10a2 2 0 1 0 0-4 2 2 0 0 0 0 4z'); break;
      case 'power': outline('M8 2v6 M4 3.5a6 6 0 1 0 8 0'); break;
      case 'list': outline('M5.5 4h8 M5.5 8h8 M5.5 12h8 M2.3 4h.01 M2.3 8h.01 M2.3 12h.01'); break;
      case 'doc': outline('M4 1.8h5.5L13 5.3V13a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V2.8a1 1 0 0 1 1-1z M9.3 1.8V5h3.5'); break;
      case 'lock': outline('M4.5 7.3V5a3.5 3.5 0 1 1 7 0v2.3 M3.8 7.3h8.4a.8.8 0 0 1 .8.8V13a1 1 0 0 1-1 1H4a1 1 0 0 1-1-1V8.1a.8.8 0 0 1 .8-.8z'); break;
      case 'logout': outline('M6.5 2H3.2a1 1 0 0 0-1 1v10a1 1 0 0 0 1 1h3.3 M10.5 11l3-3-3-3 M13.3 8H5.8'); break;
      case 'camera-off': outline('M2 2l12 12 M5.3 4H3.5a1 1 0 0 0-1 1v7a1 1 0 0 0 1 1h8.3 M11.7 5.3V5a1 1 0 0 0-1-1H9l-1-1.5H8 M14 5.5v6a1 1 0 0 1-1 1h-.3 M8 6.3A2 2 0 0 1 10 8.4'); break;
      case 'windows': filled('M1 2.6 6.6 1.8V7.3H1z M7.3 1.7 15 .6V7.3H7.3z M1 8.1h5.6v5.5L1 12.8z M7.3 8.1H15v6.7l-7.7-1.1z'); break;
      case 'linux': filled('M8 .9c1 0 1.8.9 1.8 2.1 0 .8-.3 1.3-.6 1.8.9.6 1.7 1.6 2.1 2.8.5 1.5.3 2.9-.1 3.9.4.3.6.7.6 1.2 0 .9-1.4 1.5-2.4 1.9-1.2.5-2.6.6-3.6.3-1-.3-2.4-.4-3.6-.9-1-.4-2.4-1-2.4-1.9 0-.5.2-.9.6-1.2-.4-1-.6-2.4-.1-3.9.4-1.2 1.2-2.2 2.1-2.8-.3-.5-.6-1-.6-1.8C6.2 1.8 7 .9 8 .9z M6.3 7.3a.6.6 0 1 0 0-1.2.6.6 0 0 0 0 1.2z M9.7 7.3a.6.6 0 1 0 0-1.2.6.6 0 0 0 0 1.2z'); break;
      case 'android': filled('M4.3 6.6h7.4v4.6a1 1 0 0 1-1 1h-.3v1.6a.9.9 0 0 1-1.8 0v-1.6H7.8v1.6a.9.9 0 0 1-1.8 0v-1.6h-.3a1 1 0 0 1-1-1V6.6z M3 6.6a1 1 0 1 0-1.9 0M14.9 6.6a1 1 0 1 0-1.9 0 M5.6 5.8c0-1.6 1.1-2.8 2.4-2.8s2.4 1.2 2.4 2.8M6.2 2.3l-.7-1.1M9.8 2.3l.7-1.1 M6.5 5.6h.01 M9.5 5.6h.01'); break;
      case 'device': filled('M2 2.5h12a1 1 0 0 1 1 1V10a1 1 0 0 1-1 1H9.5v1.7h1.8a.6.6 0 0 1 0 1.1H4.7a.6.6 0 0 1 0-1.1h1.8V11H2a1 1 0 0 1-1-1V3.5a1 1 0 0 1 1-1z M2.5 3.5h11V9h-11z'); break;
      case 'help': outline('M8 14.5a6.5 6.5 0 1 0 0-13 6.5 6.5 0 0 0 0 13z M6.2 6.2a1.8 1.8 0 0 1 3.5.5c0 1.2-1.7 1.3-1.7 2.6 M8 11.4h.01'); break;
      case 'check': outline('M8 14.5a6.5 6.5 0 1 0 0-13 6.5 6.5 0 0 0 0 13z M5.3 8.2l1.8 1.8 3.6-3.8'); break;
      case 'shield': outline('M8 1.5 13.5 3.6V7.5c0 3.5-2.3 5.9-5.5 7-3.2-1.1-5.5-3.5-5.5-7V3.6z M5.6 8l1.8 1.8 3.1-3.5'); break;
    }
    return s;
  }
  const label = (iconName, text) => [icon(iconName), ' ', text];
  const osKind = (os) => (/android/i.test(os) ? 'android' : /linux|ubuntu|debian/i.test(os) ? 'linux' : 'windows');
  // a square tile for the sessions list: a live screenshot for a desktop OS, an OS glyph for a phone or when there is nothing to show
  function previewTile(s) {
    const t = el('div', { class: 'tile' });
    if (s.online && osKind(s.os) !== 'android') {
      const img = el('img', { alt: '', loading: 'lazy', src: '/admin/api/preview?code=' + encodeURIComponent(s.code) + '&t=' + Math.floor(Date.now() / 15000) });
      img.addEventListener('error', () => { img.remove(); t.append(icon('camera-off', 20)); }, { once: true });
      t.append(img);
    } else t.append(icon(osKind(s.os) === 'android' ? 'android' : 'camera-off', 20));
    t.append(el('span', { class: 'badge', title: s.os }, icon(osKind(s.os), 10)));
    return t;
  }

  // our own dialogs instead of the browser's prompt / confirm / alert
  function modal(title, content, { ok = 'OK', danger = false, cancel = 'Cancel', onok } = {}) {
    return new Promise((resolve) => {
      const prev = document.activeElement, err = el('div', { class: 'err' });
      const close = (v) => { document.removeEventListener('keydown', key, true); back.remove(); if (prev && prev.focus) prev.focus(); resolve(v); };
      const yes = el('button', { class: danger ? 'go bad' : 'go', text: ok, onclick: async () => { try { const v = onok ? await onok() : true; close(v === undefined ? true : v); } catch (e) { err.textContent = e.message; } } });
      const key = (e) => { if (e.key === 'Escape') { e.stopPropagation(); close(null); } else if (e.key === 'Enter' && e.target.tagName !== 'BUTTON' && e.target.tagName !== 'TEXTAREA') { e.preventDefault(); yes.click(); } };
      const back = el('div', { class: 'back', onmousedown: (e) => { if (e.target === back) close(null); } }, el('div', { class: 'dlg', role: 'dialog', 'aria-modal': 'true', 'aria-label': title }, el('h2', { text: title }), content, err, el('div', { class: 'btns' }, cancel ? el('button', { text: cancel, onclick: () => close(null) }) : null, yes)));
      document.addEventListener('keydown', key, true); document.body.append(back); (back.querySelector('input,textarea') || yes).focus();
    });
  }
  const confirmBox = (title, text, ok) => modal(title, el('p', { class: 'msg', text }), { ok, danger: true });
  const notice = (title, text) => modal(title, el('p', { class: 'msg', text }), { cancel: null });
  const SWATCH = ['#38ff7a', '#2ec4ff', '#7a8cff', '#c77dff', '#ff5fa2', '#ff5d5d', '#ff8a1e', '#ffd166'];
  async function lookBox(s) {   // glow colour (swatches or any colour) + the task text shown on the device
    let col = /^#[0-9a-f]{6}$/i.test(s.color || '') ? s.color.toLowerCase() : '', picked = false;
    const pv = el('div', { class: 'pv' }), note = el('textarea', { rows: 2, maxlength: 90, spellcheck: false }), cnt = el('span', { class: 'mut' }), pick = el('input', { type: 'color', 'aria-label': 'custom colour', value: col || '#38ff7a' });
    note.value = s.note || ''; const sw = SWATCH.map((c) => el('button', { type: 'button', class: 'sw', title: c, 'aria-label': c, style: 'background:' + c, onclick: () => set(c) }));
    const set = (c) => { col = c; picked = true; pick.value = c; show(); };
    const show = () => { sw.forEach((b, i) => b.classList.toggle('sel', SWATCH[i] === col)); pv.style.setProperty('--c', col || '#38ff7a'); pv.textContent = note.value.trim() || 'Task text appears here'; cnt.textContent = note.value.length + ' / 90'; };
    pick.addEventListener('input', () => set(pick.value)); note.addEventListener('input', show); show();
    const gl = el('input', { type: 'checkbox', id: 'lk-glow' }), sn = el('input', { type: 'checkbox', id: 'lk-snd' }); gl.checked = !!s.glow; sn.checked = !!s.sound;
    const body = el('div', { class: 'look' }, el('div', { class: 'row' }, el('label', { text: 'Glow colour' }), el('div', { class: 'sws' }, sw, pick)), el('div', { class: 'row' }, el('label', { text: 'Task text' }), note, cnt), el('div', { class: 'row' }, el('label', { text: 'Preview' }), pv), el('div', { class: 'row' }, el('label', { class: 'chk', for: 'lk-glow' }, gl, ' Soft glow around the screen edges'), el('label', { class: 'chk', for: 'lk-snd' }, sn, ' Soft sounds (connect, question)')));
    return modal('Look of ' + s.code, body, { ok: 'Apply', onok: async () => { await call('look', { code: s.code, ...(picked ? { color: col } : {}), note: note.value, glow: gl.checked, sound: sn.checked }); return true; } });
  }
  const MODES = [
    ['confirm', 'help', 'Confirm', 'The console asks before every action.'],
    ['auto', 'check', 'Auto', 'No questions. The console stays open; Esc pauses or ends the session. The default.'],
    ['unattended', 'shield', 'Unattended', 'No questions, no console needed. Esc only pauses the AI; only the admin panel ends the session.'],
  ];
  async function modeBox(s) {
    let picked = s.mode;
    const opts = MODES.map(([v, ic, t, d]) => el('button', { type: 'button', class: 'modeopt' + (v === picked ? ' sel' : ''), onclick: () => { picked = v; show(); } }, icon(ic, 18), el('div', null, el('b', { text: t }), el('span', { text: d }))));
    const show = () => opts.forEach((b, i) => b.classList.toggle('sel', MODES[i][0] === picked));
    const body = el('div', { class: 'modes' }, opts);
    return modal('Access mode for ' + s.code, body, { ok: 'Apply', onok: async () => { if (picked !== s.mode) await call('mode', { code: s.code, mode: picked }); return true; } });
  }

  function login(msg) {
    clearInterval(timer);
    const u = el('input', { id: 'u', autocomplete: 'username', spellcheck: false, autofocus: true }), pw = el('input', { id: 'p', type: 'password', autocomplete: 'current-password' }), err = el('div', { class: 'err', text: msg || '' });
    const go = async () => { err.textContent = ''; try { const j = await call('login', { user: u.value, pass: pw.value }); csrf = j.csrf; panel(j); } catch (e) { err.textContent = e.message; pw.value = ''; } };
    pw.addEventListener('keydown', (e) => { if (e.key === 'Enter') go(); }); u.addEventListener('keydown', (e) => { if (e.key === 'Enter') pw.focus(); });
    app.replaceChildren(el('div', { class: 'login' }, el('h1', { text: 'HelperMCP / admin' }), el('label', { for: 'u', text: 'Login' }), u, el('label', { for: 'p', text: 'Password' }), pw, el('button', { class: 'go', text: 'Sign in', onclick: go }), err,
      location.protocol === 'http:' ? el('div', { class: 'note', text: 'This connection is not encrypted. Set a domain on the server (helpermcp domain <name>) before using the panel over the internet.' }) : null,
      el('div', { class: 'note', style: 'color:var(--mut)', text: 'No login yet? On the server run: helpermcp admin' })));
  }

  function defaultsBar() {   // global actions; per-device toggles remain in the device row
    const gl = el('input', { type: 'checkbox', id: 'df-glow', disabled: true }), sn = el('input', { type: 'checkbox', id: 'df-snd', disabled: true }), msg = el('span', { class: 'mut' });
    const push = async (key) => { gl.disabled = sn.disabled = true; try { const j = await call('settings', { [key]: key === 'glow' ? gl.checked : sn.checked }); gl.checked = j.glow; sn.checked = j.sound; msg.textContent = 'Applied to all devices'; refreshDevices(); } catch (e) { msg.textContent = e.message; } finally { gl.disabled = sn.disabled = false; } };
    call('settings', {}).then((j) => { gl.checked = j.glow; sn.checked = j.sound; gl.disabled = sn.disabled = false; }).catch(() => {});
    gl.addEventListener('change', () => push('glow')); sn.addEventListener('change', () => push('sound'));
    return el('div', { class: 'defaults' }, el('b', { text: 'All devices' }), el('label', { class: 'chk', for: 'df-glow' }, gl, ' Glow'), el('label', { class: 'chk', for: 'df-snd' }, sn, ' Sound'), msg, el('span', { class: 'mut', text: 'Applies now and to new connections. Use the switches beside a device for a local change.' }));
  }
  async function panel(me) {
    const status = el('div', { class: 'cards' }), body = el('div');
    const TAB_ICON = { sessions: 'list', report: 'doc', account: 'lock' };
    const tabs = ['sessions', 'report', 'account'].map((t) => el('button', { class: t === tab ? 'on' : '', onclick: () => { tab = t; panel(me); } }, label(TAB_ICON[t], t[0].toUpperCase() + t.slice(1))));
    app.replaceChildren(el('header', null, el('h1', { text: 'HelperMCP / admin' }), el('nav', null, tabs), el('span', { class: 'sp' }), el('span', { class: 'mut', text: me.user }), el('button', { onclick: async () => { try { await call('logout', {}); } catch (_) { /* gone */ } login(); } }, label('logout', 'Sign out'))), el('main', null, status, tab === 'sessions' ? defaultsBar() : null, body));
    clearInterval(timer);
    const guard = (e) => { if (e.status === 401) login('Signed out. Sign in again.'); else body.replaceChildren(el('div', { class: 'err', text: e.message })); };
    async function top() {
      try { const s = await call('status'); status.replaceChildren(...[['online', s.counts.online + ' / ' + s.counts.sessions], ['version', 'v' + s.version], ['uptime', dur(s.uptime_s)], ['viewers', s.counts.viewers], ['files', s.counts.files]].map(([k, v]) => el('div', { class: 'card' }, el('b', { text: String(v) }), el('span', { text: k })))); } catch (e) { guard(e); }
    }
    top();
    if (tab === 'sessions') {
      const draw = async () => {
        try {
          const rows = await call('sessions');
          body.replaceChildren(rows.length ? el('table', null, el('thead', null, el('tr', null, ['', 'Session', 'Device', 'State', 'Mode', 'Last seen', 'IP', ''].map((h) => el('th', { text: h })))),
            el('tbody', null, rows.map((s) => el('tr', { class: s.online ? '' : 'off' },
              el('td', { class: 'pv' }, previewTile(s)),
              el('td', null, el('div', { class: 'code', text: s.code }), s.note ? el('div', { class: 'recent', text: s.note }) : null,
                el('div', { class: 'device-switches', 'aria-label': 'This device only: ' + s.code }, ...['glow', 'sound','banner','timer'].map((key) => el('button', { class: 'device-toggle' + (s[key] ? ' on' : ''), 'aria-pressed': String(!!s[key]), title: 'Toggle ' + key + ' only on ' + s.code, onclick: async (e) => { e.currentTarget.disabled = true; try { await call('look', { code: s.code, [key]: !s[key] }); await draw(); } catch (err) { guard(err); } } }, ({glow:'Подсветка',sound:'Звук',banner:'Плашка',timer:'Таймер'}[key]) + ': ' + (s[key] ? 'вкл' : 'выкл'))))),
              el('td', null, el('div', { text: s.user + '@' + s.host }), el('div', { class: 'recent', text: s.os }), s.recent.length ? el('div', { class: 'recent', text: s.recent.map((r) => r.tool + (r.args ? ' ' + r.args.slice(0, 40) : '')).join(' · ') }) : null),
              el('td', null, el('span', { class: 'dot ' + (s.online ? (s.paused || s.taken ? 'warn' : 'on') : '') }), s.online ? (s.taken ? 'operator at the keyboard' : s.paused ? 'paused' : s.running ? 'working' : 'online') : 'offline' + (s.persist ? ' (kept)' : '')),
              el('td', null, el('button', { class: 'modebtn', title: 'change the access mode', onclick: () => modeBox(s).then(draw).catch(guard) }, label(MODES.find((m) => m[0] === s.mode)?.[1] || 'help', s.mode))),
              el('td', { text: s.last_seen_s == null ? 'unknown' : ago(s.last_seen_s) + ' ago' }), el('td', { text: s.ip || '' }),
              el('td', { class: 'ac' }, el('div', { class: 'acts' }, el('button', { class: 'go', title: 'open the live view', onclick: async () => { const viewer = window.open('about:blank', '_blank'); if(viewer)viewer.opener=null; try { const j = await call('open', { code: s.code }); if(viewer)viewer.location.replace(j.control); else await modal('Open remote screen', el('a',{href:j.control,target:'_blank',rel:'noopener',text:'Open '+s.code}),{cancel:null}); } catch (e) { if(viewer)viewer.close();guard(e); } } }, label('open', 'Open')),
                el('button', { title: 'glow colour and task text for this device', onclick: () => lookBox(s).then(draw).catch(guard) }, label('eye', 'Look')),
                el('button', { class: 'danger', title: 'end the session', onclick: async () => { if (!(await confirmBox('End session ' + s.code + '?', 'The helper on ' + (s.host || 'that device') + ' is told to stop and the session closes.', 'End session'))) return; try { await call('end', { code: s.code }); draw(); } catch (e) { guard(e); } } }, label('power', 'End')))))))) : el('p', { class: 'mut', text: 'No sessions yet. Share the link from `helpermcp link` with someone who needs help.' }));
        } catch (e) { guard(e); }
      };
      refreshDevices = draw; draw(); timer = setInterval(() => { draw(); top(); }, 3000);
    } else if (tab === 'report') {
      const pre = el('pre', { text: 'loading…' }), sel = el('input', { type: 'number', min: 1, max: 60, value: 7, style: 'width:5rem' });
      const load = async () => { try { pre.textContent = (await call('report?days=' + (sel.value || 7))).text; } catch (e) { guard(e); } };
      body.replaceChildren(el('p', null, 'Last ', sel, ' days ', el('button', { text: 'Refresh', onclick: load })), pre); load();
    } else {
      const o = el('input', { type: 'password', autocomplete: 'current-password' }), n = el('input', { type: 'password', autocomplete: 'new-password' }), n2 = el('input', { type: 'password', autocomplete: 'new-password' }), msg = el('div', { class: 'err' });
      body.replaceChildren(el('div', { class: 'set' }, el('h3', { text: 'Change password' }), el('label', { text: 'Current password' }), o, el('label', { text: 'New password (12+ characters)' }), n, el('label', { text: 'Repeat the new password' }), n2,
        el('button', { class: 'go', style: 'margin-top:1rem', text: 'Change', onclick: async () => { msg.className = 'err'; if (n.value !== n2.value) { msg.textContent = 'The new passwords differ.'; return; } try { await call('password', { old: o.value, new: n.value }); login('Password changed. Sign in with the new one.'); } catch (e) { msg.textContent = e.message; } } }), msg,
        el('p', { class: 'mut', text: 'Lost the password? On the server: helpermcp admin reset' })));
    }
  }
  (async () => { try { const me = await call('me'); csrf = me.csrf; panel(me); } catch (_) { login(); } })();
})();
