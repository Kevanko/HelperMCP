#!/usr/bin/env bash
# Install, update or reconfigure the HelperMCP relay on a Linux server with one command:
#   curl -fsSL https://raw.githubusercontent.com/Kevanko/HelperMCP/master/install.sh | sudo bash
# It asks for a domain (Enter = none: the server's IP is used) and prints the command that connects your AI plus the link for friends.
# Non-interactive:  ... | sudo bash -s -- --domain help.example.com    or    --ip 1.2.3.4 --port 8444 --yes
# Afterwards: `helpermcp help` lists everything (link, connect claude|codex|..., domain, config, key, update, logs).
set -euo pipefail

REPO="${HM_REPO:-Kevanko/HelperMCP}"
BRANCH="${HM_BRANCH:-master}"
DIR="${HM_DIR:-/opt/helpermcp}"
DOMAIN=""; IPARG=""; PORT=""; YES=""; RECONF=""
while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    --ip) IPARG="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    --yes|-y) YES=1; shift ;;
    --reconfigure) RECONF=1; shift ;;
    -h|--help) sed -n '2,6p' "$0"; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 1 ;;
  esac
done
[ "$(id -u)" -eq 0 ] || [ -n "${HM_ALLOW_NONROOT:-}" ] || { echo "run as root (sudo)" >&2; exit 1; }

case "${LC_ALL:-${LANG:-}}" in ru*) RU=1 ;; *) RU="" ;; esac
say() { if [ -n "$RU" ]; then printf '%s\n' "$1"; else printf '%s\n' "$2"; fi; }
G=$'\033[1;38;5;47m'; M=$'\033[38;5;108m'; Z=$'\033[0m'
ask() {   # ask "ru" "en" default -> reads from the terminal even when the script itself comes from a pipe
  local q a; if [ -n "$RU" ]; then q="$1"; else q="$2"; fi
  if [ -n "$YES" ] || ! [ -r /dev/tty ]; then echo "$3"; return; fi
  read -r -p "$q [$3]: " a < /dev/tty || a=""; echo "${a:-$3}"
}

if [ -z "$RECONF" ]; then
  command -v docker >/dev/null || { say ">> устанавливаю Docker" ">> installing Docker"; curl -fsSL https://get.docker.com | sh; }
  docker compose version >/dev/null 2>&1 || { echo "docker compose plugin missing" >&2; exit 1; }
  say ">> загружаю $REPO@$BRANCH в $DIR" ">> fetching $REPO@$BRANCH into $DIR"
  mkdir -p "$DIR"
  if [ -n "${HM_SRC:-}" ]; then cp -a "$HM_SRC"/. "$DIR"/
  else curl -fsSL "https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz" | tar xz --strip-components=1 -C "$DIR"; fi
fi
cd "$DIR"
mkdir -p data && chmod 700 data

# ---- current settings (re-run / reconfigure keep what is not changed)
OLD_URL=""; OLD_PORT=""; EXTRA=""
if [ -f .env ]; then
  OLD_URL="$(grep '^PUBLIC_URL=' .env | cut -d= -f2- || true)"; OLD_PORT="$(grep '^RELAY_PORT=' .env | cut -d= -f2- || true)"
  KEY="$(grep '^OPERATOR_KEY=' .env | cut -d= -f2-)"
  EXTRA="$(grep -v -E '^(OPERATOR_KEY|PUBLIC_URL|RELAY_BIND|RELAY_PORT|COMPOSE_PROFILES)=' .env || true)"   # e.g. TLS_CERT / TLS_KEY of a custom setup
else KEY="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"; fi
OLD_HOST="$(printf '%s' "$OLD_URL" | sed -E 's#^https?://##; s#[:/].*$##')"
OLD_DOMAIN=""; case "$OLD_HOST" in ""|*[!0-9.]*) OLD_DOMAIN="$OLD_HOST" ;; esac; [ "${OLD_HOST#*[a-zA-Z]}" != "$OLD_HOST" ] || OLD_DOMAIN=""

# ---- ask: domain or IP (a custom setup with its own certificate files keeps its address unless you reconfigure)
CUSTOM=""; printf '%s' "$EXTRA" | grep -q '^TLS_CERT=' && [ -n "$OLD_URL" ] && [ -z "$DOMAIN$IPARG$RECONF" ] && CUSTOM=1
if [ -n "$CUSTOM" ]; then :
elif [ -z "$DOMAIN" ] && [ -z "$IPARG" ]; then
  if [ -n "$OLD_URL" ] && [ -z "$RECONF" ]; then DOMAIN="$OLD_DOMAIN"; IPARG="$([ -z "$OLD_DOMAIN" ] && echo "$OLD_HOST" || true)"
  else
    say "" ""
    say "Домен, направленный на этот сервер, даёт автоматический HTTPS (Enter = без домена, будет IP):" "A domain pointing to this server gives automatic HTTPS (Enter = none, the IP is used):"
    DOMAIN="$(ask "домен" "domain" "$OLD_DOMAIN")"
  fi
