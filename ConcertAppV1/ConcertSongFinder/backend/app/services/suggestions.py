"""Post-suggestion generation: prompt assembly, response validation, and
operational guardrails (daily budget, circuit breaker).

Metric layering:
- CORE_PROMPT carries the timeless judging criteria (rare moments, human
  interaction, recognizable songs at their peak). Version-bump on change.
- The trend brief (services/trend_brief.py) carries this month's fashion and
  is injected at request time; both versions are stamped on every response
  so acceptance telemetry can be compared across versions.
"""
from __future__ import annotations

import json
import logging
import re
import time
import uuid
from collections import deque
from datetime import date

from fastapi import HTTPException
from pydantic import ValidationError

from app.models.suggestions import PostSuggestion, SuggestionsRequest, SuggestionsResponse
from app.services.llm_client import SuggestionLLMClient
from app.services.trend_brief import TrendBrief

logger = logging.getLogger("concert_song_finder.suggestions")

PROMPT_VERSION = "core-v1"

CORE_PROMPT = """You are an expert at judging which fan-shot concert moments perform well on TikTok.

Timeless criteria, in priority order:
1. RARITY of the moment beats everything: surprise songs, one-time guests,
   candidates marked isRareSong or isEncore, anything a viewer could not see
   at another show.
2. HUMAN moments beat pure performance: artist-fan interaction, ad-libs and
   speech between songs, visible emotional reactions, whole-crowd singalongs.
3. When it is performance footage, a RECOGNIZABLE song captured at its peak
   (chorus/drop) beats album deep cuts mid-verse.
4. The first seconds must land: prefer clips that open inside the moment.
5. Visual quality is only a tiebreaker; a shaky clip of an extraordinary
   moment beats a stable clip of an ordinary one.

Combine these with the CURRENT TREND BRIEF provided by the user; when they
conflict, rarity and human moments still win.

You will receive candidate media (keyframes plus structured metadata).
Respond with ONLY a JSON object, no markdown fences, exactly this shape:
{"suggestions": [{"candidateId": "<id from the provided list>", "rank": 1,
"reason": "<one sentence, why this will perform>", "caption": "<ready-to-post
caption in current TikTok style>", "hashtags": ["tag1", "tag2"]}]}
Rules: exactly the requested number of suggestions; candidateId MUST be one
of the provided ids; never invent ids; ranks 1..N; captions under 200
characters."""

# --- Daily budget -----------------------------------------------------------
_budget_day: date | None = None
_budget_used = 0


def _check_and_count_budget(daily_limit: int) -> None:
    global _budget_day, _budget_used
    today = date.today()
    if _budget_day != today:
        _budget_day = today
        _budget_used = 0
    if _budget_used >= daily_limit:
        logger.warning("suggestions daily budget exhausted used=%s limit=%s", _budget_used, daily_limit)
        raise HTTPException(status_code=429, detail={"code": "budget_exhausted", "message": "The daily suggestions budget has been reached. Try again tomorrow."})
    _budget_used += 1


def reset_budget_for_tests() -> None:
    global _budget_day, _budget_used
    _budget_day = None
    _budget_used = 0


# --- Circuit breaker --------------------------------------------------------
_FAILURE_WINDOW_SECONDS = 300
_FAILURE_THRESHOLD = 5
_recent_failures: deque[float] = deque()


def _breaker_check() -> None:
    now = time.monotonic()
    while _recent_failures and now - _recent_failures[0] > _FAILURE_WINDOW_SECONDS:
        _recent_failures.popleft()
    if len(_recent_failures) >= _FAILURE_THRESHOLD:
        logger.error("suggestions circuit breaker open failures=%s", len(_recent_failures))
        raise HTTPException(status_code=503, detail={"code": "suggestions_unavailable", "message": "Suggestions are temporarily unavailable."})


def _breaker_record_failure() -> None:
    _recent_failures.append(time.monotonic())


def reset_breaker_for_tests() -> None:
    _recent_failures.clear()


