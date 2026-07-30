from __future__ import annotations

import json

import pytest
from fastapi.testclient import TestClient

from app.config import Settings, get_settings
from app.main import app
from app.models.suggestions import SuggestionsRequest
from app.routes.suggestions import get_llm_client
from app.services import suggestions as suggestions_service


class MockLLM:
    """Scriptable mock: returns queued responses in order."""

    def __init__(self, responses: list[str]) -> None:
        self.responses = list(responses)
        self.calls: list[str] = []

    async def rank(self, request: SuggestionsRequest, system_prompt: str, user_prompt: str) -> str:
        self.calls.append(user_prompt)
        return self.responses.pop(0) if self.responses else "{}"


def suggestion(cid: str, category: str, rank: int, clip: tuple[float, float] | None = None) -> dict:
    entry = {
        "candidateId": cid,
        "category": category,
        "rank": rank,
        "reason": "clear artist shot with flashlights out",
        "caption": "the way the whole crowd lit up for this",
        "hashtags": ["concert"],
    }
    if clip:
        entry["clipStartSeconds"], entry["clipEndSeconds"] = clip
    return entry


def llm_json(entries: list[dict]) -> str:
    return json.dumps({"suggestions": entries})


def video_candidate(cid: str, **overrides) -> dict:
    body = {
        "id": cid,
        "kind": "video",
        "songTitle": f"Song {cid}",
        "artist": "Baby Keem",
        "durationSeconds": 40.0,
        "segmentStartSeconds": 5.0,
        "segmentEndSeconds": 45.0,
        "videoDurationSeconds": 60.0,
        "audioClarity": 0.8,
        "frames": [],
    }
    body.update(overrides)
    return body


def photo_candidate(cid: str, **overrides) -> dict:
    body = {"id": cid, "kind": "photo", "songTitle": f"Song {cid}", "artist": "Baby Keem", "frames": []}
    body.update(overrides)
    return body


def request_body(candidates: list[dict]) -> dict:
    return {
        "concertTitle": "Baby Keem — Moody Center",
        "venue": "Moody Center",
        "eventDate": "2026-05-13",
        "headlinerArtist": "Baby Keem",
        "candidates": candidates,
    }


def make_client(mock: MockLLM, settings: Settings | None = None) -> TestClient:
    suggestions_service.reset_budget_for_tests()
    suggestions_service.reset_breaker_for_tests()
    app.dependency_overrides[get_llm_client] = lambda: mock
    app.dependency_overrides[get_settings] = lambda: settings or Settings(backend_api_key=None, llm_api_key="test")
    return TestClient(app)


def teardown_function() -> None:
    app.dependency_overrides.clear()
    suggestions_service.reset_budget_for_tests()
    suggestions_service.reset_breaker_for_tests()


# --- Happy paths -------------------------------------------------------------

def test_categorized_suggestions_happy_path() -> None:
    candidates = [video_candidate(c) for c in ["a", "b", "c", "d"]] + [photo_candidate("p1")]
    mock = MockLLM([llm_json([
        suggestion("a", "bestQuality", 1),
        suggestion("b", "bestQuality", 2),
        suggestion("c", "uniqueMoment", 1),
        suggestion("d", "artistFeature", 1, clip=(10.0, 25.0)),
        suggestion("p1", "photoSlideshow", 1),
    ])])
    client = make_client(mock)
    response = client.post("/api/suggestions", json=request_body(candidates))
    assert response.status_code == 200
    body = response.json()
    categories = {s["candidateId"]: s["category"] for s in body["suggestions"]}
    assert categories == {
        "a": "bestQuality", "b": "bestQuality", "c": "uniqueMoment",
        "d": "artistFeature", "p1": "photoSlideshow",
    }
    feature = next(s for s in body["suggestions"] if s["category"] == "artistFeature")
    assert feature["clipStartSeconds"] == 10.0
    assert feature["clipEndSeconds"] == 25.0
    assert body["promptVersion"] == suggestions_service.PROMPT_VERSION
    # v2 metadata reaches the prompt.
    assert "Headliner: Baby Keem" in mock.calls[0]
    assert "audioClarity=0.80" in mock.calls[0]
    assert "segmentBounds=5s-45s" in mock.calls[0]


def test_empty_categories_are_allowed() -> None:
    candidates = [video_candidate("a")]
    mock = MockLLM([llm_json([suggestion("a", "uniqueMoment", 1)])])
    client = make_client(mock)
    response = client.post("/api/suggestions", json=request_body(candidates))
    assert response.status_code == 200
    assert len(response.json()["suggestions"]) == 1


def test_guest_feature_metadata_reaches_prompt() -> None:
    candidates = [
        video_candidate("a", artist="Rich Amiri", isGuestFeature=True, featuredArtist="Rich Amiri"),
        video_candidate("b"),
    ]
    mock = MockLLM([llm_json([suggestion("a", "artistFeature", 1)])])
    client = make_client(mock)
    response = client.post("/api/suggestions", json=request_body(candidates))
    assert response.status_code == 200
    assert "GUEST-FEATURE(Rich Amiri)" in mock.calls[0]


