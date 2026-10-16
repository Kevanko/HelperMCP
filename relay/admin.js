// HelperMCP admin panel (script from the server itself; no inline code). Everything shown comes through textContent.
(function () {
  'use strict';
  const app = document.getElementById('app'); let csrf = '', timer = null, tab = 'sessions';
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
    const body = el('div', { class: 'look' }, el('div', { class: 'row' }, el('label', { text: 'Glow colour' }), el('div', { class: 'sws' }, sw, pick)), el('div', { class: 'row' }, el('label', { text: 'Task text' }), note, cnt), el('div', { class: 'row' }, el('label', { text: 'Preview' }), pv));
    return modal('Look of ' + s.code, body, { ok: 'Apply', onok: async () => { await call('look', { code: s.code, ...(picked ? { color: col } : {}), note: note.value }); return true; } });
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

  async function panel(me) {
    const status = el('div', { class: 'cards' }), body = el('div');
    const tabs = ['sessions', 'report', 'account'].map((t) => el('button', { text: t[0].toUpperCase() + t.slice(1), class: t === tab ? 'on' : '', onclick: () => { tab = t; panel(me); } }));
    app.replaceChildren(el('header', null, el('h1', { text: 'HelperMCP / admin' }), el('nav', null, tabs), el('span', { class: 'sp' }), el('span', { class: 'mut', text: me.user }), el('button', { text: 'Sign out', onclick: async () => { try { await call('logout', {}); } catch (_) { /* gone */ } login(); } })), el('main', null, status, body));
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
          body.replaceChildren(rows.length ? el('table', null, el('thead', null, el('tr', null, ['Session', 'Device', 'State', 'Mode', 'Last seen', 'IP', ''].map((h) => el('th', { text: h })))),
            el('tbody', null, rows.map((s) => el('tr', { class: s.online ? '' : 'off' },
              el('td', null, el('div', { class: 'code', text: s.code }), s.note ? el('div', { class: 'recent', text: s.note }) : null),
              el('td', null, el('div', { text: s.user + '@' + s.host }), el('div', { class: 'recent', text: s.os }), s.recent.length ? el('div', { class: 'recent', text: s.recent.map((r) => r.tool + (r.args ? ' ' + r.args.slice(0, 40) : '')).join(' · ') }) : null),
              el('td', null, el('span', { class: 'dot ' + (s.online ? (s.paused || s.taken ? 'warn' : 'on') : '') }), s.online ? (s.taken ? 'operator at the keyboard' : s.paused ? 'paused' : s.running ? 'working' : 'online') : 'offline' + (s.persist ? ' (kept)' : '')),
              el('td', { text: s.mode }), el('td', { text: ago(s.last_seen_s) + ' ago' }), el('td', { text: s.ip || '' }),
              el('td', { class: 'ac' }, el('div', { class: 'acts' }, el('button', { class: 'go', text: 'Open', title: 'open the live view', onclick: async () => { try { const j = await call('open', { code: s.code }); window.open(j.control, '_blank', 'noopener'); } catch (e) { guard(e); } } }),
                el('button', { text: 'Look', title: 'glow colour and task text', onclick: () => lookBox(s).catch(guard) }),
                el('button', { class: 'danger', text: 'End', title: 'end the session', onclick: async () => { if (!(await confirmBox('End session ' + s.code + '?', 'The helper on ' + (s.host || 'that device') + ' is told to stop and the session closes.', 'End session'))) return; try { await call('end', { code: s.code }); draw(); } catch (e) { guard(e); } } }))))))) : el('p', { class: 'mut', text: 'No sessions yet. Share the link from `helpermcp link` with someone who needs help.' }));
        } catch (e) { guard(e); }
      };
      draw(); timer = setInterval(() => { draw(); top(); }, 3000);
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
