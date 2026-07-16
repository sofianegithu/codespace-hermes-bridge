#!/usr/bin/env bash
# start_bridge.sh — single entrypoint run by devcontainer postStartCommand.
# Starts: uvicorn receiver + localhost.run stable tunnel + webhook keeper.
# All detached so they survive. Uses WEBHOOK_BASE_URL from .env if present.
set -u
ROOT="${BRIDGE_ROOT:-/workspaces/codespace-hermes-bridge}"
PORT="${PORT:-8080}"
cd "$ROOT" || exit 1
[ -f .env ] && { set -a; source .env; set +a; }
source .venv/bin/activate 2>/dev/null || true
export PATH="$PWD/bin:$PATH"
log() { echo "$(date -u) start_bridge: $*" >> /tmp/start_bridge.log; }

# 1. uvicorn receiver
if ! pgrep -f "uvicorn app.webhook:app" >/dev/null 2>&1; then
  log "starting uvicorn"
  nohup uvicorn app.webhook:app --host 0.0.0.0 --port "$PORT" >/tmp/uvicorn.log 2>&1 &
fi

# 2. localhost.run stable tunnel (no auth) unless WEBHOOK_BASE_URL already stable
BASE="${WEBHOOK_BASE_URL:-}"
if [[ "$BASE" != *"localhost.run"* ]] && [[ "$BASE" != *"cfargotunnel.com"* ]]; then
  if ! pgrep -f "localhost.run" >/dev/null 2>&1; then
    log "starting localhost.run tunnel"
    nohup ssh -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o ServerAliveInterval=30 -R "${PORT}:localhost:${PORT}" localhost.run >/tmp/lhr.log 2>&1 &
    sleep 12
    LHR=$(grep -oE 'https://[a-z0-9-]+\.localhost\.run' /tmp/lhr.log | head -1)
    if [ -n "$LHR" ]; then
      BASE="$LHR"
      grep -q '^WEBHOOK_BASE_URL=' .env && sed -i "s#^WEBHOOK_BASE_URL=.*#WEBHOOK_BASE_URL=${LHR}#" .env || echo "WEBHOOK_BASE_URL=${LHR}" >> .env
      log "localhost.run URL: $LHR"
    fi
  fi
fi
log "WEBHOOK_BASE_URL final: ${BASE:-NONE}"

# 3. webhook keeper (re-registers every 30s)
if ! pgrep -f "webhook_keeper.sh" >/dev/null 2>&1; then
  log "starting webhook keeper"
  nohup bash scripts/webhook_keeper.sh >/tmp/webhook_keeper.out 2>&1 &
fi
log "start_bridge done"
