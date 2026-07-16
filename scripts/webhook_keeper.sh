#!/usr/bin/env bash
# webhook_keeper.sh — keeps the Telegram webhook pointed at the stable GitHub
# Codespace public port. Telegram sometimes clears the webhook (its proxy isn't
# persistent enough for Telegram's retry model); this re-registers it within
# 30s so inbound messages are delivered in near-real-time.
set -u
ROOT="${BRIDGE_ROOT:-/workspaces/codespace-hermes-bridge}"
cd "$ROOT" || exit 1
[ -f .env ] && { set -a; source .env; set +a; }
source .venv/bin/activate 2>/dev/null || true
TOK="${TELEGRAM_BOT_TOKEN:-}"
SECRET="${TELEGRAM_WEBHOOK_SECRET:-}"
CHAT="${TELEGRAM_ALLOWED_USERS:-5615834073}"; CHAT="${CHAT%%,*}"; CHAT="${CHAT//\"/}"
# Prefer WEBHOOK_BASE_URL if set (named tunnel), else GitHub public port
BASE="${WEBHOOK_BASE_URL:-https://zany-space-computing-machine-r4p5gx7x9gj7fxg4x-8080.app.github.dev}"
WH="${BASE}/webhook/telegram"
log() { echo "$(date -u) keeper: $*" >> /tmp/webhook_keeper.log; }
log "starting keeper -> $WH"

set_webhook() {
  curl -s -m 15 -X POST "https://api.telegram.org/bot${TOK}/setWebhook" \
    -d "url=${WH}" -d "drop_pending_updates=true" \
    -d "allowed_updates=[\"message\",\"edited_message\"]" \
    --data-urlencode "secret_token=${SECRET}" 2>/dev/null
}

while true; do
  CUR=$(curl -s -m 8 "https://api.telegram.org/bot${TOK}/getWebhookInfo" 2>/dev/null \
        | python3 -c "import sys,json;print(json.load(sys.stdin).get('result',{}).get('url',''))" 2>/dev/null)
  if [ "$CUR" != "$WH" ]; then
    RESP=$(set_webhook)
    log "re-registered (was: '${CUR}'): $RESP"
  fi
  sleep 30
done
