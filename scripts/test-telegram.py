"""Send a test message via the bot to confirm TELEGRAM_BOT_TOKEN works."""
from __future__ import annotations

import os
import sys
import urllib.parse
import urllib.request


def get_me() -> None:
    token = os.environ.get("TELEGRAM_BOT_TOKEN", "").strip()
    if not token:
        print("❌ TELEGRAM_BOT_TOKEN env var is empty", file=sys.stderr)
        sys.exit(1)
    with urllib.request.urlopen(f"https://api.telegram.org/bot{token}/getMe", timeout=10) as r:
        print(r.read().decode())


def send(text: str, chat_id: str) -> None:
    token = os.environ.get("TELEGRAM_BOT_TOKEN", "").strip()
    if not token:
        print("❌ TELEGRAM_BOT_TOKEN env var is empty", file=sys.stderr)
        sys.exit(1)
    data = urllib.parse.urlencode({"chat_id": chat_id, "text": text}).encode()
    with urllib.request.urlopen(f"https://api.telegram.org/bot{token}/sendMessage", data=data, timeout=10) as r:
        print(r.read().decode())


if __name__ == "__main__":
    if len(sys.argv) >= 2 and sys.argv[1] == "me":
        get_me()
    elif len(sys.argv) >= 3 and sys.argv[1] == "send":
        send(sys.argv[2], sys.argv[3])
    else:
        print("usage:\n  test-telegram.py me              # show bot info\n  test-telegram.py send <text> <chat_id>", file=sys.stderr)
        sys.exit(1)