# --- Generation -------------------------------------------------------------
def _user_prompt(request: SuggestionsRequest, brief: TrendBrief, count: int) -> str:
    lines = [
        f"Concert: {request.concertTitle}",
        f"Venue: {request.venue or 'unknown'} | Date: {request.eventDate or 'unknown'}",
        "",
        "CURRENT TREND BRIEF:",
        brief.text,
        "",
        "Candidates (metadata; keyframes were provided above in order):",
    ]
    for candidate in request.candidates:
        parts = [
            f"- id={candidate.id}",
            f"kind={candidate.kind}",
            f"song={candidate.songTitle or 'unknown'}",
            f"artist={candidate.artist or 'unknown'}",
        ]
        if candidate.isEncore:
            parts.append("ENCORE")
        if candidate.isRareSong:
            parts.append("RARE-SONG")
        if candidate.setlistPosition is not None:
            parts.append(f"setlistPosition={candidate.setlistPosition}")
        if candidate.durationSeconds is not None:
            parts.append(f"duration={candidate.durationSeconds:.0f}s")
        if candidate.contextNotes:
            parts.append(f"notes={candidate.contextNotes}")
        lines.append(" ".join(parts))
    lines.append("")
    lines.append(f"Pick the top {count} and respond with the JSON object only.")
    return "\n".join(lines)


def _parse_and_validate(raw: str, request: SuggestionsRequest, count: int) -> list[PostSuggestion]:
    text = raw.strip()
    # Tolerate accidental markdown fences.
    text = re.sub(r"^```(?:json)?\s*|\s*```$", "", text)
    try:
        payload = json.loads(text)
        items = payload["suggestions"]
        suggestions = [PostSuggestion(**item) for item in items]
    except (json.JSONDecodeError, KeyError, TypeError, ValidationError) as exc:
        raise SuggestionValidationError(f"unparseable response: {type(exc).__name__}")

    valid_ids = {candidate.id for candidate in request.candidates}
    seen_ids: set[str] = set()
    for suggestion in suggestions:
        if suggestion.candidateId not in valid_ids:
            raise SuggestionValidationError(f"unknown candidateId {suggestion.candidateId!r}")
        if suggestion.candidateId in seen_ids:
            raise SuggestionValidationError("duplicate candidateId")
        seen_ids.add(suggestion.candidateId)
    if len(suggestions) != count:
        raise SuggestionValidationError(f"expected {count} suggestions, got {len(suggestions)}")
    return sorted(suggestions, key=lambda item: item.rank)


class SuggestionValidationError(Exception):
    pass


async def generate_suggestions(
    request: SuggestionsRequest,
    client: SuggestionLLMClient,
    brief: TrendBrief,
    daily_limit: int,
) -> SuggestionsResponse:
    request_id = uuid.uuid4().hex[:12]
    count = min(3, len(request.candidates))
    _breaker_check()
    _check_and_count_budget(daily_limit)

    started = time.monotonic()
    user_prompt = _user_prompt(request, brief, count)

    last_error: str | None = None
    for attempt in (1, 2):
        prompt = user_prompt if attempt == 1 else (
            user_prompt
            + f"\n\nYour previous response was invalid ({last_error}). "
            + "Respond again with ONLY the JSON object, exactly as specified."
        )
        raw = await client.rank(request, CORE_PROMPT, prompt)
        try:
            suggestions = _parse_and_validate(raw, request, count)
            elapsed_ms = int((time.monotonic() - started) * 1000)
            logger.info(
                "suggestions ok request=%s prompt=%s brief=%s candidates=%s attempt=%s latency_ms=%s",
                request_id, PROMPT_VERSION, brief.version, len(request.candidates), attempt, elapsed_ms,
            )
            return SuggestionsResponse(
                suggestions=suggestions,
                promptVersion=PROMPT_VERSION,
                trendBriefVersion=brief.version,
            )
        except SuggestionValidationError as exc:
            last_error = str(exc)
            logger.warning("suggestions invalid request=%s attempt=%s error=%s", request_id, attempt, last_error)

    _breaker_record_failure()
    logger.error("suggestions failed after repair request=%s error=%s", request_id, last_error)
    raise HTTPException(status_code=502, detail={"code": "suggestions_invalid_response", "message": "The suggestions service returned an invalid response."})
