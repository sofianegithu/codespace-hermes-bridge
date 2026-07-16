#!/usr/bin/env bash
# launch.sh — boots the bridge + watchdog inside a Codespace (idempotent).
# Safe to call from devcontainer postStartCommand on every boot.
set -u
ROOT="${BRIDGE_ROOT:-/workspaces/codespace-hermes-bridge}"
cd "$ROOT" || exit 1

# Ensure .env exists (start.sh refuses to run without it).
if [[ ! -f .env ]]; then
  if [[ -f .env.example ]]; then
    cp .env.example .env
    echo "⚠️  No .env found — copied .env.example. Edit .env with real tokens, then re-run." >> /tmp/bridge_launch.log
  fi
fi

# Start the bridge if not already up.
if ! curl -s -m 5 http://localhost:${PORT:-8080}/health >/dev/null 2>&1; then
  echo "$(date -u) launch: starting bridge" >> /tmp/bridge_launch.log
  nohup bash "$ROOT/scripts/start.sh" >> /tmp/bridge_launch.log 2>&1 &
  sleep 3
fi

# Start the watchdog if not already running.
if ! pgrep -f "watchdog.sh" >/dev/null 2>&1; then
  echo "$(date -u) launch: starting watchdog" >> /tmp/bridge_launch.log
  nohup bash "$ROOT/scripts/watchdog.sh" >> /tmp/bridge_launch.log 2>&1 &
fi

echo "$(date -u) launch: done" >> /tmp/bridge_launch.log
