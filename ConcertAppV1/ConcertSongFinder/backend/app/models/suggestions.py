from __future__ import annotations

from pydantic import BaseModel, Field, field_validator

MAX_CANDIDATES = 12
MAX_FRAMES_PER_CANDIDATE = 4
# ~512px JPEG at quality 0.6 is ~40-80KB; base64 inflates ~4/3.
MAX_FRAME_BASE64_CHARS = 400_000

# Category caps (v2 categorized suggestions).
CATEGORY_CAPS = {
    "bestQuality": 2,
    "uniqueMoment": 3,
    "artistFeature": 1,
    "photoSlideshow": 6,
}
VIDEO_CATEGORIES = {"bestQuality", "uniqueMoment", "artistFeature"}


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
    # v2 metadata
    # 0-1 proxy for clean audio (Shazam matched-duration ratio); videos only.
    audioClarity: float | None = Field(default=None, ge=0, le=1)
    # Guest/feature detection computed on-device.
    isGuestFeature: bool = False
    featuredArtist: str | None = None
    # Segment bounds in the video FILE's timeline (defaults for clip ranges).
    segmentStartSeconds: float | None = None
    segmentEndSeconds: float | None = None
    # Full video file duration, for clip-range bounds checking.
    videoDurationSeconds: float | None = None
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
    # The main act; used to detect guest features (artist != headliner).
    headlinerArtist: str | None = None
    candidates: list[SuggestionCandidate]
    # Testing/debug: when true, the response also includes a scored
    # evaluation of EVERY candidate so model behavior can be inspected.
    debug: bool = False

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
    category: str  # one of CATEGORY_CAPS keys; validated in the service
    rank: int  # rank within its category, 1..N
    reason: str = Field(max_length=400)
    caption: str = Field(max_length=300)
    hashtags: list[str] = Field(default_factory=list, max_length=8)
    # Optional AI-suggested clip range within the video file's timeline.
    # Exports stay full-length by default; the app offers a share-time
    # "suggested clip only" toggle.
    clipStartSeconds: float | None = Field(default=None, ge=0)
    clipEndSeconds: float | None = Field(default=None, ge=0)


class CandidateEvaluation(BaseModel):
    """Per-candidate score + reasoning, returned only for debug requests."""

    candidateId: str
    score: int = Field(ge=0, le=100)
    reasoning: str = Field(max_length=500)
    # Best-fitting category for this candidate (debug insight; optional).
    category: str | None = None


class CandidateEvaluation(BaseModel):
    """Per-candidate score + reasoning, returned only for debug requests."""

    candidateId: str
    score: int = Field(ge=0, le=100)
    reasoning: str = Field(max_length=500)


class SuggestionsResponse(BaseModel):
    suggestions: list[PostSuggestion]
    promptVersion: str
    trendBriefVersion: str
    # Present only when the request set debug=true.
    evaluations: list[CandidateEvaluation] | None = None
