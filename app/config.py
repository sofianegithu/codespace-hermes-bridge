"""Configuration loader — reads env vars, validates, exposes constants."""
from __future__ import annotations

import os
from pathlib import Path


def _load_dotenv() -> None:
    """Minimal .env loader (no external dep). Lines: KEY=value, ignores # comments.

    Search order (first hit wins):
      1. .env in the current working directory
      2. .env next to this package (app/../.env)
    Real env vars always win over .env (use setdefault, not direct assign)."""
    candidates = [
        Path.cwd() / ".env",
        Path(__file__).resolve().parent.parent / ".env",
    ]
    for env_path in candidates:
        if not env_path.exists():
            continue
        for line in env_path.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            k, v = line.split("=", 1)
            k = k.strip()
            v = v.strip().strip('"').strip("'")
            # Don't override real env vars
            os.environ.setdefault(k, v)
        return  # first .env found wins


_load_dotenv()


def _require(key: str) -> str:
    val = os.environ.get(key, "").strip()
    if not val:
        raise RuntimeError(f"missing required env var: {key}")
    return val


def _opt(key: str, default: str = "") -> str:
    return os.environ.get(key, default).strip()


TELEGRAM_BOT_TOKEN: str = _opt("TELEGRAM_BOT_TOKEN")
TELEGRAM_WEBHOOK_SECRET: str = _opt("TELEGRAM_WEBHOOK_SECRET")

_allowed = _opt("TELEGRAM_ALLOWED_USERS")
TELEGRAM_ALLOWED_USERS: str = _allowed
TELEGRAM_ALLOWED_USERS_SET: set[str] = {x.strip() for x in _allowed.split(",") if x.strip()} if _allowed else set()

LLM_PROVIDER: str = _opt("LLM_PROVIDER", "openrouter").lower()
LLM_API_KEY: str = _opt("LLM_API_KEY")
LLM_MODEL: str = _opt("LLM_MODEL", "anthropic/claude-sonnet-4")
LLM_BASE_URL: str = _opt("LLM_BASE_URL")
LLM_MAX_TOKENS: int = int(_opt("LLM_MAX_TOKENS", "1500"))

PUBLIC_URL: str = _opt("PUBLIC_URL")  # Set by tunnel.py after Cloudflare quick tunnel comes up
PORT: int = int(_opt("PORT", "8080"))
HOST: str = _opt("HOST", "0.0.0.0")