# --- Category validation ------------------------------------------------------

def test_category_over_cap_fails_closed() -> None:
    candidates = [video_candidate(c) for c in ["a", "b", "c", "d"]]
    over_cap = llm_json([
        suggestion("a", "bestQuality", 1),
        suggestion("b", "bestQuality", 2),
        suggestion("c", "bestQuality", 3),  # cap is 2
    ])
    mock = MockLLM([over_cap, over_cap])
    client = make_client(mock)
    response = client.post("/api/suggestions", json=request_body(candidates))
    assert response.status_code == 502


def test_unknown_category_fails_closed() -> None:
    candidates = [video_candidate("a")]
    bad = llm_json([suggestion("a", "mostViral", 1)])
    mock = MockLLM([bad, bad])
    client = make_client(mock)
    response = client.post("/api/suggestions", json=request_body(candidates))
    assert response.status_code == 502


def test_photo_in_video_category_fails_closed() -> None:
    candidates = [photo_candidate("p1"), video_candidate("a")]
    bad = llm_json([suggestion("p1", "bestQuality", 1)])
    mock = MockLLM([bad, bad])
    client = make_client(mock)
    response = client.post("/api/suggestions", json=request_body(candidates))
    assert response.status_code == 502


def test_video_in_slideshow_fails_closed() -> None:
    candidates = [video_candidate("a")]
    bad = llm_json([suggestion("a", "photoSlideshow", 1)])
    mock = MockLLM([bad, bad])
    client = make_client(mock)
    response = client.post("/api/suggestions", json=request_body(candidates))
    assert response.status_code == 502


def test_clip_range_beyond_video_duration_fails_closed() -> None:
    candidates = [video_candidate("a", videoDurationSeconds=30.0)]
    bad = llm_json([suggestion("a", "bestQuality", 1, clip=(10.0, 95.0))])
    mock = MockLLM([bad, bad])
    client = make_client(mock)
    response = client.post("/api/suggestions", json=request_body(candidates))
    assert response.status_code == 502


def test_inverted_clip_range_fails_closed() -> None:
    candidates = [video_candidate("a")]
    bad = llm_json([suggestion("a", "bestQuality", 1, clip=(25.0, 10.0))])
    mock = MockLLM([bad, bad])
    client = make_client(mock)
    response = client.post("/api/suggestions", json=request_body(candidates))
    assert response.status_code == 502


def test_ranks_must_be_sequential_within_category() -> None:
    candidates = [video_candidate(c) for c in ["a", "b", "c", "d"]]
    bad = llm_json([
        suggestion("a", "uniqueMoment", 1),
        suggestion("b", "uniqueMoment", 3),  # gap
    ])
    mock = MockLLM([bad, bad])
    client = make_client(mock)
    response = client.post("/api/suggestions", json=request_body(candidates))
    assert response.status_code == 502


# --- Guardrails (v1 behaviors preserved) --------------------------------------

def test_malformed_response_triggers_repair_retry_then_succeeds() -> None:
    candidates = [video_candidate(c) for c in ["a", "b", "c"]]
    mock = MockLLM(["this is not json at all", llm_json([suggestion("a", "bestQuality", 1)])])
    client = make_client(mock)
    response = client.post("/api/suggestions", json=request_body(candidates))
    assert response.status_code == 200
    assert len(mock.calls) == 2
    assert "previous response was invalid" in mock.calls[1]


def test_persistent_invalid_response_fails_closed_with_flat_contract() -> None:
    candidates = [video_candidate(c) for c in ["a", "b", "c"]]
    mock = MockLLM(["garbage", "still garbage"])
    client = make_client(mock)
    response = client.post("/api/suggestions", json=request_body(candidates))
    assert response.status_code == 502
    body = response.json()
    assert body["code"] == "suggestions_invalid_response"
    assert "detail" not in body


def test_hallucinated_candidate_id_is_rejected() -> None:
    candidates = [video_candidate(c) for c in ["a", "b"]]
    bad = llm_json([suggestion("NOT-REAL", "bestQuality", 1)])
    mock = MockLLM([bad, bad])
    client = make_client(mock)
    response = client.post("/api/suggestions", json=request_body(candidates))
    assert response.status_code == 502


def test_markdown_fenced_json_is_tolerated() -> None:
    candidates = [video_candidate("a")]
    fenced = "```json\n" + llm_json([suggestion("a", "bestQuality", 1)]) + "\n```"
    mock = MockLLM([fenced])
    client = make_client(mock)
    response = client.post("/api/suggestions", json=request_body(candidates))
    assert response.status_code == 200


def test_daily_budget_exhaustion_returns_429() -> None:
    candidates = [video_candidate("a")]
    good = llm_json([suggestion("a", "bestQuality", 1)])
    settings = Settings(backend_api_key=None, llm_api_key="test", suggestions_daily_limit=2)
    mock = MockLLM([good] * 3)
    client = make_client(mock, settings)
    assert client.post("/api/suggestions", json=request_body(candidates)).status_code == 200
    assert client.post("/api/suggestions", json=request_body(candidates)).status_code == 200
    response = client.post("/api/suggestions", json=request_body(candidates))
    assert response.status_code == 429
    assert response.json()["code"] == "budget_exhausted"


