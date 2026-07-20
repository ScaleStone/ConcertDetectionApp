from __future__ import annotations

import asyncio
import logging
import math
from datetime import date, datetime, time, timedelta
from time import monotonic
from urllib.parse import urlencode

from fastapi import HTTPException

from app.config import Settings
from app.models.schemas import ConcertCandidate, ConcertSetlist, SetlistOccurrence
from app.services.cache import TTLCache
from app.services.http_client import get_shared_client
from app.services.text import normalize_title


logger = logging.getLogger("concert_song_finder.setlist_fm")


KNOWN_VENUES = [
    {
        "name": "Climate Pledge Arena",
        "city": "Seattle",
        "stateCode": "WA",
        "countryCode": "US",
        "latitude": 47.6221,
        "longitude": -122.3540,
        "matchRadiusKm": 0.35,
    },
]

# setlist.fm's free tier allows roughly 2 requests/second. Keep a small gap
# between upstream calls and cap the total calls a single search can make.
_MIN_REQUEST_INTERVAL_SECONDS = 0.55
_MAX_UPSTREAM_REQUESTS_PER_SEARCH = 12
_MAX_SEARCH_PAGES = 3

_throttle_lock = asyncio.Lock()
_last_request_at = 0.0


class SetlistFMClient:
    base_url = "https://api.setlist.fm/rest/1.0"

    def __init__(self, settings: Settings, cache: TTLCache) -> None:
        self.settings = settings
        self.cache = cache

    async def search_concerts(
        self,
        artist: str | None,
        event_date: date | None,
        venue: str | None,
        latitude: float | None,
        longitude: float | None,
        city_name: str | None,
        state_code: str | None,
        country_code: str | None,
    ) -> list[ConcertCandidate]:
        if not self.settings.setlist_fm_api_key:
            logger.warning("setlist.fm search skipped because SETLIST_FM_API_KEY is not configured")
            return []

        inferred_venue = self._infer_venue_from_location(
            latitude=latitude,
            longitude=longitude,
            city_name=city_name,
            state_code=state_code,
            country_code=country_code,
        )
        effective_venue = venue or inferred_venue
        if inferred_venue and not venue:
            logger.info("setlist.fm inferred venue from GPS venue=%s", inferred_venue)

        cache_key = self._search_cache_key(
            artist=artist,
            event_date=event_date,
            venue=effective_venue,
            city_name=city_name,
            state_code=state_code,
            country_code=country_code,
        )
        cached = self.cache.get(cache_key)
        if cached is not None:
            logger.info("setlist.fm search cache hit candidates=%s", len(cached))
            return list(cached)

        artist_mbid = await self._artist_mbid_for_name(artist)
        if artist and artist_mbid:
            logger.info("setlist.fm resolved artist=%s mbid=%s", artist, artist_mbid)
        elif artist:
            logger.info("setlist.fm could not resolve artist mbid for artist=%s; using artistName search", artist)

        search_attempts = self._search_attempts(
            artist=artist,
            artist_mbid=artist_mbid,
            event_date=event_date,
            venue=effective_venue,
            city_name=city_name,
            state_code=state_code,
            country_code=country_code,
        )
        logger.info(
            "setlist.fm search prepared attempts=%s city=%s state=%s country=%s",
            len(search_attempts),
            city_name,
            state_code,
            country_code,
        )

        candidates_by_id: dict[str, ConcertCandidate] = {}
        requests_used = 0
        rate_limited = False
        for label, params in search_attempts:
            if requests_used >= _MAX_UPSTREAM_REQUESTS_PER_SEARCH:
                logger.info("setlist.fm search stopped after reaching request budget=%s", requests_used)
                break
            candidate_count_before_attempt = len(candidates_by_id)
            try:
                raw_setlists, pages_fetched = await self._search_setlists_paginated(
                    params,
                    max_pages=min(_MAX_SEARCH_PAGES, _MAX_UPSTREAM_REQUESTS_PER_SEARCH - requests_used),
                )
                requests_used += pages_fetched
            except HTTPException as exc:
                requests_used += 1
                if exc.status_code == 404:
                    logger.info("setlist.fm search attempt=%s returned no setlists", label)
                    continue
                if exc.status_code == 429 and candidates_by_id:
                    # Rate limited mid-search: keep what we already found
                    # instead of discarding good partial results.
                    logger.warning(
                        "setlist.fm rate limited during attempt=%s; returning %s partial candidates",
                        label,
                        len(candidates_by_id),
                    )
                    rate_limited = True
                    break
                raise

            logger.info(
                "setlist.fm search attempt=%s raw_count=%s pages=%s",
                label,
                len(raw_setlists),
                pages_fetched,
            )
            for item in raw_setlists:
                candidate = self._candidate_from_setlist(
                    item,
                    requested_date=event_date,
                    requested_city=city_name,
                    requested_state_code=state_code,
                    requested_country_code=country_code,
                    requested_artist=artist,
                    requested_venue=effective_venue,
                )
                if candidate is None:
                    continue
                if artist and not self._artist_matches(candidate.artistName, artist):
                    logger.info(
                        "setlist.fm discarded unrelated artist candidate requested=%s candidate=%s id=%s",
                        artist,
                        candidate.artistName,
                        candidate.id,
                    )
                    continue
                existing = candidates_by_id.get(candidate.id)
                if existing is None or candidate.confidenceScore > existing.confidenceScore:
                    candidates_by_id[candidate.id] = candidate
            if inferred_venue and len(candidates_by_id) > candidate_count_before_attempt and params.get("venueName"):
                logger.info(
                    "setlist.fm stopping search after successful GPS-inferred venue attempt=%s candidates=%s",
                    label,
                    len(candidates_by_id),
                )
                break
            if len(candidates_by_id) >= 10:
                break

        candidates = list(candidates_by_id.values())
        if inferred_venue and not venue:
            venue_filtered_candidates = [
                candidate
                for candidate in candidates
                if self._normalized_venue_name(candidate.venueName) == self._normalized_venue_name(inferred_venue)
            ]
            if venue_filtered_candidates:
                logger.info(
                    "setlist.fm GPS venue filter applied inferredVenue=%s before=%s after=%s",
                    inferred_venue,
                    len(candidates),
                    len(venue_filtered_candidates),
                )
                candidates = venue_filtered_candidates
        candidates.sort(key=lambda candidate: candidate.confidenceScore, reverse=True)
        for candidate in candidates:
            logger.info(
                "setlist.fm candidate id=%s artist=%s venue=%s city=%s date=%s score=%s",
                candidate.id,
                candidate.artistName,
                candidate.venueName,
                candidate.city,
                candidate.eventDate,
                candidate.confidenceScore,
            )
        if not rate_limited:
            # Store a copy so callers cannot mutate the cached list.
            self.cache.set(cache_key, list(candidates))
        return candidates

    def _search_cache_key(
        self,
        artist: str | None,
        event_date: date | None,
        venue: str | None,
        city_name: str | None,
        state_code: str | None,
        country_code: str | None,
    ) -> str:
        def norm(value: str | None) -> str:
            return (value or "").strip().casefold()

        return "search:" + urlencode(
            [
                ("artist", norm(artist)),
                ("date", event_date.isoformat() if event_date else ""),
                ("venue", norm(venue)),
                ("city", norm(city_name)),
                ("state", norm(state_code)),
                ("country", norm(country_code)),
            ]
        )

    async def _search_setlists_paginated(
        self,
        params: dict[str, str],
        max_pages: int,
    ) -> tuple[list[dict], int]:
        """Fetch up to max_pages pages of search results, aggregating items."""
        aggregated: list[dict] = []
        page = 1
        pages_fetched = 0
        while page <= max(1, max_pages):
            page_params = dict(params)
            if page > 1:
                page_params["p"] = str(page)
            try:
                payload = await self._get("/search/setlists", params=page_params)
            except HTTPException as exc:
                if exc.status_code == 404 and page > 1:
                    break
                if pages_fetched:
                    # Keep earlier pages if a later page fails.
                    logger.warning(
                        "setlist.fm pagination stopped early page=%s status=%s", page, exc.status_code
                    )
                    break
                raise
            pages_fetched += 1
            aggregated.extend(payload.get("setlist", []))

            total = payload.get("total")
            items_per_page = payload.get("itemsPerPage")
            if not isinstance(total, int) or not isinstance(items_per_page, int) or items_per_page <= 0:
                break
            if page * items_per_page >= total:
                break
            page += 1
        return aggregated, max(pages_fetched, 1)

    def _infer_venue_from_location(
        self,
        latitude: float | None,
        longitude: float | None,
        city_name: str | None,
        state_code: str | None,
        country_code: str | None,
    ) -> str | None:
        if latitude is None or longitude is None:
            return None

        normalized_city = city_name.casefold() if city_name else None
        normalized_state = state_code.casefold() if state_code else None
        normalized_country = country_code.casefold() if country_code else None

        nearest_name: str | None = None
        nearest_distance: float | None = None
        for venue in KNOWN_VENUES:
            if normalized_city and venue["city"].casefold() != normalized_city:
                continue
            if normalized_state and venue["stateCode"].casefold() != normalized_state:
                continue
            if normalized_country and venue["countryCode"].casefold() != normalized_country:
                continue

            distance = self._distance_km(
                latitude,
                longitude,
                venue["latitude"],
                venue["longitude"],
            )
            if distance <= venue["matchRadiusKm"] and (nearest_distance is None or distance < nearest_distance):
                nearest_name = venue["name"]
                nearest_distance = distance

        return nearest_name

    def _distance_km(self, latitude_a: float, longitude_a: float, latitude_b: float, longitude_b: float) -> float:
        earth_radius_km = 6371.0
        lat_a = math.radians(latitude_a)
        lat_b = math.radians(latitude_b)
        delta_lat = math.radians(latitude_b - latitude_a)
        delta_lon = math.radians(longitude_b - longitude_a)

        haversine = (
            math.sin(delta_lat / 2) ** 2
            + math.cos(lat_a) * math.cos(lat_b) * math.sin(delta_lon / 2) ** 2
        )
        return earth_radius_km * 2 * math.atan2(math.sqrt(haversine), math.sqrt(1 - haversine))

    def _normalized_venue_name(self, value: str | None) -> str:
        return "".join(character for character in (value or "").casefold() if character.isalnum())

    def _search_attempts(
        self,
        artist: str | None,
        artist_mbid: str | None,
        event_date: date | None,
        venue: str | None,
        city_name: str | None,
        state_code: str | None,
        country_code: str | None,
    ) -> list[tuple[str, dict[str, str]]]:
        def cleaned(value: str | None) -> str | None:
            if value is None:
                return None
            stripped = value.strip()
            return stripped or None

        artist = cleaned(artist)
        artist_mbid = cleaned(artist_mbid)
        venue = cleaned(venue)
        city_name = cleaned(city_name)
        state_code = cleaned(state_code)
        country_code = cleaned(country_code)

        artist_key = "artistMbid" if artist_mbid else "artistName"
        artist_value = artist_mbid or artist

        dates: list[tuple[str, date | None]] = [("exact-date", event_date)]
        if event_date is not None:
            dates.extend([
                ("previous-date", event_date - timedelta(days=1)),
                ("next-date", event_date + timedelta(days=1)),
            ])

        attempts: list[tuple[str, dict[str, str]]] = []

        def add(label: str, values: dict[str, str | None]) -> None:
            params = {key: value for key, value in values.items() if value}
            if not params:
                return
            fingerprint = urlencode(sorted(params.items()))
            if any(urlencode(sorted(existing.items())) == fingerprint for _, existing in attempts):
                return
            attempts.append((label, params))

        for date_label, candidate_date in dates:
            date_text = candidate_date.strftime("%d-%m-%Y") if candidate_date else None
            base = {
                artist_key: artist_value,
                "date": date_text,
                "venueName": venue,
            }

            add(
                f"{date_label}:artist-venue-city-state-country",
                {
                    **base,
                    "cityName": city_name,
                    "stateCode": state_code,
                    "countryCode": country_code,
                },
            )
            add(
                f"{date_label}:artist-city-state-country",
                {
                    artist_key: artist_value,
                    "date": date_text,
                    "cityName": city_name,
                    "stateCode": state_code,
                    "countryCode": country_code,
                },
            )
            add(
                f"{date_label}:artist-city-country",
                {
                    artist_key: artist_value,
                    "date": date_text,
                    "cityName": city_name,
                    "countryCode": country_code,
                },
            )
            # Location-only attempts must stay bounded: require both a date and
            # a city so we never issue undated or worldwide queries.
            if date_text and city_name:
                add(
                    f"{date_label}:location-city-state-country",
                    {
                        "date": date_text,
                        "cityName": city_name,
                        "stateCode": state_code,
                        "countryCode": country_code,
                    },
                )
                add(
                    f"{date_label}:location-city-country",
                    {
                        "date": date_text,
                        "cityName": city_name,
                        "countryCode": country_code,
                    },
                )
                add(
                    f"{date_label}:location-city",
                    {
                        "date": date_text,
                        "cityName": city_name,
                    },
                )
            # An artist-date attempt without an artist would collapse to a
            # worldwide date-only search; require the artist.
            if artist_value and date_text:
                add(
                    f"{date_label}:artist-date",
                    {
                        artist_key: artist_value,
                        "date": date_text,
                    },
                )

        # Undated fallback needs both an artist and a city to stay bounded.
        if artist_value and city_name:
            add(
                "artist-location-without-date",
                {
                    artist_key: artist_value,
                    "cityName": city_name,
                    "stateCode": state_code,
                    "countryCode": country_code,
                },
            )

        return attempts

    async def _artist_mbid_for_name(self, artist: str | None) -> str | None:
        artist = (artist or "").strip()
        if not artist:
            return None

        cache_key = f"artist-mbid:{artist.casefold()}"
        cached = self.cache.get(cache_key)
        if cached is not None:
            return cached or None

        try:
            payload = await self._get("/search/artists", params={"artistName": artist})
        except HTTPException as exc:
            if exc.status_code == 404:
                return None
            if exc.status_code == 429:
                # Fall back to artistName search instead of failing the
                # whole concert lookup.
                logger.warning("setlist.fm rate limited during artist mbid lookup; falling back to name search")
                return None
            raise

        for item in payload.get("artist", []):
            name = item.get("name") or ""
            mbid = item.get("mbid")
            if mbid and self._artist_matches(name, artist):
                self.cache.set(cache_key, mbid)
                return mbid

        self.cache.set(cache_key, "")
        return None

    def _artist_matches(self, candidate: str | None, requested: str | None) -> bool:
        candidate_key = self._normalized_artist(candidate)
        requested_key = self._normalized_artist(requested)
        if not candidate_key or not requested_key:
            return False
        return candidate_key == requested_key

    def _normalized_artist(self, value: str | None) -> str:
        return "".join(character for character in (value or "").casefold() if character.isalnum())

    async def fetch_setlist(self, setlist_id: str) -> ConcertSetlist:
        if not self.settings.setlist_fm_api_key:
            raise HTTPException(status_code=503, detail={"code": "missing_setlist_key", "message": "SETLIST_FM_API_KEY is not configured."})

        cache_key = f"setlist:{setlist_id}"
        cached = self.cache.get(cache_key)
        if cached is not None:
            return cached

        payload = await self._get(f"/setlist/{setlist_id}")
        setlist = self._setlist_from_payload(payload)
        logger.info(
            "setlist.fm setlist fetched id=%s artist=%s venue=%s songs=%s",
            setlist.id,
            setlist.artistName,
            setlist.venueName,
            len(setlist.occurrences),
        )
        self.cache.set(cache_key, setlist)
        return setlist

    async def _throttle(self) -> None:
        global _last_request_at
        async with _throttle_lock:
            now = monotonic()
            wait = _last_request_at + _MIN_REQUEST_INTERVAL_SECONDS - now
            if wait > 0:
                await asyncio.sleep(wait)
            _last_request_at = monotonic()

    async def _get(self, path: str, params: dict[str, str] | None = None) -> dict:
        headers = {
            "Accept": "application/json",
            "x-api-key": self.settings.setlist_fm_api_key or "",
        }
        await self._throttle()
        client = await get_shared_client()
        response = await client.get(f"{self.base_url}{path}", params=params, headers=headers)
        logger.info("setlist.fm response path=%s status=%s", path, response.status_code)
        if response.status_code == 404:
            raise HTTPException(status_code=404, detail={"code": "not_found", "message": "No setlist was found."})
        if response.status_code == 429:
            logger.warning("setlist.fm rate limited")
            raise HTTPException(status_code=429, detail={"code": "rate_limited", "message": "setlist.fm rate limit reached."})
        if response.status_code >= 400:
            logger.error("setlist.fm provider error status=%s body=%s", response.status_code, response.text[:500])
            raise HTTPException(status_code=502, detail={"code": "setlist_provider_error", "message": "setlist.fm request failed."})
        try:
            return response.json()
        except ValueError:
            logger.error("setlist.fm returned a non-JSON body path=%s", path)
            raise HTTPException(status_code=502, detail={"code": "setlist_provider_error", "message": "setlist.fm returned an invalid response."})

    def _candidate_from_setlist(
        self,
        item: dict,
        requested_date: date | None,
        requested_city: str | None,
        requested_state_code: str | None,
        requested_country_code: str | None,
        requested_artist: str | None,
        requested_venue: str | None,
    ) -> ConcertCandidate | None:
        setlist_id = item.get("id")
        if not setlist_id:
            logger.warning("setlist.fm search item skipped because it has no id")
            return None
        event_date = self._parse_event_date(item.get("eventDate"))
        venue = item.get("venue") or {}
        city_payload = venue.get("city") or {}
        city = city_payload.get("name")
        artist_name = (item.get("artist") or {}).get("name") or "Unknown Artist"
        score = 0.35 + (0.08 if venue.get("name") else 0)
        if requested_artist and artist_name.casefold() == requested_artist.casefold():
            score += 0.2
        if requested_venue and venue.get("name") and venue.get("name").casefold() == requested_venue.casefold():
            score += 0.1
        if requested_date and event_date and event_date.date() == requested_date:
            score += 0.25
        elif requested_date and event_date and abs((event_date.date() - requested_date).days) == 1:
            score += 0.12
        if requested_city and city and city.casefold() == requested_city.casefold():
            score += 0.1
        if requested_state_code and city_payload.get("stateCode") == requested_state_code:
            score += 0.05
        country = city_payload.get("country") or {}
        if requested_country_code and country.get("code") == requested_country_code:
            score += 0.05
        return ConcertCandidate(
            id=setlist_id,
            artistName=artist_name,
            venueName=venue.get("name"),
            city=city,
            eventDate=event_date,
            confidenceScore=min(score, 0.95),
            attributionURL=item.get("url"),
        )

    def _setlist_from_payload(self, payload: dict) -> ConcertSetlist:
        setlist_id = payload.get("id")
        artist_name = (payload.get("artist") or {}).get("name") or "Unknown Artist"
        venue = payload.get("venue") or {}
        occurrences: list[SetlistOccurrence] = []
        overall_index = 0
        for set_number, set_payload in enumerate(((payload.get("sets") or {}).get("set") or [])):
            set_name = set_payload.get("name")
            is_encore = "encore" in (set_name or "").lower() or set_payload.get("encore") is not None
            for song_index, song in enumerate(set_payload.get("song") or []):
                title = song.get("name") or "Unknown Song"
                cover = song.get("cover") or {}
                occurrence_artist = cover.get("name") or artist_name
                occurrence_id = f"{setlist_id}-{set_number}-{song_index}-{overall_index}"
                occurrences.append(
                    SetlistOccurrence(
                        id=occurrence_id,
                        setlistID=setlist_id,
                        setNumber=set_number,
                        songIndex=song_index,
                        overallIndex=overall_index,
                        title=title,
                        normalizedTitle=normalize_title(title),
                        artist=occurrence_artist,
                        setName=set_name,
                        isEncore=is_encore,
                        isTape=bool(song.get("tape", False)),
                        notes=song.get("info"),
                    )
                )
                overall_index += 1

        return ConcertSetlist(
            id=setlist_id,
            artistName=artist_name,
            venueName=venue.get("name"),
            eventDate=self._parse_event_date(payload.get("eventDate")),
            occurrences=occurrences,
            attributionURL=payload.get("url"),
            versionID=payload.get("versionId") or payload.get("lastUpdated") or setlist_id,
        )

    def _parse_event_date(self, value: str | None) -> datetime | None:
        if not value:
            return None
        try:
            parsed = datetime.strptime(value, "%d-%m-%Y").date()
        except ValueError:
            logger.warning("setlist.fm returned an unparseable eventDate=%r; ignoring", value)
            return None
        return datetime.combine(parsed, time.min)
