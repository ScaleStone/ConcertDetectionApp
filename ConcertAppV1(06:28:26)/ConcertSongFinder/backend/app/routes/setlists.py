from fastapi import APIRouter, Depends

from app.config import Settings, get_settings
from app.models.schemas import ConcertSetlist
from app.routes.concerts import get_client
from app.security import require_api_key
from app.services.setlist_fm import SetlistFMClient

router = APIRouter(prefix="/api/setlists", tags=["setlists"], dependencies=[Depends(require_api_key)])


@router.get("/{setlist_id}", response_model=ConcertSetlist)
async def fetch_setlist(
    setlist_id: str,
    client: SetlistFMClient = Depends(get_client),
    settings: Settings = Depends(get_settings),
) -> ConcertSetlist:
    _ = settings
    return await client.fetch_setlist(setlist_id)
