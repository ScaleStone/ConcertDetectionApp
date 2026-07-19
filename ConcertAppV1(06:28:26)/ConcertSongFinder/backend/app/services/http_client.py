from __future__ import annotations

import asyncio

import httpx

_client: httpx.AsyncClient | None = None
_lock = asyncio.Lock()


async def get_shared_client() -> httpx.AsyncClient:
    """Return a process-wide AsyncClient so connections are pooled and reused."""
    global _client
    if _client is None or _client.is_closed:
        async with _lock:
            if _client is None or _client.is_closed:
                _client = httpx.AsyncClient(timeout=12)
    return _client


async def close_shared_client() -> None:
    global _client
    if _client is not None and not _client.is_closed:
        await _client.aclose()
    _client = None
