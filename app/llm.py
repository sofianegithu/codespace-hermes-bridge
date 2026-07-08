"""
Unified LLM client — OpenAI-compatible chat completions.

Works with any provider that exposes an OpenAI-format /chat/completions endpoint:
  - OpenRouter    (https://openrouter.ai/api/v1)
  - Groq          (https://api.groq.com/openai/v1)
  - Mistral       (https://api.mistral.ai/v1)
  - OpenAI        (https://api.openai.com/v1)
  - Cohere        (https://api.cohere.ai/v1)
  - Google Gemini (https://generativelanguage.googleapis.com/v1beta/openai)
  - DeepSeek      (https://api.deepseek.com/v1)
  - Self-hosted OpenAI-compatible servers (LM Studio, llama.cpp, vLLM, Ollama)
"""
from __future__ import annotations

import asyncio
import logging
import os
import time
from typing import Any

import httpx

from . import config

log = logging.getLogger("llm")

# Per-user conversation history (in-memory; for production use Redis/Postgres).
_HISTORY: dict[str, list[dict[str, str]]] = {}
_HISTORY_MAX = 20  # messages per user


def _provider_base_url_and_headers() -> tuple[str, dict[str, str], str]:
    """Returns (base_url, headers, path)."""
    p = config.LLM_PROVIDER.lower()
    api_key = config.LLM_API_KEY

    if p == "openrouter":
        return (
            "https://openrouter.ai/api/v1",
            {"Authorization": f"Bearer {api_key}", "HTTP-Referer": "https://github.com/hermes-bridge", "X-Title": "Hermes Bridge"},
            "/chat/completions",
        )
    if p == "groq":
        return "https://api.groq.com/openai/v1", {"Authorization": f"Bearer {api_key}"}, "/chat/completions"
    if p == "mistral":
        return "https://api.mistral.ai/v1", {"Authorization": f"Bearer {api_key}"}, "/chat/completions"
    if p == "openai":
        return "https://api.openai.com/v1", {"Authorization": f"Bearer {api_key}"}, "/chat/completions"
    if p in ("cohere",):
        return "https://api.cohere.ai/v1", {"Authorization": f"Bearer {api_key}"}, "/chat/completions"
    if p in ("google", "gemini"):
        return (
            "https://generativelanguage.googleapis.com/v1beta/openai",
            {"Authorization": f"Bearer {api_key}"},
            "/chat/completions",
        )
    if p == "deepseek":
        return "https://api.deepseek.com/v1", {"Authorization": f"Bearer {api_key}"}, "/chat/completions"
    if p in ("anthropic", "claude"):
        # Anthropic uses a different shape — handle in _call_anthropic
        return "https://api.anthropic.com/v1", {"x-api-key": api_key, "anthropic-version": "2023-06-01"}, "/messages"
    if p in ("lmstudio", "llamacpp", "ollama", "local", "custom"):
        base = config.LLM_BASE_URL or "http://localhost:1234/v1"
        return base, {"Authorization": f"Bearer {api_key or 'lm-studio'}"}, "/chat/completions"

    raise ValueError(f"unknown LLM_PROVIDER: {p!r}")


async def _call_anthropic(messages: list[dict[str, str]], system: str | None) -> str:
    """Anthropic uses a slightly different message format."""
    base, headers, path = _provider_base_url_and_headers()
    # Extract system message from messages
    extracted_system = system
    converted = []
    for m in messages:
        if m["role"] == "system":
            extracted_system = m["content"]
        else:
            converted.append(m)
    payload: dict[str, Any] = {
        "model": config.LLM_MODEL,
        "max_tokens": config.LLM_MAX_TOKENS,
        "messages": converted,
    }
    if extracted_system:
        payload["system"] = extracted_system
    async with httpx.AsyncClient(timeout=120) as client:
        r = await client.post(base + path, headers=headers, json=payload)
        r.raise_for_status()
        data = r.json()
    return data["content"][0]["text"]


async def chat_completion(user_text: str, user_id: str | None = None) -> str:
    """Send a user message (with conversation history) to the LLM and return the reply text."""
    base, headers, path = _provider_base_url_and_headers()
    is_anthropic = config.LLM_PROVIDER.lower() in ("anthropic", "claude")

    # Maintain per-user history
    key = user_id or "anon"
    history = _HISTORY.setdefault(key, [])
    history.append({"role": "user", "content": user_text})
    # Trim
    if len(history) > _HISTORY_MAX:
        _HISTORY[key] = history[-_HISTORY_MAX:]
        history = _HISTORY[key]

    system_prompt = (
        "You are Hermes, a personal AI assistant reached via Telegram. "
        "Be concise, direct, and helpful. Telegram messages render Markdown — use it sparingly. "
        "Keep responses under 1500 characters unless the user explicitly asks for detail. "
        "Use plain prose, not tables (Telegram doesn't render them). "
        "If asked to do something on the host, explain you can answer questions and run read-only commands, "
        "but destructive operations require explicit user confirmation in the chat."
    )

    if is_anthropic:
        return await _call_anthropic(history, system_prompt)

    # OpenAI-compatible
    messages = [{"role": "system", "content": system_prompt}] + history
    payload = {
        "model": config.LLM_MODEL,
        "messages": messages,
        "max_tokens": config.LLM_MAX_TOKENS,
        "temperature": 0.7,
    }
    async with httpx.AsyncClient(timeout=120) as client:
        t0 = time.time()
        r = await client.post(base + path, headers=headers, json=payload)
        if r.status_code >= 400:
            log.error("LLM %s error %s: %s", config.LLM_PROVIDER, r.status_code, r.text[:500])
            r.raise_for_status()
        data = r.json()
    reply = data["choices"][0]["message"]["content"]
    history.append({"role": "assistant", "content": reply})
    if len(history) > _HISTORY_MAX:
        _HISTORY[key] = history[-_HISTORY_MAX:]
    log.info("llm ok (%dms, %d chars reply)", int((time.time() - t0) * 1000), len(reply))
    return reply


def reset_history(user_id: str | None = None) -> int:
    """Reset conversation history for one user (or all if None). Returns number of users cleared."""
    if user_id is None:
        n = len(_HISTORY)
        _HISTORY.clear()
        return n
    _HISTORY.pop(user_id, None)
    return 1
