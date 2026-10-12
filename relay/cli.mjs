// Console panel for the relay. Runs inside the container (the `helpermcp` command starts it):
//   status   one screen: address, settings, state, sessions, queue
//   panel    the same, refreshed every 2 s (Ctrl+C to leave)
//   connect  the commands that connect an AI client, and the link for friends
import https from 'node:https';
import http from 'node:http';

const KEY = process.env.OPERATOR_KEY || '';
const PORT = Number(process.env.PORT || 8444);
const TLS = !!(process.env.TLS_CERT && process.env.TLS_KEY);
const PUBLIC = (process.env.PUBLIC_URL || '').replace(/\/$/, '');
const RU = /^ru/i.test(process.env.HM_LANG || process.env.LANG || '');
const t = (r, e) => (RU ? r : e);

const c = (code, s) => `\x1b[${code}m${s}\x1b[0m`;
const G = (s) => c('1;38;5;47', s), M = (s) => c('38;5;108', s), O = (s) => c('1;38;5;208', s), R = (s) => c('1;31', s), D = (s) => c('2;38;5;108', s);

function get(path) {
  return new Promise((resolve, reject) => {
    const lib = TLS ? https : http;
    const req = lib.request({ host: '127.0.0.1', port: PORT, path, method: 'GET', headers: { authorization: 'Bearer ' + KEY }, rejectUnauthorized: false, timeout: 4000 }, (res) => {
      let b = ''; res.on('data', (d) => (b += d)); res.on('end', () => { try { resolve(JSON.parse(b)); } catch { reject(new Error('bad answer')); } });
    });
    req.on('error', reject); req.on('timeout', () => req.destroy(new Error('timeout'))); req.end();
  });
}

const dur = (s) => (s >= 86400 ? `${Math.floor(s / 86400)}d ${Math.floor((s % 86400) / 3600)}h` : s >= 3600 ? `${Math.floor(s / 3600)}h ${Math.floor((s % 3600) / 60)}m` : s >= 60 ? `${Math.floor(s / 60)}m ${s % 60}s` : `${s}s`);
const pad = (s, n) => { s = String(s); return s.length >= n ? s.slice(0, n - 1) + '…' : s + ' '.repeat(n - s.length); };
const hostOf = (u) => { try { return new URL(u).hostname; } catch { return ''; } };
const isIp = (h) => /^\d+\.\d+\.\d+\.\d+$/.test(h) || h.includes(':');

function render(st) {
  const url = PUBLIC || st.public_url || `http${TLS ? 's' : ''}://localhost:${PORT}`;
  const host = hostOf(url);
  const L = [];
  L.push(G('┌ HelperMCP ' + '─'.repeat(52)));
  L.push(G('│ ') + (st ? G('● ' + t('работает', 'running')) + M(`   v${st.version}   ${t('аптайм', 'uptime')} ${dur(st.uptime_s)}`) : R('● ' + t('не отвечает', 'not answering'))));
  L.push(G('│'));
  L.push(G('│ ') + M(pad(t('адрес', 'address'), 12)) + url);
  L.push(G('│ ') + M(pad(isIp(host) ? 'ip' : t('домен', 'domain'), 12)) + host + (isIp(host) ? D('   ' + t('(нет домена: http без шифрования, лучше задать домен)', '(no domain: plain http, a domain is better)')) : ''));
  L.push(G('│ ') + M(pad(t('порт / TLS', 'port / TLS'), 12)) + `${process.env.RELAY_PORT || st.port}  ${st.tls || url.startsWith('https') ? G('TLS') : O(t('без TLS', 'no TLS'))}`);
  L.push(G('│ ') + M(pad(t('защита', 'protection'), 12)) + t('состояние и файлы шифруются, удаляются с сессией', 'state and files encrypted, deleted with the session'));
  L.push(G('│ ') + M(pad(t('приложения', 'apps'), 12)) + `android ${st.apk ? G('apk ✓') : D('—')}   ${t('набор курсоров', 'cursor pack')} ${st.cursor_pack ? G('✓') : D('—')}`);
  L.push(G('│'));
  const k = st.counts;
  L.push(G('│ ') + M(pad(t('сессии', 'sessions'), 12)) + `${G(k.online)} ${t('онлайн', 'online')} / ${k.sessions} ${t('всего', 'total')}   ${D(`${t('лимит', 'limit')} ${st.limits.max_sessions}, ${st.limits.per_ip} ${t('с одного ip', 'per ip')}`)}`);
  const run = st.sessions.reduce((a, x) => a + x.running, 0), q = st.sessions.reduce((a, x) => a + x.queued, 0);
  L.push(G('│ ') + M(pad(t('очередь', 'queue'), 12)) + `${run ? O(run) : 0} ${t('выполняется', 'running')}   ${q ? O(q) : 0} ${t('ждёт агента', 'waiting for an agent')}   ${D(`${k.files} ${t('файлов', 'files')}, ${k.viewers} ${t('ссылок просмотра', 'viewer links')}`)}`);
  L.push(G('└' + '─'.repeat(63)));
  L.push('');
  if (!st.sessions.length) L.push(M('  ' + t('Сейчас никто не подключён. Дайте другу ссылку: ', 'Nobody is connected. Give a friend the link: ')) + G(url + '/'));
  else {
    L.push(M('  ' + pad(t('код', 'code'), 11) + pad(t('статус', 'status'), 11) + pad(t('устройство', 'device'), 26) + pad(t('режим', 'mode'), 7) + pad(t('вып.', 'run'), 5) + pad(t('оч.', 'q'), 5) + t('активность', 'last seen')));
    for (const x of st.sessions) {
      const state = !x.online ? R(pad(t('офлайн', 'offline'), 11)) : x.running ? O(pad(t('работает', 'working'), 11)) : G(pad(t('ждёт', 'idle'), 11));
      L.push('  ' + G(pad(x.code, 11)) + state + pad(`${x.host || '?'} (${(x.os || '').split(/[ -]/)[0]})`, 26) + pad(x.mode, 7) + pad(x.running, 5) + pad(x.queued, 5) + D(`${x.last_seen_s}${t('с назад', 's ago')}`));
    }
  }
  return L.join('\n');
}

