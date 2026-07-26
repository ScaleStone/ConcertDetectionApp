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


def valid_llm_json(ids: list[str]) -> str:
    return json.dumps({
        "suggestions": [
            {"candidateId": cid, "rank": i + 1, "reason": "rare moment", "caption": "the way he stopped the show", "hashtags": ["concert"]}
            for i, cid in enumerate(ids)
        ]
    })


def request_body(candidate_ids: list[str]) -> dict:
    return {
        "concertTitle": "Baby Keem — Moody Center",
        "venue": "Moody Center",
        "eventDate": "2026-05-13",
        "candidates": [
            {"id": cid, "kind": "video", "songTitle": f"Song {i}", "artist": "Baby Keem", "isRareSong": i == 0, "frames": []}
            for i, cid in enumerate(candidate_ids)
        ],
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


def test_happy_path_returns_three_ranked_suggestions() -> None:
    ids = ["a", "b", "c", "d"]
    mock = MockLLM([valid_llm_json(["c", "a", "b"])])
    client = make_client(mock)
    response = client.post("/api/suggestions", json=request_body(ids))
    assert response.status_code == 200
    body = response.json()
    assert [s["candidateId"] for s in body["suggestions"]] == ["c", "a", "b"]
    assert [s["rank"] for s in body["suggestions"]] == [1, 2, 3]
    assert body["promptVersion"] == suggestions_service.PROMPT_VERSION
    assert body["trendBriefVersion"]
    # Trend brief and rarity metadata made it into the prompt.
    assert "TREND BRIEF" in mock.calls[0]
    assert "RARE-SONG" in mock.calls[0]


def test_fewer_than_three_candidates_returns_that_many() -> None:
    mock = MockLLM([valid_llm_json(["only"])])
    client = make_client(mock)
    response = client.post("/api/suggestions", json=request_body(["only"]))
    assert response.status_code == 200
    assert len(response.json()["suggestions"]) == 1


def test_malformed_response_triggers_repair_retry_then_succeeds() -> None:
    ids = ["a", "b", "c"]
    mock = MockLLM(["this is not json at all", valid_llm_json(["a", "b", "c"])])
    client = make_client(mock)
    response = client.post("/api/suggestions", json=request_body(ids))
    assert response.status_code == 200
    assert len(mock.calls) == 2
    assert "previous response was invalid" in mock.calls[1]


def test_persistent_invalid_response_fails_closed_with_flat_contract() -> None:
    ids = ["a", "b", "c"]
    mock = MockLLM(["garbage", "still garbage"])
    client = make_client(mock)
    response = client.post("/api/suggestions", json=request_body(ids))
    assert response.status_code == 502
    body = response.json()
    assert body["code"] == "suggestions_invalid_response"
    assert "detail" not in body


def test_hallucinated_candidate_id_is_rejected() -> None:
    ids = ["a", "b", "c"]
    mock = MockLLM([valid_llm_json(["a", "b", "NOT-REAL"]), valid_llm_json(["a", "b", "NOT-REAL"])])
    client = make_client(mock)
    response = client.post("/api/suggestions", json=request_body(ids))
    assert response.status_code == 502


def test_markdown_fenced_json_is_tolerated() -> None:
    ids = ["a", "b", "c"]
    fenced = "```json\n" + valid_llm_json(["a", "b", "c"]) + "\n```"
    mock = MockLLM([fenced])
    client = make_client(mock)
    response = client.post("/api/suggestions", json=request_body(ids))
    assert response.status_code == 200


def test_daily_budget_exhaustion_returns_429() -> None:
    ids = ["a", "b", "c"]
    settings = Settings(backend_api_key=None, llm_api_key="test", suggestions_daily_limit=2)
    mock = MockLLM([valid_llm_json(["a", "b", "c"])] * 3)
    client = make_client(mock, settings)
    assert client.post("/api/suggestions", json=request_body(ids)).status_code == 200
    assert client.post("/api/suggestions", json=request_body(ids)).status_code == 200
    response = client.post("/api/suggestions", json=request_body(ids))
    assert response.status_code == 429
    assert response.json()["code"] == "budget_exhausted"


def test_circuit_breaker_opens_after_repeated_failures() -> None:
    ids = ["a", "b", "c"]
    # Every request fails twice (initial + repair) => one breaker failure each.
    mock = MockLLM(["bad"] * 20)
    settings = Settings(backend_api_key=None, llm_api_key="test", suggestions_daily_limit=100)
    client = make_client(mock, settings)
    for _ in range(5):
        assert client.post("/api/suggestions", json=request_body(ids)).status_code == 502
    response = client.post("/api/suggestions", json=request_body(ids))
    assert response.status_code == 503
    assert response.json()["code"] == "suggestions_unavailable"


def test_kill_switch_disables_feature() -> None:
    settings = Settings(backend_api_key=None, llm_api_key="test", suggestions_enabled=False)
    client = make_client(MockLLM([]), settings)
    response = client.post("/api/suggestions", json=request_body(["a"]))
    assert response.status_code == 503
    assert response.json()["code"] == "feature_disabled"


def test_auth_required_when_key_configured() -> None:
    settings = Settings(backend_api_key="secret", llm_api_key="test")
    client = make_client(MockLLM([]), settings)
    response = client.post("/api/suggestions", json=request_body(["a"]))
    assert response.status_code == 401


def test_request_caps_enforced() -> None:
    client = make_client(MockLLM([]))
    too_many = request_body([f"id{i}" for i in range(13)])
    response = client.post("/api/suggestions", json=too_many)
    assert response.status_code == 422

    oversized_frame = request_body(["a"])
    oversized_frame["candidates"][0]["frames"] = ["x" * 500_000]
    response = client.post("/api/suggestions", json=oversized_frame)
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


def valid_debug_llm_json(picked: list[str], all_ids: list[str]) -> str:
    payload = json.loads(valid_llm_json(picked))
    payload["evaluations"] = [
        {"candidateId": cid, "score": 90 - i * 10, "reasoning": f"Scored {cid} against rarity and human-moment criteria."}
        for i, cid in enumerate(all_ids)
    ]
    return json.dumps(payload)


def test_debug_mode_returns_scored_evaluations_for_all_candidates() -> None:
    ids = ["a", "b", "c", "d"]
    mock = MockLLM([valid_debug_llm_json(["c", "a", "b"], ids)])
    client = make_client(mock)
    body_in = request_body(ids)
    body_in["debug"] = True
    response = client.post("/api/suggestions", json=body_in)
    assert response.status_code == 200
    body = response.json()
    evaluations = body["evaluations"]
    assert {e["candidateId"] for e in evaluations} == set(ids)
    # Sorted by score descending.
    assert [e["score"] for e in evaluations] == sorted([e["score"] for e in evaluations], reverse=True)
    assert all(e["reasoning"] for e in evaluations)
    assert "DEBUG MODE" in mock.calls[0]


def test_debug_mode_incomplete_evaluations_fails_closed() -> None:
    ids = ["a", "b", "c", "d"]
    # Evaluations omit candidate "d" — invalid on both attempts.
    bad = valid_debug_llm_json(["c", "a", "b"], ["a", "b", "c"])
    mock = MockLLM([bad, bad])
    client = make_client(mock)
    body_in = request_body(ids)
    body_in["debug"] = True
    response = client.post("/api/suggestions", json=body_in)
    assert response.status_code == 502


def test_non_debug_response_has_no_evaluations() -> None:
    ids = ["a", "b", "c"]
    mock = MockLLM([valid_llm_json(["a", "b", "c"])])
    client = make_client(mock)
    response = client.post("/api/suggestions", json=request_body(ids))
    assert response.status_code == 200
    assert response.json()["evaluations"] is None
    assert "DEBUG MODE" not in mock.calls[0]
