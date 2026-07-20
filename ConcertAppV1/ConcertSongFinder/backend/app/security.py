from __future__ import annotations

import secrets

from fastapi import Depends, Header, HTTPException

from app.config import Settings, get_settings


async def require_api_key(
    x_api_key: str | None = Header(default=None),
    settings: Settings = Depends(get_settings),
) -> None:
    """Require a shared API key when one is configured.

    If BACKEND_API_KEY is unset, auth is disabled (local development).
    Comparison uses compare_digest to avoid timing attacks.
    """
    if not settings.backend_api_key:
        return
    if x_api_key is None or not secrets.compare_digest(x_api_key, settings.backend_api_key):
        raise HTTPException(
            status_code=401,
            detail={"code": "unauthorized", "message": "Missing or invalid API key."},
        )