fi
[ -z "$PORT" ] && PORT="${OLD_PORT:-8444}"
if [ -n "$CUSTOM" ]; then URL="$OLD_URL"; PROFILE=""; BIND="0.0.0.0"
elif [ -n "$DOMAIN" ]; then
  URL="https://$DOMAIN"; PROFILE="caddy"; BIND="127.0.0.1"
else
  DET="$(curl -fsS --max-time 5 https://api.ipify.org 2>/dev/null || hostname -I | cut -d' ' -f1)"
  [ -z "$IPARG" ] && IPARG="$(ask "публичный IP сервера" "server public IP" "${OLD_HOST:-$DET}")"
  [ -z "$RECONF" ] || PORT="$(ask "порт" "port" "$PORT")"
  URL="http://$IPARG:$PORT"; PROFILE=""; BIND="0.0.0.0"
fi

# ---- caddy off when going back to an IP
if [ -z "$DOMAIN" ] && [ -z "$CUSTOM" ]; then COMPOSE_PROFILES=caddy docker compose rm -sf caddy >/dev/null 2>&1 || true; fi
[ -n "$DOMAIN" ] && printf '%s {\n\treverse_proxy helpermcp:8444\n}\n' "$DOMAIN" > Caddyfile

umask 077
{
  printf 'OPERATOR_KEY=%s\nPUBLIC_URL=%s\nRELAY_BIND=%s\nRELAY_PORT=%s\nCOMPOSE_PROFILES=%s\n' "$KEY" "$URL" "$BIND" "$PORT" "$PROFILE"
  [ -z "$EXTRA" ] || printf '%s\n' "$EXTRA"
} > .env

say ">> запускаю" ">> starting"
if [ -n "$RECONF" ]; then docker compose up -d; else docker compose up -d --build; fi
for _ in $(seq 1 60); do
  docker compose exec -T helpermcp wget -qO- --no-check-certificate "http://127.0.0.1:8444/health" >/dev/null 2>&1 && break
  docker compose exec -T helpermcp wget -qO- --no-check-certificate "https://127.0.0.1:8444/health" >/dev/null 2>&1 && break
  sleep 1
done

# ---- the `helpermcp` command
BIN="${HM_BIN:-/usr/local/bin/helpermcp}"
cat > "$BIN" <<CLI
#!/usr/bin/env bash
# HelperMCP console: helpermcp help
DIR="$DIR"
cd "\$DIR" || exit 1
tty=-T; [ -t 1 ] && tty=""
case "\${1:-status}" in
  status|panel|connect|link|help|-h|--help) [ "\${1:-}" = -h ] || [ "\${1:-}" = --help ] && set -- help
    exec docker compose exec \$tty -e HM_LANG="\${LC_ALL:-\${LANG:-}}" helpermcp node relay/cli.mjs "\${@:-status}" ;;
  domain) [ -n "\${2:-}" ] || { echo "usage: helpermcp domain help.example.com   (to drop the domain: helpermcp config)"; exit 1; }
    exec bash "\$DIR/install.sh" --reconfigure --yes --domain "\$2" ;;
  config) exec bash "\$DIR/install.sh" --reconfigure ;;
  update) exec bash "\$DIR/install.sh" --yes ;;
  key) sed -i "s/^OPERATOR_KEY=.*/OPERATOR_KEY=\$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \\n')/" .env && docker compose up -d && exec docker compose exec \$tty helpermcp node relay/cli.mjs connect ;;
  logs) exec docker compose logs -f --tail 100 helpermcp ;;
  restart|stop|start) exec docker compose "\$1" helpermcp ;;
  *) echo "unknown command, see: helpermcp help"; exit 1 ;;
esac
CLI
chmod 755 "$BIN"

echo
echo "${G}================ HelperMCP ================${Z}"
docker compose exec -T -e HM_LANG="${LC_ALL:-${LANG:-}}" helpermcp node relay/cli.mjs connect || true
echo
say "${M}Панель:${Z} ${G}helpermcp${Z}   ${M}все команды:${Z} ${G}helpermcp help${Z}   ${M}ссылка для друга:${Z} ${G}helpermcp link${Z}   ${M}домен:${Z} ${G}helpermcp domain help.example.com${Z}"     "${M}Panel:${Z} ${G}helpermcp${Z}   ${M}all commands:${Z} ${G}helpermcp help${Z}   ${M}friend link:${Z} ${G}helpermcp link${Z}   ${M}domain:${Z} ${G}helpermcp domain help.example.com${Z}"
echo "${G}===========================================${Z}"
