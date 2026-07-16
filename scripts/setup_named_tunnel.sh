#!/usr/bin/env bash
# setup_named_tunnel.sh — runs AFTER `cloudflared tunnel login` authorized.
# Creates a named Cloudflare Tunnel, gets its stable URL, wires the Telegram
# webhook, and verifies end-to-end delivery.
set -u
ROOT="${BRIDGE_ROOT:-/workspaces/codespace-hermes-bridge}"
PORT="${PORT:-8080}"
cd "$ROOT" || exit 1
[ -f .env ] && { set -a; source .env; set +a; }
source .venv/bin/activate 2>/dev/null || true
export PATH="$PWD/bin:$PATH"
CF="bin/cloudflared"
log() { echo "$(date -u) named_tunnel: $*" >> /tmp/named_tunnel.log; }

TOK="${TELEGRAM_BOT_TOKEN:-}"
SECRET="${TELEGRAM_WEBHOOK_SECRET:-}"
CHAT="${TELEGRAM_ALLOWED_USERS:-5615834073}"; CHAT="${CHAT%%,*}"; CHAT="${CHAT//\"/}"

# 1. Confirm login cert exists
if [ ! -f ~/.cloudflared/cert.pem ]; then
  log "ERROR: ~/.cloudflared/cert.pem not found — run 'bin/cloudflared tunnel login' first and authorize in browser"
  exit 1
fi
log "cert.pem present — login OK"

# 2. Create named tunnel (idempotent: reuse if exists)
TNAME="hermes-bridge"
EXISTING=$($CF tunnel list 2>/dev/null | awk -v t="$TNAME" '$2==t {print $1}')
if [ -z "$EXISTING" ]; then
  TID=$($CF tunnel create "$TNAME" 2>&1 | awk -F'ID: ' '/ID: /{print $2}' | tr -d ' ')
  log "created tunnel $TNAME id=$TID"
else
  TID="$EXISTING"
  log "reusing tunnel $TNAME id=$TID"
fi

# 3. Get stable URL from tunnel info
TURL=$($CF tunnel info "$TNAME" 2>/dev/null | grep -oE 'https://[a-z0-9-]+\.cfargotunnel\.com' | head -1)
if [ -z "$TURL" ]; then
  # fallback: build from tunnel id + account — use trycloudflare? no. Use `tunnel route`? 
  # The stable ingress URL for a named tunnel is https://<tunnel-id>.cfargotunnel.com
  TURL="https://${TID}.cfargotunnel.com"
fi
log "stable tunnel URL: $TURL"

# 4. Kill old quick-tunnels / dead run_direct
for p in $(pgrep -f 'cloudflared tunnel') $(pgrep -f 'run_direct.sh'); do kill "$p" 2>/dev/null; done
sleep 2

# 5. Run the named tunnel pointing at uvicorn
nohup $CF tunnel --no-autoupdate --url "http://localhost:${PORT}" "$TNAME" >/tmp/cf_named.log 2>&1 &
log "started named tunnel pid $!"

# 6. Ensure uvicorn up
if ! pgrep -f "uvicorn app.webhook:app" >/dev/null 2>&1; then
  nohup uvicorn app.webhook:app --host 0.0.0.0 --port "$PORT" >/tmp/uvicorn.log 2>&1 &
fi

# 7. Set webhook to stable URL
for attempt in $(seq 1 10); do
  sleep 5
  RESP=$(curl -s -m 15 -X POST "https://api.telegram.org/bot${TOK}/setWebhook" \
    -d "url=${TURL}/webhook/telegram" -d "drop_pending_updates=true" \
    -d "allowed_updates=[\"message\",\"edited_message\"]" \
    --data-urlencode "secret_token=${SECRET}" 2>/dev/null)
  if echo "$RESP" | grep -q '"ok":true'; then
    # verify delivery
    curl -s -m 10 -X POST "https://api.telegram.org/bot${TOK}/sendMessage" -d "chat_id=${CHAT}" -d "text=__probe__" >/dev/null 2>&1
    sleep 12
    PENDING=$(curl -s -m 8 "https://api.telegram.org/bot${TOK}/getWebhookInfo" | python3 -c "import sys,json;print(json.load(sys.stdin)['result']['pending_update_count'])" 2>/dev/null)
    UVP=$(grep -c 'POST /webhook' /tmp/uvicorn.log 2>/dev/null || echo 0)
    if [ "${PENDING:-1}" = "0" ] && [ "${UVP:-0}" != "0" ]; then
      log "webhook SET + DELIVERED on attempt $attempt -> $RESP"
      # persist the stable URL for run_direct.sh
      grep -q '^WEBHOOK_BASE_URL=' .env && sed -i "s#^WEBHOOK_BASE_URL=.*#WEBHOOK_BASE_URL=${TURL}#" .env || echo "WEBHOOK_BASE_URL=${TURL}" >> .env
      log "persisted WEBHOOK_BASE_URL=$TURL to .env"
      break
    else
      log "attempt $attempt setWebhook ok but no delivery (pending=$PENDING uvp=$UVP)"
    fi
  else
    log "attempt $attempt setWebhook failed: $RESP"
  fi
done
log "DONE. final:"; curl -s -m 10 "https://api.telegram.org/bot${TOK}/getWebhookInfo" >> /tmp/named_tunnel.log 2>&1
