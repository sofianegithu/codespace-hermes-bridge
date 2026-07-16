#!/usr/bin/env bash
# run_direct.sh — robust bridge launcher that DECOUPLES the webhook receiver
# from Telegram webhook registration.
#
# Problems this fixes (vs start.sh's trap-on-failure behaviour):
#   - Telegram returns 400/429 on setWebhook when the *.trycloudflare.com
#     hostname is intermittently unresolvable or rate-limited.
#   - start.sh's `trap ... EXIT` killed the tunnel+receiver on that failure.
#
# Here: the receiver (uvicorn) and tunnel ALWAYS stay up. Webhook registration
# is a separate retry loop that keeps trying until Telegram accepts it.
set -u
ROOT="${BRIDGE_ROOT:-/workspaces/codespace-hermes-bridge}"
PORT="${PORT:-8080}"
cd "$ROOT" || exit 1
source .venv/bin/activate 2>/dev/null || true
export PATH="$PWD/bin:$PATH"

log() { echo "$(date -u) run_direct: $*" >> /tmp/bridge_run.log; }

# ── 1. Cloudflare tunnel (always up) ────────────────────────────────────────
if ! pgrep -f "cloudflared tunnel" >/dev/null 2>&1; then
  log "starting cloudflared tunnel on :$PORT"
  nohup cloudflared tunnel --no-autoupdate --url "http://localhost:${PORT}" >/tmp/cloudflared.log 2>&1 &
fi

# wait for a URL to appear
URL=""
for i in $(seq 1 40); do
  URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' /tmp/cloudflared.log 2>/dev/null | head -1)
  [ -n "$URL" ] && break
  sleep 1
done
log "tunnel URL: ${URL:-NONE}"

# ── 2. Uvicorn receiver (always up, independent of webhook) ──────────────────
if ! pgrep -f "uvicorn app.webhook:app" >/dev/null 2>&1; then
  log "starting uvicorn on :$PORT"
  nohup uvicorn app.webhook:app --host 0.0.0.0 --port "$PORT" >/tmp/uvicorn.log 2>&1 &
fi

# ── 3. Webhook registration retry loop (separate, never kills anything) ───────
if [ -z "$URL" ]; then
  log "NO tunnel URL — receiver up but webhook cannot be set yet"
  exit 0
fi

TOK=$(grep '^TELEGRAM_BOT_TOKEN=' .env | cut -d= -f2)
SECRET=$(grep '^TELEGRAM_WEBHOOK_SECRET=' .env | cut -d= -f2)
WH="${URL}/webhook/telegram"

for attempt in $(seq 1 30); do
  RESP=$(curl -s -m 15 -X POST "https://api.telegram.org/bot${TOK}/setWebhook" \
    -d "url=${WH}" -d "drop_pending_updates=true" \
    -d "allowed_updates=[\"message\",\"edited_message\"]" \
    --data-urlencode "secret_token=${SECRET}" 2>/dev/null)
  if echo "$RESP" | grep -q '"ok":true'; then
    log "webhook SET on attempt $attempt -> $RESP"
    break
  fi
  log "webhook attempt $attempt failed: $RESP (retry in 30s)"
  sleep 30
done
log "done. final getWebhookInfo:"; curl -s -m 10 "https://api.telegram.org/bot${TOK}/getWebhookInfo" >> /tmp/bridge_run.log 2>&1
