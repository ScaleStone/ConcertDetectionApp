from __future__ import annotations

from pydantic import BaseModel, Field, field_validator

MAX_CANDIDATES = 12
MAX_FRAMES_PER_CANDIDATE = 3
# ~512px JPEG at quality 0.6 is ~40-80KB; base64 inflates ~4/3.
MAX_FRAME_BASE64_CHARS = 400_000


class SuggestionCandidate(BaseModel):
    id: str
    kind: str  # "video" | "photo"
    songTitle: str | None = None
    artist: str | None = None
    isEncore: bool = False
    isRareSong: bool = False
    setlistPosition: int | None = None
    durationSeconds: float | None = None
    contextNotes: str | None = None
    frames: list[str] = Field(default_factory=list)

    @field_validator("frames")
    @classmethod
    def validate_frames(cls, frames: list[str]) -> list[str]:
        if len(frames) > MAX_FRAMES_PER_CANDIDATE:
            raise ValueError(f"at most {MAX_FRAMES_PER_CANDIDATE} frames per candidate")
        for frame in frames:
            if len(frame) > MAX_FRAME_BASE64_CHARS:
                raise ValueError("frame too large")
        return frames


class SuggestionsRequest(BaseModel):
    concertTitle: str
    venue: str | None = None
    eventDate: str | None = None
    candidates: list[SuggestionCandidate]

    @field_validator("candidates")
    @classmethod
    def validate_candidates(cls, candidates: list[SuggestionCandidate]) -> list[SuggestionCandidate]:
        if not candidates:
            raise ValueError("at least one candidate is required")
        if len(candidates) > MAX_CANDIDATES:
            raise ValueError(f"at most {MAX_CANDIDATES} candidates")
        ids = [candidate.id for candidate in candidates]
        if len(set(ids)) != len(ids):
            raise ValueError("candidate ids must be unique")
        return candidates


class PostSuggestion(BaseModel):
    candidateId: str
    rank: int
    reason: str = Field(max_length=400)
    caption: str = Field(max_length=300)
    hashtags: list[str] = Field(default_factory=list, max_length=8)


class SuggestionsResponse(BaseModel):
    suggestions: list[PostSuggestion]
    promptVersion: str
    trendBriefVersion: str
