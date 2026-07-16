#!/usr/bin/env bash
# launch.sh — devcontainer postStartCommand entrypoint.
# Delegates to run_direct.sh (which decouples receiver from webhook registration
# and retries setWebhook until Telegram can resolve the tunnel URL).
set -u
ROOT="${BRIDGE_ROOT:-/workspaces/codespace-hermes-bridge}"
cd "$ROOT" || exit 1
echo "$(date -u) launch: delegating to run_direct.sh" >> /tmp/bridge_launch.log
exec bash "$ROOT/scripts/run_direct.sh"
