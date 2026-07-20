from __future__ import annotations

from fastapi import APIRouter, Depends

from app.config import Settings, get_settings
from app.models.schemas import ConcertCandidate, ConcertSearchRequest
from app.security import require_api_key
from app.services.cache import TTLCache
from app.services.setlist_fm import SetlistFMClient

router = APIRouter(prefix="/api/concerts", tags=["concerts"], dependencies=[Depends(require_api_key)])

# Created eagerly at import time so there is no lazy-init race between
# concurrent first requests.
cache = TTLCache(get_settings().cache_ttl_seconds)


def get_client(settings: Settings = Depends(get_settings)) -> SetlistFMClient:
    return SetlistFMClient(settings=settings, cache=cache)


@router.post("/search", response_model=list[ConcertCandidate])
async def search_concerts(
    request: ConcertSearchRequest,
    client: SetlistFMClient = Depends(get_client),
) -> list[ConcertCandidate]:
    return await client.search_concerts(
        artist=request.artist,
        event_date=request.date,
        venue=request.venue,
        latitude=request.latitude,
        longitude=request.longitude,
        city_name=request.cityName,
        state_code=request.stateCode,
        country_code=request.countryCode,
    )
