from __future__ import annotations

from fastapi.testclient import TestClient

from app.config import Settings, get_settings
from app.main import app


def _client_with(settings: Settings) -> TestClient:
    app.dependency_overrides[get_settings] = lambda: settings
    return TestClient(app)


def teardown_function() -> None:
    app.dependency_overrides.clear()


def test_health_requires_no_auth() -> None:
    client = _client_with(Settings(backend_api_key="secret-token"))
    response = client.get("/health")
    assert response.status_code == 200


def test_api_rejects_missing_key() -> None:
    client = _client_with(Settings(backend_api_key="secret-token"))
    response = client.post("/api/lyrics/batch", json={"songs": []})
    assert response.status_code == 401
    body = response.json()
    assert body == {"code": "unauthorized", "message": "Missing or invalid API key."}


def test_api_rejects_wrong_key() -> None:
    client = _client_with(Settings(backend_api_key="secret-token"))
    response = client.post(
        "/api/lyrics/batch",
        json={"songs": []},
        headers={"X-API-Key": "wrong"},
    )
    assert response.status_code == 401


def test_api_accepts_correct_key() -> None:
    client = _client_with(Settings(backend_api_key="secret-token"))
    response = client.post(
        "/api/lyrics/batch",
        json={"songs": []},
        headers={"X-API-Key": "secret-token"},
    )
    assert response.status_code == 200
    assert response.json() == []


def test_auth_disabled_when_key_unset() -> None:
    client = _client_with(Settings(backend_api_key=None))
    response = client.post("/api/lyrics/batch", json={"songs": []})
    assert response.status_code == 200


def test_http_errors_use_flat_contract() -> None:
    # Setlist fetch without a setlist.fm key raises HTTPException 503 with a
    # structured detail; the response body must be flat {code, message}.
    client = _client_with(Settings(backend_api_key=None, setlist_fm_api_key=None))
    response = client.get("/api/setlists/some-id")
    assert response.status_code == 503
    body = response.json()
    assert body["code"] == "missing_setlist_key"
    assert "message" in body
    assert "detail" not in body
