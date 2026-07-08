#!/usr/bin/env bash
# One-command bring-up:
#   1. validate config
#   2. install deps if missing
#   3. launch cloudflared tunnel
#   4. start the FastAPI webhook receiver
#   5. register the webhook with Telegram
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT="$(pwd)"

# ── 1. .env check ────────────────────────────────────────────────────────────
if [[ ! -f .env ]]; then
  echo "❌ No .env found. Copy .env.example to .env and fill in TELEGRAM_BOT_TOKEN + LLM_API_KEY."
  exit 1
fi

# shellcheck disable=SC1091
set -a; source .env; set +a

if [[ -z "${TELEGRAM_BOT_TOKEN:-}" ]]; then
  echo "❌ TELEGRAM_BOT_TOKEN is empty in .env"
  exit 1
fi
if [[ -z "${LLM_API_KEY:-}" && "${LLM_PROVIDER:-}" != "local" ]]; then
  echo "❌ LLM_API_KEY is empty in .env (and LLM_PROVIDER is not 'local')"
  exit 1
fi

# ── 2. install deps ───────────────────────────────────────────────────────────
if [[ ! -d .venv ]]; then
  echo "📦 Creating venv + installing requirements…"
  python3 -m venv .venv
  # shellcheck disable=SC1091
  source .venv/bin/activate
  pip install --quiet --upgrade pip
  pip install --quiet -r requirements.txt
fi
# shellcheck disable=SC1091
source .venv/bin/activate

# ── 3. cloudflared ────────────────────────────────────────────────────────────
if ! command -v cloudflared >/dev/null 2>&1; then
  echo "📦 Installing cloudflared…"
  ARCH=$(uname -m)
  case "$ARCH" in
    x86_64) CFEARCH=amd64 ;;
    aarch64) CFEARCH=arm64 ;;
    *) echo "❌ Unsupported arch: $ARCH"; exit 1 ;;
  esac
  curl -fsSL "https://github.com/cloudflare/cloudflared/releases/latest/download/cloudflared-linux-${CFEARCH}.deb" -o /tmp/cf.deb
  sudo dpkg -i /tmp/cf.deb || apt-get install -f -y
fi

# ── 4. start tunnel in background ────────────────────────────────────────────
echo "🌐 Starting Cloudflare quick-tunnel on port ${PORT:-8080}…"
python -m app.tunnel > /tmp/tunnel.url 2> /tmp/tunnel.err &
TUNNEL_PID=$!
trap "echo '🛑 stopping…'; kill $TUNNEL_PID 2>/dev/null || true" EXIT INT TERM

# Wait for the URL
for i in {1..40}; do
  URL=$(cat /tmp/tunnel.url 2>/dev/null || true)
  if [[ "$URL" =~ ^https:// ]]; then
    break
  fi
  sleep 1
done

if [[ ! "$URL" =~ ^https:// ]]; then
  echo "❌ Tunnel did not produce a URL. Last stderr:"
  cat /tmp/tunnel.err || true
  exit 1
fi
export PUBLIC_URL="$URL"
echo "✅ Tunnel URL: $PUBLIC_URL"

# ── 5. register webhook ──────────────────────────────────────────────────────
echo "🔗 Registering Telegram webhook → $PUBLIC_URL/webhook/telegram"
python scripts/register-webhook.py "$PUBLIC_URL/webhook/telegram" "${TELEGRAM_WEBHOOK_SECRET:-}"

# ── 6. start FastAPI ─────────────────────────────────────────────────────────
echo "🚀 Starting webhook receiver on :${PORT:-8080}"
exec uvicorn app.webhook:app --host "${HOST:-0.0.0.0}" --port "${PORT:-8080}"
