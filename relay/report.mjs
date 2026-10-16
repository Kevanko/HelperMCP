// helpermcp report [days]: what the action log (data/actions.jsonl) says: which calls fail and why, which are slow, which sequences repeat
// (candidates for one combined tool), and how the network behaved (outages, route switches). Reads the file only; nothing is changed.
import fs from 'node:fs';

export function load(file, days = 7) {
  const since = Date.now() - days * 86400_000, out = [];
  for (const f of [file + '.1', file]) {
    let txt = ''; try { txt = fs.readFileSync(f, 'utf8'); } catch { continue; }
    for (const l of txt.split('\n')) { if (!l) continue; try { const e = JSON.parse(l); if (Date.parse(e.t) >= since) out.push(e); } catch { /* a cut line */ } }
  }
  return out.sort((a, b) => Date.parse(a.t) - Date.parse(b.t));
}

const pct = (xs, q) => { if (!xs.length) return 0; const s = [...xs].sort((a, b) => a - b); return s[Math.min(s.length - 1, Math.floor(q * s.length))]; };
const sig = (m) => String(m).replace(/[A-Za-z]:\\[^\s"']+|\/[\w./-]{3,}/g, '<path>').replace(/\d+/g, '#').replace(/"[^"]{20,}"/g, '"…"').replace(/\s+/g, ' ').slice(0, 110);
const row = (...c) => c.map((x, i) => (i === 0 ? String(x).padEnd(16) : String(x).padStart(7))).join(' ');

export function report(events, { misses = [] } = {}) {
  const calls = events.filter((e) => e.tool), evs = events.filter((e) => e.kind === 'event'), L = [];
  const devs = new Set(calls.map((c) => c.dev)), sess = new Set(calls.map((c) => c.sid));
  const bad = calls.filter((c) => !c.ok);
  L.push(`${calls.length} calls, ${bad.length} failed (${calls.length ? Math.round(100 * bad.length / calls.length) : 0}%), ${sess.size} sessions, ${devs.size} devices`);

  L.push('', '== per tool', row('tool', 'calls', 'errors', 'p50 ms', 'p95 ms', 'avg chr'));
  const by = new Map(); for (const c of calls) { if (!by.has(c.tool)) by.set(c.tool, []); by.get(c.tool).push(c); }
  for (const [t, xs] of [...by].sort((a, b) => b[1].length - a[1].length)) L.push(row(t, xs.length, xs.filter((x) => !x.ok).length, pct(xs.map((x) => x.ms), 0.5), pct(xs.map((x) => x.ms), 0.95), Math.round(xs.reduce((a, x) => a + (x.n || 0), 0) / xs.length)));

  L.push('', '== failures grouped by cause (fix these first; "replay" is the call to repeat)');
  const g = new Map(); for (const c of bad) { const k = c.tool + ': ' + sig(c.err); if (!g.has(k)) g.set(k, []); g.get(k).push(c); }
  for (const [k, xs] of [...g].sort((a, b) => b[1].length - a[1].length).slice(0, 12)) {
    const ex = xs[xs.length - 1];
    L.push(`${String(xs.length).padStart(4)}x ${k}`, `       devices: ${[...new Set(xs.map((x) => x.dev))].slice(0, 3).join('; ')}`, `       replay: ${ex.tool} ${ex.a || '{}'}`, `       error:  ${String(ex.err).slice(0, 220)}`);
  }
  if (!bad.length) L.push('none');

  L.push('', '== slowest successful calls');
  for (const c of calls.filter((c) => c.ok && c.tool !== 'wait_online' && c.tool !== 'wait_job' && c.tool !== 'hold').sort((a, b) => b.ms - a.ms).slice(0, 8)) L.push(`${String(c.ms).padStart(7)} ms  ${c.tool} ${(c.a || '').slice(0, 100)}`);

  L.push('', '== repeated sequences (the same 2-4 calls in a row, 3+ times: a combined tool would save the round trips)');
  const seq = new Map(), bySid = new Map(); for (const c of calls) { if (!bySid.has(c.sid)) bySid.set(c.sid, []); bySid.get(c.sid).push(c); }
  for (const xs of bySid.values()) for (let n = 2; n <= 4; n++) for (let i = 0; i + n <= xs.length; i++) {
    const w = xs.slice(i, i + n); if (w.some((x, j) => j && Date.parse(x.t) - Date.parse(w[j - 1].t) > 120_000)) continue;
    const names = w.map((x) => x.tool); if (new Set(names).size === 1 && n > 2) continue;
    const k = names.join(' > '); seq.set(k, (seq.get(k) || 0) + 1);
  }
  const top = [...seq].filter(([k, n]) => n >= 3 && !/^(screenshot|click|type_text|press_key|scroll|wait_online|hold|move|trace)( > (screenshot|click|type_text|press_key|scroll|move|trace))*$/.test(k)).sort((a, b) => b[1] - a[1]).slice(0, 8);
  for (const [k, n] of top) L.push(`${String(n).padStart(4)}x ${k}`);
  if (!top.length) L.push('none yet');

  L.push('', '== stuck loops (the same failing call repeated)');
  const rep = new Map(); for (const c of bad) { const k = c.tool + ' ' + c.a; rep.set(k, (rep.get(k) || 0) + 1); }
  const loops = [...rep].filter(([, n]) => n >= 3).sort((a, b) => b[1] - a[1]).slice(0, 6);
  for (const [k, n] of loops) L.push(`${String(n).padStart(4)}x ${k.slice(0, 140)}`);
  if (!loops.length) L.push('none');

  L.push('', '== network and session events');
  const cnt = new Map(); for (const e of evs) cnt.set(e.type, (cnt.get(e.type) || 0) + 1);
  L.push([...cnt].sort((a, b) => b[1] - a[1]).map(([k, n]) => `${k} ${n}`).join(', ') || 'no events');
  const dj = (e) => { try { return JSON.parse(e.data) || {}; } catch { return {}; } };
  const outs = evs.filter((e) => e.type === 'outage').map(dj);
  if (outs.length) {
    const cls = new Map(); let tot = 0;
    for (const d of outs) { cls.set(d.class || '?', (cls.get(d.class || '?') || 0) + 1); tot += Number(d.duration_s) || 0; }
    const acts = new Map(); for (const d of outs) for (const x of d.actions || []) acts.set(sig(x), (acts.get(sig(x)) || 0) + 1);
    L.push(`outages: ${outs.length}, average ${Math.round(tot / outs.length)} s; by cause: ${[...cls].map(([k, n]) => `${k} ${n}`).join(', ')}`);
    if (acts.size) L.push('repairs tried: ' + [...acts].map(([k, n]) => `${k} (${n})`).join('; '));
  }
  const routes = evs.filter((e) => e.type === 'route').map((e) => String(dj(e).msg || ''));
  if (routes.length) {
    const r = new Map(); for (const x of routes) r.set(sig(x), (r.get(sig(x)) || 0) + 1);
    L.push('route switches:'); for (const [k, n] of [...r].sort((a, b) => b[1] - a[1]).slice(0, 8)) L.push(`${String(n).padStart(4)}x ${k}`);
    const noroute = routes.filter((x) => /no route reaches/.test(x)).length; if (noroute) L.push(`!! ${noroute} time(s) no route reached the relay at all: look at those devices (system {sections:["reach"]})`);
  }
  if (misses.length) { L.push('', `== missed taps / wrong screens: ${misses.length}`); const m = new Map(); for (const x of misses) m.set(x.kind, (m.get(x.kind) || 0) + 1); L.push([...m].map(([k, n]) => `${k} ${n}`).join(', ')); }
  return L.join('\n');
}

if (import.meta.url === `file://${process.argv[1].replace(/\\/g, '/')}` || process.argv[1]?.endsWith('report.mjs')) {
  const file = process.argv[2] || '/data/actions.jsonl', days = Number(process.argv[3] || 7);
  const misses = []; try { for (const l of fs.readFileSync(file.replace(/actions\.jsonl$/, 'misses.jsonl'), 'utf8').split('\n')) if (l) misses.push(JSON.parse(l)); } catch { /* none */ }
  const ev = load(file, days);
  console.log(ev.length ? `HelperMCP action log, last ${days} day(s)\n` + report(ev, { misses }) : `no entries in ${file} for the last ${days} day(s)`);
}
