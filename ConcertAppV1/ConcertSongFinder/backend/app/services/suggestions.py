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

from app.models.suggestions import (
    CATEGORY_CAPS,
    VIDEO_CATEGORIES,
    CandidateEvaluation,
    PostSuggestion,
    SuggestionsRequest,
    SuggestionsResponse,
)
from app.services.llm_client import SuggestionLLMClient
from app.services.trend_brief import TrendBrief

logger = logging.getLogger("concert_song_finder.suggestions")

PROMPT_VERSION = "core-v2"

CORE_PROMPT = """You are an expert at judging which fan-shot concert moments perform well on TikTok.

You sort candidate media into FOUR CATEGORIES with hard caps. A category may
be EMPTY if nothing genuinely qualifies — never force-fill.

1. bestQuality (max 2, videos only): the cleanest watchable footage.
   Criteria in priority order: the artist is clearly visible and identifiable
   (a distant jumbotron speck does NOT count); stable framing (compare the
   frames of the same clip — big differences mean shaky footage); good
   exposure for a dark venue; high audioClarity metadata (it is a measured
   proxy for clean audio — trust it, you cannot hear the clips).

2. uniqueMoment (max 3, videos only): clips that stand out FROM THE OTHER
   CANDIDATES IN THIS SET: a sea of phone flashlights, a mosh pit or circle
   opening, pyro/confetti, artist walking into the crowd, a visible
   whole-crowd singalong, anything visibly different from the rest.
   Your reason MUST name the unique element. Chaotic footage with no
   discernible subject is noise, not uniqueness — exclude it.

3. artistFeature (max 1, videos only): a guest artist joining mid-show.
   Strongly prefer candidates flagged isGuestFeature (detected from song
   recognition and setlist notes). Without a flag, only assign this category
   if the frames clearly show a second performer; otherwise leave it empty.

4. photoSlideshow (max 6, photos only): the sharpest, best-exposed photos
   where the artist or moment is clearly visible; favor visual variety
   across the picks. Rank them in slideshow order; the rank-1 caption is
   used for the whole slideshow.

Clip ranges: any video suggestion may include clipStartSeconds/clipEndSeconds
picking the strongest 8-20 second stretch WITHIN the candidate's provided
segment bounds (segmentStartSeconds..segmentEndSeconds, or 0..duration when
absent). Include one whenever the source runs longer than ~20 seconds.

Combine these criteria with the CURRENT TREND BRIEF provided by the user for
caption style and format preferences.

You will receive candidate media (keyframes plus structured metadata).
Respond with ONLY a JSON object, no markdown fences, exactly this shape:
{"suggestions": [{"candidateId": "<id from the provided list>",
"category": "bestQuality|uniqueMoment|artistFeature|photoSlideshow",
"rank": 1, "reason": "<one sentence, why this earns its category>",
"caption": "<ready-to-post caption in current TikTok style>",
"hashtags": ["tag1", "tag2"],
"clipStartSeconds": null, "clipEndSeconds": null}]}
Rules: candidateId MUST be one of the provided ids; never invent ids; a
candidate appears at most once across all categories; respect the caps;
rank is 1..N within each category; videos never go in photoSlideshow and
photos never go in video categories; at least one suggestion overall;
captions under 200 characters."""

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
def _user_prompt(request: SuggestionsRequest, brief: TrendBrief) -> str:
    lines = [
        f"Concert: {request.concertTitle}",
        f"Venue: {request.venue or 'unknown'} | Date: {request.eventDate or 'unknown'}",
        f"Headliner: {request.headlinerArtist or 'unknown'}",
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
        if candidate.isGuestFeature:
            parts.append(f"GUEST-FEATURE({candidate.featuredArtist or 'unknown guest'})")
        if candidate.audioClarity is not None:
            parts.append(f"audioClarity={candidate.audioClarity:.2f}")
        if candidate.setlistPosition is not None:
            parts.append(f"setlistPosition={candidate.setlistPosition}")
        if candidate.durationSeconds is not None:
            parts.append(f"duration={candidate.durationSeconds:.0f}s")
        if candidate.segmentStartSeconds is not None and candidate.segmentEndSeconds is not None:
            parts.append(f"segmentBounds={candidate.segmentStartSeconds:.0f}s-{candidate.segmentEndSeconds:.0f}s")
        if candidate.videoDurationSeconds is not None:
            parts.append(f"videoDuration={candidate.videoDurationSeconds:.0f}s")
        if candidate.contextNotes:
            parts.append(f"notes={candidate.contextNotes}")
        lines.append(" ".join(parts))
    lines.append("")
    lines.append("Categorize per the rules and respond with the JSON object only.")
    if request.debug:
        lines.append(
            'DEBUG MODE: additionally include an "evaluations" array in the same '
            "JSON object with an entry for EVERY candidate listed above (no "
            "omissions, no duplicates), each shaped as "
            '{"candidateId": "<id>", "score": <integer 0-100>, "reasoning": '
            '"<one or two sentences explaining the score against the criteria>", '
            '"category": "<the best-fitting category for this candidate, or null>"}. '
            "Scores must be consistent with your picks: suggested candidates "
            "score highest."
        )
    return "\n".join(lines)


def _validate_clip_range(suggestion: PostSuggestion, candidate) -> None:
    start, end = suggestion.clipStartSeconds, suggestion.clipEndSeconds
    if start is None and end is None:
        return
    if start is None or end is None:
        raise SuggestionValidationError(f"partial clip range on {suggestion.candidateId!r}")
    if candidate.kind != "video":
        raise SuggestionValidationError(f"clip range on non-video {suggestion.candidateId!r}")
    if end <= start:
        raise SuggestionValidationError(f"empty clip range on {suggestion.candidateId!r}")
    limit = candidate.videoDurationSeconds
    # Half-second tolerance for float rounding at the tail.
    if limit is not None and end > limit + 0.5:
        raise SuggestionValidationError(f"clip range exceeds video duration on {suggestion.candidateId!r}")


def _parse_and_validate(
    raw: str, request: SuggestionsRequest
) -> tuple[list[PostSuggestion], list[CandidateEvaluation] | None]:
    text = raw.strip()
    # Tolerate accidental markdown fences.
    text = re.sub(r"^```(?:json)?\s*|\s*```$", "", text)
    try:
        payload = json.loads(text)
        items = payload["suggestions"]
        suggestions = [PostSuggestion(**item) for item in items]
    except (json.JSONDecodeError, KeyError, TypeError, ValidationError) as exc:
        raise SuggestionValidationError(f"unparseable response: {type(exc).__name__}")

    if not suggestions:
        raise SuggestionValidationError("no suggestions returned")

    candidates_by_id = {candidate.id: candidate for candidate in request.candidates}
    seen_ids: set[str] = set()
    by_category: dict[str, list[PostSuggestion]] = {}
    for suggestion in suggestions:
        candidate = candidates_by_id.get(suggestion.candidateId)
        if candidate is None:
            raise SuggestionValidationError(f"unknown candidateId {suggestion.candidateId!r}")
        if suggestion.candidateId in seen_ids:
            raise SuggestionValidationError("duplicate candidateId")
        seen_ids.add(suggestion.candidateId)
        if suggestion.category not in CATEGORY_CAPS:
            raise SuggestionValidationError(f"unknown category {suggestion.category!r}")
        expected_kind = "video" if suggestion.category in VIDEO_CATEGORIES else "photo"
        if candidate.kind != expected_kind:
            raise SuggestionValidationError(
                f"{candidate.kind} candidate {suggestion.candidateId!r} in {suggestion.category}"
            )
        _validate_clip_range(suggestion, candidate)
        by_category.setdefault(suggestion.category, []).append(suggestion)

    for category, entries in by_category.items():
        if len(entries) > CATEGORY_CAPS[category]:
            raise SuggestionValidationError(
                f"{category} over cap: {len(entries)} > {CATEGORY_CAPS[category]}"
            )
        if sorted(entry.rank for entry in entries) != list(range(1, len(entries) + 1)):
            raise SuggestionValidationError(f"ranks not 1..N within {category}")

    evaluations: list[CandidateEvaluation] | None = None
    if request.debug:
        try:
            evaluations = [CandidateEvaluation(**item) for item in payload["evaluations"]]
        except (KeyError, TypeError, ValidationError) as exc:
            raise SuggestionValidationError(f"missing/invalid evaluations: {type(exc).__name__}")
        evaluated_ids = [evaluation.candidateId for evaluation in evaluations]
        if len(set(evaluated_ids)) != len(evaluated_ids):
            raise SuggestionValidationError("duplicate candidateId in evaluations")
        if set(evaluated_ids) != set(candidates_by_id):
            raise SuggestionValidationError("evaluations must cover every candidate exactly once")
        evaluations.sort(key=lambda item: item.score, reverse=True)

    return sorted(suggestions, key=lambda item: (item.category, item.rank)), evaluations


class SuggestionValidationError(Exception):
    pass


async def generate_suggestions(
    request: SuggestionsRequest,
    client: SuggestionLLMClient,
    brief: TrendBrief,
    daily_limit: int,
) -> SuggestionsResponse:
    request_id = uuid.uuid4().hex[:12]
    _breaker_check()
    _check_and_count_budget(daily_limit)

    started = time.monotonic()
    user_prompt = _user_prompt(request, brief)

    last_error: str | None = None
    for attempt in (1, 2):
        prompt = user_prompt if attempt == 1 else (
            user_prompt
            + f"\n\nYour previous response was invalid ({last_error}). "
            + "Respond again with ONLY the JSON object, exactly as specified."
        )
        raw = await client.rank(request, CORE_PROMPT, prompt)
        try:
            suggestions, evaluations = _parse_and_validate(raw, request)
            elapsed_ms = int((time.monotonic() - started) * 1000)
            logger.info(
                "suggestions ok request=%s prompt=%s brief=%s candidates=%s attempt=%s latency_ms=%s debug=%s",
                request_id, PROMPT_VERSION, brief.version, len(request.candidates), attempt, elapsed_ms, request.debug,
            )
            return SuggestionsResponse(
                suggestions=suggestions,
                promptVersion=PROMPT_VERSION,
                trendBriefVersion=brief.version,
                evaluations=evaluations,
            )
        except SuggestionValidationError as exc:
            last_error = str(exc)
            logger.warning("suggestions invalid request=%s attempt=%s error=%s", request_id, attempt, last_error)

    _breaker_record_failure()
    logger.error("suggestions failed after repair request=%s error=%s", request_id, last_error)
    raise HTTPException(status_code=502, detail={"code": "suggestions_invalid_response", "message": "The suggestions service returned an invalid response."})
