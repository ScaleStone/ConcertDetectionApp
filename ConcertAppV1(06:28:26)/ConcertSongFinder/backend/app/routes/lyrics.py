from fastapi import APIRouter, Depends

from app.config import Settings, get_settings
from app.models.schemas import LyricsBatchRequest, SongLyrics
from app.security import require_api_key
from app.services.lyrics_provider import LyricsProvider

router = APIRouter(prefix="/api/lyrics", tags=["lyrics"], dependencies=[Depends(require_api_key)])


def get_provider(settings: Settings = Depends(get_settings)) -> LyricsProvider:
    return LyricsProvider(settings=settings)


@router.post("/batch", response_model=list[SongLyrics])
async def lyrics_batch(
    request: LyricsBatchRequest,
    provider: LyricsProvider = Depends(get_provider),
) -> list[SongLyrics]:
    return await provider.lyrics_for(request.songs)
