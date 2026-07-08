"""Register the Telegram webhook. Re-run every time the tunnel URL changes."""
from __future__ import annotations

import json
import os
import sys
import urllib.parse
import urllib.request


def register(url: str, secret: str = "") -> None:
    token = os.environ.get("TELEGRAM_BOT_TOKEN", "").strip()
    if not token:
        print("❌ TELEGRAM_BOT_TOKEN env var is empty", file=sys.stderr)
        sys.exit(1)
    if not url.startswith("https://"):
        print(f"❌ webhook URL must be https:// — got: {url}", file=sys.stderr)
        sys.exit(1)

    params: dict[str, str] = {"url": url, "drop_pending_updates": "true", "allowed_updates": json.dumps(["message", "edited_message"])}
    if secret:
        params["secret_token"] = secret
    qs = urllib.parse.urlencode(params)
    api = f"https://api.telegram.org/bot{token}/setWebhook?{qs}"
    with urllib.request.urlopen(api, timeout=20) as r:
        body = r.read().decode()
    print(f"setWebhook → {body}")
    data = json.loads(body)
    if not data.get("ok"):
        sys.exit(1)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: register-webhook.py <https_url> [secret]", file=sys.stderr)
        sys.exit(1)
    url = sys.argv[1]
    secret = sys.argv[2] if len(sys.argv) > 2 else ""
    register(url, secret)
