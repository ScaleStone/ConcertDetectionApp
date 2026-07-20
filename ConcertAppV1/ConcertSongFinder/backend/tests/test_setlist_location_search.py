from __future__ import annotations

from datetime import date

import pytest
from fastapi import HTTPException

from app.config import Settings
from app.services.cache import TTLCache
from app.services.setlist_fm import SetlistFMClient


class FakeSetlistFMClient(SetlistFMClient):
    def __init__(self) -> None:
        super().__init__(
            settings=Settings(setlist_fm_api_key="test-key"),
            cache=TTLCache(ttl_seconds=0),
        )
        self.requests: list[dict[str, str]] = []

    async def _get(self, path: str, params: dict[str, str] | None = None) -> dict:
        self.requests.append(params or {})
        if path == "/search/artists" and params and params.get("artistName") == "Lil Tecca":
            return {"artist": [{"name": "Lil Tecca", "mbid": "lil-tecca-mbid"}]}
        if path == "/search/setlists" and params and params.get("artistMbid") == "lil-tecca-mbid":
            return {
                "setlist": [
                    {
                        "id": "wrong-artist",
                        "eventDate": "10-03-2024",
                        "url": "https://www.setlist.fm/setlist/wrong",
                        "artist": {"name": "Wrong Artist"},
                        "venue": {
                            "name": "Somewhere",
                            "city": {
                                "name": "New York",
                                "stateCode": "NY",
                                "country": {"code": "US"},
                            },
                        },
                    },
                    {
                        "id": "lil-tecca",
                        "eventDate": "10-03-2024",
                        "url": "https://www.setlist.fm/setlist/lil-tecca",
                        "artist": {"name": "Lil Tecca"},
                        "venue": {
                            "name": "Terminal 5",
                            "city": {
                                "name": "New York",
                                "stateCode": "NY",
                                "country": {"code": "US"},
                            },
                        },
                    },
                ]
            }
        if params and params.get("venueName") == "Climate Pledge Arena":
            return {
                "setlist": [
                    {
                        "id": "sahbabii",
                        "eventDate": "24-06-2026",
                        "url": "https://www.setlist.fm/setlist/sahbabii",
                        "artist": {"name": "SahBabii"},
                        "venue": {
                            "name": "Climate Pledge Arena",
                            "city": {
                                "name": "Seattle",
                                "stateCode": "WA",
                                "country": {"code": "US"},
                            },
                        },
                    },
                    {
                        "id": "don",
                        "eventDate": "24-06-2026",
                        "url": "https://www.setlist.fm/setlist/don-toliver",
                        "artist": {"name": "Don Toliver"},
                        "venue": {
                            "name": "Climate Pledge Arena",
                            "city": {
                                "name": "Seattle",
                                "stateCode": "WA",
                                "country": {"code": "US"},
                            },
                        },
                    },
                ]
            }
        if params and params.get("cityName") == "Seattle" and "stateCode" not in params:
            return {
                "setlist": [
                    {
                        "id": "abc123",
                        "eventDate": "24-06-2026",
                        "url": "https://www.setlist.fm/setlist/example",
                        "artist": {"name": "Don Toliver"},
                        "venue": {
                            "name": "Climate Pledge Arena",
                            "city": {
                                "name": "Seattle",
                                "stateCode": "WA",
                                "country": {"code": "US"},
                            },
                        },
                    }
                ]
            }
        raise HTTPException(status_code=404, detail={"code": "not_found"})


@pytest.mark.anyio
async def test_location_search_broadens_after_exact_location_miss() -> None:
    client = FakeSetlistFMClient()

    candidates = await client.search_concerts(
        artist=None,
        event_date=date(2026, 6, 24),
        venue=None,
        latitude=None,
        longitude=None,
        city_name="Seattle",
        state_code="WA",
        country_code="US",
    )

    assert len(candidates) == 1
    assert candidates[0].artistName == "Don Toliver"
    assert candidates[0].venueName == "Climate Pledge Arena"
    assert {"date": "24-06-2026", "cityName": "Seattle", "stateCode": "WA", "countryCode": "US"} in client.requests
    assert {"date": "24-06-2026", "cityName": "Seattle", "countryCode": "US"} in client.requests


@pytest.mark.anyio
async def test_location_search_uses_gps_inferred_venue() -> None:
    client = FakeSetlistFMClient()

    candidates = await client.search_concerts(
        artist=None,
        event_date=date(2026, 6, 24),
        venue=None,
        latitude=47.6225,
        longitude=-122.354,
        city_name="Seattle",
        state_code="WA",
        country_code="US",
    )

    assert {"SahBabii", "Don Toliver"}.issubset({candidate.artistName for candidate in candidates})
    assert {candidate.venueName for candidate in candidates} == {"Climate Pledge Arena"}
    assert {
        "date": "24-06-2026",
        "venueName": "Climate Pledge Arena",
        "cityName": "Seattle",
        "stateCode": "WA",
        "countryCode": "US",
    } in client.requests


@pytest.mark.anyio
async def test_artist_search_uses_mbid_and_discards_unrelated_artists() -> None:
    client = FakeSetlistFMClient()

    candidates = await client.search_concerts(
        artist="Lil Tecca",
        event_date=date(2024, 3, 10),
        venue=None,
        latitude=None,
        longitude=None,
        city_name=None,
        state_code=None,
        country_code=None,
    )

    assert [candidate.artistName for candidate in candidates] == ["Lil Tecca"]
    assert {"artistName": "Lil Tecca"} in client.requests
    assert {"artistMbid": "lil-tecca-mbid", "date": "10-03-2024"} in client.requests
