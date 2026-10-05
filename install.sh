#!/usr/bin/env bash
# Install or update the HelperMCP relay on a Linux server with one command:
#   curl -fsSL https://raw.githubusercontent.com/Kevanko/HelperMCP/master/install.sh | sudo bash -s -- --domain help.example.com
# Without --domain it serves plain HTTP on http://<server-ip>:8444 (fine for testing; use a domain for real use).
# Re-run it to update; the operator key in .env is kept.
set -euo pipefail

REPO="${HM_REPO:-Kevanko/HelperMCP}"
BRANCH="${HM_BRANCH:-master}"
DIR="${HM_DIR:-/opt/helpermcp}"
DOMAIN=""; PORT=8444
while [ $# -gt 0 ]; do
  case "$1" in
    --domain) DOMAIN="$2"; shift 2 ;;
    --port) PORT="$2"; shift 2 ;;
    -h|--help) sed -n '2,5p' "$0"; exit 0 ;;
    *) echo "unknown option $1" >&2; exit 1 ;;
  esac
done
[ "$(id -u)" -eq 0 ] || [ -n "${HM_ALLOW_NONROOT:-}" ] || { echo "run as root (sudo)" >&2; exit 1; }

command -v docker >/dev/null || { echo ">> installing Docker"; curl -fsSL https://get.docker.com | sh; }
docker compose version >/dev/null 2>&1 || { echo "docker compose plugin missing" >&2; exit 1; }

echo ">> fetching $REPO@$BRANCH into $DIR"
mkdir -p "$DIR"
if [ -n "${HM_SRC:-}" ]; then cp -a "$HM_SRC"/. "$DIR"/   # local source (testing)
else curl -fsSL "https://github.com/$REPO/archive/refs/heads/$BRANCH.tar.gz" | tar xz --strip-components=1 -C "$DIR"; fi
cd "$DIR"
mkdir -p data && chmod 700 data

if [ -f .env ]; then KEY="$(grep '^OPERATOR_KEY=' .env | cut -d= -f2-)"; else KEY="$(head -c 24 /dev/urandom | od -An -tx1 | tr -d ' \n')"; fi
if [ -n "$DOMAIN" ]; then
  URL="https://$DOMAIN"; PROFILE="caddy"; BIND="127.0.0.1"
  printf '%s {\n\treverse_proxy helpermcp:8444\n}\n' "$DOMAIN" > Caddyfile
else
  IP="$(curl -fsS https://api.ipify.org 2>/dev/null || hostname -I | cut -d' ' -f1)"
  URL="http://$IP:$PORT"; PROFILE=""; BIND="0.0.0.0"
fi
umask 077
cat > .env <<ENV
OPERATOR_KEY=$KEY
PUBLIC_URL=$URL
RELAY_BIND=$BIND
RELAY_PORT=$PORT
COMPOSE_PROFILES=$PROFILE
ENV

echo ">> starting"
docker compose up -d --build
for _ in $(seq 1 60); do
  curl -fsS "http://127.0.0.1:$PORT/health" >/dev/null 2>&1 && break
  # with Caddy the relay is only reachable inside the compose network
  docker compose exec -T helpermcp wget -qO- http://127.0.0.1:8444/health >/dev/null 2>&1 && break
  sleep 1
done

cat <<OUT

================ HelperMCP is running ================
Send your friend this link (it shows the one-line command):
  $URL/

Add it to your AI once (Claude Code):
  claude mcp add --transport http helper $URL/mcp --header "Authorization: Bearer $KEY"

Any other MCP client (streamable HTTP):
  URL:    $URL/mcp
  Header: Authorization: Bearer $KEY

Per-session connection (tools of the friend's PC appear as native ones, no 'session' argument):
  $URL/s/<CODE>/mcp   (same header)

Operator key is stored in $DIR/.env. Keep it secret.
=======================================================
OUT
