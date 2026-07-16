#!/usr/bin/env bash
# run_direct.sh — robust bridge launcher.
#
# DECOUPLES the webhook receiver (uvicorn) from Telegram webhook registration:
#   - receiver ALWAYS stays up, even if setWebhook fails
#   - webhook registration retries until Telegram accepts AND delivers
#
# TRANSPORT (priority):
#   1. $WEBHOOK_BASE_URL (from .env) if set — stable GitHub Codespace public port
#      (or named Cloudflare tunnel). NO cloudflared spawned.
#   2. Cloudflare quick-tunnel (fallback; rotates URL on resolve failures)
#
# Self-heal: if a sent test shows Telegram can't deliver, rotate the quick-tunnel
# to a fresh hostname and re-register.
set -u
ROOT="${BRIDGE_ROOT:-/workspaces/codespace-hermes-bridge}"
PORT="${PORT:-8080}"
cd "$ROOT" || exit 1

# Load .env so WEBHOOK_BASE_URL / tokens are available
if [ -f .env ]; then
  set -a; source .env; set +a
fi

source .venv/bin/activate 2>/dev/null || true
export PATH="$PWD/bin:$PATH"
log() { echo "$(date -u) run_direct: $*" >> /tmp/bridge_run.log; }

TOK="${TELEGRAM_BOT_TOKEN:-}"
SECRET="${TELEGRAM_WEBHOOK_SECRET:-}"
CHAT="${TELEGRAM_ALLOWED_USERS:-5615834073}"
CHAT="${CHAT%%,*}"; CHAT="${CHAT//\"/}"

# ── 1. Determine base URL ─────────────────────────────────────────────────────
BASE_URL="${WEBHOOK_BASE_URL:-}"
if [ -z "$BASE_URL" ]; then
  if ! pgrep -f "cloudflared tunnel" >/dev/null 2>&1; then
    log "starting cloudflared quick-tunnel on :$PORT"
    nohup cloudflared tunnel --no-autoupdate --url "http://localhost:${PORT}" >/tmp/cloudflared.log 2>&1 &
  fi
  for i in $(seq 1 40); do
    BASE_URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' /tmp/cloudflared.log 2>/dev/null | head -1)
    [ -n "$BASE_URL" ] && break
    sleep 1
  done
  log "quick-tunnel URL: ${BASE_URL:-NONE}"
else
  log "using stable WEBHOOK_BASE_URL (no tunnel): $BASE_URL"
fi

# ── 2. Receiver always up ──────────────────────────────────────────────────────
if ! pgrep -f "uvicorn app.webhook:app" >/dev/null 2>&1; then
  log "starting uvicorn on :$PORT"
  nohup uvicorn app.webhook:app --host 0.0.0.0 --port "$PORT" >/tmp/uvicorn.log 2>&1 &
fi

# ── 3. Webhook registration retry (rotate quick-tunnel on resolve failure) ─────
if [ -z "$BASE_URL" ]; then
  log "NO base URL — receiver up but webhook cannot be set"
  exit 0
fi

WH="${BASE_URL}/webhook/telegram"
for attempt in $(seq 1 40); do
  RESP=$(curl -s -m 15 -X POST "https://api.telegram.org/bot${TOK}/setWebhook" \
    -d "url=${WH}" -d "drop_pending_updates=true" \
    -d "allowed_updates=[\"message\",\"edited_message\"]" \
    --data-urlencode "secret_token=${SECRET}" 2>/dev/null)
  if echo "$RESP" | grep -q '"ok":true'; then
    # confirm Telegram can actually deliver: send a probe, watch pending count
    curl -s -m 10 -X POST "https://api.telegram.org/bot${TOK}/sendMessage" \
      -d "chat_id=${CHAT}" -d "text=__probe__" >/dev/null 2>&1
    sleep 12
    PENDING=$(curl -s -m 8 "https://api.telegram.org/bot${TOK}/getWebhookInfo" | python3 -c "import sys,json;print(json.load(sys.stdin)['result']['pending_update_count'])" 2>/dev/null)
    UVP=$(grep -c 'POST /webhook' /tmp/uvicorn.log 2>/dev/null || echo 0)
    if [ "${PENDING:-1}" = "0" ] && [ "${UVP:-0}" != "0" ]; then
      log "attempt $attempt: webhook SET + DELIVERED (uvicorn got POST) -> $RESP"
      break
    else
      log "attempt $attempt: setWebhook ok but NO delivery (pending=$PENDING, uvicorn_posts=$UVP) — rotating tunnel"
      OLD=$(pgrep -f "cloudflared tunnel" | head -1)
      [ -n "$OLD" ] && kill "$OLD" 2>/dev/null
      sleep 2
      nohup cloudflared tunnel --no-autoupdate --url "http://localhost:${PORT}" >/tmp/cloudflared.log 2>&1 &
      for i in $(seq 1 40); do
        BASE_URL=$(grep -oE 'https://[a-z0-9-]+\.trycloudflare\.com' /tmp/cloudflared.log 2>/dev/null | head -1)
        [ -n "$BASE_URL" ] && break
        sleep 1
      done
      WH="${BASE_URL}/webhook/telegram"
      log "rotated to new tunnel: $BASE_URL"
    fi
  else
    log "attempt $attempt setWebhook failed: $RESP (retry in 30s)"
    sleep 30
  fi
done
log "done. final getWebhookInfo:"; curl -s -m 10 "https://api.telegram.org/bot${TOK}/getWebhookInfo" >> /tmp/bridge_run.log 2>&1
