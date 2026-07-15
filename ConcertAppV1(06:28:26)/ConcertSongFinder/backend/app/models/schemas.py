from __future__ import annotations

from datetime import date as DateType
from datetime import datetime as DateTime
from pydantic import BaseModel, Field


class ConcertSearchRequest(BaseModel):
    artist: str | None = None
    date: DateType | None = None
    venue: str | None = None
    latitude: float | None = None
    longitude: float | None = None
    cityName: str | None = None
    stateCode: str | None = None
    countryCode: str | None = None


class ConcertCandidate(BaseModel):
    id: str
    artistName: str
    venueName: str | None = None
    city: str | None = None
    eventDate: DateTime | None = None
    confidenceScore: float = 0
    attributionURL: str | None = None


class SetlistOccurrence(BaseModel):
    id: str
    setlistID: str
    setNumber: int
    songIndex: int
    overallIndex: int
    title: str
    normalizedTitle: str
    artist: str
    setName: str | None = None
    isEncore: bool = False
    isTape: bool = False
    notes: str | None = None


class ConcertSetlist(BaseModel):
    id: str
    artistName: str
    venueName: str | None = None
    eventDate: DateTime | None = None
    occurrences: list[SetlistOccurrence]
    attributionURL: str | None = None
    versionID: str


class LyricsSongRequest(BaseModel):
    id: str
    title: str
    artist: str
    isrc: str | None = None


class LyricsBatchRequest(BaseModel):
    songs: list[LyricsSongRequest] = Field(default_factory=list)


class SongIdentity(BaseModel):
    id: str
    title: str
    artist: str
    album: str | None = None
    isrc: str | None = None


class SongLyrics(BaseModel):
    id: str
    song: SongIdentity
    lyrics: str | None = None
    languageCode: str | None = None
    providerAttribution: str | None = None
    canDisplay: bool = False


class ErrorResponse(BaseModel):
    code: str
    message: str
