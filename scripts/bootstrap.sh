#!/usr/bin/env bash
# Push this folder to a new GitHub repo + open it in a Codespace.
#
# Prereq: `gh auth login` (you'll be prompted for GitHub login in the browser).
set -euo pipefail

cd "$(dirname "$0")/.."

REPO="${REPO_NAME:-codespace-hermes-bridge}"
VIS="${REPO_VISIBILITY:-public}"   # public | private

if ! command -v gh >/dev/null 2>&1; then
  echo "❌ gh CLI not installed. Install: https://cli.github.com"
  exit 1
fi

if ! gh auth status >/dev/null 2>&1; then
  echo "🔑 gh not logged in. Running: gh auth login"
  gh auth login
fi

echo "📦 Creating $VIS repo: $REPO"
gh repo create "$REPO" "--$VIS" --source=. --push --description "Hermes Telegram bridge running in GitHub Codespace"

echo ""
echo "✅ Pushed. Now open it in a Codespace:"
echo ""
echo "   gh codespace create --repo $(gh api user --jq .login)/$REPO"
echo ""
echo "Or via the web: https://github.com/$(gh api user --jq .login)/$REPO → Code → Codespaces → Create"
echo ""
echo "Then inside the Codespace:"
echo "   cp .env.example .env && nano .env   # fill in tokens"
echo "   ./scripts/start.sh"