function connectText() {
  const url = PUBLIC || `http${TLS ? 's' : ''}://<server>:${PORT}`;
  return [
    G(t('Подключить ИИ (Claude Code), один раз:', 'Connect your AI (Claude Code), once:')),
    `  claude mcp add --transport http helper ${url}/mcp --header "Authorization: Bearer ${KEY}"`,
    '',
    G(t('Codex, один раз (Linux / macOS):', 'Codex, once (Linux / macOS):')),
    `  mkdir -p ~/.codex && printf '\\n[mcp_servers.helper]\\nurl = "${url}/mcp"\\nhttp_headers = { "Authorization" = "Bearer ${KEY}" }\\n' >> ~/.codex/config.toml`,
    G(t('Codex, один раз (Windows PowerShell):', 'Codex, once (Windows PowerShell):')),
    `  New-Item -ItemType Directory -Force "$env:USERPROFILE\\.codex" | Out-Null; Add-Content "$env:USERPROFILE\\.codex\\config.toml" "\`n[mcp_servers.helper]\`nurl = \`"${url}/mcp\`"\`nhttp_headers = { \`"Authorization\`" = \`"Bearer ${KEY}\`" }"`,
    M(t('…или просто скажите Codex: «добавь MCP-сервер helper: streamable HTTP, URL ' + url + '/mcp, заголовок Authorization: Bearer <ключ>»', '…or just tell Codex: "add the MCP server helper: streamable HTTP, URL ' + url + '/mcp, header Authorization: Bearer <key>"')),
    '',
    G(t('Любой другой клиент MCP (streamable HTTP):', 'Any other MCP client (streamable HTTP):')),
    `  URL:    ${url}/mcp`,
    `  Header: Authorization: Bearer ${KEY}`,
    '',
    G(t('Ссылка для друга (на ней команда запуска для Windows, Linux и Android):', 'Link for a friend (it has the start command for Windows, Linux and Android):')),
    `  ${url}/`,
    '',
    M(t('Ключ оператора даёт полный доступ ко всем подключённым устройствам. Не публикуйте его.', 'The operator key gives full access to every connected device. Keep it secret.')),
    '',
    G(t('Проще всего: скопируйте текст ниже и отправьте своей нейросети (Codex, Claude Code, Cursor…), она подключится сама:', 'Easiest: copy the text below and send it to your AI (Codex, Claude Code, Cursor…), it connects itself:')),
    '',
    t(`Подключи себе MCP-сервер удалённой помощи HelperMCP. Тип: streamable HTTP. Имя: helper. URL: ${url}/mcp. Заголовок: Authorization: Bearer ${KEY}. Если ты Codex — допиши в ~/.codex/config.toml (на Windows %USERPROFILE%\\.codex\\config.toml) раздел [mcp_servers.helper] с url = "${url}/mcp" и http_headers = { "Authorization" = "Bearer ${KEY}" }. Если ты Claude Code — выполни: claude mcp add --transport http helper ${url}/mcp --header "Authorization: Bearer ${KEY}". Другой клиент — добавь сервер в его настройки MCP так же. Не публикуй ключ. Потом скажи мне, что нужно перезапустить сессию (если требуется), и проверь подключение инструментом list_sessions. Когда я дам код с экрана друга, работай по инструкциям сервера и сразу открой мне живой просмотр.`,
      `Connect the HelperMCP remote-help MCP server to yourself. Type: streamable HTTP. Name: helper. URL: ${url}/mcp. Header: Authorization: Bearer ${KEY}. If you are Codex, append to ~/.codex/config.toml (on Windows %USERPROFILE%\\.codex\\config.toml) a [mcp_servers.helper] table with url = "${url}/mcp" and http_headers = { "Authorization" = "Bearer ${KEY}" }. If you are Claude Code, run: claude mcp add --transport http helper ${url}/mcp --header "Authorization: Bearer ${KEY}". Any other client: add the server to its MCP settings the same way. Never publish the key. Then tell me if the session has to be restarted, and check the connection with the list_sessions tool. When I give you a code from a friend's screen, follow the server's instructions and open the live view for me right away.`),
  ].join('\n');
}

const cmd = process.argv[2] || 'status';
if (cmd === 'connect') { console.log(connectText()); process.exit(0); }
if (!KEY) { console.error(R('OPERATOR_KEY is not set')); process.exit(1); }
const draw = async (clear) => {
  try { const st = await get('/admin/status'); if (st.error) throw new Error(st.error); process.stdout.write((clear ? '\x1b[2J\x1b[H' : '') + render(st) + '\n'); }
  catch (e) { process.stdout.write((clear ? '\x1b[2J\x1b[H' : '') + R('● ' + t('сервер не отвечает: ', 'the relay is not answering: ') + e.message) + '\n'); }
};
if (cmd === 'panel') {
  process.stdout.write('\x1b[?25l'); process.on('SIGINT', () => { process.stdout.write('\x1b[?25h\n'); process.exit(0); });
  await draw(true); setInterval(() => draw(true), 2000);
} else { await draw(false); }