def test_circuit_breaker_opens_after_repeated_failures() -> None:
    candidates = [video_candidate("a")]
    mock = MockLLM(["bad"] * 20)
    settings = Settings(backend_api_key=None, llm_api_key="test", suggestions_daily_limit=100)
    client = make_client(mock, settings)
    for _ in range(5):
        assert client.post("/api/suggestions", json=request_body(candidates)).status_code == 502
    response = client.post("/api/suggestions", json=request_body(candidates))
    assert response.status_code == 503
    assert response.json()["code"] == "suggestions_unavailable"


def test_kill_switch_disables_feature() -> None:
    settings = Settings(backend_api_key=None, llm_api_key="test", suggestions_enabled=False)
    client = make_client(MockLLM([]), settings)
    response = client.post("/api/suggestions", json=request_body([video_candidate("a")]))
    assert response.status_code == 503
    assert response.json()["code"] == "feature_disabled"


def test_auth_required_when_key_configured() -> None:
    settings = Settings(backend_api_key="secret", llm_api_key="test")
    client = make_client(MockLLM([]), settings)
    response = client.post("/api/suggestions", json=request_body([video_candidate("a")]))
    assert response.status_code == 401


def test_request_caps_enforced() -> None:
    client = make_client(MockLLM([]))
    too_many = request_body([video_candidate(f"id{i}") for i in range(13)])
    response = client.post("/api/suggestions", json=too_many)
    assert response.status_code == 422

    oversized_frame = request_body([video_candidate("a", frames=["x" * 500_000])])
    response = client.post("/api/suggestions", json=oversized_frame)
    assert response.status_code == 422

    too_many_frames = request_body([video_candidate("a", frames=["x"] * 5)])
    response = client.post("/api/suggestions", json=too_many_frames)
    assert response.status_code == 422


def test_llm_provider_autodetection():
    from app.config import Settings
    from app.services.llm_client import AnthropicSuggestionClient, GeminiSuggestionClient, make_llm_client

    assert isinstance(make_llm_client(Settings(llm_api_key="sk-ant-abc123")), AnthropicSuggestionClient)
    assert isinstance(make_llm_client(Settings(llm_api_key="AQ.vertex-express-key")), GeminiSuggestionClient)
    assert isinstance(make_llm_client(Settings(llm_api_key="AIzaStudioKey")), GeminiSuggestionClient)
    # Explicit override beats detection.
    assert isinstance(make_llm_client(Settings(llm_api_key="AQ.key", llm_provider="anthropic")), AnthropicSuggestionClient)
    assert isinstance(make_llm_client(Settings(llm_api_key="sk-ant-key", llm_provider="gemini")), GeminiSuggestionClient)


# --- Debug mode ---------------------------------------------------------------

def debug_llm_json(entries: list[dict], all_ids: list[str]) -> str:
    payload = json.loads(llm_json(entries))
    payload["evaluations"] = [
        {"candidateId": cid, "score": 90 - i * 10, "reasoning": f"Scored {cid} against the category rubrics.", "category": "bestQuality"}
        for i, cid in enumerate(all_ids)
    ]
    return json.dumps(payload)


def test_debug_mode_returns_scored_evaluations_for_all_candidates() -> None:
    ids = ["a", "b", "c"]
    candidates = [video_candidate(c) for c in ids]
    mock = MockLLM([debug_llm_json([suggestion("a", "bestQuality", 1)], ids)])
    client = make_client(mock)
    body_in = request_body(candidates)
    body_in["debug"] = True
    response = client.post("/api/suggestions", json=body_in)
    assert response.status_code == 200
    evaluations = response.json()["evaluations"]
    assert {e["candidateId"] for e in evaluations} == set(ids)
    assert [e["score"] for e in evaluations] == sorted([e["score"] for e in evaluations], reverse=True)
    assert all(e["reasoning"] for e in evaluations)
    assert all(e["category"] for e in evaluations)
    assert "DEBUG MODE" in mock.calls[0]


def test_debug_mode_incomplete_evaluations_fails_closed() -> None:
    ids = ["a", "b", "c"]
    candidates = [video_candidate(c) for c in ids]
    bad = debug_llm_json([suggestion("a", "bestQuality", 1)], ["a", "b"])  # missing "c"
    mock = MockLLM([bad, bad])
    client = make_client(mock)
    body_in = request_body(candidates)
    body_in["debug"] = True
    response = client.post("/api/suggestions", json=body_in)
    assert response.status_code == 502


def test_non_debug_response_has_no_evaluations() -> None:
    candidates = [video_candidate("a")]
    mock = MockLLM([llm_json([suggestion("a", "bestQuality", 1)])])
    client = make_client(mock)
    response = client.post("/api/suggestions", json=request_body(candidates))
    assert response.status_code == 200
    assert response.json()["evaluations"] is None
    assert "DEBUG MODE" not in mock.calls[0]
