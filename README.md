# Hermes ↔ Telegram Bridge (GitHub Codespace Edition)

A minimal, self-contained Telegram webhook receiver that runs **24/7 in a free GitHub Codespace** (60 hrs/month free tier) and lets you reach your AI from anywhere — phone, tablet, any browser — without keeping your Windows PC online.

## Why this exists

- Your Windows Hermes gateway is tied to your local machine (DNS flakiness, requires login, dies when the laptop sleeps)
- GitHub Codespace = always-on Linux container with **working DNS to Telegram**
- This bridge: receives Telegram messages via webhook → forwards them to **any** LLM provider you have a key for → replies back to Telegram
- You can also `ssh codespace` from any device to drive the full Hermes CLI inside the Codespace

## Architecture

```
[Telegram user] → webhook POST → [Codespace :8080] → [LLM provider] → reply
                                              ↓
                                     (optional) ngrok tunnel
```

Webhook mode is more reliable than polling (no DNS/IP issues, no reconnection storms).

---

## 5-minute setup

### 0. One-time: have a Telegram bot

If you don't already have a bot token:
- Open Telegram → `@BotFather` → `/newbot` → copy the token

You should already have one in `~/.hermes/.env` as `TELEGRAM_BOT_TOKEN`.

### 1. Push this folder to a GitHub repo

```bash
cd codespace-hermes-bridge
# Once you've run `gh auth login`:
gh repo create codespace-hermes-bridge --public --source=. --push --description "Hermes Telegram bridge running in Codespace"
```

Or just upload the folder to github.com via the web UI.

### 2. Open in Codespace

- Go to your new repo on github.com
- Click **Code** → **Codespaces** → **Create codespace on main**
- Wait ~60 seconds for setup

### 3. Set your secrets in Codespace

In the Codespace terminal:
```bash
export TELEGRAM_BOT_TOKEN="<your token from BotFather>"
export TELEGRAM_ALLOWED_USERS="<your numeric chat_id, e.g. 5615834073>"
export LLM_PROVIDER="openrouter"           # or: google, openai, anthropic, cohere, groq, mistral
export LLM_API_KEY="<your API key>"
export LLM_MODEL="anthropic/claude-sonnet-4"  # any model your provider supports
```

To make these permanent in the Codespace, add them via Codespace Settings → Secrets, or put them in a `.env` file (the `start.sh` script auto-loads `.env`).

### 4. Start the bridge

```bash
./scripts/start.sh
```

The script will:
1. Verify `TELEGRAM_BOT_TOKEN` works
2. Find an open tunnel to the public internet (Cloudflare Tunnel — free, no signup)
3. Register the public URL as your Telegram webhook
4. Start the webhook receiver on port 8080

### 5. Test it

Open Telegram, send `/ping` to your bot. You should get `🏓 pong` back.

Then send any message — it'll be forwarded to your LLM and the reply comes back to Telegram.

---

## Files in this repo

| Path | What it does |
|------|--------------|
| `app/webhook.py` | FastAPI server: receives Telegram webhooks, calls LLM, replies |
| `app/llm.py` | Unified LLM client (OpenAI-compatible — works with OpenRouter, Groq, Mistral, OpenAI, etc.) |
| `app/tunnel.py` | Cloudflare Tunnel launcher (free, no auth needed) |
| `app/config.py` | Loads `.env`, validates, prints status |
| `scripts/start.sh` | One-command bring-up |
| `scripts/register-webhook.py` | Standalone webhook registration (rerun if tunnel URL changes) |
| `scripts/test-telegram.py` | Send a test message to verify token works |
| `Dockerfile` | (optional) containerize it |
| `.devcontainer/devcontainer.json` | (optional) one-click Codespace config |

---

## Reaching Hermes from a Codespace

The bridge can also `ssh` into your Codespace from your phone via the GitHub mobile app or the codespaces CLI:

```bash
gh codespace ssh --codespace <name>
```

Inside the Codespace, the full `hermes` CLI is available — same slash commands, same skills, same memory as your Windows install (memory persists on the Codespace volume).

To sync memory from your Windows install to the Codespace:
```bash
# from Windows
scp -r ~/.hermes/memories/* codespace:/workspaces/codespace-hermes-bridge/memory/
```

---

## Troubleshooting

### "Webhook not set"
- Run `python scripts/register-webhook.py` to see what URL was registered
- Cloudflare Tunnel URLs are stable per-Codespace — they don't change while the Codespace is running
- Codespace stops after 30 min idle → URL stays valid but instance restarts; webhook resumes automatically

### "LLM call failed"
- Check `LLM_API_KEY` is set: `echo $LLM_API_KEY | head -c 8`
- Test the key directly: `curl -H "Authorization: Bearer $LLM_API_KEY" https://openrouter.ai/api/v1/models | head`

### "I want to keep my Windows Hermes in sync"
- The Codespace bridge is independent. It can also be used as a *thin relay* to a Hermes running on your Windows PC: set `HERMES_RELAY_URL=http://your-pc:port` and the bridge will forward each message there instead of calling the LLM directly.
