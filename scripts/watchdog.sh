#!/usr/bin/env bash
# watchdog.sh — keeps the Hermes Telegram bridge alive inside a GitHub Codespace.
#
# Two jobs, looped every 60s:
#   1. KEEPALIVE: hit /health so GitHub does not idle-shut the Codespace (30-min limit).
#   2. AUTORESTART: if the webhook receiver is not responding, relaunch start.sh.
#
# No pkill/kill of arbitrary processes — only (re)launches start.sh when the
# health check fails. Safe to run as a postStartCommand.
set -u
ROOT="${BRIDGE_ROOT:-/workspaces/codespace-hermes-bridge}"
PORT="${PORT:-8080}"
LOG="/tmp/bridge_watchdog.log"
START="$ROOT/scripts/start.sh"

echo "$(date -u) watchdog started (root=$ROOT port=$PORT)" >> "$LOG"

is_up() {
  curl -s -m 5 "http://localhost:${PORT}/health" >/dev/null 2>&1
}

already_running() {
  pgrep -f "uvicorn app.webhook:app" >/dev/null 2>&1
}

while true; do
  # 1. keepalive ping
  is_up || true

  # 2. autorestart if down
  if ! is_up; then
    if already_running; then
      echo "$(date -u) health failed but uvicorn present — waiting" >> "$LOG"
    else
      echo "$(date -u) receiver down — launching start.sh" >> "$LOG"
      nohup bash "$START" >> "$LOG" 2>&1 &
    fi
  fi

  sleep 60
done
