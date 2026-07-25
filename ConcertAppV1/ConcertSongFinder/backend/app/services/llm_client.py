"""LLM provider abstraction for post suggestions.

The Anthropic client is the production implementation; tests inject a mock
through the same interface. Frames are passed through in memory only and are
never logged or persisted (task 2.6).
"""
from __future__ import annotations

import logging
from typing import Protocol

from fastapi import HTTPException

from app.config import Settings
from app.models.suggestions import SuggestionsRequest
from app.services.http_client import get_shared_client

logger = logging.getLogger("concert_song_finder.llm")

ANTHROPIC_API_URL = "https://api.anthropic.com/v1/messages"
DEFAULT_MODEL = "claude-sonnet-4-5"
GEMINI_API_URL_TEMPLATE = "https://generativelanguage.googleapis.com/v1beta/models/{model}:generateContent"
DEFAULT_GEMINI_MODEL = "gemini-2.5-flash"
REQUEST_TIMEOUT_SECONDS = 30.0


class SuggestionLLMClient(Protocol):
    async def rank(self, request: SuggestionsRequest, system_prompt: str, user_prompt: str) -> str:
        """Returns the model's raw text response (expected to be JSON)."""
        ...


class AnthropicSuggestionClient:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings

    async def rank(self, request: SuggestionsRequest, system_prompt: str, user_prompt: str) -> str:
        if not self.settings.llm_api_key:
            raise HTTPException(
                status_code=503,
                detail={"code": "suggestions_unconfigured", "message": "The suggestions service is not configured."},
            )

        content: list[dict] = []
        for candidate in request.candidates:
            content.append({"type": "text", "text": f"Candidate {candidate.id}:"})
            for frame in candidate.frames:
                content.append({
                    "type": "image",
                    "source": {"type": "base64", "media_type": "image/jpeg", "data": frame},
                })
        content.append({"type": "text", "text": user_prompt})

        body = {
            "model": self.settings.llm_model or DEFAULT_MODEL,
            "max_tokens": 1500,
            "temperature": 0.2,
            "system": system_prompt,
            "messages": [{"role": "user", "content": content}],
        }
        headers = {
            "x-api-key": self.settings.llm_api_key,
            "anthropic-version": "2023-06-01",
            "content-type": "application/json",
        }

        client = await get_shared_client()
        try:
            response = await client.post(
                ANTHROPIC_API_URL, json=body, headers=headers, timeout=REQUEST_TIMEOUT_SECONDS
            )
        except Exception as exc:  # timeout / network
            logger.error("LLM request failed transport error=%s", type(exc).__name__)
            raise HTTPException(
                status_code=502,
                detail={"code": "suggestions_provider_error", "message": "The suggestions provider could not be reached."},
            )

        if response.status_code == 429:
            raise HTTPException(status_code=429, detail={"code": "rate_limited", "message": "Suggestions are temporarily rate limited."})
        if response.status_code >= 400:
            # Log status only; never log request bodies (they contain frames).
            logger.error("LLM provider error status=%s", response.status_code)
            raise HTTPException(status_code=502, detail={"code": "suggestions_provider_error", "message": "The suggestions provider returned an error."})

        payload = response.json()
        try:
            usage = payload.get("usage", {})
            logger.info(
                "LLM response ok input_tokens=%s output_tokens=%s",
                usage.get("input_tokens"),
                usage.get("output_tokens"),
            )
            return "".join(block.get("text", "") for block in payload.get("content", []))
        except (KeyError, AttributeError, TypeError):
            raise HTTPException(status_code=502, detail={"code": "suggestions_provider_error", "message": "The suggestions provider returned an invalid response."})


class GeminiSuggestionClient:
    """Google Gemini implementation of the same protocol. Selected
    automatically when the configured key is a Google key (see
    make_llm_client). Frames are passed in memory only and never logged."""

    def __init__(self, settings: Settings) -> None:
        self.settings = settings

    async def rank(self, request: SuggestionsRequest, system_prompt: str, user_prompt: str) -> str:
        if not self.settings.llm_api_key:
            raise HTTPException(
                status_code=503,
                detail={"code": "suggestions_unconfigured", "message": "The suggestions service is not configured."},
            )

        parts: list[dict] = []
        for candidate in request.candidates:
            parts.append({"text": f"Candidate {candidate.id}:"})
            for frame in candidate.frames:
                parts.append({"inline_data": {"mime_type": "image/jpeg", "data": frame}})
        parts.append({"text": user_prompt})

        model = self.settings.llm_model or DEFAULT_GEMINI_MODEL
        body = {
            "system_instruction": {"parts": [{"text": system_prompt}]},
            "contents": [{"role": "user", "parts": parts}],
            "generationConfig": {
                "temperature": 0.2,
                "maxOutputTokens": 2000,
                "responseMimeType": "application/json",
                # Thinking tokens count against maxOutputTokens on 2.5
                # models and can starve the actual JSON; this is a fast
                # ranking call, so disable thinking entirely.
                "thinkingConfig": {"thinkingBudget": 0},
            },
        }
        headers = {
            "x-goog-api-key": self.settings.llm_api_key,
            "content-type": "application/json",
        }

        client = await get_shared_client()
        try:
            response = await client.post(
                GEMINI_API_URL_TEMPLATE.format(model=model),
                json=body,
                headers=headers,
                timeout=REQUEST_TIMEOUT_SECONDS,
            )
        except Exception as exc:  # timeout / network
            logger.error("LLM request failed transport error=%s", type(exc).__name__)
            raise HTTPException(
                status_code=502,
                detail={"code": "suggestions_provider_error", "message": "The suggestions provider could not be reached."},
            )

        if response.status_code == 429:
            raise HTTPException(status_code=429, detail={"code": "rate_limited", "message": "Suggestions are temporarily rate limited."})
        if response.status_code >= 400:
            # Log status only; never log request bodies (they contain frames).
            logger.error("LLM provider error status=%s", response.status_code)
            raise HTTPException(status_code=502, detail={"code": "suggestions_provider_error", "message": "The suggestions provider returned an error."})

        payload = response.json()
        try:
            usage = payload.get("usageMetadata", {})
            logger.info(
                "LLM response ok input_tokens=%s output_tokens=%s",
                usage.get("promptTokenCount"),
                usage.get("candidatesTokenCount"),
            )
            candidates = payload.get("candidates", [])
            content_parts = candidates[0].get("content", {}).get("parts", []) if candidates else []
            return "".join(part.get("text", "") for part in content_parts)
        except (KeyError, AttributeError, TypeError, IndexError):
            raise HTTPException(status_code=502, detail={"code": "suggestions_provider_error", "message": "The suggestions provider returned an invalid response."})


def make_llm_client(settings: Settings) -> "SuggestionLLMClient":
    """Provider auto-detection from key format:
    - Anthropic keys start with "sk-ant-"
    - Google AI Studio keys start with "AIza"; Vertex express keys with "AQ."
    LLM_PROVIDER env/setting overrides detection when set explicitly.
    """
    provider = (settings.llm_provider or "").strip().lower()
    if not provider:
        key = settings.llm_api_key or ""
        if key.startswith(("AIza", "AQ.")):
            provider = "gemini"
        else:
            provider = "anthropic"
    if provider == "gemini":
        return GeminiSuggestionClient(settings=settings)
    return AnthropicSuggestionClient(settings=settings)
