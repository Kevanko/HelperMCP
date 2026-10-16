// The admin panel: /admin. One administrator (login + generated password, stored as a scrypt hash in data/admin.json), cookie sessions, CSRF header,
// lockout after wrong passwords, a strict CSP (scripts only from the server itself), every admin action written to the action log.
// The panel lists the connected sessions and opens any of them in the live viewer; it never shows the operator key.
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';

const ALPHABET = 'abcdefghjkmnpqrstuvwxyzABCDEFGHJKMNPQRSTUVWXYZ23456789';
const rnd = (n) => [...crypto.randomBytes(n)].map((b) => ALPHABET[b % ALPHABET.length]).join('');
const SCRYPT = { N: 32768, r: 8, p: 1, maxmem: 128 * 1024 * 1024 };
const hashPw = (pw, salt) => crypto.scryptSync(String(pw), Buffer.from(salt, 'hex'), 64, SCRYPT).toString('hex');
const same = (a, b) => { const x = Buffer.from(String(a)), y = Buffer.from(String(b)); return x.length === y.length && crypto.timingSafeEqual(x, y); };

export const adminFile = (dir) => path.join(dir, 'admin.json');
export function readAdmin(dir) { try { return JSON.parse(fs.readFileSync(adminFile(dir), 'utf8')); } catch { return null; } }
function writeAdmin(dir, user, pw) {
  const salt = crypto.randomBytes(16).toString('hex');
  fs.mkdirSync(dir, { recursive: true });
  fs.writeFileSync(adminFile(dir), JSON.stringify({ user, salt, hash: hashPw(pw, salt), changed: new Date().toISOString() }), { mode: 0o600 });
}
/** a new login and password (about 130 bits): printed once by `helpermcp admin`, never stored in clear */
export function createAdmin(dir, keepUser = true) {
  const old = readAdmin(dir), user = keepUser && old ? old.user : 'admin-' + rnd(6).toLowerCase(), password = rnd(8) + '-' + rnd(8) + '-' + rnd(8);
  writeAdmin(dir, user, password); return { user, password };
}

const CSP = "default-src 'none'; script-src 'self'; style-src 'self'; connect-src 'self'; img-src 'self' data:; frame-ancestors 'none'; base-uri 'none'; form-action 'self'";
const IDLE_MS = 30 * 60_000, MAX_MS = 8 * 3600_000, LOCK_MS = 15 * 60_000, MAX_FAILS = 5;

