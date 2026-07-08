"""
Telegram webhook receiver + LLM relay.

POST /webhook/telegram  <- Telegram sends updates here
GET  /health            <- liveness probe
GET  /                  <- status page
"""
from __future__ import annotations

import asyncio
import hashlib
import hmac
import json
import logging
import os
import secrets
import time
from typing import Any

import httpx
from fastapi import FastAPI, HTTPException, Request
from fastapi.responses import JSONResponse

from . import config
from .llm import chat_completion

logging.basicConfig(
    level=os.environ.get("LOG_LEVEL", "INFO").upper(),
    format="%(asctime)s %(levelname)s %(name)s: %(message)s",
)
log = logging.getLogger("bridge")

app = FastAPI(title="Hermes Telegram Bridge", version="1.0.0")

# In-memory dedupe (Telegram will sometimes redeliver).
# For multi-instance deployments, swap for Redis.
_RECENT_UPDATES: dict[int, float] = {}
_DEDUPE_TTL_S = 300


def _is_duplicate(update_id: int) -> bool:
    now = time.time()
    expired = [k for k, t in _RECENT_UPDATES.items() if now - t > _DEDUPE_TTL_S]
    for k in expired:
        _RECENT_UPDATES.pop(k, None)
    if update_id in _RECENT_UPDATES:
        return True
    _RECENT_UPDATES[update_id] = now
    return False


def _verify_telegram_secret_token(request: Request) -> bool:
    """If TELEGRAM_WEBHOOK_SECRET is set, reject requests without the matching X-Telegram-Bot-Api-Secret-Token header."""
    expected = config.TELEGRAM_WEBHOOK_SECRET
    if not expected:
        return True
    got = request.headers.get("X-Telegram-Bot-Api-Secret-Token", "")
    return hmac.compare_digest(got, expected)


async def _send_telegram_message(chat_id: int, text: str, reply_to: int | None = None) -> bool:
    """Send a message via Telegram Bot API. Splits long messages at 4000 chars."""
    url = f"https://api.telegram.org/bot{config.TELEGRAM_BOT_TOKEN}/sendMessage"
    chunks = [text[i:i + 4000] for i in range(0, len(text), 4000)] or [""]
    async with httpx.AsyncClient(timeout=20) as client:
        for chunk in chunks:
            payload: dict[str, Any] = {
                "chat_id": chat_id,
                "text": chunk,
                "disable_web_page_preview": True,
            }
            if reply_to is not None and chunk == chunks[0]:
                payload["reply_to_message_id"] = reply_to
            try:
                r = await client.post(url, json=payload)
                if r.status_code != 200:
                    log.warning("telegram send failed: %s %s", r.status_code, r.text[:200])
                    return False
            except Exception as e:
                log.exception("telegram send error: %s", e)
                return False
    return True


def _is_authorized(user_id: int | None) -> bool:
    if not config.TELEGRAM_ALLOWED_USERS:
        return True  # no allowlist configured → allow all
    if user_id is None:
        return False
    return str(user_id) in config.TELEGRAM_ALLOWED_USERS_SET


@app.get("/")
async def root() -> dict[str, Any]:
    return {
        "service": "hermes-telegram-bridge",
        "status": "ok",
        "llm": {"provider": config.LLM_PROVIDER, "model": config.LLM_MODEL},
        "telegram": {
            "token_set": bool(config.TELEGRAM_BOT_TOKEN),
            "allowlist": sorted(config.TELEGRAM_ALLOWED_USERS_SET) if config.TELEGRAM_ALLOWED_USERS_SET else None,
        },
        "tunnel_url": config.PUBLIC_URL,
    }


@app.get("/health")
async def health() -> dict[str, str]:
    return {"status": "ok"}


@app.post("/webhook/telegram")
async def telegram_webhook(request: Request) -> JSONResponse:
    if not _verify_telegram_secret_token(request):
        raise HTTPException(status_code=403, detail="invalid secret token")

    try:
        update = await request.json()
    except Exception:
        raise HTTPException(status_code=400, detail="invalid json")

    update_id = update.get("update_id", 0)
    if _is_duplicate(update_id):
        return JSONResponse({"ok": True, "deduped": True})

    message = update.get("message") or update.get("edited_message")
    if not message:
        # Callback queries, inline queries, etc. — ignore for now
        return JSONResponse({"ok": True, "ignored": "non-message update"})

    user = message.get("from") or {}
    user_id = user.get("id")
    chat = message.get("chat") or {}
    chat_id = chat.get("id")
    text = (message.get("text") or "").strip()
    message_id = message.get("message_id")

    if not _is_authorized(user_id):
        log.warning("unauthorized user %s tried to chat", user_id)
        await _send_telegram_message(
            chat_id, "⛔ Not authorized. Ask the bot owner to add your user_id to TELEGRAM_ALLOWED_USERS."
        )
        return JSONResponse({"ok": True, "rejected": True})

    if not text:
        return JSONResponse({"ok": True, "ignored": "empty text"})

    # Slash commands
    if text.startswith("/"):
        cmd = text.split()[0].split("@")[0].lower()
        if cmd == "/ping":
            await _send_telegram_message(chat_id, "🏓 pong", reply_to=message_id)
            return JSONResponse({"ok": True, "command": "ping"})
        if cmd in ("/start", "/help"):
            await _send_telegram_message(
                chat_id,
                "🤖 *Hermes Bridge*\n\n"
                "Send any message and I'll forward it to your LLM and reply.\n\n"
                f"Model: `{config.LLM_MODEL}`\n"
                f"Provider: `{config.LLM_PROVIDER}`\n\n"
                "Commands:\n"
                "/ping — liveness check\n"
                "/status — show config (no secrets)\n"
                "/reset — clear conversation history\n"
                "/help — this message",
                reply_to=message_id,
            )
            return JSONResponse({"ok": True, "command": "help"})
        if cmd == "/status":
            await _send_telegram_message(
                chat_id,
                f"✅ *Bridge online*\n\n"
                f"Model: `{config.LLM_MODEL}`\n"
                f"Provider: `{config.LLM_PROVIDER}`\n"
                f"Tunnel: `{config.PUBLIC_URL or '(not set)'}`\n"
                f"Allowlist: {len(config.TELEGRAM_ALLOWED_USERS_SET)} user(s)",
                reply_to=message_id,
            )
            return JSONResponse({"ok": True, "command": "status"})

    log.info("msg from %s: %s", user_id, text[:100])

    # Forward to LLM
    try:
        reply = await asyncio.wait_for(
            chat_completion(text, user_id=str(user_id) if user_id else None),
            timeout=120,
        )
    except asyncio.TimeoutError:
        await _send_telegram_message(chat_id, "⏱ LLM took too long, try again.", reply_to=message_id)
        return JSONResponse({"ok": True, "timeout": True})
    except Exception as e:
        log.exception("llm error")
        await _send_telegram_message(chat_id, f"❌ LLM error: `{type(e).__name__}: {e}`", reply_to=message_id)
        return JSONResponse({"ok": True, "error": str(e)}, status_code=200)

    await _send_telegram_message(chat_id, reply, reply_to=message_id)
    return JSONResponse({"ok": True})
