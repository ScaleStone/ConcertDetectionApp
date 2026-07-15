from uuid import uuid4

from app.config import Settings
from app.models.schemas import LyricsSongRequest, SongIdentity, SongLyrics


class LyricsProvider:
    def __init__(self, settings: Settings) -> None:
        self.settings = settings

    async def lyrics_for(self, songs: list[LyricsSongRequest]) -> list[SongLyrics]:
        # The MVP intentionally avoids scraping lyric websites. Configure a licensed
        # provider here; until then, return unavailable lyric records with identities.
        responses: list[SongLyrics] = []
        for song in songs:
            responses.append(
                SongLyrics(
                    id=str(uuid4()),
                    song=SongIdentity(id=song.id, title=song.title, artist=song.artist, isrc=song.isrc),
                    lyrics=None,
                    languageCode=None,
                    providerAttribution=None,
                    canDisplay=False,
                )
            )
        return responses