export function makeAdminHandler(d) {   // d: { dir, here, sessions, makeViewer, drop, json, text, body, clientIp, baseUrl, status, report, audit, ONLINE_MS }
  const fails = new Map(), logins = new Map(); let recentFails = [];   // ip -> { n, until } ; sha(token) -> { csrf, exp, last, user }
  const sha = (x) => crypto.createHash('sha256').update(String(x)).digest('hex');
  const dummy = crypto.randomBytes(16).toString('hex');
  setInterval(() => { const now = Date.now(); for (const [k, v] of logins) if (v.exp < now || now - v.last > IDLE_MS) logins.delete(k); for (const [k, v] of fails) if (v.until < now && v.n < MAX_FAILS) fails.delete(k); recentFails = recentFails.filter((t) => now - t < 600_000); }, 60_000).unref();
  const cookieOf = (req) => (/(?:^|;\s*)hm_admin=([0-9a-f]{64})/.exec(req.headers.cookie || '') || [])[1];
  const secure = (req) => req.socket.encrypted || req.headers['x-forwarded-proto'] === 'https';
  const sessionOf = (req) => { const t = cookieOf(req); if (!t) return null; const s = logins.get(sha(t)); if (!s) return null; const now = Date.now(); if (s.exp < now || now - s.last > IDLE_MS) { logins.delete(sha(t)); return null; } s.last = now; return s; };
  const send = (res, code, obj) => { res.setHeader('cache-control', 'no-store'); return d.json(res, code, obj); };
  const asset = (res, name, type) => { try { res.writeHead(200, { 'content-type': type, 'cache-control': 'no-cache' }); res.end(fs.readFileSync(path.join(d.here, name))); } catch { d.text(res, 404, 'not found'); } };
  const page = `<!doctype html><html lang=en><meta charset=utf-8><meta name=viewport content="width=device-width,initial-scale=1"><meta name=color-scheme content=dark><meta name=robots content=noindex><title>HelperMCP admin</title><link rel=stylesheet href=/admin/assets/admin.css><div id=app></div><script src=/admin/assets/admin.js></script></html>`;

  return async function handle(req, res, url) {
    const p = url.pathname;
    if (!(p === '/admin' || p.startsWith('/admin/')) || p === '/admin/status') return false;
    res.setHeader('content-security-policy', CSP); res.setHeader('x-frame-options', 'DENY'); res.setHeader('cache-control', 'no-store');
    if (process.env.ADMIN_DISABLE === '1') { d.text(res, 404, 'not found'); return true; }
    if (p === '/admin' || p === '/admin/') { res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' }); res.end(page); return true; }
    if (p === '/admin/assets/admin.js') { asset(res, 'admin.js', 'text/javascript; charset=utf-8'); return true; }
    if (p === '/admin/assets/admin.css') { asset(res, 'admin.css', 'text/css; charset=utf-8'); return true; }
    if (!p.startsWith('/admin/api/')) { d.text(res, 404, 'not found'); return true; }
    const remote = d.clientIp(req) || '', xff = String(req.headers['x-forwarded-for'] || '').split(',').pop().trim();
    const api = p.slice(11), ip = xff && /^(::1|::ffff:)?(127\.|10\.|192\.168\.|172\.(1[6-9]|2\d|3[01])\.)|^::1$|^fc|^fd/.test(remote.replace(/^::ffff:/, '')) ? xff : remote;   // behind our own reverse proxy: the address it saw (the last entry it added)
    if (req.method === 'POST') {   // CSRF, defence in depth: a browser always sends Origin on cross-site POSTs
      const o = req.headers.origin; if (o) { let h = ''; try { h = new URL(o).host; } catch { /* bad origin */ } if (h !== req.headers.host) { send(res, 403, { error: 'bad origin' }); return true; } }
    }
    if (api === 'login' && req.method === 'POST') {
      const f = fails.get(ip), now = Date.now();
      if (f && f.n >= MAX_FAILS && now < f.until) { send(res, 429, { error: 'too many attempts, try again later' }); return true; }
      const b = JSON.parse((await d.body(req, 2000)) || '{}'), adm = readAdmin(d.dir);
      if (!adm) { send(res, 503, { error: 'no admin account yet: run `helpermcp admin` on the server' }); return true; }
      if (recentFails.length > 40) await new Promise((r) => setTimeout(r, 2000));   // under attack: slow everyone down
      const okUser = same(String(b.user || ''), adm.user), h = hashPw(String(b.pass || '').slice(0, 200), okUser ? adm.salt : dummy), ok = okUser && same(h, adm.hash);   // the same work either way
      if (!ok) {
        const n = (f && now < f.until ? f.n : 0) + 1; fails.set(ip, { n, until: now + (n >= MAX_FAILS ? LOCK_MS : 600_000) }); recentFails.push(now); d.audit('admin_login_failed', { ip });
        await new Promise((r) => setTimeout(r, 500)); send(res, 401, { error: 'wrong login or password' }); return true;
      }
      fails.delete(ip); const tok = crypto.randomBytes(32).toString('hex'), csrf = crypto.randomBytes(16).toString('hex');
      logins.set(sha(tok), { csrf, exp: now + MAX_MS, last: now, user: adm.user }); d.audit('admin_login', { ip });
      res.setHeader('set-cookie', `hm_admin=${tok}; HttpOnly; SameSite=Strict; Path=/admin; Max-Age=${MAX_MS / 1000}${secure(req) ? '; Secure' : ''}`);
      send(res, 200, { user: adm.user, csrf, secure: secure(req) }); return true;
    }
    const ses = sessionOf(req);
    if (!ses) { send(res, 401, { error: 'not logged in' }); return true; }
    if (api === 'me') { send(res, 200, { user: ses.user, csrf: ses.csrf, secure: secure(req) }); return true; }
    if (req.method === 'POST' && !same(req.headers['x-csrf'] || '', ses.csrf)) { send(res, 403, { error: 'bad csrf token' }); return true; }
    const now = Date.now();
    if (api === 'logout' && req.method === 'POST') { logins.delete(sha(cookieOf(req))); res.setHeader('set-cookie', 'hm_admin=; HttpOnly; SameSite=Strict; Path=/admin; Max-Age=0'); send(res, 200, {}); return true; }
    if (api === 'status') { send(res, 200, d.status()); return true; }
    if (api === 'sessions') {
      send(res, 200, [...d.sessions].map(([code, s]) => ({
        code, user: s.info?.user || '', host: s.info?.host || '', os: s.info?.os || '', mode: s.mode, persist: !!s.persist, online: now - s.lastSeen < d.ONLINE_MS, paused: !!s.paused, taken: !!(s.takeover && now - s.takeover < 300_000),
        last_seen_s: Math.round((now - s.lastSeen) / 1000), created: s.created, ip: s.ip, running: s.pending.size, queued: s.queue.length, note: s.note || '',
        recent: (s.log || []).slice(-6).map((l) => ({ ago_s: Math.round((now - l.t) / 1000), tool: l.tool, args: l.args })),
      })).sort((a, b) => Number(b.online) - Number(a.online) || a.last_seen_s - b.last_seen_s)); return true;
    }
    if (api === 'report') { send(res, 200, { text: d.report(Math.min(60, Math.max(1, Number(url.searchParams.get('days')) || 7))) }); return true; }
    if (req.method !== 'POST') { send(res, 404, { error: 'unknown' }); return true; }
    const b = JSON.parse((await d.body(req, 5000)) || '{}');
    if (api === 'open') {
      const code = String(b.code || '').toUpperCase(); if (!d.sessions.has(code)) { send(res, 404, { error: 'no such session' }); return true; }
      const l = d.makeViewer(code, d.baseUrl(req)); d.audit('admin_open', { code }); send(res, 200, { control: l.control, watch: l.watch }); return true;
    }
    if (api === 'look') {
      const code = String(b.code || '').toUpperCase(); if (!d.sessions.has(code)) { send(res, 404, { error: 'no such session' }); return true; }
      try { d.audit('admin_look', { code }); send(res, 200, { text: await d.look(code, b.color, b.note) }); } catch (e) { send(res, 400, { error: e.message }); } return true;
    }
    if (api === 'end') {
      const code = String(b.code || '').toUpperCase(); if (!d.sessions.has(code)) { send(res, 404, { error: 'no such session' }); return true; }
      d.drop(code, 'The session was ended by the administrator. STOP: do not retry, tell the operator.'); d.audit('admin_end', { code }); send(res, 200, {}); return true;
    }
    if (api === 'password') {
      const adm = readAdmin(d.dir), np = String(b.new || '');
      if (!adm || !same(hashPw(String(b.old || '').slice(0, 200), adm.salt), adm.hash)) { await new Promise((r) => setTimeout(r, 500)); send(res, 401, { error: 'the current password is wrong' }); return true; }
      if (np.length < 12) { send(res, 400, { error: 'the new password must be at least 12 characters' }); return true; }
      writeAdmin(d.dir, adm.user, np); logins.clear(); d.audit('admin_password_changed', {}); send(res, 200, {}); return true;   // every login is cancelled
    }
    send(res, 404, { error: 'unknown' }); return true;
  };
}
