from __future__ import annotations

from dataclasses import dataclass
from time import monotonic
from typing import Any


@dataclass
class CacheEntry:
    value: Any
    expires_at: float


class TTLCache:
    """A small TTL cache with bounded size.

    Expired entries are purged on writes so the cache cannot grow without
    bound on a long-running server, and the oldest entries are evicted when
    the entry cap is reached.
    """

    def __init__(self, ttl_seconds: int, max_entries: int = 512) -> None:
        self.ttl_seconds = ttl_seconds
        self.max_entries = max_entries
        self._values: dict[str, CacheEntry] = {}

    def get(self, key: str) -> Any | None:
        entry = self._values.get(key)
        if entry is None:
            return None
        if entry.expires_at < monotonic():
            self._values.pop(key, None)
            return None
        return entry.value

    def set(self, key: str, value: Any) -> None:
        self._purge_expired()
        if len(self._values) >= self.max_entries and key not in self._values:
            self._evict_oldest()
        self._values[key] = CacheEntry(value=value, expires_at=monotonic() + self.ttl_seconds)

    def _purge_expired(self) -> None:
        now = monotonic()
        expired = [key for key, entry in self._values.items() if entry.expires_at < now]
        for key in expired:
            self._values.pop(key, None)

    def _evict_oldest(self) -> None:
        if not self._values:
            return
        oldest_key = min(self._values, key=lambda key: self._values[key].expires_at)
        self._values.pop(oldest_key, None)
