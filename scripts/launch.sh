#!/usr/bin/env bash
# launch.sh — devcontainer postStartCommand entrypoint.
# Delegates to start_bridge.sh (uvicorn + localhost.run stable tunnel + webhook keeper).
set -u
ROOT="${BRIDGE_ROOT:-/workspaces/codespace-hermes-bridge}"
cd "$ROOT" || exit 1
echo "$(date -u) launch: delegating to start_bridge.sh" >> /tmp/bridge_launch.log
exec bash "$ROOT/scripts/start_bridge.sh"
