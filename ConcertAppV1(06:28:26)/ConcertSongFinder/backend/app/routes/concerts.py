from fastapi import APIRouter, Depends

from app.config import Settings, get_settings
from app.models.schemas import ConcertCandidate, ConcertSearchRequest
from app.services.cache import TTLCache
from app.services.setlist_fm import SetlistFMClient

router = APIRouter(prefix="/api/concerts", tags=["concerts"])
cache: TTLCache | None = None


def get_client(settings: Settings = Depends(get_settings)) -> SetlistFMClient:
    global cache
    if cache is None:
        cache = TTLCache(settings.cache_ttl_seconds)
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
